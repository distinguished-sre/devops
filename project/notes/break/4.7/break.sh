#!/usr/bin/env bash
# Поломки для урока 4.7 «Образы: multi-stage, теги и реестр». Запуск: bash break.sh 1|2|3|fix
# Правит только файл .github/workflows/image.yml в твоём репозитории ~/notes (без sudo).
# Другой каталог репозитория: NOTES_DIR=/путь bash break.sh 1
set -euo pipefail

NOTES_DIR=${NOTES_DIR:-$HOME/notes}
WF=$NOTES_DIR/.github/workflows/image.yml

if [[ $EUID -eq 0 ]]; then
  echo "Не запускай через sudo: файл workflow принадлежит твоему пользователю." >&2
  exit 1
fi

if [[ ! -f $WF ]] || ! grep -q 'docker/build-push-action' "$WF"; then
  echo "Не найден $WF с шагом build-push-action. Сначала пройди задание 4 урока 4.7." >&2
  exit 1
fi

# Правильные строки (как в уроке) и сломанные.
GOOD_PERM='  packages: write'
BAD_PERM='  packages: read'
# shellcheck disable=SC2016  # ${{ }} это текст для GitHub, а не переменная shell
GOOD_TAGS='          tags: ${{ steps.meta.outputs.image }}:${{ steps.meta.outputs.version }}'
# shellcheck disable=SC2016
BAD_TAGS='          tags: ${{ steps.meta.outputs.image }}:0.4.0'
GOOD_CTX='          context: .'
BAD_CTX='          context: ./app'

# Заменяет строку целиком: $1 старая, $2 новая. Если старой строки нет, ничего не делает
# (сценарий уже применён), поэтому повторный запуск безопасен.
swap() {
  if ! grep -qxF -- "$1" "$WF"; then
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == "$1" ]]; then
      printf '%s\n' "$2"
    else
      printf '%s\n' "$line"
    fi
  done < "$WF" > "$tmp"
  cat "$tmp" > "$WF"
  rm -f "$tmp"
}

case "${1:-}" in
  1)
    swap "$GOOD_PERM" "$BAD_PERM"
    echo "Готово: у workflow image нет права писать пакеты. Закоммить, запушь тег v0.4.1 и смотри лог шага push."
    ;;
  2)
    swap "$GOOD_TAGS" "$BAD_TAGS"
    echo "Готово: тег образа зашит в workflow. Закоммить, запушь тег v0.4.1 и сравни его с тегом образа в реестре."
    ;;
  3)
    swap "$GOOD_CTX" "$BAD_CTX"
    echo "Готово: сборка идёт не из того каталога. Закоммить, запушь тег v0.4.1 и смотри лог шага сборки."
    ;;
  fix)
    swap "$BAD_PERM" "$GOOD_PERM"
    swap "$BAD_TAGS" "$GOOD_TAGS"
    swap "$BAD_CTX" "$GOOD_CTX"
    echo "Исправлено: image.yml как в уроке. Закоммить правку и выпусти новый тег."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
