#!/usr/bin/env bash
# Поломки для урока 10.3 «Бэкапы, восстановление и ёмкость». Запуск: bash break.sh 1|2|fix
# 1: «ночной» дамп обрезан (файл ~/notes-backups/notes-nightly.dump).
# 2: том с данными notes-db забит лишними файлами (каталог old-wal-archive в томе).
# Без sudo. Нужен дамп из задания 1 урока и работающий кластер notes-db.
set -euo pipefail

NS=notes
POD=notes-db-1
DIR=$HOME/notes-backups
SRC=$DIR/notes-manual.dump
NIGHTLY=$DIR/notes-nightly.dump
JUNK=/var/lib/postgresql/data/old-wal-archive

die() { echo "$*" >&2; exit 1; }

need_kubectl() {
  command -v kubectl >/dev/null || die "Нет kubectl. Сначала пройди урок 5.1."
  kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1 \
    || die "Не найден под $POD в namespace $NS. Проверь контекст и урок 9.5."
}

break_1() {
  [[ -s $SRC ]] || die "Нет $SRC. Сначала сделай дамп в задании 1 урока."
  if [[ -e $NIGHTLY ]]; then echo "Сценарий 1 уже применён."; return 0; fi
  local size; size=$(wc -c < "$SRC")
  # Оставляем 60% файла: похоже на дамп, оборванный переполненным диском.
  head -c $(( size * 6 / 10 )) "$SRC" > "$NIGHTLY"
  echo "Ночной бэкап готов: $NIGHTLY (зелёный, размер ненулевой)."
}

break_2() {
  need_kubectl
  if kubectl -n "$NS" exec "$POD" -c postgres -- test -d "$JUNK" 2>/dev/null; then
    echo "Сценарий 2 уже применён."; return 0
  fi
  local avail
  avail=$(kubectl -n "$NS" exec "$POD" -c postgres -- df -Pm /var/lib/postgresql/data | awk 'NR==2{print $4}')
  if [[ -z $avail || $avail -gt 6000 ]]; then
    die "Том слишком велик (${avail:-?} МБ) для безопасного заполнения, сценарий не применён."
  fi
  # Занимаем 90% свободного места, чтобы PostgreSQL не упал сразу, а том стал почти полным.
  kubectl -n "$NS" exec "$POD" -c postgres -- sh -c \
    "mkdir -p $JUNK && dd if=/dev/zero of=$JUNK/segment.bin bs=1M count=$(( avail * 9 / 10 )) 2>/dev/null"
  echo "Готово: утром пришёл алерт про том с данными."
}

do_fix() {
  rm -f "$NIGHTLY"
  if command -v kubectl >/dev/null && kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1; then
    kubectl -n "$NS" exec "$POD" -c postgres -- rm -rf "$JUNK"
  fi
  echo "Исправлено."
}

case ${1:-} in
  1) break_1 ;;
  2) break_2 ;;
  fix) do_fix ;;
  *) die "Использование: bash $0 1|2|fix" ;;
esac
