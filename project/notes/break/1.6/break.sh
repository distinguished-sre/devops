#!/usr/bin/env bash
# Поломки для урока 1.6 «Основы bash и Make». Запуск: bash /tmp/break-1.6.sh 1|2|3|fix
# Правит только Makefile и test_app.py в ~/notes. Без sudo: файлы принадлежат тебе.
set -euo pipefail

NOTES_DIR="${HOME}/notes"
MAKEFILE="${NOTES_DIR}/Makefile"
TESTS="${NOTES_DIR}/test_app.py"

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo: bash $0 ${1:-}. Иначе файлы в ~/notes станут принадлежать root." >&2
  exit 1
fi

need_files() {
  if [[ ! -f $MAKEFILE || ! -f $TESTS ]]; then
    echo "Не найдены ${MAKEFILE} и ${TESTS}. Сначала выполни задание 5 урока 1.6." >&2
    exit 1
  fi
}

# В sed нужны одинарные кавычки: $(PYTHON) не должна раскрываться оболочкой
# shellcheck disable=SC2016
case "${1:-}" in
  1)
    need_files
    # В команде unittest вместо TAB ставим 4 пробела: Make не поймёт строку
    sed -i 's/^\t\$(PYTHON) -m unittest -v$/    $(PYTHON) -m unittest -v/' "$MAKEFILE"
    echo "Сценарий 1 готов. Проверь: cd ~/notes && make test"
    ;;
  2)
    need_files
    # Тест ждёт версию v1, а сервис в тесте запускается с APP_VERSION=test
    sed -i 's/Notes service vtest/Notes service v1/' "$TESTS"
    echo "Сценарий 2 готов. Проверь: cd ~/notes && make test"
    ;;
  3)
    need_files
    # Опечатка в имени переменной: PROT вместо PORT
    sed -i 's/PORT=\$(PORT) /PORT=$(PROT) /' "$MAKEFILE"
    echo "Сценарий 3 готов. Проверь: cd ~/notes && make run PORT=9000"
    ;;
  fix)
    need_files
    sed -i 's/^ \+\(\$(PYTHON)\)/\t\1/' "$MAKEFILE"
    sed -i 's/Notes service v1/Notes service vtest/' "$TESTS"
    sed -i 's/PORT=\$(PROT) /PORT=$(PORT) /' "$MAKEFILE"
    echo "Всё возвращено: TAB в Makefile, ожидание vtest в test_app.py, PORT=\$(PORT) в run."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
