#!/usr/bin/env bash
# Поломки для урока 1.3 «Пользователи, права и sudo». Запуск: sudo bash break.sh 1|2|3|fix
# Меняет права на /var/lib/notes и файл /etc/sudoers.d/deploy-du: только для учебной ВМ.
set -euo pipefail

DATA_DIR=/var/lib/notes
DATA_FILE=$DATA_DIR/notes.txt
SUDOERS_FILE=/etc/sudoers.d/deploy-du
RULE='deploy ALL=(root) NOPASSWD: /usr/bin/du -sh /var/log'

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_notes() {
  if ! id notes >/dev/null 2>&1 || [[ ! -d $DATA_DIR ]]; then
    echo "Не найден пользователь notes или каталог $DATA_DIR. Сначала выполни задание 4 урока 1.3." >&2
    exit 1
  fi
}

need_deploy() {
  if ! id deploy >/dev/null 2>&1; then
    echo "Не найден пользователь deploy. Сначала выполни задание 3 урока 1.3." >&2
    exit 1
  fi
}

need_modern_sudo() {
  # В старом sudo 1.8 одна ошибка в sudoers.d отключает sudo целиком. Учебная поломка на таком не нужна.
  if sudo --version 2>/dev/null | head -n 1 | grep -q '^Sudo version 1\.8'; then
    echo "Здесь sudo 1.8: сценарий 2 может отключить sudo целиком, поэтому он не запускается." >&2
    exit 1
  fi
}

# Гарантирует, что файл данных есть (иначе ломать нечего)
ensure_data_file() {
  if [[ ! -f $DATA_FILE ]]; then
    printf '{"id": 1, "text": "первая заметка", "created_at": "2026-01-01T00:00:00+00:00"}\n' > "$DATA_FILE"
    chown notes:notes "$DATA_FILE"
    chmod 640 "$DATA_FILE"
  fi
}

case "${1:-}" in
  1)
    need_root 1; need_notes; ensure_data_file
    # Как будто файл и каталог создали от root при отладке
    chown -R root:root "$DATA_DIR"
    chmod 755 "$DATA_DIR"
    chmod 644 "$DATA_FILE"
    echo "Сценарий 1 готов. Запусти сервис от notes и отправь POST /notes."
    ;;
  2)
    need_root 2; need_deploy; need_modern_sudo
    # Опечатка: после ALL пропущено «=». Файл лежит в sudoers.d с обычным режимом 440
    printf 'deploy ALL(root) NOPASSWD: /usr/bin/du -sh /var/log\n' > "$SUDOERS_FILE"
    chown root:root "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    echo "Сценарий 2 готов. Выполни любую команду с sudo, потом: sudo -u deploy sudo -n /usr/bin/du -sh /var/log"
    ;;
  3)
    need_root 3; need_notes; ensure_data_file
    # Как будто кто-то «починил» права одной командой chmod -R 777
    chmod -R 777 "$DATA_DIR"
    echo "Сценарий 3 готов. Посмотри: ls -ld $DATA_DIR"
    ;;
  fix)
    need_root fix
    if [[ -d $DATA_DIR ]] && id notes >/dev/null 2>&1; then
      chown -R notes:notes "$DATA_DIR"
      chmod 750 "$DATA_DIR"
      find "$DATA_DIR" -type f -exec chmod 640 {} +
    fi
    if [[ -f $SUDOERS_FILE ]]; then
      tmp=$(mktemp)
      printf '%s\n' "$RULE" > "$tmp"
      if visudo -cf "$tmp" >/dev/null; then
        install -m 440 -o root -g root "$tmp" "$SUDOERS_FILE"
      fi
      rm -f "$tmp"
    fi
    echo "Всё возвращено: данные $DATA_DIR (750, владелец notes, файлы 640) и правило $SUDOERS_FILE, если они есть."
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
