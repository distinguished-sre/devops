#!/usr/bin/env bash
# Поломки для урока 4.8 «Безопасность образов». Запуск: bash break.sh 1|2|3|fix (без sudo).
# Работает только с Docker: образ notes:break-1, контейнер notes-break-2 и файлы в ~/lab48/break.
set -euo pipefail

# Переменные ниже нужны для проверки самого скрипта, ученику их задавать не надо.
NOTES_DIR=${NOTES_DIR:-$HOME/notes}
BREAK_DIR=${BREAK_DIR:-$HOME/lab48/break}
IMG=${BREAK_IMAGE:-notes:0.4.0}
NAME=${BREAK_NAME:-notes-break-2}
BROKEN_IMG=${BREAK_BROKEN_IMAGE:-notes:break-1}
PORT=${BREAK_PORT:-8080}
LABEL=break-4.8

need_user() {
  if [[ $EUID -eq 0 ]]; then
    echo "Запусти без sudo: bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "Docker недоступен. Проверь, что он запущен и ты в группе docker (урок 4.1)." >&2
    exit 1
  fi
}

need_project() {
  if [[ ! -f $NOTES_DIR/Dockerfile ]] || ! grep -q '^FROM python:3.13-slim' "$NOTES_DIR/Dockerfile"; then
    echo "Не найден $NOTES_DIR/Dockerfile с базой python:3.13-slim. Сначала пройди урок 4.7." >&2
    exit 1
  fi
}

need_image() {
  if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    echo "Нет образа $IMG. Собери его: cd $NOTES_DIR && docker build -t $IMG ." >&2
    exit 1
  fi
}

# Есть ли контейнер сценария 2 (только наш, по метке).
our_container() {
  docker ps -aq --filter "name=^${NAME}\$" --filter "label=$LABEL" | grep -q .
}

case "${1:-}" in
  1)
    need_user 1; need_docker; need_project
    mkdir -p "$BREAK_DIR/scenario1"
    # Копия Dockerfile проекта со старой базой: чинить нужно только эту копию.
    if [[ -f $BREAK_DIR/scenario1/Dockerfile ]] \
      && grep -q '^FROM python:3.9.5-slim' "$BREAK_DIR/scenario1/Dockerfile" \
      && docker image inspect "$BROKEN_IMG" >/dev/null 2>&1; then
      echo "Сценарий 1 уже запущен."
    else
      sed 's|^FROM python:3.13-slim|FROM python:3.9.5-slim|' "$NOTES_DIR/Dockerfile" > "$BREAK_DIR/scenario1/Dockerfile"
      echo "Собираю образ $BROKEN_IMG (нужен интернет, минуту-две)..."
      docker build -q --label "$LABEL=1" -f "$BREAK_DIR/scenario1/Dockerfile" -t "$BROKEN_IMG" "$NOTES_DIR" >/dev/null
    fi
    echo "Сценарий 1 готов: образ $BROKEN_IMG, Dockerfile лежит в $BREAK_DIR/scenario1."
    echo "Проверь шлюз Trivy по образу $BROKEN_IMG (команда из раздела «Проверки»)."
    ;;
  2)
    need_user 2; need_docker; need_image
    if our_container && [[ $(docker inspect -f '{{.State.Running}}' "$NAME") == true ]]; then
      echo "Сценарий 2 уже запущен."
    else
      our_container && docker rm -f "$NAME" >/dev/null
      if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
        echo "Контейнер $NAME уже есть, но это не сценарий скрипта. Убери его сам: docker rm -f $NAME" >&2
        exit 1
      fi
      docker run -d --name "$NAME" --label "$LABEL=2" \
        --read-only --cap-drop ALL --security-opt no-new-privileges \
        -p "127.0.0.1:$PORT:8080" "$IMG" >/dev/null || {
        echo "Не удалось запустить контейнер. Возможно, порт $PORT занят: docker ps, docker compose down (урок 4.5)." >&2
        exit 1
      }
      # Ждём до 10 секунд, пока приложение начнёт отвечать.
      for _ in $(seq 1 20); do
        curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
        sleep 0.5
      done
    fi
    echo "Сценарий 2 готов: контейнер $NAME."
    echo "Проверь: curl -sS -X POST -d '{\"text\":\"проверка\"}' http://127.0.0.1:$PORT/notes"
    ;;
  3)
    need_user 3; need_docker; need_project
    mkdir -p "$BREAK_DIR/scenario3"
    # Копия Dockerfile проекта, в которой процесс работает от root.
    sed 's|^USER 10001:10001|USER root|' "$NOTES_DIR/Dockerfile" > "$BREAK_DIR/scenario3/Dockerfile"
    if grep -q '^USER root' "$BREAK_DIR/scenario3/Dockerfile"; then
      echo "Сценарий 3 готов: $BREAK_DIR/scenario3/Dockerfile."
      echo "Проверь его Hadolint и trivy config (команды из раздела «Проверки»)."
    else
      echo "В $NOTES_DIR/Dockerfile нет строки USER 10001:10001. Сначала пройди урок 4.7." >&2
      exit 1
    fi
    ;;
  fix)
    need_user fix; need_docker
    # Удаляем только своё: контейнер и образ с меткой скрипта и файлы в $BREAK_DIR.
    if our_container; then
      docker rm -f "$NAME" >/dev/null
    fi
    if [[ -n $(docker images -q --filter "label=$LABEL" "$BROKEN_IMG") ]]; then
      docker rmi "$BROKEN_IMG" >/dev/null || true
    fi
    rm -f "$BREAK_DIR/scenario1/Dockerfile" "$BREAK_DIR/scenario3/Dockerfile"
    rmdir "$BREAK_DIR/scenario1" "$BREAK_DIR/scenario3" "$BREAK_DIR" 2>/dev/null || true
    echo "Всё убрано: контейнер $NAME, образ $BROKEN_IMG и файлы в $BREAK_DIR. Твой образ $IMG не тронут."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
