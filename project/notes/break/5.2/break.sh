#!/usr/bin/env bash
# Поломки для урока 5.2 «Поды и Deployment». Запуск: bash break.sh 1|2|3|fix (без sudo).
# Берёт твой k8s/base/10-deployment.yaml, делает из него испорченную копию во временном
# каталоге и применяет её к Deployment notes в namespace notes. Сам файл в ~/notes не меняется.
set -euo pipefail

# Переменные ниже нужны для проверки самого скрипта, ученику их задавать не надо.
NOTES_DIR=${NOTES_DIR:-$HOME/notes}
FILE=${BREAK_FILE:-$NOTES_DIR/k8s/base/10-deployment.yaml}
NS=${BREAK_NAMESPACE:-notes}
WORK=${BREAK_WORK:-${TMPDIR:-/tmp}/notes-break-5.2}

need_user() {
  if [[ $EUID -eq 0 ]]; then
    echo "Запусти без sudo: bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_ready() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "Не найден kubectl. Сначала пройди урок 5.1." >&2
    exit 1
  fi
  if [[ ! -f $FILE ]] || ! grep -q '^kind: Deployment' "$FILE"; then
    echo "Не найден $FILE. Сначала пройди задание 4 урока 5.2." >&2
    exit 1
  fi
  if grep -q '<github-user>' "$FILE"; then
    echo "В $FILE остался <github-user>. Подставь свой логин GitHub (строчными) и запусти снова." >&2
    exit 1
  fi
  if ! grep -q '^          image: .*notes:0\.4\.0$' "$FILE"; then
    echo "В $FILE нет образа с тегом 0.4.0 (ожидается строка image: ...notes:0.4.0)." >&2
    exit 1
  fi
  if ! kubectl -n "$NS" get deployment notes >/dev/null 2>&1; then
    echo "В кластере нет Deployment notes в namespace $NS. Примени файл: kubectl apply -f $FILE" >&2
    exit 1
  fi
}

# Готовит испорченную копию манифеста в $WORK/broken.yaml.
make_broken() {
  mkdir -p "$WORK"
  case "$1" in
    1)  # опечатка в теге: латинская буква O вместо нуля
      sed 's|^\(          image: .*notes:0\.4\.\)0$|\1O|' "$FILE" > "$WORK/broken.yaml" ;;
    2)  # неверное значение PORT: приложение завершится с кодом 2
      awk '{print} /^          env:$/ {print "            - name: PORT"; print "              value: \"abc\""}' \
        "$FILE" > "$WORK/broken.yaml" ;;
    3)  # запрос 100 ядер CPU: ни один узел не подойдёт
      awk '{print} /^          imagePullPolicy:/ {print "          resources:"; print "            requests:"; print "              cpu: \"100\""; print "              memory: 64Mi"}' \
        "$FILE" > "$WORK/broken.yaml" ;;
  esac
  if cmp -s "$FILE" "$WORK/broken.yaml"; then
    echo "Не удалось испортить копию: формат $FILE отличается от урока (отступы?)." >&2
    exit 1
  fi
}

case "${1:-}" in
  1|2|3)
    need_user "$1"; need_ready
    make_broken "$1"
    out=$(kubectl apply -f "$WORK/broken.yaml")
    if grep -q 'unchanged' <<<"$out"; then
      echo "Сценарий $1 уже применён."
    else
      echo "Сценарий $1 применён."
    fi
    echo "Смотри, что стало с подами: kubectl -n $NS get pods"
    ;;
  fix)
    need_user fix; need_ready
    # Применяем исходный файл: kubectl сам уберёт то, что добавила поломка.
    kubectl apply -f "$FILE" >/dev/null
    rm -rf "$WORK"
    if kubectl -n "$NS" rollout status deploy/notes --timeout=120s >/dev/null 2>&1; then
      echo "Всё исправлено: Deployment notes выкатан из $FILE."
    else
      echo "Файл применён, но выкатка ещё идёт. Проверь: kubectl -n $NS rollout status deploy/notes" >&2
    fi
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
