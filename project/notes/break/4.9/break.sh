#!/usr/bin/env bash
# Поломки для урока 4.9 «Отладка контейнеров и уборка диска».
# Запуск (без sudo, от пользователя в группе docker): bash break.sh 1|2|3|fix
# Всё создаётся в Docker и помечено меткой break=4.9; fix убирает только это.
# Объём «мусора» ограничен (сотни мегабайт), реальный диск сценарии не заполняют.
set -euo pipefail

LABEL=break=4.9
NET=break49-net
# Образ «Заметок» из урока 4.7: нужен сценарию 3.
NOTES_IMAGE=notes:0.4.0
# Маленький образ для мусора и генератора логов.
BASE_IMAGE=alpine:3.22

need_docker() {
  if [[ $EUID -eq 0 ]]; then
    echo "Не запускай через sudo: скрипт работает с твоим Docker. Запусти: bash $0 ${1:-}" >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "Docker недоступен. Проверь, что демон запущен и ты в группе docker (урок 4.1)." >&2
    exit 1
  fi
}

need_notes_image() {
  if ! docker image inspect "$NOTES_IMAGE" >/dev/null 2>&1; then
    echo "Нет образа $NOTES_IMAGE. Собери его в ~/notes: docker build -t $NOTES_IMAGE . (уроки 4.2 и 4.7)." >&2
    exit 1
  fi
}

# Есть ли контейнер с таким именем (любой, даже остановленный).
exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

case "${1:-}" in
  1)
    need_docker 1
    if exists notes-worker; then
      echo "Сценарий 1 уже запущен."
      exit 0
    fi
    # Контейнер без ротации логов быстро печатает ~450 МБ ошибок и засыпает.
    docker run -d --name notes-worker --label "$LABEL" "$BASE_IMAGE" sh -c \
      'yes "ERROR notes-worker: не могу записать заметку в очередь, повторяю попытку" | head -n 2500000; echo flood-finished; sleep 100000' >/dev/null
    for _ in $(seq 1 60); do
      if docker logs --tail 1 notes-worker 2>&1 | grep -q flood-finished; then break; fi
      sleep 1
    done
    echo "Сценарий 1 готов. Найди, что растёт на диске: docker system df и размер логов контейнеров."
    ;;
  2)
    need_docker 2
    if docker image ls -q --filter "label=$LABEL" | grep -q . || exists notes-old-1; then
      echo "Сценарий 2 уже запущен."
      exit 0
    fi
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    cat >"$work/Dockerfile" <<DOCKERFILE
FROM $BASE_IMAGE
LABEL $LABEL
ARG N=0
# ARG в RUN даёт каждому образу свой слой (кэш не совпадает)
RUN echo "\$N" && dd if=/dev/urandom of=/junk bs=1M count=40 2>/dev/null
DOCKERFILE
    # Четыре образа без имени: так выглядят старые сборки CI.
    for n in 1 2 3 4; do
      docker build -q --build-arg "N=$n" "$work" >/dev/null
    done
    # Три остановленных контейнера, каждый записал по 30 МБ в свой слой.
    for n in 1 2 3; do
      docker run --name "notes-old-$n" --label "$LABEL" "$BASE_IMAGE" \
        sh -c 'dd if=/dev/urandom of=/cache bs=1M count=30 2>/dev/null' >/dev/null
    done
    echo "Сценарий 2 готов. Диск почти забит: docker system df покажет, где именно."
    ;;
  3)
    need_docker 3
    need_notes_image
    if exists notes-api; then
      echo "Сценарий 3 уже запущен."
      exit 0
    fi
    docker network inspect "$NET" >/dev/null 2>&1 || docker network create --label "$LABEL" "$NET" >/dev/null
    docker run -d --name notes-api --label "$LABEL" --network "$NET" \
      -m 48m --memory-swap 48m --restart unless-stopped \
      -p 127.0.0.1:8090:8080 "$NOTES_IMAGE" >/dev/null
    # Соседний контейнер раз в 2 секунды дёргает эндпоинт, который держит память.
    docker run -d --name notes-probe --label "$LABEL" --network "$NET" --restart unless-stopped \
      "$BASE_IMAGE" sh -c \
      'while true; do wget -q -T 2 -O /dev/null "http://notes-api:8080/leak?mb=10" 2>/dev/null; sleep 2; done' >/dev/null
    sleep 12
    echo "Сценарий 3 готов. Проверь: curl -sS --max-time 3 http://127.0.0.1:8090/healthz, затем docker ps."
    ;;
  fix)
    need_docker fix
    # Контейнеры и сеть с меткой break=4.9 (образы уроков и чужие контейнеры не трогаем).
    ids=$(docker container ls -aq --filter "label=$LABEL")
    if [[ -n $ids ]]; then
      # shellcheck disable=SC2086
      docker container rm -f $ids >/dev/null
    fi
    docker network rm "$NET" >/dev/null 2>&1 || true
    # Образы без имени с меткой и кэш сборки: и то и другое безопасно пересоздаётся.
    docker image prune -f --filter "label=$LABEL" >/dev/null
    docker builder prune -f >/dev/null
    echo "Готово: контейнеры, сеть и мусор сценариев удалены. Проверь: docker ps -a и docker system df."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 1
    ;;
esac
