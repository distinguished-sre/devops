#!/usr/bin/env bash
# Поломки для урока 8.3 «PromQL». Запуск (без sudo): bash break.sh 1|2|3|fix
# Каталог проекта: NOTES_DIR (по умолчанию ~/notes). Скрипт правит только
# monitoring/prometheus/rules/notes.rules.yml (файл из задания 4 урока 8.3),
# копию исходника кладёт рядом с суффиксом .before-break, fix возвращает её.
set -euo pipefail

NOTES_DIR=${NOTES_DIR:-$HOME/notes}
RULES="$NOTES_DIR/monitoring/prometheus/rules/notes.rules.yml"
SAVED="$RULES.before-break"
COMPOSE="$NOTES_DIR/monitoring/compose.yml"

need_ready() {
  if [[ $EUID -eq 0 ]]; then
    echo "Не запускай через sudo: скрипт работает с твоим Docker. Запусти: bash $0 ${1:-}" >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "Docker недоступен. Проверь, что демон запущен и ты в группе docker (урок 4.1)." >&2
    exit 1
  fi
  if [[ ! -f $RULES || ! -f $COMPOSE ]]; then
    echo "Не найден $RULES. Выполни задание 4 урока 8.3 или задай NOTES_DIR." >&2
    exit 1
  fi
}

# Перезапуск Prometheus и ожидание готовности (до 20 секунд).
restart_prom() {
  docker compose -f "$COMPOSE" restart prometheus >/dev/null
  for _ in $(seq 1 20); do
    if curl -fs localhost:9090/-/ready >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
}

# Применить правку sed к правилам; если текст не изменился, значит файл не совпал с уроком.
break_with() {
  cp "$RULES" "$SAVED"
  sed -i -E "$1" "$RULES"
  if cmp -s "$RULES" "$SAVED"; then
    rm -f "$SAVED"
    echo "Файл правил отличается от версии из урока, ничего не изменено." >&2
    exit 1
  fi
  restart_prom
}

case "${1:-}" in
  1)
    need_ready 1
    [[ -f $SAVED ]] && { echo "Поломка уже применена. Сначала: bash $0 fix"; exit 0; }
    # p95 без метки le: sum схлопывает и корзины
    break_with 's/sum by \(le\) \(rate\(/sum (rate(/'
    echo "Сценарий 1 готов. Подожди минуту и сравни правила с их значениями."
    ;;
  2)
    need_ready 2
    [[ -f $SAVED ]] && { echo "Поломка уже применена. Сначала: bash $0 fix"; exit 0; }
    # окно 15s в правиле RPS
    break_with 's/(expr: sum\(rate\(notes_http_requests_total)\[5m\]/\1[15s]/'
    echo "Сценарий 2 готов. Подожди минуту и сравни правила с их значениями."
    ;;
  3)
    need_ready 3
    [[ -f $SAVED ]] && { echo "Поломка уже применена. Сначала: bash $0 fix"; exit 0; }
    # опечатка в имени метки
    break_with 's/\{status=~/{statuss=~/'
    echo "Сценарий 3 готов. Подожди минуту и сравни правила с их значениями."
    ;;
  fix)
    need_ready fix
    if [[ -f $SAVED ]]; then
      mv "$SAVED" "$RULES"
      restart_prom
    fi
    echo "Готово: файл правил возвращён. Проверь: три правила дают значения."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 1
    ;;
esac
