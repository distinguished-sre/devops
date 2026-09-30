#!/usr/bin/env bash
# Поломки для урока 4.2 «Dockerfile». Запуск: bash break.sh 1|2|3|fix (без sudo).
# Работает в отдельном каталоге ~/notes-break-4.2 и с контейнером notes-break:
# твой репозиторий ~/notes, образ notes:0.3.0 и контейнер notes не трогаются.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo: bash $0 ${1:-}" >&2
  exit 1
fi

WORK="$HOME/notes-break-4.2"
NAME=notes-break
IMAGE=notes:break
PORT="${BREAK_PORT:-8080}"

need_ready() {
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "Docker не отвечает. Сначала пройди урок 4.1 (и проверь, что ты в группе docker)." >&2
    exit 1
  fi
  if [[ ! -f $HOME/notes/app.py ]]; then
    echo "Не найден ~/notes/app.py. Сначала пройди задание 1 этого урока." >&2
    exit 1
  fi
}

# Убирает всё, что создавал этот скрипт: контейнер, образ, каталог.
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  case $WORK in
    "$HOME"/notes-break-4.2) rm -rf -- "$WORK" ;;
  esac
}

# Каталог с копией кода и правильным .dockerignore; Dockerfile пишет вызывающий.
prepare() {
  cleanup
  mkdir -p "$WORK"
  cp "$HOME/notes/app.py" "$WORK/app.py"
  echo "# зависимости приложения (пока только стандартная библиотека)" > "$WORK/requirements.txt"
  printf '.git\n.env\n__pycache__\n*.md\n' > "$WORK/.dockerignore"
}

# Уже применён ли сценарий $1: контейнер с меткой break=4.2-$1 работает.
applied() {
  [[ $(docker inspect -f '{{index .Config.Labels "break"}} {{.State.Running}}' "$NAME" 2>/dev/null || true) == "4.2-$1 true" ]]
}

# Собирает образ и запускает контейнер notes-break с портом $PORT наружу.
build_and_run() {
  docker build -q -t "$IMAGE" --label "break=4.2-$1" "$WORK" >/dev/null
  if ! docker run -d --name "$NAME" --label "break=4.2-$1" -p "$PORT:8080" "$IMAGE" >/dev/null; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    echo "Не удалось запустить контейнер (порт $PORT занят?). Останови свой контейнер: docker rm -f notes" >&2
    exit 1
  fi
  # ждём до 5 секунд, пока приложение начнёт слушать порт внутри контейнера
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if docker logs "$NAME" 2>&1 | grep -q started; then return 0; fi
    sleep 0.5
  done
  echo "Контейнер не запустился, смотри: docker logs $NAME" >&2
}

good_dockerfile() {
  cat <<'DF'
FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
RUN groupadd --system --gid 10001 notes \
 && useradd --system --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin notes \
 && mkdir /data && chown 10001:10001 /data
ENV HOST=0.0.0.0 PORT=8080 NOTES_DATA=/data/notes.txt
USER 10001:10001
EXPOSE 8080
CMD ["python", "app.py"]
DF
}

case "${1:-}" in
  1)
    need_ready
    if [[ -f $WORK/.dockerignore ]] && grep -qx 'app.py' "$WORK/.dockerignore"; then
      echo "Сценарий 1 уже запущен."
    else
      prepare
      good_dockerfile > "$WORK/Dockerfile"
      echo 'app.py' >> "$WORK/.dockerignore"
    fi
    echo "Сценарий 1 готов. Каталог: $WORK. Собери образ: cd $WORK && docker build -t notes:break ."
    ;;
  2)
    need_ready
    if applied 2; then
      echo "Сценарий 2 уже запущен."
    else
      prepare
      # правильный Dockerfile, но с HOST=127.0.0.1
      good_dockerfile | sed 's/^ENV HOST=0.0.0.0 /ENV HOST=127.0.0.1 /' > "$WORK/Dockerfile"
      build_and_run 2
    fi
    echo "Сценарий 2 готов. Проверь: curl -sS http://localhost:$PORT/healthz"
    ;;
  3)
    need_ready
    if applied 3; then
      echo "Сценарий 3 уже запущен."
    else
      prepare
      # каталог /data создан, но владелец остался root
      good_dockerfile | sed 's/ && mkdir \/data && chown 10001:10001 \/data/ \&\& mkdir \/data/' > "$WORK/Dockerfile"
      build_and_run 3
    fi
    echo "Сценарий 3 готов. Проверь: curl -sS -X POST http://localhost:$PORT/notes -d '{\"text\":\"проба\"}'"
    ;;
  fix)
    need_ready
    cleanup
    echo "Всё убрано: контейнер $NAME, образ $IMAGE и каталог $WORK удалены. Твои ~/notes и notes:0.3.0 не тронуты."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
