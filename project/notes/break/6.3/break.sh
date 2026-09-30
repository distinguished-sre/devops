#!/usr/bin/env bash
# Поломки для урока 6.3 «Деплой на ВМ». Запуск на ВМ notes-vm: sudo bash break.sh 1|2|3|fix
# Трогает только: правило DROP на порт 80 (метка break-6.3), права authorized_keys
# пользователя deploy и файл /opt/notes/compose.break.yml.
set -euo pipefail

APP_DIR=/opt/notes
AUTH_KEYS=/home/deploy/.ssh/authorized_keys
BREAK_FILE=$APP_DIR/compose.break.yml

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_stack() {
  if [[ ! -f $APP_DIR/compose.prod.yml ]] || ! command -v docker >/dev/null 2>&1; then
    echo "Не найден $APP_DIR/compose.prod.yml или docker. Сначала пройди задания 1 и 2 урока 6.3." >&2
    exit 1
  fi
}

# docker compose под пользователем deploy, с теми же файлами, что использует deploy.sh.
# Тег берём из .current-tag, а если деплоя ещё не было, из образа, который уже запущен.
dc() {
  local tag
  tag=$(cat "$APP_DIR/.current-tag" 2>/dev/null || echo "${NOTES_TAG:-0.4.1}")
  runuser -u deploy -- env NOTES_TAG="$tag" APP_VERSION="$tag" \
    docker compose --project-directory "$APP_DIR" -f compose.yml -f compose.prod.yml "$@"
}

# Правило в DOCKER-USER: порты, опубликованные Docker, идут через FORWARD, а не INPUT.
# Условие ctstate DNAT ловит только входящие соединения на опубликованный порт,
# исходящие запросы контейнеров (apt, pull) не задеваются.
drop_rule() {
  iptables "$@" DOCKER-USER -p tcp -m conntrack --ctstate DNAT --ctorigdstport 80 \
    -m comment --comment break-6.3 -j DROP
}

case "${1:-}" in
  1)
    need_root 1; need_stack
    if ! iptables -n -L DOCKER-USER >/dev/null 2>&1; then
      echo "Нет цепочки DOCKER-USER: Docker не запущен?" >&2
      exit 1
    fi
    drop_rule -C 2>/dev/null || drop_rule -I
    echo "Сценарий 1 готов. Проверь снаружи (с ноутбука): curl -m 5 http://<твой домен>/"
    ;;
  2)
    need_root 2
    if [[ ! -f $AUTH_KEYS ]]; then
      echo "Нет $AUTH_KEYS. Сначала пройди задание 1 урока 6.3." >&2
      exit 1
    fi
    chmod 666 "$AUTH_KEYS"
    echo "Сценарий 2 готов. Проверь с ноутбука: ssh -v -i ~/.ssh/notes-deploy deploy@<твой домен> true"
    ;;
  3)
    need_root 3; need_stack
    cat > "$BREAK_FILE" <<'YAML'
# Поломка учебного сценария 3: приложение слушает только loopback внутри контейнера
services:
  notes:
    environment:
      HOST: 127.0.0.1
YAML
    dc -f compose.break.yml up -d notes
    echo "Сценарий 3 готов. Проверь: curl -sSi https://<твой домен>/healthz"
    ;;
  fix)
    need_root fix
    # Независимые поломки чиним первыми: они не зависят от состояния стека.
    if command -v iptables >/dev/null 2>&1 && iptables -n -L DOCKER-USER >/dev/null 2>&1; then
      while drop_rule -C 2>/dev/null; do drop_rule -D; done
    fi
    if [[ -f $AUTH_KEYS ]]; then
      chmod 600 "$AUTH_KEYS"
    fi
    if [[ -f $BREAK_FILE ]]; then
      rm -f "$BREAK_FILE"
      # без compose.break.yml контейнер notes пересоздаётся с настройками из compose.yml
      dc up -d notes
    fi
    echo "Всё возвращено: порт 80 открыт, права authorized_keys 600, notes слушает по-прежнему."
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
