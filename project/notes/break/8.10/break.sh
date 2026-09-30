#!/usr/bin/env bash
# Поломки для урока 8.10 «Service mesh: Istio ambient». Запуск: bash break.sh 1|2|3|fix
# Меняет политику и метки в namespace notes кластера kind-notes: только для учебного стенда.
set -euo pipefail

NS=notes
CTX=kind-notes

need_cluster() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "Не найден kubectl. Сначала пройди тему 5." >&2
    exit 1
  fi
  if [[ "$(kubectl config current-context 2>/dev/null)" != "$CTX" ]]; then
    echo "Текущий контекст не $CTX. Переключись: kubectl config use-context $CTX" >&2
    exit 1
  fi
  if ! kubectl get ns istio-system >/dev/null 2>&1; then
    echo "Istio не установлен. Выполни задания 1-4 урока 8.10." >&2
    exit 1
  fi
}

# Правильная политика из задания 3 (три источника).
apply_good_policy() {
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: notes-allow
  namespace: notes
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: notes
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces: ["envoy-gateway-system"]
        - source:
            namespaces: ["monitoring"]
        - source:
            principals: ["cluster.local/ns/mesh-lab/sa/curl-ok"]
      to:
        - operation:
            ports: ["8080"]
YAML
}

# Сценарий 1: политика перестаёт пускать вход (нет envoy-gateway-system).
break1() {
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: notes-allow
  namespace: notes
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: notes
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/mesh-lab/sa/curl-ok"]
      to:
        - operation:
            ports: ["8080"]
YAML
  echo "Готово. Проверь https://notes.lab снаружи."
}

# Сценарий 2: namespace выпадает из ambient. Повторный запуск ничего не меняет.
break2() {
  kubectl label namespace "$NS" istio.io/dataplane-mode- >/dev/null 2>&1 || true
  echo "Готово. Посмотри протокол в istioctl ztunnel-config workload -n $NS."
}

# Сценарий 3: waypoint остаётся, но namespace перестаёт им пользоваться.
break3() {
  if ! kubectl -n "$NS" get gateway waypoint >/dev/null 2>&1; then
    echo "Нет waypoint. Выполни задание 4 урока 8.10." >&2
    exit 1
  fi
  kubectl label namespace "$NS" istio.io/use-waypoint- >/dev/null 2>&1 || true
  echo "Готово. Проверь /slow?sec=5 из пода mesh-lab."
}

# fix выставляет нужное состояние, поэтому безопасен при повторном запуске.
fix() {
  kubectl label namespace "$NS" istio.io/dataplane-mode=ambient --overwrite >/dev/null
  if kubectl -n "$NS" get authorizationpolicy notes-allow >/dev/null 2>&1; then
    apply_good_policy
  fi
  if kubectl -n "$NS" get gateway waypoint >/dev/null 2>&1; then
    kubectl label namespace "$NS" istio.io/use-waypoint=waypoint --overwrite >/dev/null
  fi
  echo "Исправлено: namespace в ambient, политика и waypoint на месте."
}

case "${1:-}" in
  1)
    need_cluster
    kubectl -n "$NS" get authorizationpolicy notes-allow >/dev/null 2>&1 || {
      echo "Нет политики notes-allow. Выполни задание 3 урока 8.10." >&2
      exit 1
    }
    break1 ;;
  2) need_cluster; break2 ;;
  3) need_cluster; break3 ;;
  fix) need_cluster; fix ;;
  *) echo "Использование: bash $0 1|2|3|fix" >&2; exit 1 ;;
esac
