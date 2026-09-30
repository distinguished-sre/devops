#!/usr/bin/env bash
# Поломки для урока 4.5 «Compose: Заметки и PostgreSQL».
# Запуск из каталога ~/notes (там лежит compose.yml): bash /tmp/break-4.5.sh 1|2|3|fix
# Без sudo: скрипт правит только файлы в ~/notes и управляет контейнерами проекта.
# Учебный стенд: сценарии 1 и 2 могут пересоздать том с данными БД.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Не запускай через sudo: скрипт работает от твоего пользователя, docker должен быть доступен ему." >&2
  exit 1
fi

if [[ -f compose.yml ]]; then
  NOTES_DIR=$PWD
else
  NOTES_DIR=${NOTES_DIR:-$HOME/notes}
fi
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/break-4.5
ENV_BACKUP=$STATE_DIR/env.orig     # метка сценария 1: сюда сохранён исходный .env
PORT_HOLDER=break-4-5-pg           # метка сценария 3: контейнер, занявший порт 5432 на хосте
OVERRIDE=compose.override.yml
MARK='# break-4.5: файл создан скриптом поломки, fix его удалит'

need_stand() {
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    echo "Не найден docker compose. Сначала пройди уроки 4.1 и 4.5 (задания 1-4)." >&2
    exit 1
  fi
  if [[ ! -f $NOTES_DIR/compose.yml || ! -f $NOTES_DIR/.env ]]; then
    echo "В $NOTES_DIR нет compose.yml или .env. Сначала пройди задания 1-4 урока 4.5 и запускай скрипт из ~/notes." >&2
    exit 1
  fi
  cd "$NOTES_DIR"
  local services
  services=$(docker compose config --services 2>/dev/null || true)
  if ! grep -qx notes <<<"$services" || ! grep -qx db <<<"$services"; then
    echo "В compose.yml должны быть сервисы notes и db (задания 1-2 урока 4.5)." >&2
    exit 1
  fi
  mkdir -p "$STATE_DIR"
}

# Наш ли compose.override.yml (есть метка в первой строке).
override_is_ours() {
  [[ -f $OVERRIDE ]] && [[ $(head -n 1 "$OVERRIDE") == "$MARK" ]]
}

# Чужой compose.override.yml скрипт не трогает.
need_override_free() {
  if [[ -f $OVERRIDE ]] && ! override_is_ours; then
    echo "В каталоге уже есть твой $OVERRIDE, скрипт его не трогает. Переименуй его и повтори." >&2
    exit 1
  fi
}

# Сценарий $1 уже применён: повторно ничего не делаем.
already() {
  local done=0
  case $1 in
    1) [[ -f $ENV_BACKUP ]] && done=1 ;;
    2) override_is_ours && grep -q service_started "$OVERRIDE" && done=1 ;;
    3) holder_exists && done=1 ;;
  esac
  if [[ $done == 1 ]]; then
    echo "Сценарий $1 уже применён. Чтобы вернуть стенд: bash $0 fix"
    exit 0
  fi
}

# Другой сценарий уже применён: сначала fix.
need_clean() {
  if [[ -f $ENV_BACKUP ]] || holder_exists || override_is_ours; then
    echo "Сначала верни стенд в норму: bash $0 fix" >&2
    exit 1
  fi
}

# Адрес приложения на хосте (из compose, по умолчанию 127.0.0.1:8080).
app_addr() {
  local a
  a=$(docker compose port notes 8080 2>/dev/null | head -n 1 || true)
  echo "${a:-127.0.0.1:8080}"
}

ready_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$(app_addr)/readyz" || true
}

# Ждём до $1 секунд, пока /readyz не ответит 200.
wait_ready() {
  local i
  for ((i = 0; i < $1; i++)); do
    if [[ $(ready_code) == 200 ]]; then return 0; fi
    sleep 1
  done
  return 1
}

holder_exists() {
  docker container inspect "$PORT_HOLDER" >/dev/null 2>&1
}

case "${1:-}" in
  1)
    need_stand; already 1; need_override_free; need_clean
    docker compose up -d
    if ! wait_ready 60; then
      echo "Стенд не поднялся с текущим .env: сначала почини его (docker compose logs), потом запускай сценарий." >&2
      exit 1
    fi
    old=$(grep -m1 '^POSTGRES_PASSWORD=' .env | cut -d= -f2- || true)
    if [[ ! $old =~ ^[A-Za-z0-9]+$ ]]; then
      echo "Ожидался пароль из букв и цифр в POSTGRES_PASSWORD (openssl rand -hex 16, задание 1)." >&2
      exit 1
    fi
    cp .env "$ENV_BACKUP"
    new=$(openssl rand -hex 16)
    # меняем пароль везде, где он есть в .env (POSTGRES_PASSWORD и DATABASE_URL)
    sed "s/$old/$new/g" "$ENV_BACKUP" > "$STATE_DIR/env.new"
    cat "$STATE_DIR/env.new" > .env
    rm -f "$STATE_DIR/env.new"
    docker compose up -d
    sleep 3
    printf 'Сценарий 1 готов. Проверь: curl -s -o /dev/null -w "%%{http_code}\\n" http://%s/readyz\n' "$(app_addr)"
    ;;
  2)
    need_stand; already 2; need_override_free; need_clean
    cat > "$OVERRIDE" <<YAML
$MARK
services:
  notes:
    depends_on:
      db:
        condition: service_started
YAML
    # свежая БД инициализируется несколько секунд: так гонка воспроизводится честно
    docker compose down -v
    docker compose up -d
    sleep 4
    echo "Сценарий 2 готов. Проверь: docker compose logs notes | head"
    ;;
  3)
    need_stand; already 3; need_override_free; need_clean
    # «Второй PostgreSQL» на хосте: контейнер, который уже опубликовал порт 5432
    if ! docker run -d --name "$PORT_HOLDER" -e POSTGRES_PASSWORD=break -p 5432:5432 postgres:18 >/dev/null; then
      docker rm -f "$PORT_HOLDER" >/dev/null 2>&1 || true
      echo "Порт 5432 на хосте уже занят до скрипта, поломка уже есть: найди владельца (docker ps)." >&2
      exit 1
    fi
    cat > "$OVERRIDE" <<YAML
$MARK
services:
  db:
    ports:
      - "5432:5432"
YAML
    docker compose down
    if docker compose up -d; then
      echo "Неожиданно: up прошёл. Проверь docker compose ps." >&2
    fi
    echo "Сценарий 3 готов. Проверь: docker compose ps -a"
    ;;
  fix)
    need_stand
    if holder_exists; then docker rm -f "$PORT_HOLDER" >/dev/null; fi
    if override_is_ours; then rm -f "$OVERRIDE"; fi
    restored=0
    if [[ -f $ENV_BACKUP ]]; then
      cat "$ENV_BACKUP" > .env
      rm -f "$ENV_BACKUP"
      restored=1
    fi
    docker compose up -d
    if ! wait_ready 60; then
      if [[ $restored == 1 ]]; then
        # том уже пересоздан с другим паролем: учебные данные не нужны, начинаем с чистого тома
        echo "Пароль в томе не совпал с .env. Пересоздаю том (данные стенда будут потеряны)."
        docker compose down -v
        docker compose up -d
        wait_ready 60 || true
      fi
    fi
    if [[ $(ready_code) == 200 ]]; then
      echo "Стенд в норме: /readyz отвечает 200, лишний $OVERRIDE удалён, .env возвращён, порт 5432 свободен."
    else
      echo "Стенд не поднялся, смотри: docker compose ps -a и docker compose logs" >&2
      exit 1
    fi
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix (из каталога ~/notes)" >&2
    exit 2
    ;;
esac
