#!/usr/bin/env bash
# Поломки для урока 5.4 «Вход в кластер: Ingress и Gateway API». Запуск: bash break.sh 1|2|3|random|fix
# Меняет HTTPRoute notes, EnvoyProxy notes-proxy и Secret notes-tls. Только для учебного kind-кластера.
set -euo pipefail

CTX=kind-notes
K=(kubectl --context "$CTX")
PORTS_OK='{"spec":{"provider":{"kubernetes":{"envoyService":{"patch":{"value":{"spec":{"ports":[{"name":"http-80","port":80,"nodePort":30080},{"name":"https-443","port":443,"nodePort":30443}]}}}}}}}}'
PORTS_BAD='{"spec":{"provider":{"kubernetes":{"envoyService":{"patch":{"value":{"spec":{"ports":[{"name":"http-80","port":80,"nodePort":31080},{"name":"https-443","port":443,"nodePort":31443}]}}}}}}}}'

check_env() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "Не найден kubectl. Сначала пройди урок 5.1." >&2
    exit 1
  fi
  if ! "${K[@]}" -n notes get httproute notes >/dev/null 2>&1 \
    || ! "${K[@]}" -n notes get gateway notes-gw >/dev/null 2>&1 \
    || ! "${K[@]}" -n envoy-gateway-system get envoyproxy notes-proxy >/dev/null 2>&1; then
    echo "Не найдены Gateway notes-gw, HTTPRoute notes или EnvoyProxy notes-proxy. Сначала выполни задания 2 и 3 урока 5.4." >&2
    exit 1
  fi
}

# Копирует Secret notes-tls из namespace $1 в namespace $2 (тот же сертификат) и удаляет исходный.
move_secret() {
  local from=$1 to=$2 tmp
  "${K[@]}" -n "$from" get secret notes-tls >/dev/null 2>&1 || return 0
  tmp=$(mktemp -d)
  "${K[@]}" -n "$from" get secret notes-tls -o jsonpath='{.data.tls\.crt}' | base64 --decode >"$tmp/tls.crt"
  "${K[@]}" -n "$from" get secret notes-tls -o jsonpath='{.data.tls\.key}' | base64 --decode >"$tmp/tls.key"
  if ! "${K[@]}" -n "$to" get secret notes-tls >/dev/null 2>&1; then
    "${K[@]}" -n "$to" create secret tls notes-tls --cert="$tmp/tls.crt" --key="$tmp/tls.key" >/dev/null
  fi
  "${K[@]}" -n "$from" delete secret notes-tls >/dev/null
  rm -rf "$tmp"
}

case "${1:-}" in
  random)
    exec bash "$0" "$((RANDOM % 3 + 1))"
    ;;
  1)
    check_env
    "${K[@]}" -n notes patch httproute notes --type merge \
      -p '{"spec":{"parentRefs":[{"name":"notes-gateway"}]}}' >/dev/null
    echo "Сценарий готов. Проверь: curl -sS -m 3 --resolve notes.lab:80:127.0.0.1 http://notes.lab/healthz"
    ;;
  2)
    check_env
    "${K[@]}" -n envoy-gateway-system patch envoyproxy notes-proxy --type merge -p "$PORTS_BAD" >/dev/null
    echo "Сценарий готов (подожди 20-30 секунд). Проверь: curl -sS -m 3 --resolve notes.lab:80:127.0.0.1 http://notes.lab/healthz"
    ;;
  3)
    check_env
    if "${K[@]}" -n notes get secret notes-tls >/dev/null 2>&1; then
      move_secret notes default
    elif ! "${K[@]}" -n default get secret notes-tls >/dev/null 2>&1; then
      echo "Не найден Secret notes-tls. Сначала выполни задание 4 урока 5.4." >&2
      exit 1
    fi
    echo "Сценарий готов. Проверь: curl -sS -m 3 --cacert /tmp/notes-lab.crt --resolve notes.lab:443:127.0.0.1 https://notes.lab/healthz"
    ;;
  fix)
    check_env
    "${K[@]}" -n notes patch httproute notes --type merge \
      -p '{"spec":{"parentRefs":[{"name":"notes-gw"}]}}' >/dev/null
    "${K[@]}" -n envoy-gateway-system patch envoyproxy notes-proxy --type merge -p "$PORTS_OK" >/dev/null
    move_secret default notes
    echo "Всё возвращено: parentRefs notes-gw, NodePort 30080 и 30443, Secret notes-tls в namespace notes."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|random|fix" >&2
    exit 2
    ;;
esac
