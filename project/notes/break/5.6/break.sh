#!/usr/bin/env bash
# Поломки для урока 5.6 «ConfigMap и Secret». Запуск: bash break.sh 1|2|3|fix (без sudo).
# Работает только в namespace notes кластера kind: Deployment notes, ConfigMap notes-config, Secret notes-db.
set -euo pipefail

# Переменные ниже нужны для проверки самого скрипта, ученику их задавать не надо.
NS=${NS:-notes}
MARK=break-5.6   # аннотация-отметка на Deployment: какой сценарий сейчас применён

need_user() {
  if [[ $EUID -eq 0 ]]; then
    echo "Запусти без sudo: bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_lesson() {
  if ! command -v kubectl >/dev/null 2>&1 \
    || ! kubectl -n "$NS" get deployment notes >/dev/null 2>&1 \
    || ! kubectl -n "$NS" get configmap notes-config >/dev/null 2>&1 \
    || ! kubectl -n "$NS" get secret notes-db -o jsonpath='{.data.DATABASE_URL}' 2>/dev/null | grep -q .; then
    echo "Не найдены Deployment notes, ConfigMap notes-config или ключ DATABASE_URL в Secret notes-db в namespace $NS." >&2
    echo "Сначала выполни задание 3 урока 5.6 и проверь kubectl config current-context (kind-notes)." >&2
    exit 1
  fi
}

current() {
  kubectl -n "$NS" get deployment notes -o "jsonpath={.metadata.annotations.break-5\.6}" 2>/dev/null || true
}

mark() {
  kubectl -n "$NS" annotate deployment notes --overwrite "$MARK=$1" >/dev/null
}

restart_and_wait() {
  kubectl -n "$NS" rollout restart deployment/notes >/dev/null
  kubectl -n "$NS" rollout status deployment/notes --timeout=180s >/dev/null
}

# Строка подключения с заданным хостом и паролем из Secret (POSTGRES_PASSWORD не меняем).
set_url() {
  local host=$1 pass
  pass=$(kubectl -n "$NS" get secret notes-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
  kubectl -n "$NS" patch secret notes-db --type merge \
    -p "{\"stringData\":{\"DATABASE_URL\":\"postgresql://notes:${pass}@${host}:5432/notes\"}}" >/dev/null
}

busy() {
  if [[ -n $(current) ]]; then
    echo "Сначала выполни fix: сейчас применён сценарий $(current)." >&2
    exit 1
  fi
}

case "${1:-}" in
  1)
    need_user 1
    # Повторный запуск не меняет ничего (ключа DATABASE_URL уже нет, поэтому отметку смотрим до need_lesson).
    if [[ $(current) == 1 ]]; then
      echo "Сценарий 1 уже применён."
    else
      need_lesson; busy
      kubectl -n "$NS" patch secret notes-db --type json \
        -p '[{"op":"remove","path":"/data/DATABASE_URL"}]' >/dev/null
      kubectl -n "$NS" rollout restart deployment/notes >/dev/null
      mark 1
    fi
    echo "Сценарий 1 готов. Посмотри на поды: kubectl -n $NS get pods."
    ;;
  2)
    need_user 2
    if [[ $(current) == 2 ]]; then
      echo "Сценарий 2 уже применён."
    else
      need_lesson; busy
      set_url db1
      restart_and_wait
      mark 2
    fi
    echo "Сценарий 2 готов. Поды запущены, попробуй записать заметку."
    ;;
  3)
    need_user 3
    if [[ $(current) == 3 ]]; then
      echo "Сценарий 3 уже применён."
    else
      need_lesson; busy
      kubectl -n "$NS" patch configmap notes-config --type merge \
        -p '{"data":{"LOG_LEVEL":"debug"}}' >/dev/null
      mark 3
    fi
    echo "Сценарий 3 готов. В ConfigMap LOG_LEVEL изменён, сравни его с тем, что видит под."
    ;;
  fix)
    need_user fix
    case "$(current)" in
      1|2|3)
        # Возвращаем рабочие значения: строка подключения с хостом db, LOG_LEVEL=info.
        # Для сценария 1 ключа DATABASE_URL уже нет, поэтому проверку need_lesson здесь не делаем.
        set_url db
        kubectl -n "$NS" patch configmap notes-config --type merge \
          -p '{"data":{"LOG_LEVEL":"info"}}' >/dev/null
        restart_and_wait
        kubectl -n "$NS" annotate deployment notes "$MARK-" >/dev/null
        echo "Исправлено: DATABASE_URL и LOG_LEVEL возвращены, поды перезапущены."
        ;;
      *)
        echo "Нечего исправлять: ни один сценарий не применён."
        ;;
    esac
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 1
    ;;
esac
