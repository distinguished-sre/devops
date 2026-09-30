#!/usr/bin/env bash
# Поломки для урока 5.12 «Безопасность кластера: RBAC, NetworkPolicy, PSS».
# Запуск (от обычного пользователя, не root): bash break-5.12.sh 1|2|3|4|fix
# Трогает только namespace notes в учебном kind-кластере.
set -euo pipefail

NS=notes

if [[ $EUID -eq 0 ]]; then
  echo "Не запускай через sudo: kubectl работает с твоим kubeconfig." >&2
  exit 1
fi

command -v kubectl >/dev/null || { echo "Нет kubectl. Сначала пройди урок 5.1." >&2; exit 1; }

ctx=$(kubectl config current-context 2>/dev/null || true)
if [[ $ctx != kind-* ]]; then
  echo "Текущий контекст '$ctx' не похож на kind. Выбери учебный: kubectl config use-context kind-notes" >&2
  exit 1
fi

need_deploy() {
  kubectl -n "$NS" get deploy notes >/dev/null 2>&1 || { echo "Нет Deployment notes в namespace $NS. Сначала уроки 5.2 и 5.9." >&2; exit 1; }
}

store_value() {
  kubectl -n "$NS" get deploy notes -o 'jsonpath={.spec.template.spec.containers[0].env[?(@.name=="STORE")].value}'
}

case "${1:-}" in
  1)
    # Запрет всего исходящего трафика: DNS тоже блокируется, приложение не находит базу по имени db.
    kubectl apply -f - >/dev/null <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: break-egress-deny
  namespace: $NS
spec:
  podSelector: {}
  policyTypes: [Egress]
YAML
    echo "Сценарий 1 готов. Проверь: kubectl -n notes get pods и логи приложения (kubectl -n notes logs deploy/notes --tail=20)"
    ;;
  2)
    need_deploy
    enforce=$(kubectl get ns "$NS" -o 'jsonpath={.metadata.labels.pod-security\.kubernetes\.io/enforce}')
    if [[ $enforce != restricted ]]; then
      echo "На namespace $NS нет метки enforce=restricted. Сначала задание 4 урока 5.12." >&2
      exit 1
    fi
    cur=$(kubectl -n "$NS" get deploy notes -o 'jsonpath={.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation}')
    if [[ $cur == true ]]; then
      echo "Сценарий 2 уже запущен."
      exit 0
    fi
    kubectl -n "$NS" patch deploy notes -p '{"spec":{"template":{"spec":{"containers":[{"name":"notes","securityContext":{"allowPrivilegeEscalation":true}}]}}}}' >/dev/null
    echo "Сценарий 2 готов. Проверь: kubectl -n notes rollout status deploy/notes --timeout=30s"
    ;;
  3)
    need_deploy
    cur=$(store_value)
    if [[ $cur == file ]]; then
      echo "Сценарий 3 уже запущен."
      exit 0
    fi
    # Запоминаем, что было (или none), чтобы fix вернул ровно то же.
    kubectl -n "$NS" annotate deploy notes --overwrite "break-5.12/store=${cur:-none}" >/dev/null
    kubectl -n "$NS" set env deploy/notes STORE=file >/dev/null
    echo "Сценарий 3 готов. Проверь: kubectl -n notes get pods (новый под не станет Ready)"
    ;;
  4)
    kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: report-bot
  namespace: $NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: report-reader
  namespace: $NS
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: report-bot-reader
  namespace: $NS
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: report-reader}
subjects:
  - {kind: ServiceAccount, name: report-bot, namespace: $NS}
YAML
    echo "Сценарий 4 готов. Проверь: kubectl -n notes get pods --as=system:serviceaccount:notes:report-bot"
    ;;
  fix)
    kubectl -n "$NS" delete networkpolicy break-egress-deny --ignore-not-found >/dev/null
    kubectl -n "$NS" delete rolebinding report-bot-reader --ignore-not-found >/dev/null
    kubectl -n "$NS" delete role report-reader --ignore-not-found >/dev/null
    kubectl -n "$NS" delete serviceaccount report-bot --ignore-not-found >/dev/null
    if kubectl -n "$NS" get deploy notes >/dev/null 2>&1; then
      cur=$(kubectl -n "$NS" get deploy notes -o 'jsonpath={.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation}')
      if [[ $cur == true ]]; then
        kubectl -n "$NS" patch deploy notes -p '{"spec":{"template":{"spec":{"containers":[{"name":"notes","securityContext":{"allowPrivilegeEscalation":false}}]}}}}' >/dev/null
        echo "allowPrivilegeEscalation возвращён в false."
      fi
      saved=$(kubectl -n "$NS" get deploy notes -o 'jsonpath={.metadata.annotations.break-5\.12/store}')
      if [[ -n $saved ]]; then
        if [[ $saved == none ]]; then
          kubectl -n "$NS" set env deploy/notes STORE- >/dev/null
        else
          kubectl -n "$NS" set env deploy/notes "STORE=$saved" >/dev/null
        fi
        kubectl -n "$NS" annotate deploy notes "break-5.12/store-" >/dev/null
        echo "Переменная STORE возвращена."
      fi
    fi
    echo "Готово: рабочее состояние. Проверь: kubectl -n notes get pods"
    ;;
  *)
    echo "Использование: bash $0 1|2|3|4|fix" >&2
    exit 1
    ;;
esac
