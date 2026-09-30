#!/usr/bin/env bash
# Поломки для урока 5.11 «Масштабирование: HPA и metrics-server».
# Запуск (от обычного пользователя, не root): bash break-5.11.sh 1|2|3|fix
# Трогает только namespace notes и Deployment metrics-server в kube-system, только в учебном kind-кластере.
set -euo pipefail

NS=notes
ANN_RES=break-5.11/resources   # где Deployment хранит свои исходные resources
ANN_HPA=break-5.11/hpa         # где HPA хранит исходные цель и окно уменьшения

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

need_hpa() {
  kubectl -n "$NS" get hpa notes >/dev/null 2>&1 || {
    echo "Нет HPA notes. Сначала задание 2 или 3 урока 5.11 (kubectl -n notes autoscale ... или hpa.enabled=true)." >&2
    exit 1
  }
}

need_ms() {
  kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1 || {
    echo "Нет metrics-server в kube-system. Сначала задание 1 урока 5.11." >&2
    exit 1
  }
}

res_path='/spec/template/spec/containers/0/resources'

case "${1:-}" in
  1)
    need_deploy; need_hpa
    cur=$(kubectl -n "$NS" get deploy notes -o jsonpath='{.spec.template.spec.containers[0].resources}')
    saved=$(kubectl -n "$NS" get deploy notes -o "jsonpath={.metadata.annotations.break-5\.11/resources}")
    if [[ -z $cur || $cur == '{}' ]]; then
      echo "Сценарий 1 уже запущен."
      exit 0
    fi
    # Исходные resources сохраняем один раз, повторный запуск их не затирает.
    [[ -n $saved ]] || kubectl -n "$NS" annotate deploy notes --overwrite "$ANN_RES=$cur" >/dev/null
    # Убираем resources целиком: если оставить limits, Kubernetes сам скопирует их в requests.
    kubectl -n "$NS" patch deploy notes --type=json \
      -p "[{\"op\":\"replace\",\"path\":\"$res_path\",\"value\":{}}]" >/dev/null
    echo "Сценарий 1 готов. Создай нагрузку из задания 2 и смотри: kubectl -n notes get hpa notes"
    ;;
  2)
    need_ms
    reps=$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.replicas}')
    if [[ $reps == 0 ]]; then
      echo "Сценарий 2 уже запущен."
      exit 0
    fi
    kubectl -n kube-system scale deploy metrics-server --replicas=0 >/dev/null
    echo "Сценарий 2 готов. Проверь: kubectl top pods -n notes (метрики пропадут через минуту-две)"
    ;;
  3)
    need_hpa
    saved=$(kubectl -n "$NS" get hpa notes -o "jsonpath={.metadata.annotations.break-5\.11/hpa}")
    target=$(kubectl -n "$NS" get hpa notes -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}')
    win=$(kubectl -n "$NS" get hpa notes -o jsonpath='{.spec.behavior.scaleDown.stabilizationWindowSeconds}')
    if [[ $target == 10 && $win == 0 ]]; then
      echo "Сценарий 3 уже запущен."
      exit 0
    fi
    # Запоминаем исходные значения в виде "цель:окно" (пустое окно пишем как none).
    [[ -n $saved ]] || kubectl -n "$NS" annotate hpa notes --overwrite "$ANN_HPA=${target}:${win:-none}" >/dev/null
    kubectl -n "$NS" patch hpa notes --type=merge -p '{"spec":{"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":10}}}],"behavior":{"scaleDown":{"stabilizationWindowSeconds":0}}}}' >/dev/null
    echo "Сценарий 3 готов. Дай нагрузку из задания 2, потом убери и смотри: kubectl -n notes describe hpa notes"
    ;;
  fix)
    # 1. Deployment: вернуть resources из аннотации.
    if kubectl -n "$NS" get deploy notes >/dev/null 2>&1; then
      saved=$(kubectl -n "$NS" get deploy notes -o "jsonpath={.metadata.annotations.break-5\.11/resources}")
      if [[ -n $saved ]]; then
        kubectl -n "$NS" patch deploy notes --type=json \
          -p "[{\"op\":\"replace\",\"path\":\"$res_path\",\"value\":$saved}]" >/dev/null
        kubectl -n "$NS" annotate deploy notes "break-5.11/resources-" >/dev/null
        echo "resources в Deployment notes возвращены."
      fi
    fi
    # 2. metrics-server: включить обратно, если сценарий 2 его выключил.
    if kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
      reps=$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.replicas}')
      if [[ $reps == 0 ]]; then
        kubectl -n kube-system scale deploy metrics-server --replicas=1 >/dev/null
        kubectl -n kube-system rollout status deploy/metrics-server --timeout=120s >/dev/null
        echo "metrics-server включён."
      fi
    fi
    # 3. HPA: вернуть цель и окно из аннотации.
    if kubectl -n "$NS" get hpa notes >/dev/null 2>&1; then
      saved=$(kubectl -n "$NS" get hpa notes -o "jsonpath={.metadata.annotations.break-5\.11/hpa}")
      if [[ -n $saved ]]; then
        t=${saved%%:*}; w=${saved#*:}
        [[ $w == none ]] && w=null
        kubectl -n "$NS" patch hpa notes --type=merge \
          -p "{\"spec\":{\"metrics\":[{\"type\":\"Resource\",\"resource\":{\"name\":\"cpu\",\"target\":{\"type\":\"Utilization\",\"averageUtilization\":$t}}}],\"behavior\":{\"scaleDown\":{\"stabilizationWindowSeconds\":$w}}}}" >/dev/null
        kubectl -n "$NS" annotate hpa notes "break-5.11/hpa-" >/dev/null
        echo "Цель и окно HPA возвращены."
      fi
    fi
    echo "Готово: рабочее состояние. Проверь: kubectl -n notes get hpa notes"
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 1
    ;;
esac
