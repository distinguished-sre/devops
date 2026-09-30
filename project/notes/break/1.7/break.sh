#!/usr/bin/env bash
# Поломки для урока 1.7 «Bash в эксплуатации». Запуск: sudo bash break.sh 1|2|3|4|fix
# Портит только скрипты и расписание «Заметок» из этого урока: /usr/local/bin/notes-backup.sh
# и /etc/cron.d/notes. Оригиналы сохраняются в /var/lib/notes-break-1.7, `fix` их возвращает.
set -euo pipefail

BACKUP_SH=/usr/local/bin/notes-backup.sh
CRON_FILE=/etc/cron.d/notes
BACKUP_DIR=/var/backups/notes
STATE=/var/lib/notes-break-1.7

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

need_lesson() {
  if [[ ! -f $BACKUP_SH || ! -f $CRON_FILE || ! -f /usr/local/bin/notes-healthcheck.sh ]]; then
    echo "Не найдены $BACKUP_SH, /usr/local/bin/notes-healthcheck.sh или $CRON_FILE." >&2
    echo "Сначала выполни задание «Шаг проекта» урока 1.7." >&2
    exit 1
  fi
}

# Возвращает скрипт бэкапа и расписание из сохранённых копий. Безопасно вызывать повторно.
restore() {
  [[ -d $STATE ]] || return 0
  if [[ -f $STATE/notes-backup.sh ]]; then
    install -m 755 -o root -g root "$STATE/notes-backup.sh" "$BACKUP_SH"
  fi
  if [[ -f $STATE/notes ]]; then
    install -m 644 -o root -g root "$STATE/notes" "$CRON_FILE"
  fi
  # мусор, который создали поломки: пустые (меньше 100 байт) архивы и «чужие» файлы с именами из сценария 2
  find "$BACKUP_DIR" -maxdepth 1 -name 'notes-*.tar.gz' -size -100c -delete 2>/dev/null || true
  rm -f -- "$BACKUP_DIR"/notes-2025010?-0000.tar.gz "$BACKUP_DIR/notes-old copy.tar.gz" \
    "$BACKUP_DIR"/notes-????????-??????.tar.gz
  pkill -f "$BACKUP_SH" 2>/dev/null || true
  pkill -f 'sleep 90' 2>/dev/null || true
  rm -rf -- "$STATE"
}

# Сохраняет оригиналы один раз: повторный запуск сценария не затирает их поломанной версией.
save_originals() {
  mkdir -p "$STATE"
  chmod 700 "$STATE"
  [[ -f $STATE/notes-backup.sh ]] || cp -p "$BACKUP_SH" "$STATE/notes-backup.sh"
  [[ -f $STATE/notes ]] || cp -p "$CRON_FILE" "$STATE/notes"
}

install_script() {
  install -m 755 -o root -g root /dev/stdin "$BACKUP_SH"
}

case "${1:-}" in
  1)
    need_root 1; need_lesson; restore; save_originals
    # нет строгого режима и опечатка в пути к данным: tar падает, а скрипт идёт дальше
    install_script <<'SCRIPT'
#!/usr/bin/env bash
# Бэкап данных «Заметок»: tar.gz, хранение 7 последних копий.

DATA_DIR="${NOTES_DATA_DIR:-/var/lib/note}"
BACKUP_DIR="${NOTES_BACKUP_DIR:-/var/backups/notes}"
LOCK_FILE="${NOTES_LOCK_FILE:-/run/lock/notes-backup.lock}"
KEEP=7

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "notes-backup: уже запущен, выхожу" >&2
  exit 0
fi

mkdir -p "$BACKUP_DIR"

tmp=$(mktemp "$BACKUP_DIR/.notes-XXXXXX.tmp")
trap 'rm -f "$tmp"' EXIT

stamp=$(date +%Y%m%d-%H%M)
tar -czf "$tmp" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"
mv "$tmp" "$BACKUP_DIR/notes-$stamp.tar.gz"

backups=("$BACKUP_DIR"/notes-*.tar.gz)
extra=$(( ${#backups[@]} - KEEP ))
if (( extra > 0 )); then
  rm -f -- "${backups[@]:0:extra}"
fi

logger -t notes-backup "готово: notes-$stamp.tar.gz"
SCRIPT
    echo "Сценарий 1 готов. Запусти бэкап: sudo $BACKUP_SH; echo \"код=\$?\"; sudo ls -l $BACKUP_DIR"
    ;;
  2)
    need_root 2; need_lesson; restore; save_originals
    mkdir -p "$BACKUP_DIR"
    # девять «старых» архивов и один с пробелом в имени, чтобы ротации было что удалять
    for i in 1 2 3 4 5 6 7 8 9; do
      touch -d "$((i + 20)) days ago" "$BACKUP_DIR/notes-2025010$i-0000.tar.gz"
    done
    touch -d "40 days ago" "$BACKUP_DIR/notes-old copy.tar.gz"
    # ротация написана циклом по выводу ls без кавычек
    install_script <<'SCRIPT'
#!/usr/bin/env bash
# Бэкап данных «Заметок»: tar.gz, хранение 7 последних копий.
set -euo pipefail

DATA_DIR="${NOTES_DATA_DIR:-/var/lib/notes}"
BACKUP_DIR="${NOTES_BACKUP_DIR:-/var/backups/notes}"
LOCK_FILE="${NOTES_LOCK_FILE:-/run/lock/notes-backup.lock}"
KEEP=7

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "notes-backup: уже запущен, выхожу" >&2
  exit 0
fi

mkdir -p "$BACKUP_DIR"

tmp=$(mktemp "$BACKUP_DIR/.notes-XXXXXX.tmp")
trap 'rm -f "$tmp"' EXIT

stamp=$(date +%Y%m%d-%H%M)
tar -czf "$tmp" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"
mv "$tmp" "$BACKUP_DIR/notes-$stamp.tar.gz"

for f in $(ls -1t "$BACKUP_DIR"/notes-*.tar.gz | tail -n +$((KEEP + 1))); do
  echo "удаляю старую копию: $f"
  rm $f
done

logger -t notes-backup "готово: notes-$stamp.tar.gz"
SCRIPT
    echo "Сценарий 2 готов. Запусти бэкап: sudo $BACKUP_SH; echo \"код=\$?\"; sudo ls -1 $BACKUP_DIR"
    ;;
  3)
    need_root 3; need_lesson; restore; save_originals
    # в таблице нет SHELL=/bin/bash, а команда использует синтаксис bash: cron запустит её через /bin/sh
    cat > "$CRON_FILE" <<'CRON'
# Расписание «Заметок» (урок 1.7)
PATH=/usr/local/bin:/usr/bin:/bin

*/30 * * * * root /usr/local/bin/notes-backup.sh
* * * * * root [[ -x /usr/local/bin/notes-healthcheck.sh ]] && /usr/local/bin/notes-healthcheck.sh
CRON
    chmod 644 "$CRON_FILE"
    echo "Сценарий 3 готов. Останови приложение и подожди 2-3 минуты: в /var/log/notes-health.log должны появляться строки раз в минуту."
    echo "Вручную: sudo /usr/local/bin/notes-healthcheck.sh; echo \"код=\$?\""
    ;;
  4)
    need_root 4; need_lesson; restore; save_originals
    # нет flock, а «данных много»: бэкап идёт 90 секунд, и cron запускает его каждую минуту
    install_script <<'SCRIPT'
#!/usr/bin/env bash
# Бэкап данных «Заметок»: tar.gz, хранение 7 последних копий.
set -euo pipefail

DATA_DIR="${NOTES_DATA_DIR:-/var/lib/notes}"
BACKUP_DIR="${NOTES_BACKUP_DIR:-/var/backups/notes}"
KEEP=7

mkdir -p "$BACKUP_DIR"

tmp=$(mktemp "$BACKUP_DIR/.notes-XXXXXX.tmp")
trap 'rm -f "$tmp"' EXIT

stamp=$(date +%Y%m%d-%H%M%S)
tar -czf "$tmp" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"
sleep 90   # имитация медленного диска и большого объёма данных
mv "$tmp" "$BACKUP_DIR/notes-$stamp.tar.gz"

backups=("$BACKUP_DIR"/notes-*.tar.gz)
extra=$(( ${#backups[@]} - KEEP ))
if (( extra > 0 )); then
  rm -f -- "${backups[@]:0:extra}"
fi

logger -t notes-backup "готово: notes-$stamp.tar.gz"
SCRIPT
    cat > "$CRON_FILE" <<'CRON'
# Расписание «Заметок» (урок 1.7)
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin

* * * * * root /usr/local/bin/notes-backup.sh
* * * * * root /usr/local/bin/notes-healthcheck.sh
CRON
    chmod 644 "$CRON_FILE"
    echo "Сценарий 4 готов. Подожди 2-3 минуты и посмотри: pgrep -af notes-backup; sudo ls -l $BACKUP_DIR"
    ;;
  fix)
    need_root fix
    restore
    echo "Всё возвращено: $BACKUP_SH и $CRON_FILE как до поломки, лишние процессы и файлы бэкапа из сценариев удалены."
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|4|fix" >&2
    exit 2
    ;;
esac
