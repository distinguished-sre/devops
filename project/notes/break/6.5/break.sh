#!/usr/bin/env bash
# Поломки для урока 6.5 «Эксплуатация в облаке». Запуск на ВМ notes-vm: sudo bash break.sh 1|2|3|fix
# Ломает регулярный бэкап БД, настроенный в задании 2 урока 6.5 (скрипт /usr/local/bin/notes-pg-backup-s3.sh,
# файл /etc/cron.d/notes-pg-backup, ключи в /home/deploy/.aws). Ничего не создаёт и не удаляет в облаке.
# Трогает только: режим файла cron.d, процесс-держатель замка (PID в /var/backups/notes/.break-6.5.pid)
# и файл /home/deploy/.aws/credentials (копия рядом, суффикс .break-6.5).
set -euo pipefail

CRON_FILE=/etc/cron.d/notes-pg-backup
SCRIPT=/usr/local/bin/notes-pg-backup-s3.sh
LOCK=/var/backups/notes/.lock
CRED=/home/deploy/.aws/credentials
CRED_SAVED=$CRED.break-6.5
PIDFILE=/var/backups/notes/.break-6.5.pid

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

# Задание 2 выполнено: скрипт бэкапа и запись cron на месте.
need_backup() {
  if [[ ! -x $SCRIPT || ! -f $CRON_FILE ]]; then
    echo "Нет $SCRIPT или $CRON_FILE. Сначала выполни задание 2 урока 6.5." >&2
    exit 1
  fi
}

holder_running() {
  [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

case "${1:-}" in
  1)
    need_root 1; need_backup
    # cron не читает файлы в /etc/cron.d, доступные на запись всем: бэкап молча перестаёт запускаться.
    chmod 666 "$CRON_FILE"
    echo "Сценарий 1 готов. Подожди 2-3 часа или сравни возраст последнего объекта в бакете с расписанием."
    ;;
  2)
    need_root 2; need_backup
    if ! holder_running; then
      # Процесс deploy держит тот же замок, что берёт скрипт бэкапа: скрипт печатает
      # «уже выполняется» и завершается с кодом 0, то есть cron считает запуск успешным.
      install -d -o deploy -g deploy -m 750 /var/backups/notes
      # Внутри bash пишем свой PID и заменяем процесс на sleep (exec): PID остаётся тем же, замок держится.
      # shellcheck disable=SC2016
      runuser -u deploy -- setsid nohup bash -c 'echo $$ > "$1"; exec 9>"$2"; flock -n 9 && exec sleep 86400' \
        _ "$PIDFILE" "$LOCK" >/dev/null 2>&1 &
      sleep 1
    fi
    echo "Сценарий 2 готов. Запусти скрипт вручную и посмотри на его вывод и код возврата: sudo -u deploy $SCRIPT; echo код=\$?"
    ;;
  3)
    need_root 3; need_backup
    if [[ -f $CRED && ! -f $CRED_SAVED ]]; then
      mv "$CRED" "$CRED_SAVED"
    fi
    echo "Сценарий 3 готов. Запусти скрипт вручную: sudo -u deploy $SCRIPT; echo код=\$?"
    ;;
  fix)
    need_root fix
    if [[ -f $CRON_FILE ]]; then
      chmod 644 "$CRON_FILE"
    fi
    if holder_running; then
      kill "$(cat "$PIDFILE")" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
    if [[ -f $CRED_SAVED ]]; then
      mv -f "$CRED_SAVED" "$CRED"
    fi
    echo "Всё возвращено: cron.d 644, замок свободен, ключи на месте."
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
