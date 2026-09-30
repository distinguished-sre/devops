#!/usr/bin/env bash
# Поломки для урока 9.1 «Проблема секретов и Vault». Запуск: bash break.sh 1|2|3|random|fix
# Работает с Vault в кластере kind-notes (namespace vault) и с файлами в домашнем каталоге.
# Без sudo. Ничего вне учебного стенда не трогает.
set -euo pipefail

NS=vault
POD=vault-0
INIT_DIR="$HOME/.notes-secrets"
INIT_FILE="$INIT_DIR/vault-init.json"
LOST_FILE="$INIT_DIR/vault-init.json.lost"
# Метка в добавленных строках истории: fix удаляет только строки с ней.
MARK="# break-9.1"
HIST_FILES=("$HOME/.bash_history" "$HOME/.zsh_history")

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo: bash $0 ${1:-}" >&2
  exit 1
fi

need_lab() {
  for c in kubectl jq; do
    command -v "$c" >/dev/null 2>&1 || { echo "Нет команды $c. Пройди уроки 5.1 и 9.1." >&2; exit 1; }
  done
  if ! kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1; then
    echo "Не найден под $POD в namespace $NS. Сначала задание 4 урока 9.1." >&2
    exit 1
  fi
  if [[ ! -f $INIT_FILE && ! -f $LOST_FILE ]]; then
    echo "Нет $INIT_FILE. Сначала запусти scripts/seed-vault.sh (урок 9.1)." >&2
    exit 1
  fi
}

# Команда vault внутри пода. Токен передаём через env, не через историю.
vcmd() {
  kubectl -n "$NS" exec -i "$POD" -- env VAULT_TOKEN="${ROOT:-}" vault "$@"
}

is_sealed() {
  [[ $(kubectl -n "$NS" exec "$POD" -- vault status -format=json 2>/dev/null | jq -r .sealed) == "true" ]]
}

wait_ready() {
  local _
  for _ in 1 2 3 4 5; do
    [[ $(kubectl -n "$NS" exec "$POD" -- vault status -format=json 2>/dev/null | jq -r .initialized 2>/dev/null) == "true" ]] && return 0
    sleep 1
  done
  return 0
}

seal_vault() {
  if is_sealed; then
    echo "Vault уже запечатан, повторно ничего не делаю."
    return 0
  fi
  ROOT=$(jq -r .root_token "$INIT_FILE")
  vcmd operator seal >/dev/null
  echo "Vault запечатан."
}

unseal_vault() {
  if [[ -f $LOST_FILE && ! -f $INIT_FILE ]]; then
    mv "$LOST_FILE" "$INIT_FILE"
    echo "Файл с ключами возвращён: $INIT_FILE"
  fi
  wait_ready
  if is_sealed; then
    vcmd operator unseal "$(jq -r '.unseal_keys_b64[0]' "$INIT_FILE")" >/dev/null
    echo "Vault распечатан."
  fi
}

scenario_1() {
  seal_vault
}

scenario_2() {
  # Сначала запечатываем (если ещё нет), потом «теряем» ключи: файл переименован, не удалён.
  if [[ -f $INIT_FILE ]]; then
    seal_vault
    mv "$INIT_FILE" "$LOST_FILE"
    echo "Файл с ключами убран."
  else
    echo "Файл с ключами уже убран, повторно ничего не делаю."
  fi
}

scenario_3() {
  local f added=0
  for f in "${HIST_FILES[@]}"; do
    [[ -f $f ]] || continue
    if ! grep -q -F "$MARK" "$f"; then
      printf 'export VAULT_TOKEN=hvs.FAKE0000000000000000000000 %s\n' "$MARK" >>"$f"
      added=1
    fi
  done
  if [[ $added -eq 0 ]]; then
    echo "Строка с токеном уже есть (или нет файлов истории)."
  else
    echo "В историю shell добавлена строка с токеном."
  fi
}

fix() {
  local f
  unseal_vault
  for f in "${HIST_FILES[@]}"; do
    [[ -f $f ]] || continue
    if grep -q -F "$MARK" "$f"; then
      grep -v -F "$MARK" "$f" >"$f.tmp" || true
      cat "$f.tmp" >"$f"
      rm -f "$f.tmp"
    fi
  done
  echo "Готово: Vault распечатан, ключи на месте, метки в истории убраны."
}

case "${1:-}" in
  1) need_lab; scenario_1; echo "Поломка применена. Диагностируй." ;;
  2) need_lab; scenario_2; echo "Поломка применена. Диагностируй." ;;
  3) need_lab; scenario_3; echo "Поломка применена. Диагностируй." ;;
  random) need_lab; n=$((RANDOM % 3 + 1)); "scenario_$n"; echo "Поломка применена. Диагностируй." ;;
  fix) need_lab; fix ;;
  *) echo "Использование: bash $0 1|2|3|random|fix" >&2; exit 1 ;;
esac
