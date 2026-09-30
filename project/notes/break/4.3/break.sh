#!/usr/bin/env bash
# Поломки для урока 4.3 «Тома и сети Docker». Запуск: bash break.sh 1|2|fix
# Ломает только контейнер notes, том notes-data и контейнер notes-client. Запускай без sudo:
# нужны права пользователя в группе docker (урок 4.1).
set -euo pipefail

# Имена из урока. BREAK_PREFIX, BREAK_PORT и BREAK_IMAGE нужны только для проверки скрипта
# на стенде с другими именами, ученику их задавать не нужно.
PFX=${BREAK_PREFIX:-}
PORT=${BREAK_PORT:-8080}
IMAGE=${BREAK_IMAGE:-notes:0.3.0}
APP=${PFX}notes            # контейнер «Заметок»
VOL=${PFX}notes-data       # правильный том
TYPO=${PFX}notes_data      # том с «опечаткой»: его создаёт сценарий 1
NET=${PFX}notes-net        # пользовательская сеть
CLIENT=${PFX}notes-client  # контейнер-клиент из сценария 2

need_user() {
  if [[ $EUID -eq 0 ]]; then
    echo "Запусти без sudo: bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "Docker недоступен. Проверь 'docker info' (урок 4.1: группа docker, сервис запущен)." >&2
    exit 1
  fi
}

# Нужны контейнер, том, сеть и образ из задания 5 урока 4.3.
need_lesson() {
  local missing=0
  docker container inspect "$APP" >/dev/null 2>&1 || { echo "Нет контейнера $APP." >&2; missing=1; }
  docker volume inspect "$VOL" >/dev/null 2>&1 || { echo "Нет тома $VOL." >&2; missing=1; }
  docker network inspect "$NET" >/dev/null 2>&1 || { echo "Нет сети $NET." >&2; missing=1; }
  docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "Нет образа $IMAGE." >&2; missing=1; }
  if [[ $missing -eq 1 ]]; then
    echo "Сначала пройди задание 5 урока 4.3 (сервис с томом $VOL в сети $NET)." >&2
    exit 1
  fi
}

# Имя тома, смонтированного в /data контейнера $1 (пусто, если контейнера нет).
data_volume() {
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$1" 2>/dev/null || true
}

# Ждём до 5 секунд, пока сервис ответит на /healthz.
wait_healthy() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fs -m 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  echo "Сервис не ответил на 127.0.0.1:$PORT, смотри: docker logs $APP" >&2
  return 1
}

# Запуск «Заметок» ровно так, как в задании 5, с томом $1.
run_app() {
  docker rm -f "$APP" >/dev/null 2>&1 || true
  docker run -d --name "$APP" --network "$NET" \
    -p "127.0.0.1:$PORT:8080" -v "$1:/data" \
    --restart unless-stopped "$IMAGE" >/dev/null
  wait_healthy
}

# Сервис должен работать: иначе сценарий ничего не докажет.
need_running() {
  if [[ $(docker inspect -f '{{.State.Running}}' "$APP") != true ]]; then
    echo "Контейнер $APP остановлен. Запусти его: docker start $APP" >&2
    exit 1
  fi
}

break1() {
  need_lesson
  need_running
  if [[ $(data_volume "$APP") == "$TYPO" ]]; then
    echo "Сценарий 1 уже применён: контейнер $APP смонтировал том $TYPO."
    return 0
  fi
  # Чтобы было что терять, кладём заметку, если сервис пуст.
  if [[ $(curl -fs -m 3 "http://127.0.0.1:$PORT/notes" || true) == "[]" ]]; then
    curl -fs -m 3 -X POST -d '{"text": "заметка в томе"}' "http://127.0.0.1:$PORT/notes" >/dev/null
  fi
  # «Обновление» контейнера с опечаткой в имени тома: Docker молча создаёт новый пустой том.
  run_app "$TYPO"
  echo "Сценарий 1 применён: сервис работает, но заметок в нём нет."
}

break2() {
  need_lesson
  need_running
  if [[ $(docker inspect -f '{{json .NetworkSettings.Networks}}' "$APP") != *"\"$NET\""* ]]; then
    echo "Контейнер $APP не в сети $NET. Верни его: docker network connect $NET $APP" >&2
    exit 1
  fi
  if docker container inspect "$CLIENT" >/dev/null 2>&1 &&
    [[ $(docker inspect -f '{{json .NetworkSettings.Networks}}' "$CLIENT") != *"\"$NET\""* ]]; then
    echo "Сценарий 2 уже применён: контейнер $CLIENT не в сети $NET."
    return 0
  fi
  docker rm -f "$CLIENT" >/dev/null 2>&1 || true
  # Клиент стартует в сети bridge по умолчанию (без --network) и раз в 2 секунды ходит к $APP по имени.
  docker run -d --name "$CLIENT" alpine:3.22 \
    sh -c "while true; do wget -qO- -T 2 http://$APP:8080/healthz; echo; sleep 2; done" >/dev/null
  echo "Сценарий 2 применён: смотри 'docker logs $CLIENT'."
}

fix() {
  need_lesson
  # Сценарий 1: возвращаем настоящий том, лишний том с опечаткой удаляем.
  if [[ $(data_volume "$APP") != "$VOL" ]]; then
    run_app "$VOL"
    echo "Контейнер $APP снова смонтировал том $VOL."
  fi
  if docker volume inspect "$TYPO" >/dev/null 2>&1; then
    docker volume rm "$TYPO" >/dev/null
    echo "Том $TYPO удалён."
  fi
  # Сценарий 2: клиент из упражнения больше не нужен.
  if docker container inspect "$CLIENT" >/dev/null 2>&1; then
    docker rm -f "$CLIENT" >/dev/null
    echo "Контейнер $CLIENT удалён."
  fi
  echo "Состояние после задания 5 восстановлено."
}

case "${1:-}" in
  1) need_user 1; need_docker; break1 ;;
  2) need_user 2; need_docker; break2 ;;
  fix) need_user fix; need_docker; fix ;;
  *) echo "Использование: bash $0 1|2|fix" >&2; exit 1 ;;
esac
