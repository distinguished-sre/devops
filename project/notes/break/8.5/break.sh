#!/usr/bin/env bash
# Поломки для урока 8.5 «Алерты и Alertmanager». Запуск: bash break.sh 1|2|3|4|fix
# Правит файлы в ~/notes/monitoring: только для учебной ВМ. Без sudo.
set -euo pipefail

MON=${MON:-$HOME/notes/monitoring}
RULES=$MON/prometheus/rules/alerts.yml
PROM=$MON/prometheus/prometheus.yml
AM=$MON/alertmanager/alertmanager.yml
COMPOSE=$MON/compose.yml

if [[ $EUID -eq 0 ]]; then
  echo "Не запускай через sudo: скрипт правит файлы твоего пользователя." >&2
  exit 1
fi

for f in "$RULES" "$PROM" "$AM" "$COMPOSE"; do
  if [[ ! -f $f ]]; then
    echo "Не найден $f. Сначала выполни задания 1 и 2 урока 8.5." >&2
    exit 1
  fi
done

dc() { docker compose -f "$COMPOSE" "$@"; }

# Перечитать конфиги без перезапуска (SIGHUP), если контейнеры запущены.
reload() {
  dc kill -s HUP prometheus alertmanager >/dev/null 2>&1 || true
}

# Сценарий 1: в expr NotesDown лишний фильтр по несуществующему instance.
NORMAL1='expr: up{job="notes"} == 0'
BROKEN1='expr: up{job="notes", instance="notes:9999"} == 0'
# Сценарий 2: у NotesHighErrorRate нет for и порог почти у нуля.
NORMAL2A='expr: notes:http_errors:ratio5m > 0.05'
BROKEN2A='expr: notes:http_errors:ratio5m > 0.002'
# Сценарий 3: напоминания и новые уведомления каждую минуту.
NORMAL3A='repeat_interval: 4h'
BROKEN3A='repeat_interval: 1m'
NORMAL3B='group_interval: 5m'
BROKEN3B='group_interval: 1m'

# Заменяет строку в файле, только если она там есть (повторный запуск ничего не меняет).
swap() { # файл старое новое
  if grep -qF -- "$2" "$1"; then
    local tmp
    tmp=$(mktemp)
    awk -v old="$2" -v new="$3" '{ i = index($0, old); if (i > 0) $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); print }' "$1" >"$tmp"
    cat "$tmp" >"$1"
    rm -f "$tmp"
  fi
}

# Сценарий 2: for: 5m меняем на for: 0s только внутри правила NotesHighErrorRate.
break_for() {
  awk '
    /alert: NotesHighErrorRate/ { inrule = 1 }
    /alert: NotesHighLatency/   { inrule = 0 }
    inrule && /^ *for: 5m$/ { sub(/5m/, "0s") }
    { print }' "$RULES" >"$RULES.tmp" && cat "$RULES.tmp" >"$RULES" && rm -f "$RULES.tmp"
}
fix_for() {
  awk '
    /alert: NotesHighErrorRate/ { inrule = 1 }
    /alert: NotesHighLatency/   { inrule = 0 }
    inrule && /^ *for: 0s$/ { sub(/0s/, "5m") }
    { print }' "$RULES" >"$RULES.tmp" && cat "$RULES.tmp" >"$RULES" && rm -f "$RULES.tmp"
}

# Сценарий 4: блок alerting: закомментирован с меткой BREAK85.
break_alerting() {
  if ! grep -q '^#BREAK85 ' "$PROM"; then
    sed -i.tmp '/^alerting:/,/targets:/ s/^/#BREAK85 /' "$PROM"
    rm -f "$PROM.tmp"
  fi
}
fix_alerting() {
  sed -i.tmp 's/^#BREAK85 //' "$PROM"
  rm -f "$PROM.tmp"
}

case "${1:-}" in
  1)
    swap "$RULES" "$NORMAL1" "$BROKEN1"
    reload
    echo "Сценарий 1 готов. Останови notes (docker compose stop notes) и подожди: NotesDown не придёт."
    ;;
  2)
    swap "$RULES" "$NORMAL2A" "$BROKEN2A"
    break_for
    reload
    echo "Сценарий 2 готов. Включи ошибки (FAIL_RATE) и наблюдай за алертами: docker compose logs webhook"
    ;;
  3)
    swap "$AM" "$NORMAL3A" "$BROKEN3A"
    swap "$AM" "$NORMAL3B" "$BROKEN3B"
    reload
    echo "Сценарий 3 готов. Останови notes и смотри, как часто приходят повторы: docker compose logs webhook"
    ;;
  4)
    break_alerting
    reload
    echo "Сценарий 4 готов. Останови notes: в Prometheus алерт firing, а в Alertmanager пусто."
    ;;
  fix)
    swap "$RULES" "$BROKEN1" "$NORMAL1"
    swap "$RULES" "$BROKEN2A" "$NORMAL2A"
    fix_for
    swap "$AM" "$BROKEN3A" "$NORMAL3A"
    swap "$AM" "$BROKEN3B" "$NORMAL3B"
    fix_alerting
    reload
    echo "Всё возвращено: правила, alertmanager.yml и prometheus.yml в эталонном виде, конфиги перечитаны."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|4|fix" >&2
    exit 2
    ;;
esac
