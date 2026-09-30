#!/usr/bin/env bash
# Поломки для урока 10.1 «On-call». Запуск: bash break.sh random|1|2|3|4|5|fix
# Ломает «Заметки» в учебном kind-кластере: 1 OOM, 2 диск, 3 плохой релиз,
# 4 сертификат, 5 БД недоступна. Без sudo. Что именно сломано, скрипт не печатает.
# Состояние хранится в ConfigMap break-10-1 (namespace notes), fix читает его.
set -euo pipefail

NS=notes
STATE=break-10-1
CHART=${NOTES_CHART:-$HOME/notes/helm/notes}

die() { echo "$*" >&2; exit 1; }

need() {
  command -v kubectl >/dev/null || die "Нет kubectl. Сначала пройди урок 5.1."
  command -v helm >/dev/null || die "Нет helm. Сначала пройди урок 5.9."
  kubectl -n "$NS" get deploy notes >/dev/null 2>&1 \
    || die "Не найден Deployment notes в namespace $NS. Проверь контекст (kubectl config use-context kind-notes) и уроки 5.x."
}

# Читает поле из ConfigMap состояния; пусто, если ConfigMap или поля нет.
st() { kubectl -n "$NS" get cm "$STATE" -o "jsonpath={.data.$1}" 2>/dev/null || true; }

save() { kubectl -n "$NS" create cm "$STATE" "$@" >/dev/null; }

deployed_rev() {
  helm history notes -n "$NS" -o json | python3 -c \
    'import json,sys; print([r["revision"] for r in json.load(sys.stdin) if r["status"]=="deployed"][-1])'
}

wait_rollout() { kubectl -n "$NS" rollout status deploy/notes --timeout=120s >/dev/null || true; }

break_1() {
  local orig; orig=$(kubectl -n "$NS" get deploy notes -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')
  save --from-literal=scenario=1 --from-literal=orig="$orig"
  kubectl -n "$NS" set resources deploy/notes --limits=memory=8Mi >/dev/null
}

break_2() {
  local avail
  avail=$(kubectl -n "$NS" exec deploy/notes -- df -Pm /data | awk 'NR==2{print $4}')
  if [[ -z $avail || $avail -gt 4096 ]]; then
    echo "Диск /data слишком велик (${avail:-?} МБ) для безопасного заполнения, сценарий пропущен." >&2
    return 2
  fi
  save --from-literal=scenario=2
  kubectl -n "$NS" exec deploy/notes -- sh -c "dd if=/dev/zero of=/data/.break-fill bs=1M count=$avail 2>/dev/null || true"
}

break_3() {
  [[ -d $CHART ]] || die "Не найден чарт $CHART (репозиторий ~/notes из урока 5.9). Можно задать NOTES_CHART=путь."
  local rev; rev=$(deployed_rev)
  save --from-literal=scenario=3 --from-literal=rev="$rev"
  helm upgrade notes "$CHART" -n "$NS" --reuse-values --set-string config.FAIL_RATE=0.5 >/dev/null
  wait_rollout
}

break_4() {
  kubectl -n cert-manager get deploy cert-manager >/dev/null 2>&1 || die "Нет cert-manager. Сначала пройди урок 9.4."
  local rep; rep=$(kubectl -n cert-manager get deploy cert-manager -o jsonpath='{.spec.replicas}')
  save --from-literal=scenario=4 --from-literal=replicas="$rep"
  kubectl -n cert-manager scale deploy/cert-manager --replicas=0 >/dev/null
  kubectl -n "$NS" patch secret notes-tls -p '{"data":{"tls.crt":"Zm9v"}}' >/dev/null
}

break_5() {
  kubectl -n "$NS" get cluster.postgresql.cnpg.io notes-db >/dev/null 2>&1 || die "Нет Cluster notes-db. Сначала пройди урок 9.5."
  save --from-literal=scenario=5
  kubectl -n "$NS" annotate cluster.postgresql.cnpg.io notes-db cnpg.io/hibernation=on --overwrite >/dev/null
}

do_fix() {
  local sc; sc=$(st scenario)
  if [[ -z $sc ]]; then echo "Ничего не сломано (нет состояния $STATE), чинить нечего."; return 0; fi
  case $sc in
    1)
      local orig; orig=$(st orig)
      if [[ -n $orig ]]; then
        kubectl -n "$NS" set resources deploy/notes --limits=memory="$orig" >/dev/null
      else
        kubectl -n "$NS" patch deploy notes --type=json \
          -p '[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/memory"}]' >/dev/null || true
      fi
      wait_rollout ;;
    2) kubectl -n "$NS" exec deploy/notes -- rm -f /data/.break-fill ;;
    3) helm rollback notes "$(st rev)" -n "$NS" >/dev/null; wait_rollout ;;
    4)
      kubectl -n cert-manager scale deploy/cert-manager --replicas="$(st replicas)" >/dev/null
      kubectl -n cert-manager rollout status deploy/cert-manager --timeout=120s >/dev/null || true
      kubectl -n "$NS" delete secret notes-tls --ignore-not-found >/dev/null ;;
    5) kubectl -n "$NS" annotate cluster.postgresql.cnpg.io notes-db cnpg.io/hibernation=off --overwrite >/dev/null ;;
    *) die "Неизвестное состояние $sc" ;;
  esac
  kubectl -n "$NS" delete cm "$STATE" --ignore-not-found >/dev/null
  echo "Исправлено. Подожди минуту и проверь: kubectl get pods -n $NS"
}

do_break() {
  local n=$1
  if [[ -n $(st scenario) ]]; then
    echo "Сценарий уже применён. Сначала выполни: bash $0 fix"
    return 0
  fi
  if [[ $n == random ]]; then
    n=$(( RANDOM % 5 + 1 ))
    "break_$n" || { local rc=$?; kubectl -n "$NS" delete cm "$STATE" --ignore-not-found >/dev/null; [[ $rc == 2 ]] && n=$(( n % 5 + 1 )) && "break_$n"; }
  else
    "break_$n" || { kubectl -n "$NS" delete cm "$STATE" --ignore-not-found >/dev/null; exit 1; }
  fi
  echo "Готово: что-то сломано. Ты дежурный. Включай секундомер."
}

need
case ${1:-} in
  1|2|3|4|5|random) do_break "$1" ;;
  fix) do_fix ;;
  *) die "Использование: bash $0 random|1|2|3|4|5|fix" ;;
esac
