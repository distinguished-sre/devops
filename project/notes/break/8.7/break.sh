#!/usr/bin/env bash
# Поломки для урока 8.7 «Логи: JSON, Loki и Alloy». Запуск: bash break.sh 1|2|3|4|fix
# Правит файлы в ~/notes/monitoring/alloy и ~/notes/monitoring/loki: только для учебной ВМ. Без sudo.
set -euo pipefail

MON=${MON:-$HOME/notes/monitoring}
ALLOY=$MON/alloy/config.alloy
LOKI=$MON/loki/loki.yml
COMPOSE=$MON/compose.yml

if [[ $EUID -eq 0 ]]; then
  echo "Не запускай через sudo: скрипт правит файлы твоего пользователя." >&2
  exit 1
fi

for f in "$ALLOY" "$LOKI" "$COMPOSE"; do
  if [[ ! -f $f ]]; then
    echo "Не найден $f. Сначала выполни задание 2 урока 8.7." >&2
    exit 1
  fi
done

restart_stack() {
  docker compose -f "$COMPOSE" restart loki alloy >/dev/null 2>&1 || true
}

# Заменяет первое вхождение подстроки в файле, если оно есть (повторный запуск ничего не меняет).
# Строки передаются через окружение: awk -v съел бы обратные слэши.
swap() { # файл старое новое
  if grep -qF -- "$2" "$1"; then
    local tmp
    tmp=$(mktemp)
    OLD=$2 NEW=$3 awk '{ i = index($0, ENVIRON["OLD"]); if (i > 0) $0 = substr($0, 1, i - 1) ENVIRON["NEW"] substr($0, i + length(ENVIRON["OLD"])); print }' "$1" >"$tmp"
    cat "$tmp" >"$1"
    rm -f "$tmp"
  fi
}

# Возвращает файлы к исходному виду: строки с меткой #BREAK87 удаляются, замены откатываются.
undo_all() {
  swap "$ALLOY" 'expressions = { level = "level", path = "path" }' 'expressions = { level = "level" }'
  swap "$ALLOY" 'values = { level = "", path = "" }' 'values = { level = "" }'
  swap "$ALLOY" 'url = "http://loki:3101/loki/api/v1/push"' 'url = "http://loki:3100/loki/api/v1/push"'
  swap "$ALLOY" 'selector = "{service=\"notes-app\"}"' 'selector = "{service=\"notes\"}"'
  if grep -q '#BREAK87' "$LOKI"; then
    local tmp
    tmp=$(mktemp)
    grep -v '#BREAK87' "$LOKI" >"$tmp" || true
    cat "$tmp" >"$LOKI"
    rm -f "$tmp"
  fi
}

case "${1:-}" in
  1)
    swap "$ALLOY" 'expressions = { level = "level" }' 'expressions = { level = "level", path = "path" }'
    swap "$ALLOY" 'values = { level = "" }' 'values = { level = "", path = "" }'
    restart_stack
    echo "Сценарий 1 включён. Сделай несколько запросов к приложению и ищи причину."
    ;;
  2)
    swap "$ALLOY" 'url = "http://loki:3100/loki/api/v1/push"' 'url = "http://loki:3101/loki/api/v1/push"'
    restart_stack
    echo "Сценарий 2 включён. Сделай несколько запросов к приложению и ищи причину."
    ;;
  3)
    swap "$ALLOY" 'selector = "{service=\"notes\"}"' 'selector = "{service=\"notes-app\"}"'
    restart_stack
    echo "Сценарий 3 включён. Сделай несколько запросов к приложению и ищи причину."
    ;;
  4)
    if ! grep -q '#BREAK87' "$LOKI"; then
      swap "$LOKI" '  reject_old_samples: true' $'  reject_old_samples: true\n  max_global_streams_per_user: 1  #BREAK87'
    fi
    restart_stack
    echo "Сценарий 4 включён. Сделай несколько запросов к приложению, в том числе к /error, и ищи причину."
    ;;
  fix)
    undo_all
    restart_stack
    echo "Исходное состояние восстановлено."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|4|fix" >&2
    exit 2
    ;;
esac
