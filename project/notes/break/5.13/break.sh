#!/usr/bin/env bash
# Поломки для урока 5.13 «Диагностика Kubernetes: разбор поломок».
# Запуск (от обычного пользователя, не root): bash break-5.13.sh 1|2|3|4|5|random|fix
# Трогает только Deployment notes и Service notes в namespace notes учебного kind-кластера.
# Исходные значения хранятся в аннотациях break-5.13/*, поэтому fix возвращает всё как было.
set -euo pipefail

NS=notes
ANN=break-5.13

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

kubectl -n "$NS" get deploy notes >/dev/null 2>&1 || { echo "Нет Deployment notes в namespace $NS. Сначала уроки 5.2 и 5.9." >&2; exit 1; }
kubectl -n "$NS" get svc notes >/dev/null 2>&1 || { echo "Нет Service notes в namespace $NS. Сначала урок 5.3." >&2; exit 1; }

# Читает аннотацию Deployment (ключ после break-5.13/), пусто если её нет.
dann() {
  kubectl -n "$NS" get deploy notes -o "jsonpath={.metadata.annotations.break-5\.13/$1}"
}

# Пишет аннотацию, только если её ещё нет (повторный запуск не затирает оригинал).
dsave() {
  if [[ -z $(dann "$1") ]]; then
    kubectl -n "$NS" annotate deploy notes "$ANN/$1=$2" >/dev/null
  fi
}

done_msg() {
  echo "Поломка применена. Найди причину алгоритмом: статус, события, describe, логи."
}

break_one() {
  case "$1" in
    1)
      # Несуществующий тег образа: ImagePullBackOff.
      cur=$(kubectl -n "$NS" get deploy notes -o 'jsonpath={.spec.template.spec.containers[0].image}')
      dsave image "$cur"
      orig=$(dann image)
      kubectl -n "$NS" set image deploy/notes "notes=${orig%:*}:9.9.9" >/dev/null
      ;;
    2)
      # Ссылка на ключ, которого нет в Secret: CreateContainerConfigError.
      kubectl -n "$NS" patch deploy notes -p '{"spec":{"template":{"spec":{"containers":[{"name":"notes","env":[{"name":"BREAK_X","valueFrom":{"secretKeyRef":{"name":"notes-db","key":"NO_SUCH_KEY"}}}]}]}}}}' >/dev/null
      ;;
    3)
      # Selector Service не совпадает с метками подов: пустые endpoints.
      cur=$(kubectl -n "$NS" get svc notes -o 'jsonpath={.spec.selector.app\.kubernetes\.io/name}')
      if [[ $cur != notez ]]; then
        kubectl -n "$NS" annotate svc notes "$ANN/selector=$cur" --overwrite >/dev/null
        kubectl -n "$NS" patch svc notes --type=merge -p '{"spec":{"selector":{"app.kubernetes.io/name":"notez"}}}' >/dev/null
      fi
      ;;
    4)
      # Запуск несуществующего файла: CrashLoopBackOff.
      kubectl -n "$NS" patch deploy notes -p '{"spec":{"template":{"spec":{"containers":[{"name":"notes","command":["python","/no/such/app.py"]}]}}}}' >/dev/null
      ;;
    5)
      # Неверный путь readiness-пробы: Running, но 0/1 Ready.
      cur=$(kubectl -n "$NS" get deploy notes -o 'jsonpath={.spec.template.spec.containers[0].readinessProbe.httpGet.path}')
      if [[ -z $cur ]]; then
        echo "У контейнера нет readiness-пробы httpGet. Сначала урок 5.7." >&2
        exit 1
      fi
      if [[ $cur != /nope ]]; then
        dsave probe "$cur"
        kubectl -n "$NS" patch deploy notes -p '{"spec":{"template":{"spec":{"containers":[{"name":"notes","readinessProbe":{"httpGet":{"path":"/nope"}}}]}}}}' >/dev/null
      fi
      ;;
  esac
}

fix_all() {
  img=$(dann image)
  if [[ -n $img ]]; then
    kubectl -n "$NS" set image deploy/notes "notes=$img" >/dev/null
    kubectl -n "$NS" annotate deploy notes "$ANN/image-" >/dev/null
  fi

  kubectl -n "$NS" set env deploy/notes BREAK_X- >/dev/null

  sel=$(kubectl -n "$NS" get svc notes -o 'jsonpath={.metadata.annotations.break-5\.13/selector}')
  if [[ -n $sel ]]; then
    kubectl -n "$NS" patch svc notes --type=merge -p "{\"spec\":{\"selector\":{\"app.kubernetes.io/name\":\"$sel\"}}}" >/dev/null
    kubectl -n "$NS" annotate svc notes "$ANN/selector-" >/dev/null
  fi

  cmd=$(kubectl -n "$NS" get deploy notes -o 'jsonpath={.spec.template.spec.containers[0].command[1]}')
  if [[ $cmd == /no/such/app.py ]]; then
    kubectl -n "$NS" patch deploy notes --type=json -p '[{"op":"remove","path":"/spec/template/spec/containers/0/command"}]' >/dev/null
  fi

  probe=$(dann probe)
  if [[ -n $probe ]]; then
    kubectl -n "$NS" patch deploy notes -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"notes\",\"readinessProbe\":{\"httpGet\":{\"path\":\"$probe\"}}}]}}}}" >/dev/null
    kubectl -n "$NS" annotate deploy notes "$ANN/probe-" >/dev/null
  fi
}

case "${1:-}" in
  1|2|3|4|5)
    break_one "$1"
    done_msg
    ;;
  random)
    break_one "$(( (RANDOM % 5) + 1 ))"
    done_msg
    ;;
  fix)
    fix_all
    echo "Всё возвращено. Проверь: kubectl -n notes rollout status deploy/notes --timeout=120s"
    ;;
  *)
    echo "Использование: bash break-5.13.sh 1|2|3|4|5|random|fix" >&2
    exit 2
    ;;
esac
