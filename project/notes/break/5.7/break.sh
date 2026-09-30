#!/usr/bin/env bash
# Поломки для урока 5.7 «Пробы, ресурсы и обновление без простоя».
# Запуск: bash break.sh 1|2|3|4|fix (без sudo).
# Меняет только Deployment notes в namespace notes кластера kind. Ничего не удаляет.
set -euo pipefail

NS=${BREAK_NS:-notes}
DEP=notes
NOTES_DIR=${NOTES_DIR:-$HOME/notes}
MANIFEST=$NOTES_DIR/k8s/base/10-deployment.yaml
C=/spec/template/spec/containers/0     # путь к первому (единственному) контейнеру

k() { kubectl -n "$NS" "$@"; }

need_user() {
  if [[ $EUID -eq 0 ]]; then
    echo "Запусти без sudo: bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_cluster() {
  if ! k get deployment "$DEP" >/dev/null 2>&1; then
    echo "Не найден Deployment $DEP в namespace $NS. Проверь контекст: kubectl config use-context kind-notes (уроки 5.1-5.6)." >&2
    exit 1
  fi
}

# Какой сценарий сейчас применён (пусто, если никакой). Метка лежит в аннотации Deployment.
current() {
  k get deployment "$DEP" -o jsonpath='{.metadata.annotations.break57}'
}

# Поломки рассчитаны на Deployment из задания 3 урока: пробы, ресурсы и preStop на месте.
need_baseline() {
  local missing=0 field
  for field in startupProbe readinessProbe lifecycle; do
    if [[ -z $(k get deployment "$DEP" -o jsonpath="{.spec.template.spec.containers[0].$field}") ]]; then
      echo "В Deployment нет $field." >&2
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    echo "Сначала выполни задание 3 урока 5.7: kubectl apply -f k8s/base/10-deployment.yaml" >&2
    exit 1
  fi
}

resume() {
  k rollout resume deployment/"$DEP" >/dev/null 2>&1 || true
}

case "${1:-}" in
  1|2|3|4)
    need_user "$1"; need_cluster
    cur=$(current)
    if [[ $cur == "$1" ]]; then
      echo "Сценарий $1 уже применён."
      exit 0
    fi
    if [[ -n $cur ]]; then
      echo "Сейчас применён сценарий $cur. Сначала верни рабочее состояние: bash $0 fix" >&2
      exit 1
    fi
    need_baseline
    # Все правки идут одной выкаткой: ставим на паузу, меняем, снимаем паузу.
    k rollout pause deployment/"$DEP" >/dev/null
    trap resume EXIT
    case "$1" in
      1)
        # Пауза старта 20 секунд, startupProbe нет, liveness строгая: 3 неудачи по 2 секунды.
        k patch deployment "$DEP" --type=json -p "[
          {\"op\":\"remove\",\"path\":\"$C/startupProbe\"},
          {\"op\":\"replace\",\"path\":\"$C/livenessProbe/periodSeconds\",\"value\":2}]" >/dev/null
        k set env deployment/"$DEP" STARTUP_DELAY=20 >/dev/null
        ;;
      2)
        # Лимит памяти 8Mi: меньше, чем нужно интерпретатору Python.
        k patch deployment "$DEP" --type=json -p "[
          {\"op\":\"replace\",\"path\":\"$C/resources\",\"value\":
            {\"requests\":{\"cpu\":\"50m\",\"memory\":\"8Mi\"},\"limits\":{\"cpu\":\"200m\",\"memory\":\"8Mi\"}}}]" >/dev/null
        ;;
      3)
        # Нет startup и readiness, нет preStop, разрешено терять один под, порт открывается через 5 секунд.
        k patch deployment "$DEP" --type=json -p "[
          {\"op\":\"remove\",\"path\":\"$C/startupProbe\"},
          {\"op\":\"remove\",\"path\":\"$C/readinessProbe\"},
          {\"op\":\"remove\",\"path\":\"$C/lifecycle\"},
          {\"op\":\"replace\",\"path\":\"/spec/strategy/rollingUpdate/maxUnavailable\",\"value\":1}]" >/dev/null
        k set env deployment/"$DEP" STARTUP_DELAY=5 >/dev/null
        ;;
      4)
        # /readyz всегда отвечает 503.
        k set env deployment/"$DEP" READY_FAIL=-1 >/dev/null
        ;;
    esac
    k annotate deployment/"$DEP" --overwrite break57="$1" >/dev/null
    resume
    echo "Сценарий $1 применён, Deployment начал выкатку. Смотри: kubectl -n $NS get pods -w"
    ;;
  fix)
    need_user fix; need_cluster
    if [[ -z $(current) ]]; then
      echo "Нечего чинить: сценарий не применён."
      exit 0
    fi
    if [[ ! -f $MANIFEST ]]; then
      echo "Не найден $MANIFEST. Проверь NOTES_DIR (по умолчанию ~/notes) и задание 3 урока 5.7." >&2
      exit 1
    fi
    k rollout pause deployment/"$DEP" >/dev/null
    trap resume EXIT
    # Переменные, добавленные через set env, apply не удаляет: убираем сами.
    k set env deployment/"$DEP" STARTUP_DELAY- READY_FAIL- >/dev/null
    kubectl apply -f "$MANIFEST" >/dev/null
    k annotate deployment/"$DEP" break57- >/dev/null
    resume
    if k rollout status deployment/"$DEP" --timeout=180s; then
      echo "Рабочее состояние возвращено."
    else
      echo "Выкатка не завершилась за 180 секунд: проверь kubectl -n $NS get pods и describe." >&2
      exit 1
    fi
    ;;
  *)
    echo "Использование: bash $0 1|2|3|4|fix" >&2
    exit 1
    ;;
esac
