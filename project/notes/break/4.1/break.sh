#!/usr/bin/env bash
# Поломки для урока 4.1 «Контейнеры». Запуск: sudo bash break.sh 1|2|3|fix
# Работает только с Docker и с контейнерами break-4-1-*: файлы и сервисы «Заметок» не трогает.
set -euo pipefail

PORT_HOLDER=break-4-1-port   # контейнер, который занимает порт 8080 (сценарий 1)
QUICK_EXIT=break-4-1-exit    # контейнер, который сразу выходит (сценарий 3)
IMAGE=nginx:1.30             # образ из задания 2 урока

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! systemctl cat docker >/dev/null 2>&1; then
    echo "Docker Engine не установлен. Сначала пройди задание 1 урока 4.1." >&2
    exit 1
  fi
}

# Демон отвечает на запросы (а не просто «сервис active»).
docker_up() {
  docker info >/dev/null 2>&1
}

# Запускает демон и ждёт до 10 секунд, пока он начнёт отвечать.
start_docker() {
  systemctl reset-failed docker docker.socket 2>/dev/null || true
  systemctl start docker.socket docker || true
  for _ in $(seq 1 20); do
    if docker_up; then return 0; fi
    sleep 0.5
  done
  echo "Демон Docker не поднялся, смотри: journalctl -u docker -n 20" >&2
  return 1
}

exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

case "${1:-}" in
  1)
    need_root 1; need_docker
    docker_up || start_docker
    if exists "$PORT_HOLDER"; then
      echo "Сценарий 1 уже запущен."
      exit 0
    fi
    if ss -tlnH 'sport = :8080' | grep -q .; then
      echo "Порт 8080 уже занят не сценарием: $(ss -tlnH 'sport = :8080' | awk '{print $4}' | head -n 1). Освободи его (урок 4.1, задание 1) и запусти снова." >&2
      exit 1
    fi
    docker run -d --name "$PORT_HOLDER" -p 8080:80 "$IMAGE" >/dev/null
    echo "Сценарий 1 готов. Проверь: docker run -d -p 8080:8080 --name app python:3.13-slim python -m http.server 8080"
    ;;
  2)
    need_root 2; need_docker
    if ! systemctl is-active -q docker && ! systemctl is-active -q docker.socket; then
      echo "Сценарий 2 уже запущен."
      exit 0
    fi
    # Останавливаем и сервис, и сокет: иначе первый же запрос к сокету запустит демон снова.
    systemctl stop docker.socket docker
    echo "Сценарий 2 готов. Проверь: docker ps"
    ;;
  3)
    need_root 3; need_docker
    docker_up || start_docker
    if exists "$QUICK_EXIT"; then
      echo "Сценарий 3 уже запущен."
      exit 0
    fi
    # Без «daemon off;» nginx уходит в фон, главный процесс завершается, и контейнер вместе с ним.
    docker run -d --name "$QUICK_EXIT" "$IMAGE" nginx >/dev/null
    sleep 1
    echo "Сценарий 3 готов. Проверь: docker ps и docker ps -a"
    ;;
  fix)
    need_root fix; need_docker
    docker_up || start_docker
    for name in "$PORT_HOLDER" "$QUICK_EXIT"; do
      if exists "$name"; then docker rm -f "$name" >/dev/null; fi
    done
    echo "Всё возвращено: демон Docker работает, контейнеры $PORT_HOLDER и $QUICK_EXIT удалены."
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
