#!/usr/bin/env bash
# Поломка для урока 10.5 «Ревью безопасности и релизного процесса».
# Запуск: bash break.sh 1|fix
# Работает с kind-кластером (контекст kind-notes, namespace notes). Без sudo.
# Ничего вне учебного кластера не трогает.
set -euo pipefail

CTX=kind-notes
NS=notes
SA=ci-deployer
CRB=ci-deployer-admin
KC=(kubectl --context "$CTX")

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo: bash $0 ${1:-}" >&2
  exit 1
fi

need_lab() {
  command -v kubectl >/dev/null 2>&1 || { echo "Нет kubectl. Пройди урок 5.1." >&2; exit 1; }
  if ! "${KC[@]}" get ns "$NS" >/dev/null 2>&1; then
    echo "Нет namespace $NS в контексте $CTX. Подними кластер по урокам 5.1 и 9.7." >&2
    exit 1
  fi
}

ensure_sa() {
  "${KC[@]}" -n "$NS" get sa "$SA" >/dev/null 2>&1 || "${KC[@]}" -n "$NS" create sa "$SA" >/dev/null
}

scenario_1() {
  ensure_sa
  if "${KC[@]}" get clusterrolebinding "$CRB" >/dev/null 2>&1; then
    echo "Привязка $CRB уже есть, повторно ничего не делаю."
    return 0
  fi
  "${KC[@]}" create clusterrolebinding "$CRB" --clusterrole=cluster-admin \
    --serviceaccount="$NS:$SA" >/dev/null
  echo "Поломка 1 применена. Проверь права аккаунта CI и привязки cluster-admin."
}

fix() {
  ensure_sa
  "${KC[@]}" delete clusterrolebinding "$CRB" --ignore-not-found >/dev/null
  # Минимальные права на один namespace: только выкатка приложения
  "${KC[@]}" -n "$NS" apply -f - >/dev/null <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ci-deployer
rules:
  - apiGroups: ["apps", "argoproj.io"]
    resources: ["deployments", "rollouts"]
    verbs: ["get", "list", "watch", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-deployer
subjects:
  - kind: ServiceAccount
    name: ci-deployer
    namespace: notes
roleRef:
  kind: Role
  name: ci-deployer
  apiGroup: rbac.authorization.k8s.io
YAML
  echo "Исправлено: cluster-admin снят, у $SA только Role на namespace $NS."
}

need_lab
case "${1:-}" in
  1) scenario_1 ;;
  fix) fix ;;
  *) echo "Использование: bash $0 1|fix" >&2; exit 2 ;;
esac
