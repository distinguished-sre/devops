#!/usr/bin/env bash
# Поломки для урока 9.3 «GitOps: Flux». Запуск: bash break.sh 1|2|3|4|random|fix
# Ломает объекты Flux в кластере kind-notes (git не трогает). Без sudo.
set -euo pipefail

FS=flux-system
NS=notes
STATE_DIR="$HOME/.notes-break-9.3"   # здесь запоминаем исходные значения для fix

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo: bash $0 ${1:-}" >&2
  exit 1
fi

need_lab() {
  local c
  for c in kubectl jq; do
    command -v "$c" >/dev/null 2>&1 || { echo "Нет команды $c." >&2; exit 1; }
  done
  kubectl -n "$FS" get gitrepository flux-system >/dev/null 2>&1 || { echo "Нет Flux. Сначала задание 1 урока 9.3." >&2; exit 1; }
  kubectl -n "$NS" get helmrelease notes >/dev/null 2>&1 || { echo "Нет HelmRelease notes. Сначала задание 3 урока 9.3." >&2; exit 1; }
  mkdir -p "$STATE_DIR"
}

# Запомнить значение один раз, чтобы повторный запуск не затёр исходное.
save() { [[ -f $STATE_DIR/$1 ]] || printf '%s' "$2" > "$STATE_DIR/$1"; }

scenario_1() { # GitRepository: неверный адрес
  save url "$(kubectl -n "$FS" get gitrepository flux-system -o jsonpath='{.spec.url}')"
  kubectl -n "$FS" patch gitrepository flux-system --type=merge \
    -p '{"spec":{"url":"ssh://git@github.com/no-such-user/no-such-repo.git"}}' >/dev/null
  kubectl -n "$FS" annotate gitrepository flux-system "reconcile.fluxcd.io/requestedAt=$(date +%s)" --overwrite >/dev/null
}

scenario_2() { # HelmRelease: несуществующий тег, Flux приостановлен, чтобы не откатил
  save tag "$(kubectl -n "$NS" get helmrelease notes -o jsonpath='{.spec.values.image.tag}')"
  save suspended "$(kubectl -n "$FS" get kustomization apps -o jsonpath='{.spec.suspend}')"
  kubectl -n "$FS" patch kustomization apps --type=merge -p '{"spec":{"suspend":true}}' >/dev/null
  kubectl -n "$NS" patch helmrelease notes --type=merge \
    -p '{"spec":{"values":{"image":{"tag":"9.9.9"}},"upgrade":{"remediation":{"retries":1}}}}' >/dev/null
}

scenario_3() { # Kustomization apps: путь с опечаткой
  save path "$(kubectl -n "$FS" get kustomization apps -o jsonpath='{.spec.path}')"
  kubectl -n "$FS" patch kustomization apps --type=merge -p '{"spec":{"path":"./apps/notes-typo"}}' >/dev/null
  kubectl -n "$FS" annotate kustomization apps "reconcile.fluxcd.io/requestedAt=$(date +%s)" --overwrite >/dev/null
}

scenario_4() { # дрейф: ручной scale и приостановка, из-за которой правка «не откатывается»
  save suspended4 "$(kubectl -n "$NS" get helmrelease notes -o jsonpath='{.spec.suspend}')"
  kubectl -n "$NS" patch helmrelease notes --type=merge -p '{"spec":{"suspend":true}}' >/dev/null
  kubectl -n "$NS" scale deployment notes --replicas=7 >/dev/null
}

do_fix() {
  if [[ -f $STATE_DIR/url ]]; then
    kubectl -n "$FS" patch gitrepository flux-system --type=merge \
      -p "{\"spec\":{\"url\":\"$(cat "$STATE_DIR/url")\"}}" >/dev/null
  fi
  if [[ -f $STATE_DIR/path ]]; then
    kubectl -n "$FS" patch kustomization apps --type=merge \
      -p "{\"spec\":{\"path\":\"$(cat "$STATE_DIR/path")\"}}" >/dev/null
  fi
  # Тег и ретраи возвращаем как в git: Flux сам перезапишет HelmRelease из репозитория.
  kubectl -n "$FS" patch kustomization apps --type=merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
  kubectl -n "$NS" patch helmrelease notes --type=merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
  if [[ -f $STATE_DIR/tag ]]; then
    kubectl -n "$NS" patch helmrelease notes --type=merge \
      -p "{\"spec\":{\"values\":{\"image\":{\"tag\":\"$(cat "$STATE_DIR/tag")\"}},\"upgrade\":{\"remediation\":{\"retries\":3}}}}" >/dev/null
  fi
  command -v flux >/dev/null 2>&1 && {
    flux reconcile source git flux-system >/dev/null 2>&1 || true
    flux reconcile kustomization apps --with-source >/dev/null 2>&1 || true
    flux reconcile helmrelease notes -n "$NS" --reset >/dev/null 2>&1 || true
  }
  rm -rf "$STATE_DIR"
  echo "Починено: адрес, путь, тег и приостановка возвращены. Проверь: flux get all -A"
}

cmd=${1:-}
case $cmd in
  1|2|3|4) need_lab; "scenario_$cmd"; echo "Сломано. Найди причину: flux get all -A" ;;
  random) need_lab; "scenario_$((RANDOM % 4 + 1))"; echo "Сломано (какой сценарий, не скажу). Найди причину: flux get all -A" ;;
  fix) do_fix ;;
  *) echo "Использование: bash $0 1|2|3|4|random|fix" >&2; exit 1 ;;
esac
