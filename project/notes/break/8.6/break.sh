#!/usr/bin/env bash
# Поломки для урока 8.6 «Grafana: дашборды как код». Запуск: bash break.sh 1|2|3|fix
# Правит файлы в ~/notes/monitoring/grafana: только для учебной ВМ. Без sudo.
set -euo pipefail

MON=${MON:-$HOME/notes/monitoring}
DS=$MON/grafana/provisioning/datasources/prometheus.yml
DASH=$MON/grafana/dashboards/notes-red.json
COMPOSE=$MON/compose.yml
# Копия исходного дашборда лежит вне каталога дашбордов, иначе Grafana покажет и её.
BACKUP_DIR=$MON/grafana/.break-8.6
BACKUP=$BACKUP_DIR/notes-red.json

if [[ $EUID -eq 0 ]]; then
  echo "Не запускай через sudo: скрипт правит файлы твоего пользователя." >&2
  exit 1
fi

for f in "$DS" "$COMPOSE"; do
  if [[ ! -f $f ]]; then
    echo "Не найден $f. Сначала выполни задания 1 и 2 урока 8.6." >&2
    exit 1
  fi
done
if [[ ! -f $DASH && ! -f $BACKUP ]]; then
  echo "Не найден $DASH. Сначала выполни задание 2 урока 8.6." >&2
  exit 1
fi

restart_grafana() {
  # Провайдер дашбордов перечитывает файлы сам, а источник данных только при старте.
  docker compose -f "$COMPOSE" restart grafana >/dev/null 2>&1 || true
}

GOOD_URL='url: http://prometheus:9090'
BAD_URL='url: http://localhost:9090'

# Заменяет первую подстроку в файле, если она есть (повторный запуск ничего не меняет).
swap() { # файл старое новое
  if grep -qF -- "$2" "$1"; then
    local tmp
    tmp=$(mktemp)
    awk -v old="$2" -v new="$3" '{ i = index($0, old); if (i > 0) $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); print }' "$1" >"$tmp"
    cat "$tmp" >"$1"
    rm -f "$tmp"
  fi
}

# Кладёт исходный дашборд в резерв, но не затирает уже сохранённый оригинал.
save_backup() {
  mkdir -p "$BACKUP_DIR"
  if [[ ! -f $BACKUP && -f $DASH ]]; then
    cp "$DASH" "$BACKUP"
  fi
}

case "${1:-}" in
  1)
    swap "$DS" "$GOOD_URL" "$BAD_URL"
    restart_grafana
    echo "Сценарий 1 готов. Открой http://127.0.0.1:3000/d/notes-red и посмотри на панели."
    ;;
  2)
    save_backup
    if [[ -f $DASH ]]; then
      rm -f "$DASH"
    fi
    echo "Сценарий 2 готов. Подожди 30-60 секунд и посмотри список дашбордов: curl -s -u admin:ПАРОЛЬ 'http://127.0.0.1:3000/api/search?query=Notes'"
    ;;
  3)
    save_backup
    if [[ -f $BACKUP ]]; then
      # Берём исходный дашборд и добавляем 26 панелей без порядка, порогов и смысла.
      jq '.panels += [range(6; 32) as $i | {
            id: $i, type: "timeseries", title: ("Panel " + ($i | tostring)),
            gridPos: {x: (($i % 3) * 8), y: (13 + (($i / 3) | floor) * 6), w: 8, h: 6},
            datasource: {type: "prometheus", uid: "prometheus"},
            targets: [{refId: "A", expr: "rate(notes_http_requests_total[5m])"}]
          }]' "$BACKUP" >"$DASH"
    fi
    echo "Сценарий 3 готов. Подожди 30-60 секунд и открой http://127.0.0.1:3000/d/notes-red"
    ;;
  fix)
    swap "$DS" "$BAD_URL" "$GOOD_URL"
    if [[ -f $BACKUP ]]; then
      cp "$BACKUP" "$DASH"
      rm -f "$BACKUP"
      rmdir "$BACKUP_DIR" 2>/dev/null || true
    fi
    restart_grafana
    echo "Всё возвращено: datasource на prometheus:9090, дашборд notes-red.json на месте. Дашборд появится в течение 30 секунд."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
