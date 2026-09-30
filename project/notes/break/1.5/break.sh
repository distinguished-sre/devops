#!/usr/bin/env bash
# Поломки для урока 1.5 «Диск, память и процессор». Запуск: sudo bash break.sh 1|2|3|4|random|fix
# Скрипт сам запускает свою копию «Заметок» на 127.0.0.1:8080 и ломает только её и свой
# тестовый диск (файл-образ в /var/lib/break-1.5, точка монтирования /mnt/break-1.5).
# Системный диск, твои данные и SSH-доступ скрипт не трогает. Только для учебной ВМ.
set -euo pipefail

STATE=/var/lib/break-1.5     # образ диска, pid-файл, лог и данные сценариев
MNT=/mnt/break-1.5           # сюда монтируется тестовый диск (сценарии 3 и 4)
UNIT=break-1.5               # имя systemd-scope для сценария 1
PORT=8080

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

# Пользователь, от имени которого работает сервис: тот, кто вызвал sudo.
need_user() {
  RUN_USER=${SUDO_USER:-}
  if [[ -z $RUN_USER || $RUN_USER == root ]]; then
    echo "Запусти из-под своего обычного пользователя через sudo, а не из-под root." >&2
    exit 1
  fi
  RUN_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
  APP=$RUN_HOME/notes/app.py
  if [[ ! -f $APP ]] || ! grep -q '/leak' "$APP"; then
    echo "Не найден $APP с эндпоинтом /leak. Сначала сделай задание 4 урока 1.5 (app.py версии v2.2)." >&2
    exit 1
  fi
}

need_tools() {
  local t
  for t in curl setpriv mkfs.ext4 mount ss; do
    if ! command -v "$t" >/dev/null 2>&1; then
      echo "Не найдена команда $t. Поставь пакеты: sudo apt install -y curl e2fsprogs iproute2 util-linux" >&2
      exit 1
    fi
  done
}

need_port_free() {
  if ss -H -ltn "sport = :$PORT" | grep -q .; then
    echo "Порт $PORT занят (наверное, твой сервис Заметок из урока). Останови его: pkill -f 'python3 app.py'" >&2
    exit 1
  fi
}

# Запускает сервис Заметок от имени ученика; $1 - файл данных, остальное - префикс запуска.
start_app() {
  local data=$1; shift
  local gid
  gid=$(id -g "$RUN_USER")
  mkdir -p "$STATE"
  chmod 755 "$STATE"
  # setpriv выполняет python3 сам (без промежуточного процесса) под нужным пользователем
  setsid nohup "$@" setpriv --reuid="$RUN_USER" --regid="$gid" --init-groups \
    env HOST=127.0.0.1 PORT=$PORT NOTES_DATA="$data" python3 "$APP" \
    >>"$STATE/app.log" 2>&1 &
  echo $! >"$STATE/app.pid"
  disown
  local i
  for i in $(seq 1 25); do
    if curl -fs -m 1 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  echo "Сервис не поднялся, смотри $STATE/app.log" >&2
  exit 1
}

make_disk() {  # $1 - число inodes или пусто
  mkdir -p "$STATE" "$MNT"
  truncate -s 64M "$STATE/disk.img"
  if [[ -n ${1:-} ]]; then
    mkfs.ext4 -q -F -N "$1" "$STATE/disk.img"
  else
    mkfs.ext4 -q -F "$STATE/disk.img"
  fi
  mount -o loop "$STATE/disk.img" "$MNT"
  chown "$RUN_USER": "$MNT"
}

# Каталог данных для сценариев 1 и 2: на обычном диске, доступный ученику на запись
make_data_dir() {
  mkdir -p "$STATE/data"
  chmod 755 "$STATE"
  chown "$RUN_USER": "$STATE/data"
}

finish() {
  echo "Сценарий $1 готов. Сервис Заметок на 127.0.0.1:$PORT не в порядке: найди причину по методу USE."
}

stop_all() {
  systemctl stop "$UNIT.scope" 2>/dev/null || true
  systemctl reset-failed "$UNIT.scope" 2>/dev/null || true   # после OOM scope остаётся «упавшим»
  pkill -f notes-break-burn 2>/dev/null || true
  if [[ -f $STATE/app.pid ]]; then
    local pid
    pid=$(cat "$STATE/app.pid")
    # убиваем только свой процесс: проверяем, что это действительно app.py
    if [[ -n $pid ]] && grep -aq 'app.py' "/proc/$pid/cmdline" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
}

scenario() {
  case $1 in
    1)  # память: /leak до срабатывания OOM-killer внутри cgroup с лимитом
      need_port_free
      make_data_dir
      start_app "$STATE/data/notes.txt" systemd-run --scope --quiet --unit="$UNIT" \
        -p MemoryMax=150M -p MemorySwapMax=0
      local i
      for i in 1 2 3; do
        curl -s -m 5 "http://127.0.0.1:$PORT/leak?mb=60" >/dev/null 2>&1 || true
      done
      sleep 1
      ;;
    2)  # процессор: три клиента гоняют /burn?sec=60 по кругу
      need_port_free
      make_data_dir
      start_app "$STATE/data/notes.txt"
      local i
      for i in 1 2 3; do
        setsid nohup setpriv --reuid="$RUN_USER" --regid="$(id -g "$RUN_USER")" --init-groups \
          bash -c 'while curl -s -m 70 "http://127.0.0.1:8080/burn?sec=60" >/dev/null; do :; done' \
          notes-break-burn >/dev/null 2>&1 &
        disown
      done
      sleep 2
      ;;
    3)  # диск: данные сервиса лежат на разделе, где кончилось место
      need_port_free
      make_disk ""
      mkdir "$MNT/export"
      dd if=/dev/zero of="$MNT/export/dump-2026-09.bin" bs=1M status=none 2>/dev/null || true
      chown -R "$RUN_USER": "$MNT/export"
      start_app "$MNT/notes.txt"
      ;;
    4)  # inodes: место есть, а свободных карточек файлов нет
      need_port_free
      make_disk 2000
      mkdir "$MNT/spool"
      local i
      for i in $(seq 1 3000); do
        { : >"$MNT/spool/m$i"; } 2>/dev/null || break
      done
      chown -R "$RUN_USER": "$MNT/spool" 2>/dev/null || true
      start_app "$MNT/notes.txt"
      ;;
  esac
  finish "$1"
}

case "${1:-}" in
  1|2|3|4)
    need_root "$1"; need_user; need_tools
    bash "$0" fix >/dev/null 2>&1 || true   # начинаем с чистого состояния
    scenario "$1"
    ;;
  random)
    need_root random; need_user; need_tools
    bash "$0" fix >/dev/null 2>&1 || true
    scenario $((RANDOM % 4 + 1)) | sed 's/Сценарий [0-9] готов\./Сломано./'
    ;;
  fix)
    need_root fix
    stop_all
    if mountpoint -q "$MNT" 2>/dev/null; then
      umount "$MNT" 2>/dev/null || umount -l "$MNT"
    fi
    rmdir "$MNT" 2>/dev/null || true
    rm -f "$STATE/disk.img" "$STATE/app.pid" "$STATE/app.log" "$STATE/data/notes.txt"
    rmdir "$STATE/data" 2>/dev/null || true
    rmdir "$STATE" 2>/dev/null || true
    echo "Всё возвращено: сервис скрипта остановлен, тестовый диск отключён и удалён. Запусти свой сервис: cd ~/notes && python3 app.py"
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|4|random|fix" >&2
    exit 2
    ;;
esac
