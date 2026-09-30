#!/usr/bin/env bash
# Поломки для урока 8.4 «Проверки снаружи: blackbox». Запуск (без sudo): bash break.sh 1|2|3|fix
# Каталог проекта: NOTES_DIR (по умолчанию ~/notes). Скрипт правит
# monitoring/blackbox/blackbox.yml (сценарий 1), monitoring/prometheus/prometheus.yml
# (сценарий 2) или останавливает контейнер proxy (сценарий 3). Копии исходных файлов
# лежат рядом с суффиксом .before-break, состояние в monitoring/.break-8.4; fix всё возвращает.
set -euo pipefail

NOTES_DIR=${NOTES_DIR:-$HOME/notes}
MON="$NOTES_DIR/monitoring"
BB="$MON/blackbox/blackbox.yml"
PR="$MON/prometheus/prometheus.yml"
STATE="$MON/.break-8.4"
MON_COMPOSE="$MON/compose.yml"

need_ready() {
  if [[ $EUID -eq 0 ]]; then
    echo "Не запускай через sudo: скрипт работает с твоим Docker. Запусти: bash $0 ${1:-}" >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "Docker недоступен. Проверь, что демон запущен и ты в группе docker (урок 4.1)." >&2
    exit 1
  fi
  if [[ ! -f $BB || ! -f $PR || ! -f $MON_COMPOSE ]]; then
    echo "Не найден стек из урока 8.4 в $MON. Выполни задания 1 и 2 урока или задай NOTES_DIR." >&2
    exit 1
  fi
}

wait_ready() {
  for _ in $(seq 1 20); do
    if curl -fs "$1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
}

case "${1:-}" in
  1)
    need_ready 1
    [[ -f $STATE ]] && { echo "Поломка уже применена. Сначала: bash $0 fix"; exit 0; }
    grep -q 'ca_file:' "$BB" || { echo "В $BB нет ca_file: файл отличается от урока." >&2; exit 1; }
    cp "$BB" "$BB.before-break"
    echo 1 >"$STATE"
    # убираем доверие к нашему сертификату
    sed -i -E '/^ *tls_config:$/d;/^ *ca_file: /d' "$BB"
    docker compose -f "$MON_COMPOSE" restart blackbox >/dev/null
    wait_ready localhost:9115/-/healthy
    echo "Сценарий 1 готов. Подожди минуту: проба https-цели красная, найди причину."
    ;;
  2)
    need_ready 2
    [[ -f $STATE ]] && { echo "Поломка уже применена. Сначала: bash $0 fix"; exit 0; }
    grep -q 'module: \[http_2xx_tls\]' "$PR" || { echo "В $PR нет job с http_2xx_tls: файл отличается от урока." >&2; exit 1; }
    cp "$PR" "$PR.before-break"
    echo 2 >"$STATE"
    sed -i 's/module: \[http_2xx_tls\]/module: [http_2xx_tsl]/' "$PR"
    docker compose -f "$MON_COMPOSE" restart prometheus >/dev/null
    wait_ready localhost:9090/-/ready
    echo "Сценарий 2 готов. Подожди минуту: https-пробы красные, найди причину."
    ;;
  3)
    need_ready 3
    [[ -f $STATE ]] && { echo "Поломка уже применена. Сначала: bash $0 fix"; exit 0; }
    echo 3 >"$STATE"
    (cd "$NOTES_DIR" && docker compose stop proxy >/dev/null)
    echo "Сценарий 3 готов. Подожди минуту: внешние пробы красные, найди слой и причину."
    ;;
  fix)
    need_ready fix
    if [[ -f "$BB.before-break" ]]; then
      mv "$BB.before-break" "$BB"
      docker compose -f "$MON_COMPOSE" restart blackbox >/dev/null
    fi
    if [[ -f "$PR.before-break" ]]; then
      mv "$PR.before-break" "$PR"
      docker compose -f "$MON_COMPOSE" restart prometheus >/dev/null
    fi
    if [[ -f $STATE ]] && [[ $(cat "$STATE") == 3 ]]; then
      (cd "$NOTES_DIR" && docker compose start proxy >/dev/null)
    fi
    rm -f "$STATE"
    echo "Готово: всё возвращено. Через минуту все четыре пробы должны быть равны 1."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 1
    ;;
esac
