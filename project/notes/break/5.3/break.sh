#!/usr/bin/env bash
# Поломки для урока 5.3 «Service и DNS кластера». Запуск: bash break.sh 1|2|3|random|fix
# Меняет только Service notes в namespace notes и создаёт под notes-client в namespace default.
# Работает с kind-кластером из урока 5.1 (контекст kind-notes).
set -euo pipefail

CTX=kind-notes
K=(kubectl --context "$CTX")

check_env() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "Не найден kubectl. Сначала пройди урок 5.1." >&2
    exit 1
  fi
  if ! "${K[@]}" get namespace notes >/dev/null 2>&1; then
    echo "Не найден кластер kind-notes или namespace notes. Сначала пройди урок 5.1." >&2
    exit 1
  fi
  if ! "${K[@]}" -n notes get svc notes >/dev/null 2>&1; then
    echo "Не найден Service notes. Сначала выполни задание 1 урока 5.3." >&2
    exit 1
  fi
}

# Исправное состояние Service: selector и порты из k8s/base/20-service.yaml.
fix_service() {
  "${K[@]}" -n notes patch svc notes --type merge \
    -p '{"spec":{"selector":{"app":"notes"},"ports":[{"name":"http","port":8080,"targetPort":8080}]}}' >/dev/null
}

case "${1:-}" in
  random)
    exec bash "$0" "$((RANDOM % 3 + 1))"
    ;;
  1)
    check_env
    # merge-patch по ключу app заменяет значение: селектор перестаёт совпадать с метками подов
    "${K[@]}" -n notes patch svc notes --type merge -p '{"spec":{"selector":{"app":"note"}}}' >/dev/null
    echo "Сценарий готов. Проверь из пода tmp: curl -sS -m 3 http://notes:8080/healthz"
    ;;
  2)
    check_env
    "${K[@]}" -n notes patch svc notes --type merge \
      -p '{"spec":{"ports":[{"name":"http","port":8080,"targetPort":8081}]}}' >/dev/null
    echo "Сценарий готов. Проверь из пода tmp: curl -sS -m 3 http://notes:8080/healthz"
    ;;
  3)
    check_env
    # Клиент в другом namespace ходит на короткое имя: под уже есть, тогда ничего не пересоздаём
    if ! "${K[@]}" -n default get pod notes-client >/dev/null 2>&1; then
      "${K[@]}" -n default run notes-client --restart=Never --image=nicolaka/netshoot:v0.14 -- \
        sh -c 'while true; do curl -sS -m 3 http://notes:8080/healthz; echo; sleep 5; done' >/dev/null
    fi
    echo "Сценарий готов. Смотри: kubectl -n default logs notes-client (подожди 10-20 секунд)"
    ;;
  fix)
    check_env
    fix_service
    "${K[@]}" -n default delete pod notes-client --ignore-not-found --wait=false >/dev/null
    echo "Всё возвращено: Service notes с selector app=notes и targetPort 8080, под notes-client удалён."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|random|fix" >&2
    exit 2
    ;;
esac
