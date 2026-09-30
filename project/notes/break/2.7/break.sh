#!/usr/bin/env bash
# Поломки для урока 2.7 «Файрвол и защита SSH». Запуск: sudo bash break.sh 1|2|3|fix
# Меняет правила ufw и настройки sshd: только для учебной ВМ, у которой есть консоль
# (multipass shell, консоль облака). Сценарии 1 и 3 отрезают новые входы по SSH.
# Страховка: через 30 минут скрипт сам запустит fix (таймер break-2.7-heal).
set -euo pipefail

TAG='break-2.7'                                  # пометка в комментариях правил ufw
STATE_DIR=/var/lib/notes-break-2.7               # тут запоминаем, каким был файрвол
SELF_COPY=$STATE_DIR/break.sh                    # копия скрипта для таймера страховки
SSH_DROPIN=/etc/ssh/sshd_config.d/20-break-2.7.conf
HEAL_UNIT=break-2.7-heal

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти через sudo: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

# Нужные уроки: 1.8 (сервис notes), 2.5 и 2.6 (nginx), 2.2 (sshd).
need_lessons() {
  local missing=0
  if ! systemctl cat notes >/dev/null 2>&1; then
    echo "Не найден сервис notes. Сначала пройди урок 1.8." >&2; missing=1
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    echo "Не найден nginx. Сначала пройди уроки 2.5 и 2.6." >&2; missing=1
  fi
  if [[ ! -x /usr/sbin/sshd ]]; then
    echo "Не найден sshd. Сначала пройди урок 2.2." >&2; missing=1
  fi
  [[ $missing -eq 0 ]] || exit 1
}

need_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    apt-get install -y -qq ufw >/dev/null
  fi
}

ufw_is_active() {
  ufw status | grep -q '^Status: active'
}

# Запоминаем, был ли файрвол включён до поломки (только при первом запуске сценария).
remember_state() {
  mkdir -p "$STATE_DIR"
  if [[ ! -f $STATE_DIR/ufw_was_active ]]; then
    if ufw_is_active; then echo yes; else echo no; fi > "$STATE_DIR/ufw_was_active"
  fi
  cp "$0" "$SELF_COPY"
}

# Есть ли в ufw правило allow или limit для порта (порт в виде 22/tcp).
has_rule() {
  ufw status | grep -Eq "^$1 +(ALLOW|LIMIT)( IN)? "
}

# Удаляет все правила порта (allow и limit), которые могли быть записаны разными способами.
drop_port_rules() {
  local port=$1
  ufw --force delete allow "$port" >/dev/null 2>&1 || true
  ufw --force delete limit "$port" >/dev/null 2>&1 || true
}

# Удаляет правила ufw с нашей пометкой, пока они есть. Берём наибольший номер,
# чтобы номера остальных правил не сдвигались.
delete_tagged_rules() {
  local n
  while n=$(ufw status numbered | grep -F "# $TAG" | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn | head -n 1) && [[ -n $n ]]; do
    ufw --force delete "$n" >/dev/null
  done
}

schedule_heal() {
  systemctl stop "$HEAL_UNIT.timer" >/dev/null 2>&1 || true
  systemd-run --quiet --on-active=30min --unit="$HEAL_UNIT" /usr/bin/bash "$SELF_COPY" fix
}

case "${1:-}" in
  1)
    need_root 1; need_lessons; need_ufw; remember_state
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    has_rule '80/tcp'  || ufw allow 80/tcp comment "$TAG" >/dev/null
    has_rule '443/tcp' || ufw allow 443/tcp comment "$TAG" >/dev/null
    drop_port_rules 22/tcp
    drop_port_rules OpenSSH
    ufw --force enable >/dev/null
    schedule_heal
    echo "Сценарий 1 готов. Твоя текущая сессия жива, новые входы по SSH не пройдут."
    echo "Проверь с ноутбука: ssh USER@VM_IP. Лечить через консоль ВМ. Страховка: fix запустится сам через 30 минут."
    ;;
  2)
    need_root 2; need_lessons; need_ufw; remember_state
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    has_rule '22/tcp' || ufw allow 22/tcp comment "$TAG" >/dev/null
    has_rule '80/tcp' || ufw allow 80/tcp comment "$TAG" >/dev/null
    drop_port_rules 443/tcp
    ufw --force enable >/dev/null
    echo "Сценарий 2 готов. Проверь с ноутбука: curl -sS --max-time 5 -k https://VM_IP/healthz"
    ;;
  3)
    need_root 3; need_lessons
    mkdir -p "$STATE_DIR"; cp "$0" "$SELF_COPY"
    printf '# Поломка урока 2.7: вход по ключу выключен\nPubkeyAuthentication no\n' > "$SSH_DROPIN"
    chmod 644 "$SSH_DROPIN"
    if ! sshd -t; then
      rm -f "$SSH_DROPIN"
      echo "sshd -t нашёл ошибку в конфигурации, поломку не применяю." >&2
      exit 1
    fi
    systemctl reload ssh
    schedule_heal
    echo "Сценарий 3 готов. Твоя текущая сессия жива. Проверь с ноутбука: ssh USER@VM_IP"
    echo "Лечить через консоль ВМ. Страховка: fix запустится сам через 30 минут."
    ;;
  fix)
    need_root fix
    systemctl stop "$HEAL_UNIT.timer" >/dev/null 2>&1 || true
    # sshd: убираем нашу поломку и перечитываем конфигурацию.
    if [[ -f $SSH_DROPIN ]]; then
      rm -f "$SSH_DROPIN"
      if sshd -t; then systemctl reload ssh; fi
    fi
    # ufw: убираем правила с нашей пометкой и возвращаем 22, 80, 443 (итог урока).
    if command -v ufw >/dev/null 2>&1; then
      delete_tagged_rules
      was=$(cat "$STATE_DIR/ufw_was_active" 2>/dev/null || echo yes)
      if [[ $was == yes ]]; then
        ufw default deny incoming >/dev/null
        has_rule '22/tcp'  || ufw allow 22/tcp comment ssh >/dev/null
        has_rule '80/tcp'  || ufw allow 80/tcp comment http >/dev/null
        has_rule '443/tcp' || ufw allow 443/tcp comment https >/dev/null
        ufw --force enable >/dev/null
      else
        ufw --force disable >/dev/null
      fi
    fi
    rm -rf "$STATE_DIR"
    echo "Всё возвращено: убраны правила ${TAG} и настройка PubkeyAuthentication no."
    if command -v ufw >/dev/null 2>&1 && ufw_is_active; then
      echo "Файрвол включён, открыты 22, 80, 443."
    else
      echo "Файрвол выключен, как и был до поломки."
    fi
    ;;
  *)
    echo "Использование: sudo bash $0 1|2|3|fix" >&2
    exit 2
    ;;
esac
