#!/usr/bin/env bash
# Поломки для урока 8.9 «Мониторинг в Kubernetes». Запуск: bash break.sh 1|2|3|fix
# Меняет объекты в namespace notes кластера kind-notes: только для учебного стенда.
# Правки делаются командами kubectl, поэтому следующий `helm upgrade` вернёт исходное состояние.
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
  if ! kubectl get servicemonitor notes -n "$NS" >/dev/null 2>&1 ||
     ! kubectl get prometheusrule notes -n "$NS" >/dev/null 2>&1; then
    echo "Нет ServiceMonitor или PrometheusRule notes в namespace $NS. Выполни задания 2-4 урока 8.9." >&2
    exit 1
  fi
}

# Сценарий 1: у ServiceMonitor убираем label release, Prometheus его не выбирает.
break1() {
  kubectl label servicemonitor notes -n "$NS" release- >/dev/null
  echo "Готово. Загляни в /targets: цели notes нет."
}

# Сценарий 2: порт в Service получает другое имя, ServiceMonitor ищет http.
break2() {
  local cur
  cur=$(kubectl get svc notes -n "$NS" -o jsonpath='{.spec.ports[0].name}')
  if [[ $cur != web ]]; then
    kubectl patch svc notes -n "$NS" --type=json \
      -p '[{"op":"replace","path":"/spec/ports/0/name","value":"web"}]' >/dev/null
  fi
  echo "Готово. Загляни в /targets: цели notes нет."
}

# Сценарий 3: у PrometheusRule убираем label release, правил нет в /alerts.
break3() {
  kubectl label prometheusrule notes -n "$NS" release- >/dev/null
  echo "Готово. Загляни в /alerts: группы notes.rules нет."
}

# fix безопасен при повторном запуске: команды выставляют нужное состояние, а не переключают его.
fix() {
  kubectl label servicemonitor notes -n "$NS" release=kps --overwrite >/dev/null
  kubectl label prometheusrule notes -n "$NS" release=kps --overwrite >/dev/null
  kubectl patch svc notes -n "$NS" --type=json \
    -p '[{"op":"replace","path":"/spec/ports/0/name","value":"http"}]' >/dev/null
  echo "Исправлено: label release=kps и имя порта http на месте."
}

case "${1:-}" in
  1) need_cluster; break1 ;;
  2) need_cluster; break2 ;;
  3) need_cluster; break3 ;;
  fix) need_cluster; fix ;;
  *) echo "Использование: bash $0 1|2|3|fix" >&2; exit 1 ;;
esac
