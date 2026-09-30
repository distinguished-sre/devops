#!/usr/bin/env bash
# Поломки для урока 5.5 «Хранилище и StatefulSet». Запуск: bash break.sh 1|2|3|fix (без sudo).
# Работает только в namespace notes кластера kind: StatefulSet postgres, PVC data-postgres-0, Secret notes-db.
# ВНИМАНИЕ: сценарии 1 и 2 стирают данные базы (это учебная база из урока 5.5).
set -euo pipefail

# Переменные ниже нужны для проверки самого скрипта, ученику их задавать не надо.
NS=${NS:-notes}
MANIFEST=${MANIFEST:-$HOME/notes/k8s/base/40-postgres.yaml}
MARK=break-5.5   # аннотация-отметка: какой сценарий сейчас применён

need_user() {
  if [[ $EUID -eq 0 ]]; then
    echo "Запусти без sudo: bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_lesson() {
  if ! command -v kubectl >/dev/null 2>&1 || ! kubectl -n "$NS" get statefulset postgres >/dev/null 2>&1; then
    echo "Нет StatefulSet postgres в namespace $NS. Сначала выполни задания 1-4 урока 5.5 и проверь kubectl config current-context (kind-notes)." >&2
    exit 1
  fi
  if [[ ! -f $MANIFEST ]]; then
    echo "Не найден $MANIFEST. Он создаётся в задании 1 урока 5.5." >&2
    exit 1
  fi
}

# Какой сценарий применён (пусто, если никакой).
current() {
  kubectl -n "$NS" get statefulset postgres -o "jsonpath={.metadata.annotations.break-5\.5}" 2>/dev/null || true
}

mark() {
  kubectl -n "$NS" annotate statefulset postgres --overwrite "$MARK=$1" >/dev/null
}

wait_pod() {
  kubectl -n "$NS" wait --for=condition=Ready pod/postgres-0 --timeout=180s >/dev/null
}

# Пересоздаёт StatefulSet и PVC из манифеста урока (данные при этом стираются).
recreate_clean() {
  kubectl -n "$NS" delete statefulset postgres --ignore-not-found --wait=true >/dev/null
  kubectl -n "$NS" delete pvc data-postgres-0 --ignore-not-found --wait=true >/dev/null
}

case "${1:-}" in
  1)
    need_user 1; need_lesson
    if [[ $(current) == 1 ]]; then
      echo "Сценарий 1 уже применён."
    elif [[ -n $(current) ]]; then
      echo "Сначала выполни fix: сейчас применён сценарий $(current)." >&2
      exit 1
    else
      recreate_clean
      # Тот же манифест, но с несуществующим классом хранилища fast-ssd в volumeClaimTemplates.
      awk '{print} /accessModes: \["ReadWriteOnce"\]/{match($0,/^ */); printf "%*sstorageClassName: fast-ssd\n", RLENGTH, ""}' "$MANIFEST" \
        | kubectl apply -f - >/dev/null
      mark 1
    fi
    echo "Сценарий 1 готов. Посмотри на postgres-0 и PVC."
    ;;
  2)
    need_user 2; need_lesson
    if [[ $(current) == 2 ]]; then
      echo "Сценарий 2 уже применён."
    elif [[ -n $(current) ]]; then
      echo "Сначала выполни fix: сейчас применён сценарий $(current)." >&2
      exit 1
    else
      wait_pod
      # «Почистили лишнее»: удаляем PVC вместе с подом, StatefulSet создаёт новый пустой том.
      # Сначала останавливаем базу (replicas=0), иначе новый под успеет занять удаляемый PVC.
      kubectl -n "$NS" scale statefulset postgres --replicas=0 >/dev/null
      kubectl -n "$NS" wait --for=delete pod/postgres-0 --timeout=120s >/dev/null
      kubectl -n "$NS" delete pvc data-postgres-0 --wait=true >/dev/null
      kubectl -n "$NS" scale statefulset postgres --replicas=1 >/dev/null
      wait_pod
      mark 2
    fi
    echo "Сценарий 2 готов. Под живой, загляни в базу."
    ;;
  3)
    need_user 3; need_lesson
    if [[ $(current) == 3 ]]; then
      echo "Сценарий 3 уже применён."
    elif [[ -n $(current) ]]; then
      echo "Сначала выполни fix: сейчас применён сценарий $(current)." >&2
      exit 1
    elif kubectl -n "$NS" get secret notes-db -o jsonpath='{.data.DATABASE_URL}' 2>/dev/null | grep -q .; then
      echo "Сценарий 3 рассчитан на состояние конца урока 5.5 (в Secret notes-db ещё нет DATABASE_URL)." >&2
      exit 1
    else
      wait_pod
      # Пароль в Secret меняем, а в самой базе он остаётся прежним.
      NEWPASS=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
      kubectl -n "$NS" patch secret notes-db --type merge \
        -p "{\"stringData\":{\"POSTGRES_PASSWORD\":\"$NEWPASS\"}}" >/dev/null
      kubectl -n "$NS" delete pod postgres-0 --wait=true >/dev/null
      wait_pod
      mark 3
    fi
    echo "Сценарий 3 готов. Подключись к базе по сети с паролем из Secret."
    ;;
  fix)
    need_user fix; need_lesson
    case "$(current)" in
      1|2)
        # Возвращаем чистую базу из манифеста урока и таблицу notes.
        recreate_clean
        kubectl apply -f "$MANIFEST" >/dev/null
        kubectl -n "$NS" wait --for=jsonpath='{.status.readyReplicas}'=1 statefulset/postgres --timeout=180s >/dev/null
        kubectl -n "$NS" exec -i postgres-0 -- psql -U notes -d notes -q >/dev/null <<'SQL'
CREATE TABLE IF NOT EXISTS notes (
  id serial PRIMARY KEY,
  text text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
SQL
        echo "Исправлено: база пересоздана из $MANIFEST, таблица notes пуста (старые данные не вернуть)."
        ;;
      3)
        # Приводим пароль внутри базы к паролю из Secret (подключение по сокету доверенное).
        PASS=$(kubectl -n "$NS" get secret notes-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
        kubectl -n "$NS" exec -i postgres-0 -- psql -U notes -d notes -q -c "ALTER USER notes PASSWORD '$PASS';" >/dev/null
        echo "Исправлено: пароль в базе совпадает с Secret."
        ;;
      *)
        echo "Нечего исправлять: ни один сценарий не применён."
        ;;
    esac
    # Отметку снимаем в самом конце (после сценариев 1 и 2 StatefulSet новый, отметки на нём уже нет).
    kubectl -n "$NS" annotate statefulset postgres "$MARK-" >/dev/null 2>&1 || true
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 1
    ;;
esac
