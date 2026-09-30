#!/usr/bin/env bash
# Поломки для урока 5.9 «Helm». Запуск: bash break.sh 1|2|3|fix (без sudo).
# Меняет только файлы чарта ~/notes/helm/notes. Кластер не трогает.
# Перед первой правкой файла копия кладётся в ~/.cache/break-5.9, fix возвращает её.
set -euo pipefail

CHART="${NOTES_DIR:-$HOME/notes}/helm/notes"
BACKUP="${XDG_CACHE_HOME:-$HOME/.cache}/break-5.9"
VALUES="$CHART/values.yaml"
DEPLOY="$CHART/templates/deployment.yaml"

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo: bash $0 ${1:-}" >&2
  exit 1
fi
if [[ ! -f $VALUES || ! -f $DEPLOY ]]; then
  echo "Не найден чарт $CHART. Сначала пройди задание 2 урока 5.9." >&2
  exit 1
fi

# Копия файла сохраняется один раз: повторный запуск не затирает оригинал.
save() {
  mkdir -p "$BACKUP"
  local name
  name=$(echo "${1#"$CHART"/}" | tr '/' '_')
  [[ -f $BACKUP/$name ]] || cp "$1" "$BACKUP/$name"
}

restore() {
  local f name
  for f in "$VALUES" "$DEPLOY"; do
    name=$(echo "${f#"$CHART"/}" | tr '/' '_')
    if [[ -f $BACKUP/$name ]]; then
      cp "$BACKUP/$name" "$f"
      rm -f "$BACKUP/$name"
    fi
  done
  rmdir "$BACKUP" 2>/dev/null || true
}

case "${1:-}" in
  1)
    save "$VALUES"
    # Удаляем блок image: целиком (до пустой строки).
    perl -0pi -e 's/^image:\n.*?\n\n//ms' "$VALUES"
    echo "Готово. Попробуй: helm template notes $CHART"
    ;;
  2)
    save "$DEPLOY"
    # nindent заменён на indent: перевода строки перед resources больше нет.
    perl -pi -e 's/\{\{- toYaml \.Values\.resources \| nindent 12 \}\}/{{ toYaml .Values.resources | indent 12 }}/' "$DEPLOY"
    echo "Готово. Попробуй: helm template notes $CHART"
    ;;
  3)
    save "$VALUES"
    # Хост в values.yaml становится пустым.
    perl -pi -e 's/^(  host:).*/$1 ""/' "$VALUES"
    echo "Готово. Попробуй: helm template notes $CHART"
    ;;
  fix)
    restore
    echo "Чарт возвращён в исходное состояние."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
