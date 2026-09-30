#!/usr/bin/env bash
# Поломки для урока 4.4 «SQL и PostgreSQL». Запуск: bash break.sh 1|2|3|4|fix
# Работает только с Docker-ресурсами урока: контейнеры db и notes, сеть notes-net,
# база lab. Sudo не нужен, нужен доступ к docker (в ВМ из урока 1.1 он есть у ubuntu).
# Имена можно подменить переменными BREAK_DB, BREAK_APP, BREAK_NET, BREAK_ALIAS, BREAK_HOLDER.
set -euo pipefail

DB=${BREAK_DB:-db}                    # контейнер PostgreSQL
APP=${BREAK_APP:-notes}               # контейнер «Заметок»
NET=${BREAK_NET:-notes-net}           # сеть проекта
ALIAS=${BREAK_ALIAS:-db}              # имя базы внутри сети (его знает приложение)
HOLDER=${BREAK_HOLDER:-break-4-4-port}  # контейнер, который занимает порт 5432 (сценарий 4)
MARK='break-4.4'                      # метка в комментарии роли: «пароль сломал сценарий 1»

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo: bash $0 ${1:-}. Скрипт работает с docker от твоего пользователя." >&2
  exit 1
fi

need_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "Docker недоступен. Сначала пройди уроки 4.1 и 4.3." >&2
    exit 1
  fi
}

running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == true ]]; }

# Нужны работающие db и notes: их ты создал в задании 4 этого урока.
need_stack() {
  if ! running "$DB" || ! running "$APP"; then
    echo "Не найдены запущенные контейнеры $DB и $APP. Сначала выполни задание 4 урока 4.4." >&2
    exit 1
  fi
  if ! docker exec "$APP" printenv DATABASE_URL >/dev/null 2>&1; then
    echo "У контейнера $APP нет DATABASE_URL: запусти его с STORE=postgres, как в задании 4." >&2
    exit 1
  fi
}

# psql внутри контейнера базы. По сокету пароль не спрашивают, поэтому работает всегда.
sql() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$DB" psql -U notes -v ON_ERROR_STOP=1 -qtA "$@"; }

# Соединяется ли приложение с базой так, как оно это делает само (DATABASE_URL из его окружения).
app_connects() {
  docker exec "$APP" python -c \
    "import os, psycopg; psycopg.connect(os.environ['DATABASE_URL'], connect_timeout=3).close()" \
    >/dev/null 2>&1
}

app_password() {
  docker exec "$APP" python -c \
    "import os; from urllib.parse import urlparse, unquote; print(unquote(urlparse(os.environ['DATABASE_URL']).password or ''))"
}

on_net() {
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$DB" |
    tr ' ' '\n' | grep -qx "$NET"
}

role_marked() {
  [[ "$(sql -d notes -c "SELECT shobj_description(oid, 'pg_authid') FROM pg_roles WHERE rolname = 'notes'")" == "$MARK" ]]
}

wait_app() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    app_connects && return 0
    sleep 0.5
  done
  return 1
}

case "${1:-}" in
  1)
    need_docker; need_stack
    if role_marked; then
      echo "Сценарий 1 уже запущен."; exit 0
    fi
    # Пароль роли меняется в базе, а в DATABASE_URL приложения остаётся старый.
    new_pw=$(openssl rand -hex 10)
    printf "ALTER USER notes PASSWORD :'pw';\nCOMMENT ON ROLE notes IS '%s';\n" "$MARK" |
      sql -d notes -v pw="$new_pw" >/dev/null
    echo "Сценарий 1 готов. Проверь: curl -si http://127.0.0.1:8080/readyz | head -1"
    ;;
  2)
    need_docker; need_stack
    if ! on_net; then
      echo "Сценарий 2 уже запущен."; exit 0
    fi
    # Контейнер базы жив, но выпал из сети проекта: имя db перестаёт резолвиться.
    docker network disconnect "$NET" "$DB"
    echo "Сценарий 2 готов. Проверь: curl -si http://127.0.0.1:8080/notes | head -1"
    ;;
  3)
    need_docker
    if ! running "$DB"; then
      echo "Не найден запущенный контейнер $DB. Сначала выполни задание 1 урока 4.4." >&2
      exit 1
    fi
    if [[ "$(sql -d notes -c "SELECT 1 FROM pg_database WHERE datname = 'lab'")" != 1 ]]; then
      sql -d notes -c "CREATE DATABASE lab" >/dev/null
    fi
    if [[ "$(sql -d lab -c "SELECT to_regclass('public.events') IS NOT NULL")" == t ]]; then
      echo "Сценарий 3 уже запущен."; exit 0
    fi
    # Таблица событий на 3 миллиона строк без единого индекса, кроме первичного ключа.
    sql -d lab >/dev/null <<'SQL'
CREATE TABLE events (
  id         serial PRIMARY KEY,
  user_id    int NOT NULL,
  kind       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO events (user_id, kind, created_at)
SELECT g % 50000, 'click', now() - (g || ' seconds')::interval
FROM generate_series(1, 3000000) AS g;
ANALYZE events;
SQL
    echo "Сценарий 3 готов. Отчёт аналитика ходит в таблицу events базы lab, смотри раздел «Симптом» урока."
    ;;
  4)
    need_docker
    if running "$HOLDER"; then
      echo "Сценарий 4 уже запущен."; exit 0
    fi
    docker rm -f "$HOLDER" >/dev/null 2>&1 || true
    if ! docker run -d --name "$HOLDER" --stop-timeout 1 -p 127.0.0.1:5432:5432 alpine:3.22 sleep 86400 >/dev/null 2>&1; then
      docker rm -f "$HOLDER" >/dev/null 2>&1 || true
      echo "Порт 127.0.0.1:5432 на хосте уже занят чем-то другим, сценарий 4 не нужен." >&2
      exit 1
    fi
    echo "Сценарий 4 готов. Попробуй открыть базу наружу: docker run -d --name db-ext -p 127.0.0.1:5432:5432 -e POSTGRES_PASSWORD=x postgres:18"
    ;;
  fix)
    need_docker
    # Сначала сеть: без неё приложение не увидит базу, что бы мы ни чинили дальше.
    if running "$DB" && ! on_net; then
      docker network connect --alias "$ALIAS" "$NET" "$DB"
    fi
    if running "$DB" && running "$APP" && docker exec "$APP" printenv DATABASE_URL >/dev/null 2>&1; then
      # Возвращаем в базе тот пароль, который знает приложение.
      if role_marked || ! app_connects; then
        printf "ALTER USER notes PASSWORD :'pw';\nCOMMENT ON ROLE notes IS NULL;\n" |
          sql -d notes -v pw="$(app_password)" >/dev/null
      fi
    fi
    if running "$DB"; then
      sql -d notes -c "SELECT 1" >/dev/null
      if [[ "$(sql -d lab -c "SELECT 1" 2>/dev/null || true)" == 1 ]]; then
        sql -d lab -c "DROP TABLE IF EXISTS events" >/dev/null
      fi
    fi
    docker rm -f "$HOLDER" >/dev/null 2>&1 || true
    if running "$APP" && running "$DB"; then
      wait_app || echo "Приложение всё ещё не подключается к базе: смотри docker logs $APP" >&2
    fi
    echo "Всё возвращено: db в сети $NET, пароль совпадает с DATABASE_URL, таблица events удалена, порт 5432 свободен."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|4|fix" >&2
    exit 2
    ;;
esac
