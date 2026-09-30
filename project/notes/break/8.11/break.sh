#!/usr/bin/env bash
# Поломки для урока 8.11 «Надёжность». Запуск: bash break.sh 1|2|3|fix
# Правит учебные файлы в ~/notes (клиент и правила); root не нужен, кластер не трогается.
# Свой каталог можно задать так: NOTES_DIR=/путь bash break.sh 1
set -euo pipefail

NOTES_DIR=${NOTES_DIR:-$HOME/notes}
CLIENT=$NOTES_DIR/examples/retry_client.py
RULES=$NOTES_DIR/monitoring/prometheus/rules/burnrate.yml

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo: скрипт правит файлы обычного пользователя." >&2
  exit 1
fi

need_files() {
  local f
  for f in "$@"; do
    if [[ ! -f $f ]]; then
      echo "Не найден $f. Выполни задания 1-3 урока 8.11." >&2
      exit 1
    fi
  done
}

# Сценарий 1: пауза без случайности, клиенты повторяют синхронно.
break1() {
  need_files "$CLIENT"
  sed -i 's/^\( *\)return random.uniform(0, limit) if jitter else limit$/\1return limit/' "$CLIENT"
  echo "Готово. Запусти: python3 $CLIENT storm"
}

# Сценарий 2: счётчик ошибок размыкателя не накапливается.
break2() {
  need_files "$CLIENT"
  sed -i 's/^\( *\)self.fails += 1$/\1self.fails = 1/' "$CLIENT"
  echo "Готово. Запусти: python3 $CLIENT breaker"
}

# Сценарий 3: правила ловят несуществующий статус, ряды пусты, алерт молчит.
break3() {
  need_files "$RULES"
  sed -i 's/status=~"5\.\."/status=~"5..."/g' "$RULES"
  echo "Готово. Перечитай правила в Prometheus (kill -HUP) и посмотри ряды ratio_rate*."
}

# fix возвращает исходный текст; повторный запуск ничего не меняет.
fix() {
  local f
  for f in "$CLIENT" "$RULES"; do
    [[ -f $f ]] || continue
    case $f in
      "$CLIENT")
        sed -i 's/^\( *\)return limit$/\1return random.uniform(0, limit) if jitter else limit/' "$f"
        sed -i 's/^\( *\)self.fails = 1$/\1self.fails += 1/' "$f" ;;
      "$RULES")
        sed -i 's/status=~"5\.\.\."/status=~"5.."/g' "$f" ;;
    esac
  done
  echo "Исправлено. Если менялись правила, перечитай их в Prometheus."
}

case "${1:-}" in
  1) break1 ;;
  2) break2 ;;
  3) break3 ;;
  fix) fix ;;
  *) echo "Использование: bash $0 1|2|3|fix" >&2; exit 1 ;;
esac
