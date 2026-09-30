#!/usr/bin/env bash
# Поломки для урока 6.4 «Managed-сервисы». Запуск на ВМ notes-vm: sudo bash break.sh 1|2|3|fix
# Трогает только: DATABASE_URL в /opt/notes/.env (копия в .env.break-6.4), правила DROP на порт 6432
# (метка break-6.4) и последовательность notes_id_seq в базе «Заметок».
# Ничего не создаёт и не удаляет в облаке.
set -euo pipefail

APP_DIR=/opt/notes
ENV_FILE=$APP_DIR/.env
BACKUP=$APP_DIR/.env.break-6.4
CA_HOST=/etc/notes/tls/yc-ca.pem

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

# Урок 6.4 (задание 5) выполнен: в .env адрес managed-кластера, сертификат на месте.
need_managed() {
  if ! grep -q '^DATABASE_URL=.*mdb\.yandexcloud\.net' "$ENV_FILE" 2>/dev/null || [[ ! -f $CA_HOST ]]; then
    echo "В $ENV_FILE нет адреса Managed PostgreSQL или нет $CA_HOST. Сначала выполни задания 2-5 урока 6.4." >&2
    exit 1
  fi
}

# docker compose под пользователем deploy с теми же файлами, что использует deploy.sh.
dc() {
  local tag
  tag=$(cat "$APP_DIR/.current-tag" 2>/dev/null || echo 0.4.1)
  runuser -u deploy -- env NOTES_TAG="$tag" \
    docker compose --project-directory "$APP_DIR" -f compose.yml -f compose.prod.yml "$@"
}

# Строка подключения для psql с хоста: в контейнере сертификат лежит в /certs, на ВМ в /etc/notes/tls.
host_url() {
  grep '^DATABASE_URL=' "$ENV_FILE" | cut -d= -f2- | sed "s#/certs/yc-ca.pem#$CA_HOST#"
}

# Правило и в DOCKER-USER (трафик контейнеров), и в OUTPUT (трафик самой ВМ):
# иначе проверка с хоста покажет «порт открыт», а контейнер всё равно не дойдёт.
drop_rule() {
  local chain=$1; shift
  iptables "$@" "$chain" -p tcp --dport 6432 -m comment --comment break-6.4 -j DROP
}

case "${1:-}" in
  1)
    need_root 1; need_managed
    [[ -f $BACKUP ]] || install -m 600 -o deploy -g deploy "$ENV_FILE" "$BACKUP"
    sed -i 's/sslmode=verify-full/sslmode=disable/' "$ENV_FILE"
    dc up -d notes
    echo "Сценарий 1 готов. Проверь: curl -sS https://<твой домен>/readyz и docker compose logs --tail 20 notes"
    ;;
  2)
    need_root 2; need_managed
    for chain in DOCKER-USER OUTPUT; do
      drop_rule "$chain" -C 2>/dev/null || drop_rule "$chain" -I
    done
    echo "Сценарий 2 готов. Проверь: curl -sS https://<твой домен>/readyz"
    ;;
  3)
    need_root 3; need_managed
    if ! command -v psql >/dev/null 2>&1; then
      echo "Нет psql: установи postgresql-client (задание 2 урока 6.4)." >&2
      exit 1
    fi
    if [[ $(psql "$(host_url)" -Atc "SELECT count(*) FROM notes;") -lt 1 ]]; then
      echo "В таблице notes нет строк. Добавь заметку через приложение и запусти сценарий снова." >&2
      exit 1
    fi
    psql "$(host_url)" -Atq -c "SELECT setval(pg_get_serial_sequence('notes', 'id'), 1, false);" >/dev/null
    echo "Сценарий 3 готов. Проверь: создай заметку через POST /notes и смотри ответ и логи notes."
    ;;
  fix)
    need_root fix
    # Независимые поломки чиним первыми: они не зависят от состояния стека.
    if command -v iptables >/dev/null 2>&1; then
      for chain in DOCKER-USER OUTPUT; do
        while drop_rule "$chain" -C 2>/dev/null; do drop_rule "$chain" -D; done
      done
    fi
    if [[ -f $BACKUP ]]; then
      cp -p "$BACKUP" "$ENV_FILE"
      rm -f "$BACKUP"
      dc up -d notes
    fi
    # Последовательность к максимальному id: для целой таблицы безопасно и при повторном запуске.
    if [[ -f $CA_HOST ]] && grep -q '^DATABASE_URL=.*mdb\.yandexcloud\.net' "$ENV_FILE" 2>/dev/null \
       && command -v psql >/dev/null 2>&1; then
      psql "$(host_url)" -Atq -c "SELECT setval(pg_get_serial_sequence('notes', 'id'), COALESCE((SELECT max(id) FROM notes), 1), (SELECT max(id) IS NOT NULL FROM notes));" >/dev/null
    fi
    echo "Всё возвращено: sslmode=verify-full, порт 6432 открыт, последовательность выровнена."
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
