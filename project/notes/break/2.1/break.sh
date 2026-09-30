#!/usr/bin/env bash
# Поломки для урока 2.1 «Адреса и маршруты». Запуск: sudo bash break.sh 1|2|3|fix
# Меняет настройки «Заметок», файрвол и маршруты: только для учебной ВМ.
set -euo pipefail

ENV_FILE=/etc/notes/notes.env
# Метка «маршрут создал сценарий 3»: fix удаляет маршрут, только если она есть.
# /run очищается при перезагрузке, как и сам маршрут.
ROUTE_MARK=/run/break-2.1-route

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_notes() {
  if [[ ! -f $ENV_FILE ]] || ! systemctl cat notes >/dev/null 2>&1; then
    echo "Не найден сервис notes или $ENV_FILE. Сначала пройди урок 1.8." >&2
    exit 1
  fi
}

need_iptables() {
  if ! command -v iptables >/dev/null 2>&1; then
    apt-get install -y -qq iptables >/dev/null
  fi
}

# Меняет HOST и перезапускает сервис. reset-failed снимает счётчик частых перезапусков
# (иначе systemd после нескольких запусков скрипта подряд откажется стартовать сервис),
# затем ждём до 5 секунд, пока сервис не станет active и не начнёт слушать $1:8080.
set_host() {
  sed -i "s/^HOST=.*/HOST=$1/" "$ENV_FILE"
  systemctl reset-failed notes 2>/dev/null || true
  systemctl restart notes || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if systemctl is-active -q notes && listening "$1"; then return 0; fi
    sleep 0.5
  done
  echo "Сервис notes не начал слушать $1:8080, смотри: journalctl -u notes -n 20" >&2
  return 1
}

# Слушает ли кто-то ровно адрес $1 и порт 8080.
listening() {
  ss -ltnH "sport = :8080" | awk '{print $4}' | grep -qx "$1:8080"
}

# Сервис в нужном состоянии: HOST=$1 в файле, сервис active и слушает $1:8080.
host_ok() {
  grep -q "^HOST=$1\$" "$ENV_FILE" && systemctl is-active -q notes && listening "$1"
}

# Метка в комментарии отличает правило упражнения от правил ученика: fix удаляет только его.
drop_rule() {
  iptables "$@" -p tcp -m tcp --dport 8080 -m comment --comment break-2.1 -j DROP
}

case "${1:-}" in
  1)
    need_root 1; need_notes
    host_ok 127.0.0.2 || set_host 127.0.0.2
    echo "Сценарий 1 готов. Проверь: curl -sS --max-time 3 http://127.0.0.1:8080/healthz"
    ;;
  2)
    need_root 2; need_notes; need_iptables
    # В начало цепочки, чтобы правило сработало раньше разрешающих (например, для lo).
    drop_rule -C INPUT 2>/dev/null || drop_rule -I INPUT 1
    echo "Сценарий 2 готов. Проверь: curl -sS --max-time 3 http://127.0.0.1:8080/healthz"
    ;;
  3)
    need_root 3
    if ip route show 1.1.1.1/32 | grep -q .; then
      if [[ -f $ROUTE_MARK ]] && ip route show 1.1.1.1/32 | grep -q '^unreachable'; then
        echo "Сценарий 3 уже запущен."
        exit 0
      fi
      echo "Маршрут до 1.1.1.1 уже настроен тобой, сценарий 3 его не трогает: $(ip route show 1.1.1.1/32)" >&2
      exit 1
    fi
    ip route add unreachable 1.1.1.1/32
    touch "$ROUTE_MARK"
    echo "Сценарий 3 готов. Проверь: ping -c 3 8.8.8.8 и ping -c 3 1.1.1.1"
    ;;
  fix)
    need_root fix
    # Сначала независимые поломки: они чинятся, даже если сервис не поднимется.
    if command -v iptables >/dev/null 2>&1; then
      while drop_rule -C INPUT 2>/dev/null; do drop_rule -D INPUT; done
    fi
    if [[ -f $ROUTE_MARK ]]; then
      if ip route show 1.1.1.1/32 | grep -q '^unreachable'; then
        ip route del unreachable 1.1.1.1/32
      fi
      rm -f "$ROUTE_MARK"
    fi
    if [[ -f $ENV_FILE ]] && ! host_ok 127.0.0.1; then
      set_host 127.0.0.1
    fi
    echo "Всё возвращено: HOST=127.0.0.1, правило DROP на 8080 удалено, маршрут до 1.1.1.1 восстановлен."
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
