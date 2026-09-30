#!/usr/bin/env bash
# Поломки для урока 7.6 «Ansible: роли и деплой "Заметок"». Запуск: bash break.sh 1|2|3|fix
# Меняет только файлы в каталоге ansible (по умолчанию ~/notes/infra/ansible), без sudo.
# Другой каталог: ANSIBLE_DIR=/путь bash break.sh 1
set -euo pipefail

DIR="${ANSIBLE_DIR:-$HOME/notes/infra/ansible}"
CFG="$DIR/ansible.cfg"
TPL="$DIR/roles/notes/templates/notes.env.j2"
VARS="$DIR/roles/notes/vars/main.yml"
# В ansible.cfg путь пишется с тильдой, как в уроке; Ansible раскрывает её сам.
# shellcheck disable=SC2088
GOOD_CFG='~/.notes-secrets/ansible-vault-pass'
# Файл со "старым" паролем: сценарий 1 подсовывает его в ansible.cfg.
OLD_PASS="$HOME/.notes-secrets/break-7.6-old-pass"
# shellcheck disable=SC2088
OLD_CFG='~/.notes-secrets/break-7.6-old-pass'
# Метка в vars/main.yml: fix удаляет только файл, созданный сценарием.
MARK="# break-7.6"

if [[ $EUID -eq 0 ]]; then
  echo "Запусти без sudo, от своего пользователя: bash $0 ${1:-}" >&2
  exit 1
fi

if [[ ! -f $CFG || ! -f $TPL || ! -f $DIR/group_vars/all/vault.yml ]]; then
  echo "Не найдены ansible.cfg, роль notes или vault.yml в $DIR. Сначала пройди задания 1-3 урока 7.6." >&2
  exit 1
fi
if ! grep -q '^vault_password_file' "$CFG"; then
  echo "В $CFG нет строки vault_password_file. Сначала пройди задание 2 урока 7.6." >&2
  exit 1
fi

case "${1:-}" in
  1)
    # Вместо настоящего файла пароля в конфиге указан другой, с чужим паролем.
    if [[ ! -f $OLD_PASS ]]; then
      (umask 077; openssl rand -base64 24 > "$OLD_PASS")
    fi
    sed -i.bak "s|^vault_password_file.*|vault_password_file = $OLD_CFG|" "$CFG"
    rm -f "$CFG.bak"
    echo "Сценарий 1 готов. Проверь: cd $DIR && ansible-playbook site.yml"
    ;;
  2)
    # Опечатка в имени переменной внутри шаблона. Повторный запуск ничего не меняет.
    sed -i.bak 's/{{ notes_db_password }}/{{ notes_db_pasword }}/g' "$TPL"
    rm -f "$TPL.bak"
    echo "Сценарий 2 готов. Проверь: cd $DIR && ansible-playbook site.yml"
    ;;
  3)
    if [[ -f $VARS ]] && ! grep -qx "$MARK" "$VARS"; then
      echo "Файл $VARS уже есть и создан не сценарием. Сценарий 3 его не трогает." >&2
      exit 1
    fi
    mkdir -p "$(dirname "$VARS")"
    printf '%s\nnotes_tag: "0.0.1"\n' "$MARK" > "$VARS"
    echo "Сценарий 3 готов. Проверь: cd $DIR && ansible-playbook site.yml --check --diff"
    ;;
  fix)
    sed -i.bak "s|^vault_password_file.*|vault_password_file = $GOOD_CFG|" "$CFG"
    rm -f "$CFG.bak" "$OLD_PASS"
    sed -i.bak 's/{{ notes_db_pasword }}/{{ notes_db_password }}/g' "$TPL"
    rm -f "$TPL.bak"
    if [[ -f $VARS ]] && grep -qx "$MARK" "$VARS"; then
      rm -f "$VARS"
      rmdir "$(dirname "$VARS")" 2>/dev/null || true
    fi
    echo "Всё возвращено: пароль vault из $GOOD_CFG, шаблон с notes_db_password, roles/notes/vars удалён."
    ;;
  *)
    echo "Использование: bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
