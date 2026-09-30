#!/usr/bin/env bash
# Поломки для урока 5.8 «Job, CronJob и DaemonSet».
# Запуск: bash break.sh 1|2|3|fix (без sudo).
# Меняет только CronJob pg-backup и DaemonSet node-agent в namespace notes кластера kind.
set -euo pipefail

NS=${BREAK_NS:-notes}
NOTES_DIR=${NOTES_DIR:-$HOME/notes}
CRON=$NOTES_DIR/k8s/base/60-pg-backup-cronjob.yaml

k() { kubectl -n "$NS" "$@"; }

need_user() {
  if [[ $EUID -eq 0 ]]; then
    echo "Запусти без sudo: bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_cron() {
  if ! k get cronjob pg-backup >/dev/null 2>&1; then
    echo "Не найден CronJob pg-backup в namespace $NS. Выполни задание 3 урока 5.8." >&2
    exit 1
  fi
}

case "${1:-}" in
  1)
    need_user 1; need_cron
    # 30 февраля не бывает: расписание принято, но запуск не случится никогда
    k patch cronjob pg-backup --type=merge -p '{"spec":{"schedule":"0 0 30 2 *"}}' >/dev/null
    echo "Сценарий 1 применён: бэкап не запускается. Разбирайся."
    ;;
  2)
    need_user 2; need_cron
    # неверный пользователь в pg_dump, затем ручной запуск, чтобы симптом появился сразу
    k get cronjob pg-backup -o json | sed 's/-U notes -d/-U notes_backup -d/' | k replace -f - >/dev/null
    k delete job break58-run --ignore-not-found >/dev/null
    k create job --from=cronjob/pg-backup break58-run >/dev/null
    echo "Сценарий 2 применён: Job break58-run запущен, подожди около минуты. Разбирайся."
    ;;
  3)
    need_user 3
    # агент без tolerations: на control-plane он не сядет
    k apply -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-agent
  namespace: notes
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-agent
  template:
    metadata:
      labels:
        app.kubernetes.io/name: node-agent
    spec:
      containers:
        - name: agent
          image: busybox:1.37.0
          command: ["sh", "-c", "while true; do sleep 30; done"]
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 32Mi
YAML
    echo "Сценарий 3 применён: DaemonSet node-agent создан. Разбирайся."
    ;;
  fix)
    need_user fix
    if [[ -f $CRON ]]; then
      k apply -f "$CRON" >/dev/null
    fi
    k delete job break58-run --ignore-not-found >/dev/null
    k delete ds node-agent --ignore-not-found >/dev/null
    echo "Исправлено: CronJob возвращён из манифеста, break58-run и node-agent удалены."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
