#!/usr/bin/env bash
# Поломки для урока 1.4 «Процессы и сигналы». Запуск: sudo bash break.sh 1|2|3|fix
# Все следы живут в /tmp/notes-break-1.4, в /tmp/notes.pid, /tmp/notes-start.sh и
# в каталоге /mnt/notes-break. Только для учебной ВМ.
set -euo pipefail

STATE=/tmp/notes-break-1.4      # pid-файлы и образ диска этого скрипта
PIDFILE=/tmp/notes.pid          # PID-файл «скрипта запуска» из сценария 2
STARTER=/tmp/notes-start.sh     # сам «скрипт запуска» из сценария 2
MNT=/mnt/notes-break            # точка монтирования из сценария 3
IMG=$STATE/disk.img

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
  if [[ -z ${SUDO_USER:-} || $SUDO_USER == root ]]; then
    echo "Запусти под своим пользователем через sudo, а не из-под root: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

user_home() { getent passwd "$SUDO_USER" | cut -d: -f6; }

need_app() {
  APP_DIR=$(user_home)/notes
  if [[ ! -f $APP_DIR/app.py ]]; then
    echo "Не найден $APP_DIR/app.py. Сначала пройди уроки 1.1-1.3 и задания этого урока." >&2
    exit 1
  fi
}

port_busy() { ss -tln | awk '{print $4}' | grep -q ':8080$'; }

need_free_port() {
  if port_busy; then
    echo "Порт 8080 уже занят. Останови свои запущенные «Заметки» (pgrep -af app.py) и повтори." >&2
    exit 1
  fi
}

# Завершает процесс из pid-файла, но только если это действительно app.py
# или наш писатель: номер мог достаться чужому процессу.
kill_recorded() {
  local file=$1 pattern=$2 pid
  [[ -f $file ]] || return 0
  while read -r pid; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    if [[ -r /proc/$pid/cmdline ]] && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q -- "$pattern"; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.5
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done < "$file"
}

cleanup() {
  # 1. Файловая система сценария 3: сначала разморозить, потом убрать писателей.
  if mountpoint -q "$MNT" 2>/dev/null; then
    fsfreeze -u "$MNT" 2>/dev/null || true
  fi
  kill_recorded "$STATE/writers.pid" "notes-break-1.4/writer.sh"
  if mountpoint -q "$MNT" 2>/dev/null; then
    sleep 1
    umount "$MNT" 2>/dev/null || true
  fi
  if mountpoint -q "$MNT" 2>/dev/null; then
    echo "Не удалось отмонтировать $MNT: проверь, что в нём никто не работает, и повтори fix." >&2
    exit 1
  fi
  rmdir "$MNT" 2>/dev/null || true
  # 2. «Скрипт запуска» и его PID-файл из сценария 2.
  if [[ -f $PIDFILE ]]; then
    printf '%s\n' "$(cat "$PIDFILE")" > "$STATE/starter.pid" 2>/dev/null || true
    kill_recorded "$STATE/starter.pid" "app.py"
  fi
  rm -f "$PIDFILE" "$STARTER"
  # 3. Забытая копия сервиса из сценария 1.
  kill_recorded "$STATE/stray.pid" "app.py"
  rm -rf "$STATE"
}

case "${1:-}" in
  1)
    need_root 1; need_app
    cleanup; need_free_port
    mkdir -p "$STATE"
    # «Забытая» копия сервиса: отдельная сессия, поэтому живёт после закрытия терминала
    setsid -f setpriv --reuid "$SUDO_UID" --regid "$SUDO_GID" --init-groups \
      env NOTES_DATA=/tmp/notes-break-stray.txt python3 "$APP_DIR/app.py" \
      </dev/null >/dev/null 2>&1
    sleep 1
    # PID запомним по порту: setsid -f возвращается сразу, номер его потомка неизвестен
    ss -tlnpH 'sport = :8080' | grep -o 'pid=[0-9]*' | cut -d= -f2 > "$STATE/stray.pid" || true
    echo "Сценарий 1 готов. Попробуй: cd ~/notes && python3 app.py"
    ;;
  2)
    need_root 2; need_app
    cleanup; need_free_port
    mkdir -p "$STATE"
    cat > "$STARTER" <<STARTER_EOF
#!/usr/bin/env bash
# Скрипт запуска «Заметок» с PID-файлом (учебный, урок 1.4)
PIDFILE=$PIDFILE
if [[ -f \$PIDFILE ]]; then
  echo "Сервис уже запущен (PID \$(cat "\$PIDFILE"))" >&2
  exit 1
fi
cd "$APP_DIR" || exit 1
NOTES_DATA=/tmp/notes-break-start.txt python3 app.py >/dev/null 2>&1 &
echo \$! > "\$PIDFILE"
echo "Сервис запущен (PID \$!)"
STARTER_EOF
    chown "$SUDO_USER": "$STARTER"
    # Запускаем сервис этим скриптом и «аварийно» убиваем: PID-файл остаётся
    runuser -u "$SUDO_USER" -- bash "$STARTER" >/dev/null
    sleep 1
    kill -KILL "$(cat "$PIDFILE")"
    echo "Сценарий 2 готов. Попробуй: bash $STARTER"
    ;;
  3)
    need_root 3
    for tool in mkfs.ext4 fsfreeze mount losetup; do
      command -v "$tool" >/dev/null 2>&1 || { echo "Не найдена команда $tool." >&2; exit 1; }
    done
    cleanup
    mkdir -p "$STATE" "$MNT"
    # Маленький диск в файле: ext4 на 16 МБ, подключённый как обычный каталог
    dd if=/dev/zero of="$IMG" bs=1M count=16 status=none
    mkfs.ext4 -q "$IMG"
    mount -o loop "$IMG" "$MNT"
    # Три писателя, каждый раз в секунду дописывают строку в файл на этом диске
    cat > "$STATE/writer.sh" <<'WRITER_EOF'
#!/usr/bin/env bash
# Учебный писатель (урок 1.4): раз в секунду дописывает строку в файл журнала
exec 3>> "/mnt/notes-break/journal-$1.log"   # файл открыт один раз, дескриптор 3
while true; do
  printf '%(%T)T\n' -1 >&3                   # запись делает сам bash, без дочерних процессов
  sleep 1
done
WRITER_EOF
    for n in 1 2 3; do
      setsid bash "$STATE/writer.sh" "$n" </dev/null >/dev/null 2>&1 &
      echo $! >> "$STATE/writers.pid"
    done
    sleep 2
    # «Бэкап» заморозил файловую систему и не разморозил: любая запись теперь ждёт
    fsfreeze -f "$MNT"
    sleep 3
    echo "Сценарий 3 готов. Через минуту посмотри uptime и ps."
    echo "Не пиши ничего в $MNT: команда записи зависнет так же, как писатели."
    ;;
  fix)
    need_root fix
    cleanup
    echo "Всё возвращено: лишние процессы остановлены, файлы и точка монтирования сценариев удалены."
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
