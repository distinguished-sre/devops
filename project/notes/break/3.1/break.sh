#!/usr/bin/env bash
# Поломки для урока 3.1 «Git: коммиты, история и ветки». Запуск: bash break.sh 1|2|fix
# Всё создаётся в отдельном каталоге ~/break-3.1, твои ~/notes и ~/git-lab не затрагиваются.
# Запускай от обычного пользователя, без sudo.
set -euo pipefail

BASE="$HOME/break-3.1"
MARK="$BASE/.break-3.1"

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo, от своего пользователя: bash $0 ${1:-}" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "Не найден git. Сначала пройди начало практики урока 3.1." >&2
  exit 1
fi

# Идентичность для коммитов сценария: задаём через окружение, чтобы не трогать настройки ученика.
export GIT_AUTHOR_NAME="Коллега" GIT_AUTHOR_EMAIL="colleague@example.com"
export GIT_COMMITTER_NAME="Коллега" GIT_COMMITTER_EMAIL="colleague@example.com"

need_git_identity() {
  if [[ -z "$(git config --global user.name || true)" || -z "$(git config --global user.email || true)" ]]; then
    echo "Не заданы user.name и user.email. Выполни git config --global из начала практики урока 3.1." >&2
    exit 1
  fi
}

# Каталог сценария уже есть: повторно ничего не создаём, чтобы не затереть твою работу.
already() {
  if [[ -d "$BASE/$1" ]]; then
    echo "Сценарий $2 уже применён: репозиторий $BASE/$1 на месте."
    echo "Чтобы начать заново, выполни: bash $0 fix"
    exit 0
  fi
}

mkbase() {
  mkdir -p "$BASE"
  : > "$MARK"
}

# Сценарий 1: коллега сделал git reset --hard и потерял два коммита с правками app.py.
scenario1() {
  already lost 1
  mkbase
  mkdir "$BASE/lost"
  cd "$BASE/lost"
  git init -q -b main
  printf '# app.py: версия 1\nGET /healthz\n' > app.py
  git add app.py
  git commit -q -m "feat: первая версия app.py"
  printf 'GET /headers\n' >> app.py
  git commit -q -am "feat: добавить /headers"
  printf 'DELETE вернёт 405\n' >> app.py
  git commit -q -am "fix: вернуть 405 на DELETE"
  git reset -q --hard HEAD~2
  echo "Готово. Репозиторий: $BASE/lost"
  echo "Симптом: коллега сделал git reset --hard, и два его коммита с правками app.py пропали из git log."
}

# Сценарий 2: в истории лежит коммит с настоящим на вид паролем в .env.
scenario2() {
  already leak 2
  mkbase
  mkdir "$BASE/leak"
  cd "$BASE/leak"
  git init -q -b main
  printf '# app.py: версия 1\nGET /healthz\n' > app.py
  git add app.py
  git commit -q -m "feat: первая версия app.py"
  printf 'DB_PASSWORD=Zx9-notes-db-2026\n' > .env
  git add .env
  git commit -q -m "chore: добавить конфиг базы"
  printf '# Заметки\n' > README.md
  git add README.md
  git commit -q -m "docs: добавить README"
  echo "Готово. Репозиторий: $BASE/leak"
  echo "Симптом: в истории есть коммит, где закоммичен файл .env с паролем. Репозиторий только локальный."
}

# Возвращает чистое состояние: удаляет каталог сценариев, но только если в нём наша метка.
fix() {
  if [[ ! -e "$BASE" ]]; then
    echo "Нечего чинить: каталога $BASE нет."
    return 0
  fi
  if [[ ! -f "$MARK" ]]; then
    echo "В $BASE нет метки скрипта, поэтому я его не трогаю." >&2
    exit 1
  fi
  rm -rf -- "$BASE"
  echo "Учебные репозитории удалены (каталог $BASE)."
  echo "Если твой терминал стоял внутри него, выполни: cd ~"
}

case "${1:-}" in
  1) need_git_identity; scenario1 ;;
  2) need_git_identity; scenario2 ;;
  fix) fix ;;
  *) echo "Использование: bash $0 1|2|fix" >&2; exit 2 ;;
esac
