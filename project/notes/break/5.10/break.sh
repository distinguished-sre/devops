#!/usr/bin/env bash
# Поломки для урока 5.10 «Kustomize». Запуск: bash break.sh 1|2|3|fix (без sudo).
# Меняет только файлы overlay ~/notes/k8s/overlays/dev. Кластер не трогает.
# Перед первой правкой файла копия кладётся в ~/.cache/break-5.10, fix возвращает её.
set -euo pipefail

OVERLAY="${NOTES_DIR:-$HOME/notes}/k8s/overlays/dev"
BACKUP="${XDG_CACHE_HOME:-$HOME/.cache}/break-5.10"
KUST="$OVERLAY/kustomization.yaml"
PATCH="$OVERLAY/postgres-resources.yaml"
EXTRA="$OVERLAY/extra-postgres.yaml"

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo: bash $0 ${1:-}" >&2
  exit 1
fi
if [[ ! -f $KUST || ! -f $PATCH ]]; then
  echo "Не найден overlay $OVERLAY. Сначала пройди задание 3 урока 5.10." >&2
  exit 1
fi

# Копия файла сохраняется один раз: повторный запуск не затирает оригинал.
save() {
  mkdir -p "$BACKUP"
  [[ -f $BACKUP/$(basename "$1") ]] || cp "$1" "$BACKUP/$(basename "$1")"
}

restore() {
  local f
  for f in "$KUST" "$PATCH"; do
    if [[ -f $BACKUP/$(basename "$f") ]]; then
      cp "$BACKUP/$(basename "$f")" "$f"
      rm -f "$BACKUP/$(basename "$f")"
    fi
  done
  rm -f "$EXTRA"
  rmdir "$BACKUP" 2>/dev/null || true
}

case "${1:-}" in
  1)
    save "$PATCH"
    # Опечатка в имени ресурса, к которому относится патч.
    perl -pi -e 's/^  name: postgres$/  name: postgress/' "$PATCH"
    ;;
  2)
    save "$KUST"
    # Неверный путь к базе.
    perl -pi -e 's{^  - \.\./\.\./base$}{  - ../../bas}' "$KUST"
    ;;
  3)
    save "$KUST"
    # Второй StatefulSet postgres в overlay: такой ресурс уже есть в базе.
    cat > "$EXTRA" <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: notes
spec:
  serviceName: db
  selector:
    matchLabels:
      app.kubernetes.io/name: postgres
  template:
    metadata:
      labels:
        app.kubernetes.io/name: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:18
EOF
    grep -q '^  - extra-postgres.yaml$' "$KUST" ||
      perl -pi -e 's{^(  - \.\./\.\./base)$}{$1\n  - extra-postgres.yaml}' "$KUST"
    ;;
  fix)
    restore
    echo "Overlay dev возвращён в исходное состояние."
    exit 0
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
echo "Готово. Попробуй: kubectl kustomize $OVERLAY"
