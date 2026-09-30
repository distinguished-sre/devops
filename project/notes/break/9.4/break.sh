#!/usr/bin/env bash
# Поломки для урока 9.4 «cert-manager». Запуск: bash break.sh 1|2|3|random|fix
# Ломает Certificate notes-tls и оператор cert-manager в кластере kind-notes. Без sudo.
set -euo pipefail

NS=notes
CM=cert-manager
STATE_DIR="$HOME/.notes-break-9.4"

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo: bash $0 ${1:-}" >&2
  exit 1
fi

need_lab() {
  command -v kubectl >/dev/null 2>&1 || { echo "Нет команды kubectl." >&2; exit 1; }
  kubectl -n "$NS" get certificate notes-tls >/dev/null 2>&1 || { echo "Нет Certificate notes-tls. Сначала задание 3 урока 9.4." >&2; exit 1; }
  mkdir -p "$STATE_DIR"
}

# Flux не должен откатывать поломку, пока ты диагностируешь.
freeze() { kubectl -n flux-system patch kustomization infrastructure-config --type=merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true; }

scenario_1() { # опечатка в имени издателя
  freeze
  kubectl -n "$NS" patch certificate notes-tls --type=merge -p '{"spec":{"issuerRef":{"name":"notes-ca-typo"}}}' >/dev/null
  # Новый выпуск запускаем удалением Secret, иначе cert-manager ничего не пересчитает.
  kubectl -n "$NS" delete secret notes-tls --ignore-not-found >/dev/null
}

scenario_2() { # в сертификате не то имя (SAN)
  freeze
  kubectl -n "$NS" patch certificate notes-tls --type=merge -p '{"spec":{"dnsNames":["notes.example.invalid"]}}' >/dev/null
}

scenario_3() { # оператор остановлен, Secret удалён
  freeze
  kubectl -n "$CM" get deployment cert-manager -o jsonpath='{.spec.replicas}' > "$STATE_DIR/replicas"
  kubectl -n "$CM" scale deployment cert-manager --replicas=0 >/dev/null
  kubectl -n "$NS" delete secret notes-tls --ignore-not-found >/dev/null
}

do_fix() {
  kubectl -n "$NS" patch certificate notes-tls --type=merge \
    -p '{"spec":{"issuerRef":{"name":"notes-ca"},"dnsNames":["notes.lab"]}}' >/dev/null 2>&1 || true
  local r=1
  [[ -f $STATE_DIR/replicas ]] && r=$(cat "$STATE_DIR/replicas")
  [[ $r -ge 1 ]] || r=1
  kubectl -n "$CM" scale deployment cert-manager --replicas="$r" >/dev/null 2>&1 || true
  kubectl -n flux-system patch kustomization infrastructure-config --type=merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
  # Secret удаляем, чтобы выпуск прошёл заново с правильными настройками.
  kubectl -n "$NS" delete secret notes-tls --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR"
  echo "Починено. Подожди минуту: kubectl -n $NS get certificate notes-tls"
}

cmd=${1:-}
case $cmd in
  1|2|3) need_lab; "scenario_$cmd"; echo "Сломано. Найди причину: kubectl -n $NS describe certificate notes-tls" ;;
  random) need_lab; "scenario_$((RANDOM % 3 + 1))"; echo "Сломано (какой сценарий, не скажу). Найди причину: kubectl -n $NS describe certificate notes-tls" ;;
  fix) do_fix ;;
  *) echo "Использование: bash $0 1|2|3|random|fix" >&2; exit 1 ;;
esac
