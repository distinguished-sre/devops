#!/usr/bin/env bash
# Поломки для урока 9.2 «Vault и External Secrets Operator». Запуск: bash break.sh 1|2|3|random|fix
# Меняет ClusterSecretStore vault-backend и запечатывает Vault в кластере kind-notes. Без sudo.
set -euo pipefail

STORE=vault-backend
NS_APP=notes
NS_VAULT=vault
POD=vault-0
INIT_FILE="$HOME/.notes-secrets/vault-init.json"
# Метка на служебном ServiceAccount из сценария 2: fix удаляет только его.
LABEL=break-9.2

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo: bash $0 ${1:-}" >&2
  exit 1
fi

need_lab() {
  local c
  for c in kubectl jq; do
    command -v "$c" >/dev/null 2>&1 || { echo "Нет команды $c." >&2; exit 1; }
  done
  if ! kubectl get clustersecretstore "$STORE" >/dev/null 2>&1; then
    echo "Нет ClusterSecretStore $STORE. Сначала задания 1-2 урока 9.2." >&2
    exit 1
  fi
  if ! kubectl -n "$NS_APP" get externalsecret notes-db >/dev/null 2>&1; then
    echo "Нет ExternalSecret notes-db. Сначала задание 4 урока 9.2." >&2
    exit 1
  fi
  if [[ ! -f $INIT_FILE ]]; then
    echo "Нет $INIT_FILE. Сначала урок 9.1." >&2
    exit 1
  fi
}

vcmd() {
  kubectl -n "$NS_VAULT" exec -i "$POD" -- env VAULT_TOKEN="${ROOT:-}" vault "$@"
}

is_sealed() {
  [[ $(kubectl -n "$NS_VAULT" exec "$POD" -- vault status -format=json 2>/dev/null | jq -r .sealed) == "true" ]]
}

# Заставляем ESO перечитать Vault сейчас, а не через час.
force_sync() {
  kubectl -n "$NS_APP" annotate externalsecret notes-db "force-sync=$(date +%s)" --overwrite >/dev/null
}

set_store() { # роль, имя SA, namespace SA
  kubectl patch clustersecretstore "$STORE" --type=merge -p \
    "{\"spec\":{\"provider\":{\"vault\":{\"auth\":{\"kubernetes\":{\"role\":\"$1\",\"serviceAccountRef\":{\"name\":\"$2\",\"namespace\":\"$3\"}}}}}}}" >/dev/null
}

scenario_1() {
  set_store notes-typo notes "$NS_APP"
  force_sync
}

scenario_2() {
  # SA notes в чужом namespace default: имя совпадает, namespace нет.
  if ! kubectl -n default get serviceaccount notes >/dev/null 2>&1; then
    kubectl -n default create serviceaccount notes >/dev/null
    kubectl -n default label serviceaccount notes "$LABEL=1" >/dev/null
  fi
  set_store notes notes default
  force_sync
}

scenario_3() {
  if is_sealed; then
    echo "Vault уже запечатан, повторно ничего не делаю."
  else
    ROOT=$(jq -r .root_token "$INIT_FILE")
    vcmd operator seal >/dev/null
  fi
  force_sync
}

fix() {
  set_store notes notes "$NS_APP"
  if kubectl -n default get serviceaccount -l "$LABEL=1" -o name 2>/dev/null | grep -q .; then
    kubectl -n default delete serviceaccount -l "$LABEL=1" >/dev/null
  fi
  if is_sealed; then
    ROOT=$(jq -r .root_token "$INIT_FILE")
    vcmd operator unseal "$(jq -r '.unseal_keys_b64[0]' "$INIT_FILE")" >/dev/null
  fi
  force_sync
  echo "Готово: хранилище и Vault исправлены, ESO перечитает секрет за несколько секунд."
}

case "${1:-}" in
  1) need_lab; scenario_1; echo "Поломка применена. Диагностируй." ;;
  2) need_lab; scenario_2; echo "Поломка применена. Диагностируй." ;;
  3) need_lab; scenario_3; echo "Поломка применена. Диагностируй." ;;
  random) need_lab; n=$((RANDOM % 3 + 1)); "scenario_$n"; echo "Поломка применена. Диагностируй." ;;
  fix) need_lab; fix ;;
  *) echo "Использование: bash $0 1|2|3|random|fix" >&2; exit 1 ;;
esac
