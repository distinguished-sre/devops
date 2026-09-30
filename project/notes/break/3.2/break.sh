#!/usr/bin/env bash
# Поломки для урока 3.2 «Удалённые репозитории, rebase, конфликты». Запуск: bash break.sh 1|2|3|fix
# Работает только в каталоге ~/break-3.2 (голый «сервер» origin.git и твой клон me).
# Твой проект ~/notes и каталог ~/sandbox из практики не трогает. Без sudo.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Не запускай через sudo: песочница создаётся в домашнем каталоге обычного пользователя." >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "Не найден git. Сначала пройди урок 3.1." >&2
  exit 1
fi

DIR=$HOME/break-3.2
SERVER=$DIR/origin.git
ME=$DIR/me
MARK=$DIR/.break-3.2

# Все git-команды скрипта идут от имени учебных «людей»: глобальные настройки не нужны и не меняются.
as() { # as <имя> <аргументы git>
  local who=$1
  shift
  GIT_AUTHOR_NAME=$who GIT_AUTHOR_EMAIL=$who@example.com \
    GIT_COMMITTER_NAME=$who GIT_COMMITTER_EMAIL=$who@example.com \
    GIT_EDITOR=true git -c init.defaultBranch=main -c pull.ff=only "$@"
}

# Удаляем только каталог, который создал этот скрипт (есть метка), и только по точному пути.
wipe() {
  if [[ -e $DIR && ! -f $MARK ]]; then
    echo "Каталог $DIR есть, но создан не этим скриптом. Не трогаю. Переименуй его и запусти снова." >&2
    exit 1
  fi
  if [[ -d $DIR ]]; then
    rm -rf -- "$DIR"
  fi
}

# Чистое состояние: сервер, три коммита в main, твой клон me и клон коллеги colleague в порядке.
base() {
  wipe
  mkdir -p "$DIR"
  echo "$1" >"$MARK"
  as admin init -q --bare -b main "$SERVER"
  as admin clone -q "$SERVER" "$DIR/colleague" 2>/dev/null
  (
    cd "$DIR/colleague"
    printf 'app=notes\nversion=1.0\nowner=team\n' >config.txt
    printf '# Настройки\n' >README.md
    as colleague add .
    as colleague commit -q -m "Добавить config.txt и README"
    echo 'debug=false' >>config.txt
    as colleague commit -q -am "Добавить debug"
    as colleague push -q -u origin main 2>/dev/null
  )
  as me clone -q "$SERVER" "$ME"
  git -C "$ME" config user.name me
  git -C "$ME" config user.email me@example.com
  git -C "$DIR/colleague" config user.name colleague
  git -C "$DIR/colleague" config user.email colleague@example.com
}

# Есть ли уже песочница со сломанным сценарием (после fix в метке лежит «чисто»).
active() {
  [[ -f $MARK && $(cat "$MARK") != чисто ]]
}

case "${1:-}" in
  1)
    if active; then
      echo "Песочница уже есть (сценарий $(cat "$MARK")). Ничего не меняю. Чтобы начать заново: bash $0 fix, потом снова $0 1."
      exit 0
    fi
    base 1
    (
      cd "$DIR/colleague"
      echo 'timeout=30' >>config.txt
      as colleague commit -q -am "Добавить timeout"
      as colleague push -q
    )
    (
      cd "$ME"
      echo 'Запуск: python3 app.py' >>README.md
      as me commit -q -am "Описать запуск в README"
    )
    echo "Сценарий 1 готов. Каталог: cd $ME. Отправь свой коммит: git push"
    ;;
  2)
    if active; then
      echo "Песочница уже есть (сценарий $(cat "$MARK")). Ничего не меняю. Чтобы начать заново: bash $0 fix, потом снова $0 2."
      exit 0
    fi
    base 2
    (
      cd "$DIR/colleague"
      sed -i 's/version=1.0/version=2.0/' config.txt
      as colleague commit -q -am "Поднять версию до 2.0"
      as colleague push -q
    )
    (
      cd "$ME"
      sed -i 's/version=1.0/version=1.5/' config.txt
      echo 'timeout=30' >>config.txt
      as me commit -q -am "Поднять версию до 1.5 и добавить timeout"
      # rebase остановится на конфликте: это и есть состояние сценария, поэтому ошибку глушим
      as me pull -q --rebase >/dev/null 2>&1 || true
    )
    echo "Сценарий 2 готов. Каталог: cd $ME. Проверь: git status"
    ;;
  3)
    if active; then
      echo "Песочница уже есть (сценарий $(cat "$MARK")). Ничего не меняю. Чтобы начать заново: bash $0 fix, потом снова $0 3."
      exit 0
    fi
    base 3
    (
      cd "$ME"
      echo 'retention=14' >>config.txt
      as me commit -q -am "Добавить срок хранения"
      as me push -q
      # У «тебя» в reflog остаётся то, что было на сервере до force-push
      cd "$DIR/colleague"
      as colleague pull -q
      as colleague reset -q --hard HEAD~1
      echo 'Логи: journalctl -u notes' >>README.md
      as colleague commit -q -am "Описать логи в README"
      as colleague push -q --force
    )
    as me -C "$ME" fetch -q
    echo "Сценарий 3 готов. Каталог: cd $ME. Проверь: git status"
    ;;
  fix)
    base чисто
    echo "Всё возвращено: $ME чистый, синхронизирован с сервером $SERVER, rebase и конфликтов нет."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
