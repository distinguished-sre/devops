#!/usr/bin/env bash
# Поломки для урока 8.8 «Трейсинг: OpenTelemetry и Tempo». Запуск: bash break.sh 1|2|3|4|fix
# Правит файлы в ~/notes и ~/notes/monitoring: только для учебной ВМ. Без sudo.
set -euo pipefail

APP=${APP:-$HOME/notes}
MON=${MON:-$APP/monitoring}
APP_COMPOSE=$APP/compose.yml
MON_COMPOSE=$MON/compose.yml
ALLOY=$MON/alloy/config.alloy
LOKI_DS=$MON/grafana/provisioning/datasources/loki.yml

if [[ $EUID -eq 0 ]]; then
  echo "Не запускай через sudo: скрипт правит файлы твоего пользователя." >&2
  exit 1
fi

for f in "$APP_COMPOSE" "$MON_COMPOSE" "$ALLOY" "$LOKI_DS"; do
  if [[ ! -f $f ]]; then
    echo "Не найден $f. Сначала выполни задания 1-4 урока 8.8." >&2
    exit 1
  fi
done

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

restart_app() { docker compose -f "$APP_COMPOSE" up -d notes >/dev/null 2>&1 || true; }
restart_alloy() { docker compose -f "$MON_COMPOSE" restart alloy >/dev/null 2>&1 || true; }
restart_grafana() { docker compose -f "$MON_COMPOSE" restart grafana >/dev/null 2>&1 || true; }

# Возвращает файлы к исходному виду (каждая замена откатывается, если она была применена).
undo_all() {
  swap "$APP_COMPOSE" '"http://alloy:4317"' '"http://alloy:4318"'
  swap "$ALLOY" 'insecure = false' 'insecure = true'
  swap "$ALLOY" 'endpoint = "127.0.0.1:4318"' 'endpoint = "0.0.0.0:4318"'
  swap "$LOKI_DS" '"traceid":"' '"trace_id":"'
}

case "${1:-}" in
  1)
    swap "$APP_COMPOSE" 'OTEL_EXPORTER_OTLP_ENDPOINT: "http://alloy:4318"' 'OTEL_EXPORTER_OTLP_ENDPOINT: "http://alloy:4317"'
    restart_app
    echo "Сценарий 1 включён. Сделай несколько запросов к приложению и ищи причину."
    ;;
  2)
    swap "$ALLOY" 'insecure = true' 'insecure = false'
    restart_alloy
    echo "Сценарий 2 включён. Сделай несколько запросов к приложению и ищи причину."
    ;;
  3)
    swap "$ALLOY" 'endpoint = "0.0.0.0:4318"' 'endpoint = "127.0.0.1:4318"'
    restart_alloy
    echo "Сценарий 3 включён. Сделай несколько запросов к приложению и ищи причину."
    ;;
  4)
    swap "$LOKI_DS" '"trace_id":"' '"traceid":"'
    restart_grafana
    echo "Сценарий 4 включён. Открой логи в Grafana и ищи причину."
    ;;
  fix)
    undo_all
    restart_app
    restart_alloy
    restart_grafana
    echo "Исходное состояние восстановлено."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|4|fix" >&2
    exit 2
    ;;
esac
