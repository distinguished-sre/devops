#!/usr/bin/env bash
# Поломки для урока 5.1 «Зачем Kubernetes». Запуск: bash break.sh 1|2|3|fix (без sudo).
# Трогает только кластер kind «notes», контейнер notes-break-port и файл ~/.kube/config
# (его копия лежит рядом под именем config.break-5.1).
set -euo pipefail

# Переменные ниже нужны для проверки самого скрипта, ученику их задавать не надо.
CLUSTER=${BREAK_CLUSTER:-notes}
KUBE_CFG=${BREAK_KUBECONFIG:-$HOME/.kube/config}
KIND_YAML=${BREAK_KIND_YAML:-$HOME/notes/kind/kind.yaml}
BLOCKER=${BREAK_BLOCKER:-notes-break-port}
LABEL=break-5.1
SAVED="$KUBE_CFG.break-5.1"

need_user() {
  if [[ $EUID -eq 0 ]]; then
    echo "Запусти без sudo: bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_tools() {
  for t in docker kind kubectl; do
    if ! command -v "$t" >/dev/null 2>&1; then
      echo "Не найден $t. Сначала пройди задание 1 урока 5.1." >&2
      exit 1
    fi
  done
  if ! docker info >/dev/null 2>&1; then
    echo "Docker недоступен. Проверь, что он запущен (урок 4.1)." >&2
    exit 1
  fi
}

need_cluster() {
  if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    echo "Кластера $CLUSTER нет. Создай его: cd ~/notes && kind create cluster --config kind/kind.yaml" >&2
    exit 1
  fi
}

# Узел для сценария 3: worker, а в облегчённом режиме (один узел) control-plane.
pick_node() {
  if docker ps -a --format '{{.Names}}' | grep -qx "$CLUSTER-worker"; then
    echo "$CLUSTER-worker"
  else
    echo "$CLUSTER-control-plane"
  fi
}

our_blocker() {
  docker ps -aq --filter "name=^${BLOCKER}\$" --filter "label=$LABEL" | grep -q .
}

case "${1:-}" in
  1)
    need_user 1; need_tools
    if [[ -f $SAVED ]]; then
      echo "Сценарий 1 уже запущен."
    else
      if [[ ! -f $KUBE_CFG ]]; then
        echo "Нет файла $KUBE_CFG: нечего ломать. Создай кластер (задание 2 урока 5.1)." >&2
        exit 1
      fi
      mv "$KUBE_CFG" "$SAVED"
    fi
    echo "Сценарий 1 готов: kubectl потерял свой конфиг. Проверь: kubectl get nodes"
    ;;
  2)
    need_user 2; need_tools
    if our_blocker && [[ $(docker inspect -f '{{.State.Running}}' "$BLOCKER") == true ]]; then
      echo "Сценарий 2 уже запущен."
    else
      if docker ps -a --format '{{.Names}}' | grep -qx "$BLOCKER" && ! our_blocker; then
        echo "Контейнер $BLOCKER уже есть, но это не сценарий скрипта. Убери его сам: docker rm -f $BLOCKER" >&2
        exit 1
      fi
      if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
        echo "Удаляю кластер $CLUSTER (его порты 80 и 443 нужны для поломки)..."
        kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
      fi
      our_blocker && docker rm -f "$BLOCKER" >/dev/null
      # Занимаем порт 80 хоста учебным контейнером. Образ busybox знаком по урокам темы 4.
      docker run -d --name "$BLOCKER" --label "$LABEL=2" -p 80:80 busybox:1.37 sleep 86400 >/dev/null || {
        echo "Не удалось занять порт 80: он уже занят кем-то другим. Это тоже годный сценарий, ищи владельца: sudo ss -tlnp | grep ':80 '" >&2
        exit 1
      }
    fi
    echo "Сценарий 2 готов: кластера $CLUSTER нет, порт 80 занят. Попробуй создать кластер: cd ~/notes && kind create cluster --config kind/kind.yaml"
    ;;
  3)
    need_user 3; need_tools; need_cluster
    node=$(pick_node)
    if [[ $(docker inspect -f '{{.State.Running}}' "$node") != true ]]; then
      echo "Контейнер $node остановлен. Сначала верни всё как было: bash $0 fix" >&2
      exit 1
    fi
    if docker exec "$node" systemctl is-active --quiet kubelet; then
      docker exec "$node" systemctl stop kubelet
    else
      echo "Сценарий 3 уже запущен."
    fi
    echo "Сценарий 3 готов: на узле $node остановлен kubelet. Статус NotReady появится примерно через минуту: kubectl get nodes"
    ;;
  fix)
    need_user fix; need_tools
    # Сценарий 1: возвращаем конфиг. Если копии нет, а конфига тоже нет, кластер восстановит kind.
    if [[ -f $SAVED ]]; then
      if [[ -f $KUBE_CFG ]]; then
        rm -f "$SAVED"
      else
        mv "$SAVED" "$KUBE_CFG"
      fi
    fi
    # Сценарий 2: убираем только свой контейнер, кластер пересоздаём, если его нет.
    if our_blocker; then
      docker rm -f "$BLOCKER" >/dev/null
    fi
    if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
      if [[ ! -f $KIND_YAML ]]; then
        echo "Кластера $CLUSTER нет, а файла $KIND_YAML тоже нет. Сначала пройди задание 2 урока 5.1." >&2
        exit 1
      fi
      echo "Создаю кластер $CLUSTER заново (минуты две)..."
      kind create cluster --config "$KIND_YAML" >/dev/null 2>&1 || {
        echo "Кластер не создался. Запусти команду сам и прочитай ошибку: kind create cluster --config $KIND_YAML" >&2
        exit 1
      }
    fi
    # Сценарий 3: запускаем остановленные узлы и kubelet.
    for node in $(docker ps -a --filter "name=^${CLUSTER}-" --format '{{.Names}}'); do
      [[ $(docker inspect -f '{{.State.Running}}' "$node") == true ]] || docker start "$node" >/dev/null
      docker exec "$node" systemctl is-active --quiet kubelet || docker exec "$node" systemctl start kubelet
    done
    [[ -f $KUBE_CFG ]] || kind export kubeconfig --name "$CLUSTER" >/dev/null 2>&1
    kubectl config use-context "kind-$CLUSTER" >/dev/null 2>&1 || true
    if kubectl wait --for=condition=Ready node --all --timeout=90s >/dev/null 2>&1; then
      echo "Всё убрано, кластер $CLUSTER работает: kubectl get nodes"
    else
      echo "Поломки убраны, но узлы ещё не Ready. Подожди минуту и проверь: kubectl get nodes"
    fi
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
