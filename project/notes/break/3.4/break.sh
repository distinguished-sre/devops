#!/usr/bin/env bash
# Поломки для урока 3.4 «Качество и безопасность в CI». Запуск: bash break.sh 1|2|3|fix
# Работает только в репозитории ~/notes на отдельной ветке ci/break-drill (без sudo).
# Каждый сценарий делает коммит на этой ветке; fix возвращает ветку к состоянию до поломок.
set -euo pipefail

REPO=${NOTES_REPO:-$HOME/notes}
BRANCH=ci/break-drill
# «Утёкший» токен: выдуманный, формата ghp_ + 36 символов. Настоящим доступом не обладает.
FAKE_TOKEN=ghp_9xQ2mV7bLd4TfR8kZc1NwHy6PaJe3UsGo5Ki
INJECT_FILE=.github/workflows/inject-demo.yml
# $(whoami) в заголовке PR должен остаться текстом, поэтому одинарные кавычки
# shellcheck disable=SC2016
INJECT_TITLE='x"; echo INJECTED-$(whoami); echo "'

if [[ $EUID -eq 0 ]]; then
  echo "Не запускай через sudo: поломка в твоём репозитории, а не в системе." >&2
  exit 1
fi

usage() {
  echo "Использование: bash $0 1|2|3|fix" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
ACTION=$1
[[ $ACTION =~ ^(1|2|3|fix)$ ]] || usage

# Проверяем, что предыдущие уроки выполнены и мы в безопасном месте.
if [[ ! -d $REPO/.git ]]; then
  echo "Нет репозитория $REPO. Сначала пройди уроки 3.1 и 3.2." >&2
  exit 1
fi
cd "$REPO"
if [[ ! -f .github/workflows/ci.yml ]] \
  || ! grep -q '^  secrets:' .github/workflows/ci.yml \
  || ! grep -q '^  trivy-fs:' .github/workflows/ci.yml; then
  echo "В .github/workflows/ci.yml нет jobs secrets и trivy-fs. Сначала выполни задание 4 урока 3.4 и влей PR в main." >&2
  exit 1
fi
current=$(git branch --show-current)
if [[ $current != "$BRANCH" ]]; then
  echo "Ты на ветке '$current'. Поломки делаются только на '$BRANCH':" >&2
  echo "  git switch main && git pull && git switch -c $BRANCH" >&2
  exit 1
fi

BASE_FILE=$(git rev-parse --git-dir)/break-3.4-base

# Запоминаем коммит, с которого началась тренировка: до него откатывает fix.
remember_base() {
  if [[ ! -f $BASE_FILE ]]; then
    git rev-parse HEAD >"$BASE_FILE"
  fi
}

need_clean_tree() {
  if [[ -n $(git status --porcelain) ]]; then
    echo "В репозитории есть незакоммиченные изменения. Закоммить их или убери (git stash), потом повтори." >&2
    exit 1
  fi
}

# Сценарий 1: секрет добавлен и удалён следующим коммитом. В итоговом diff его нет, в истории он есть.
scenario1() {
  if git log --all --oneline -S"$FAKE_TOKEN" | grep -q .; then
    echo "Сценарий 1 уже применён: токен есть в истории ветки."
    return 0
  fi
  need_clean_tree
  remember_base
  printf '# локальные настройки разработчика\nGITHUB_TOKEN = "%s"\n' "$FAKE_TOKEN" >settings_local.py
  git add settings_local.py
  git commit -q -m "chore: локальные настройки"
  git rm -q settings_local.py
  git commit -q -m "chore: убрать локальные настройки"
  echo "Сценарий 1 применён: два коммита. Запушь ветку и открой Pull Request, проверь job secrets."
}

# Сценарий 2: workflow подставляет заголовок PR прямо в команду.
scenario2() {
  if [[ -f $INJECT_FILE ]]; then
    echo "Сценарий 2 уже применён: файл $INJECT_FILE есть."
    return 0
  fi
  need_clean_tree
  remember_base
  cat >"$INJECT_FILE" <<'YAML'
name: inject-demo
on:
  pull_request:
permissions:
  contents: read
jobs:
  hello:
    runs-on: ubuntu-24.04
    steps:
      - run: echo "Привет, ${{ github.event.pull_request.title }}"
YAML
  git add "$INJECT_FILE"
  git commit -q -m "ci: приветствие в Pull Request"
  echo "Сценарий 2 применён. Запушь ветку и открой Pull Request с заголовком ровно таким (одна строка):"
  printf '%s\n' "$INJECT_TITLE"
}

# Сценарий 3: в requirements.txt старая версия requests с известной CVE.
scenario3() {
  if grep -qx 'requests==2.19.0' requirements.txt 2>/dev/null; then
    echo "Сценарий 3 уже применён: в requirements.txt есть requests==2.19.0."
    return 0
  fi
  need_clean_tree
  remember_base
  echo 'requests==2.19.0' >>requirements.txt
  git add requirements.txt
  git commit -q -m "chore: правки окружения"
  echo "Сценарий 3 применён. Запушь ветку и открой Pull Request, проверь job trivy-fs."
}

# fix: возвращаем ветку к коммиту, с которого началась тренировка.
fix() {
  if [[ ! -f $BASE_FILE ]]; then
    echo "Нечего чинить: сценарии на этой ветке не применялись."
    return 0
  fi
  local base
  base=$(cat "$BASE_FILE")
  if ! git merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
    echo "Коммит $base не найден в истории ветки, откат не делаю. Проще удалить ветку и создать заново." >&2
    return 1
  fi
  git reset -q --hard "$base"
  rm -f "$BASE_FILE"
  echo "Ветка $BRANCH возвращена к коммиту ${base:0:7}. Если ты уже пушил её, закрой PR и удали ветку на GitHub:"
  echo "  git push origin --delete $BRANCH"
}

case $ACTION in
  1) scenario1 ;;
  2) scenario2 ;;
  3) scenario3 ;;
  fix) fix ;;
esac
