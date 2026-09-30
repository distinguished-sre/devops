#!/usr/bin/env bash
# Поломки для урока 1.1 «Первый сервер». Запуск: bash break-1.1.sh 1|2|3|fix
# Работает только с файлами твоего пользователя (~/notes и ~/.bashrc), sudo не нужен.
# Ничего не удаляет: то, что «пропало», лежит в ~/.break-1.1, оттуда его вернёт fix.
set -euo pipefail

# Свой PATH, чтобы скрипт работал, даже если оболочка сломана сценарием 3
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

STASH="$HOME/.break-1.1"
NOTES="$HOME/notes"
WRONG="$HOME/note"
BASHRC="$HOME/.bashrc"
MARK="# break-1.1"

if [[ $EUID -eq 0 ]]; then
  echo "Не запускай через sudo и не от root: поломка делается в твоём домашнем каталоге." >&2
  echo "Запусти так: bash $0 ${1:-1}" >&2
  exit 1
fi

need_notes() {
  if [[ ! -f $NOTES/app.py ]]; then
    echo "Не найден $NOTES/app.py. Сначала выполни задание 5 урока 1.1." >&2
    exit 1
  fi
}

case "${1:-}" in
  1)
    need_notes
    mkdir -p "$STASH"
    mv "$NOTES/app.py" "$STASH/app.py"
    echo "Сценарий 1 готов. Проверь: cd ~/notes && python3 app.py"
    ;;
  2)
    need_notes
    mv "$NOTES" "$WRONG"
    echo "Сценарий 2 готов. Проверь: cd ~/notes"
    ;;
  3)
    if ! grep -qF "$MARK" "$BASHRC" 2>/dev/null; then
      printf '%s\nPATH=/opt/tool/bin  %s\n' "$MARK" "$MARK" >> "$BASHRC"
    fi
    echo "Сценарий 3 готов. Открой новую оболочку: exec bash"
    echo "Дальше проверяй: python3 --version"
    ;;
  fix)
    # Сценарий 1: вернуть app.py, если каталога с файлом нет на месте
    if [[ -f $STASH/app.py && ! -e $NOTES/app.py ]]; then
      mkdir -p "$NOTES"
      mv "$STASH/app.py" "$NOTES/app.py"
    fi
    # Сценарий 2: вернуть имя каталога
    if [[ -d $WRONG && ! -e $NOTES ]]; then
      mv "$WRONG" "$NOTES"
    fi
    # Сценарий 3: убрать строки поломки из ~/.bashrc
    if grep -qF "$MARK" "$BASHRC" 2>/dev/null; then
      sed -i "/$MARK/d" "$BASHRC"
    fi
    rmdir "$STASH" 2>/dev/null || true
    echo "Всё возвращено: ~/notes/app.py на месте, ~/.bashrc очищен."
    echo "Если PATH в открытой оболочке сломан, выполни: exec bash"
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
