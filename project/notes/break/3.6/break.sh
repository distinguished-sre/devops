#!/usr/bin/env bash
# Поломки для урока 3.6 «GitLab CI и Jenkins». Запуск: bash break.sh 1|2|3|fix
# Без sudo: сценарии 1 и 2 правят .gitlab-ci.yml в ~/notes на отдельной ветке break/3.6,
# сценарий 3 убирает клиент docker из контейнера jenkins (файл переименовывается, не удаляется).
set -euo pipefail

NOTES=${NOTES_DIR:-$HOME/notes}
JENKINS=${JENKINS_CONTAINER:-jenkins}
BRANCH=break/3.6
CI_FILE=.gitlab-ci.yml
# Состояние сценариев 1 и 2 (какая ветка была до поломки, какой сценарий применён) лежит внутри .git.
STATE="$NOTES/.git/break-3.6.state"

if [[ $EUID -eq 0 ]]; then
  echo "Не запускай через sudo: скрипт правит файлы твоего пользователя. Запуск: bash $0 ${1:-}" >&2
  exit 1
fi

usage() {
  echo "Использование: bash $0 1|2|3|fix" >&2
  exit 2
}

git_notes() {
  git -C "$NOTES" "$@"
}

need_repo() {
  if ! git_notes rev-parse --git-dir >/dev/null 2>&1; then
    echo "Не найден репозиторий $NOTES. Сначала пройди уроки 3.1-3.3." >&2
    exit 1
  fi
}

need_ci_file() {
  if [[ ! -f $NOTES/$CI_FILE ]]; then
    echo "В $NOTES нет $CI_FILE. Сначала выполни задание 1 урока 3.6 (перейди на ветку, где файл закоммичен)." >&2
    exit 1
  fi
}

# Docker: сначала обычный вызов, если нет доступа к сокету, то через sudo.
docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

current_branch() {
  git_notes symbolic-ref --short HEAD 2>/dev/null || true
}

state_get() {
  sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -1
}

# Применён ли сценарий $1 (печатает сообщение). Другой применённый сценарий: остановка с подсказкой про fix.
already_applied() {
  local applied
  [[ -f $STATE ]] || return 1
  applied=$(state_get scenario)
  if [[ $applied == "$1" ]]; then
    echo "Сценарий $1 уже применён (ветка $BRANCH). Чтобы вернуть как было: bash $0 fix"
    return 0
  fi
  echo "Уже применён сценарий $applied. Сначала: bash $0 fix" >&2
  exit 1
}

# Готовит ветку break/3.6 для сценария $1 и запоминает, с какой ветки ушли.
start_git_scenario() {
  local cur
  if [[ -n $(git_notes status --porcelain --untracked-files=no) ]]; then
    echo "В $NOTES есть незакоммиченные изменения. Закоммить или убери их и повтори." >&2
    exit 1
  fi
  if git_notes show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "Ветка $BRANCH уже есть, но скрипт её не создавал. Удали её (git branch -D $BRANCH) и повтори." >&2
    exit 1
  fi
  cur=$(current_branch)
  if [[ -z $cur ]]; then
    echo "Репозиторий в состоянии detached HEAD. Перейди на ветку (git switch main) и повтори." >&2
    exit 1
  fi
  printf 'base=%s\nscenario=%s\n' "$cur" "$1" >"$STATE"
  git_notes switch -q -c "$BRANCH"
}

commit_break() {
  git_notes commit -q -am "break 3.6: сценарий $1"
}

# Сценарий 1: job просит тег, которого нет ни у одного раннера.
scenario1() {
  need_repo
  already_applied 1 && return 0
  need_ci_file
  if ! grep -q '^  tags: \[docker\]' "$NOTES/$CI_FILE"; then
    echo "В $CI_FILE нет строк 'tags: [docker]'. Сначала выполни задание 2 урока 3.6." >&2
    exit 1
  fi
  start_git_scenario 1
  sed -i 's/^  tags: \[docker\]/  tags: [docker-arm]/' "$NOTES/$CI_FILE"
  commit_break 1
  echo "Сценарий 1 готов: ветка $BRANCH, в jobs тег docker-arm."
  echo "Отправь и открой merge request: git push -o merge_request.create -u gitlab $BRANCH"
}

# Сценарий 2: опечатка в имени образа (лишняя буква m в python:3.13m).
scenario2() {
  need_repo
  already_applied 2 && return 0
  need_ci_file
  if ! grep -q '^  image: python:3\.13\([[:space:]]\|$\)' "$NOTES/$CI_FILE"; then
    echo "В $CI_FILE нет строки '  image: python:3.13' (в блоке default). Сверь файл с заданием 1." >&2
    exit 1
  fi
  start_git_scenario 2
  sed -i 's/^\(  image: python:3\.13\)\([[:space:]]\|$\)/\1m\2/' "$NOTES/$CI_FILE"
  commit_break 2
  echo "Сценарий 2 готов: ветка $BRANCH, образ python:3.13m."
  echo "Отправь и открой merge request: git push -o merge_request.create -u gitlab $BRANCH"
}

# Сценарий 3: у Jenkins пропадает клиент docker (как в обычном образе jenkins/jenkins).
scenario3() {
  if ! docker_cmd inspect "$JENKINS" >/dev/null 2>&1; then
    echo "Нет контейнера $JENKINS. Сначала выполни задание 3 урока 3.6." >&2
    exit 1
  fi
  if [[ $(docker_cmd inspect -f '{{.State.Running}}' "$JENKINS") != true ]]; then
    docker_cmd start "$JENKINS" >/dev/null
    sleep 2
  fi
  if docker_cmd exec "$JENKINS" test -e /usr/bin/docker.off; then
    echo "Сценарий 3 уже применён. Чтобы вернуть как было: bash $0 fix"
    return 0
  fi
  if ! docker_cmd exec "$JENKINS" test -x /usr/bin/docker; then
    echo "В контейнере $JENKINS нет /usr/bin/docker: клиент уже отсутствует, ломать нечего." >&2
    exit 1
  fi
  docker_cmd exec -u root "$JENKINS" mv /usr/bin/docker /usr/bin/docker.off
  echo "Сценарий 3 готов: в контейнере $JENKINS нет клиента docker. Запусти сборку: Build Now."
}

fix_git() {
  local base cur
  [[ -f $STATE ]] || return 0
  base=$(state_get base)
  cur=$(current_branch)
  if [[ $cur == "$BRANCH" ]]; then
    if [[ -n $(git_notes status --porcelain --untracked-files=no) ]]; then
      echo "На ветке $BRANCH есть незакоммиченные изменения. Закоммить или убери их и повтори fix." >&2
      exit 1
    fi
    git_notes switch -q "$base"
  fi
  # Ветку создал скрипт, её удаление ничего не теряет: файл на $base не менялся.
  if git_notes show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git_notes branch -q -D "$BRANCH"
  fi
  rm -f "$STATE"
  echo "Ветка $BRANCH удалена, ты на ветке ${base}. Если ветку уже отправляли: git push gitlab --delete $BRANCH"
}

fix_jenkins() {
  if ! docker_cmd inspect "$JENKINS" >/dev/null 2>&1; then
    return 0
  fi
  if [[ $(docker_cmd inspect -f '{{.State.Running}}' "$JENKINS") != true ]]; then
    docker_cmd start "$JENKINS" >/dev/null
    sleep 2
  fi
  if docker_cmd exec "$JENKINS" test -e /usr/bin/docker.off; then
    docker_cmd exec -u root "$JENKINS" mv /usr/bin/docker.off /usr/bin/docker
    echo "В контейнере $JENKINS клиент docker возвращён."
  fi
}

case "${1:-}" in
  1) scenario1 ;;
  2) scenario2 ;;
  3) scenario3 ;;
  fix)
    if git_notes rev-parse --git-dir >/dev/null 2>&1; then
      fix_git
    fi
    fix_jenkins
    echo "Готово: файлы и контейнер в рабочем состоянии."
    ;;
  *) usage ;;
esac
