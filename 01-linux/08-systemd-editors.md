---
layout: lesson
title: "systemd и редакторы: «Заметки» как сервис"
topic: 1
lesson: "1.8"
time: "2.5 ч"
---

## Зачем это нужно

Пока «Заметки» запущены руками в терминале (`sudo -u notes python3 /opt/notes/app.py`), любое закрытое окно, перезагрузка сервера или падение процесса означают простой. На работе такое не допускается: сервис должен стартовать сам, подниматься после падения и писать логи в одно место. Это делает systemd, а править его конфиги на сервере придётся в vim или nano: другого редактора там может не быть.
Шаг проекта: `deploy/systemd/notes.service` ставится в `/etc/systemd/system/`, конфиг выносится в `/etc/notes/notes.env` (640 `root:notes`), сервис работает под пользователем `notes` на 127.0.0.1:8080 и переживает `kill -9` и перезагрузку.

## Что нужно знать

- [Урок 1.1: первый сервер](01-first-server-shell.md) - терминал, `apt`, первое знакомство с редактором.
- [Урок 1.2: текст и конвейеры](02-text-pipes.md) - `grep` и `|` нужны для фильтрации вывода `journalctl`.
- [Урок 1.3: пользователи и права](03-users-permissions.md) - пользователь `notes`, `/var/lib/notes`, `/opt/notes`, режим 640.
- [Урок 1.4: процессы и сигналы](04-processes-signals.md) - SIGTERM и SIGKILL: systemd шлёт именно их.
- [Урок 1.5: диск, память, процессор](05-disk-memory-cpu.md) - `/leak` пригодится, чтобы увидеть лимиты сервиса.
- [Урок 1.7: bash в эксплуатации](07-bash-in-ops.md) - скрипты и cron, которые теперь будут ходить в сервис под systemd.

## Теория

### Что такое systemd и юнит

**systemd** - это первый процесс системы (PID 1). Он запускает всё остальное, следит за процессами и перезапускает упавшие. Описание того, чем управляет systemd, называется юнитом (unit). Юнит для сервиса - это текстовый файл `*.service`. Системные юниты пакетов лежат в `/usr/lib/systemd/system/`, а твои собственные кладут в `/etc/systemd/system/`: они приоритетнее и не затираются обновлениями.

Файл состоит из трёх секций:

- `[Unit]` - описание и порядок запуска (`After=network.target`: стартовать после сети).
- `[Service]` - как запускать: пользователь, команда `ExecStart`, политика перезапуска.
- `[Install]` - к какой цели (target) подключить при `enable`. `multi-user.target` - обычное состояние сервера без графики.

Важное правило: systemd читает файлы юнитов в память. Изменил файл на диске, а `systemctl daemon-reload` не выполнил, значит, systemd работает по старой версии и напишет предупреждение `Warning: The unit file, source configuration file or drop-ins of notes.service changed on disk. Run 'systemctl daemon-reload' to reload units.`

> **Проверь понимание:** чем `systemctl start notes` отличается от `systemctl enable notes`?

<details markdown="1">
<summary>Ответ</summary>

`start` запускает сервис сейчас, но после перезагрузки он не поднимется. `enable` создаёт симлинк в `multi-user.target.wants/`, и сервис стартует при загрузке, но прямо сейчас не запускается. Поэтому обычно пишут `enable --now`: и то, и другое.

</details>

### Как systemd запускает процесс

Тип `Type=simple` (по умолчанию) значит: процесс из `ExecStart` и есть сервис, он остаётся на переднем плане и не делает fork в фон. Наше приложение именно такое. Логи оно пишет в stderr, а systemd подключает stdout и stderr к журналу (journal), поэтому `2>> app.log` из урока 1.2 больше не нужен.

Пользователь задаётся `User=` и `Group=`. Если такого пользователя нет, процесс не стартует со статусом `217/USER`. Если неверен путь в `ExecStart`, статус `203/EXEC`. Коды в `status=` это первое, на что смотришь при диагностике.

Переменные окружения сервису дают через `EnvironmentFile=/etc/notes/notes.env`: файл строк `KEY=value` без `export` и без кавычек вокруг всей строки. Права 640 `root:notes` значат: root пишет, группа `notes` читает, остальные ничего не видят. Секреты в юнит-файл (`Environment=`) класть нельзя: его читают все командой `systemctl show`.

> **Проверь понимание:** почему `ExecStart=python3 /opt/notes/app.py` не сработает?

<details markdown="1">
<summary>Ответ</summary>

systemd не ищет команду по `PATH`, как shell: путь должен быть абсолютным (`/usr/bin/python3`). Кроме того, в `ExecStart` нет shell: нельзя писать `>`, `|`, `$VAR` (для подстановки переменных есть отдельный синтаксис). Получишь `status=203/EXEC`.

</details>

### Restart и защита от бесконечного перезапуска

`Restart=on-failure` перезапускает сервис, если он завершился с ненулевым кодом, был убит сигналом или упал по таймауту. Штатная остановка (`systemctl stop`, код 0) перезапуска не вызывает. Другие значения: `always` (всегда, даже при код 0), `no` (по умолчанию), `on-abnormal`. `RestartSec=2` даёт паузу между попытками.

Есть предохранитель: если сервис упал слишком много раз за короткое время (по умолчанию 5 раз за 10 секунд), systemd сдаётся, и юнит переходит в `failed` с сообщением `Start request repeated too quickly`. Тогда после починки причины нужен `systemctl reset-failed notes`. Это защита от ситуации, когда сломанный сервис молотит CPU.

> **Проверь понимание:** ты убил сервис командой `kill -9`, `Restart=on-failure`. Что произойдёт? А после `systemctl stop`?

<details markdown="1">
<summary>Ответ</summary>

После `kill -9` процесс завершён сигналом, это failure, systemd поднимет его через `RestartSec`. После `systemctl stop` сервис остановлен намеренно, и он останется остановленным.

</details>

### Журнал: journalctl

systemd собирает вывод сервисов в журнал (journal). Читают его командой `journalctl`. Ходовые ключи: `-u notes` (только этот юнит), `-f` (следить в реальном времени), `--since "10 min ago"` и `--since yesterday`, `-p err` (только приоритет error и выше), `-n 50` (последние строки), `-b` (с текущей загрузки), `--no-pager` (не открывать `less`, удобно в конвейере с `grep`).

> **Проверь понимание:** как показать только ошибки сервиса за последний час?

<details markdown="1">
<summary>Ответ</summary>

`journalctl -u notes -p err --since "1 hour ago" --no-pager`

</details>

### Ограничение прав сервиса (hardening)

Сервис - это удалённо доступный процесс, поэтому его лишают всего лишнего. Базовый набор для «Заметок»:

- `NoNewPrivileges=true` - процесс и его потомки не могут получить больше прав (например, через setuid-программу).
- `ProtectSystem=strict` - вся файловая система только для чтения, кроме `/dev`, `/proc`, `/sys`.
- `ReadWritePaths=/var/lib/notes` - исключение: сюда писать можно.
- `ProtectHome=true` - `/home` невидим.
- `PrivateTmp=true` - у сервиса свой `/tmp`.

Оценить результат: `systemd-analyze security notes` ставит оценку экспозиции от 0 (закрыто) до 10 (открыто). Гнаться за нулём не нужно: сервису, слушающему сеть, часть возможностей всё равно нужна.

### Редакторы: vim и nano

Конфиги на сервере правят в терминале. **nano** прост: подсказки внизу, сохранить `Ctrl+O`, `Enter`, выйти `Ctrl+X`. **vim** есть почти везде и работает режимами (modes): в обычном (normal) клавиши - это команды, в режиме вставки (insert) - текст.

| Клавиши | Действие |
|---|---|
| `i` | войти в режим вставки |
| `Esc` | вернуться в обычный режим |
| `:wq` / `:q!` | сохранить и выйти / выйти без сохранения |
| `/слово`, `n` | искать вперёд, следующее вхождение |
| `dd`, `yy`, `p` | вырезать строку, скопировать строку, вставить |
| `u`, `Ctrl+r` | отмена, повтор |
| `gg`, `G` | в начало файла, в конец |
| `:%s/старое/новое/g` | заменить во всём файле |

Правки системных файлов делай через `sudoedit /etc/systemd/system/notes.service` (или `sudo -e`): редактируется временная копия, а привилегии повышаются только на запись. Какой редактор откроется, задаёт переменная `EDITOR`: `export EDITOR=nano` (постоянно: строка в `~/.bashrc`). Если открыл файл без прав и всё набрал, спасёт `:w !sudo tee %` с последующим `:q!`.

> **Проверь понимание:** ты открыл vim, набираешь текст, а он выполняет странные команды. Что случилось?

<details markdown="1">
<summary>Ответ</summary>

Ты в обычном режиме, а не в режиме вставки. Нажми `Esc`, затем `i` и печатай. Выйти без сохранения: `Esc`, `:q!`.

</details>

## Практика

Все задания выполняются на твоём сервере (Ubuntu 26.04 или 24.04). Если ты на WSL2: systemd там нужно включить. Проверка: `systemctl is-system-running`. Если пишет `offline`, добавь в `/etc/wsl.conf` секцию `[boot]` со строкой `systemd=true` и выполни в PowerShell `wsl --shutdown`.

### Задание 1. Vim без паники

**Цель:** уверенно править файл в vim и выходить из него в любом состоянии.

**Предскажи:** ты открыл файл, нажал `dd` три раза, затем `u`. Сколько строк останется удалено? Что произойдёт, если набрать `:q` после изменения?

<details markdown="1">
<summary>Ответ</summary>

`u` отменяет одно последнее удаление, значит, удалено две строки. `:q` при несохранённых правках откажет: `E37: No write since last change (add ! to override)`.

</details>

**Шаги:**

1. Подготовь тренировочный файл и открой его:

   ```bash
   printf 'строка %s\n' 1 2 3 4 5 > ~/vim-drill.txt
   vim ~/vim-drill.txt
   ```

2. Внутри vim: `dd` три раза, `u`, `G`, `p` (вставить вырезанную строку в конец), `/строка 2` и `Enter`, затем `i`, допиши `!` и `Esc`.
3. Сохрани и выйди: `:wq`. Проверь результат:

   ```bash
   cat ~/vim-drill.txt
   ```

4. Открой снова, испорти файл (`dd`), выйди без сохранения `:q!` и убедись, что файл не изменился.

**Что должно получиться:**

```text
строка 3
строка 4
строка 5
строка 1
строка 2
```

**Объясни себе:** почему `dd` не удалил текст «навсегда»? В каком регистре он лежит до `p`? Чем `:wq` отличается от `:x`?

**Типичные ошибки:**
- `E37: No write since last change (add ! to override)`: пытаешься выйти `:q` с несохранёнными правками. Либо `:wq`, либо `:q!`.
- `E45: 'readonly' option is set (add ! to override)`: файл без прав на запись. Выйди `:q!` и открой через `sudoedit`.
- `Swap file "..." already exists!`: файл уже открыт в другом vim или прошлый сеанс упал. Выбери `(Q)uit`, закрой второй сеанс, при необходимости удали `.swp`-файл.

### Задание 2. Конфиг и unit-файл «Заметок»

**Цель:** создать конфиг `/etc/notes/notes.env` с нужными правами и unit-файл в репозитории проекта.

**Предскажи:** какие права получит файл, созданный `sudo tee`, и сможет ли его прочитать пользователь `notes` без `chgrp`?

<details markdown="1">
<summary>Ответ</summary>

По умолчанию 644 `root:root`: читать смогут все, но это неверная модель для конфига (в будущем в нём появятся секреты). Поэтому явно задаём 640 `root:notes`: читает только группа `notes`.

</details>

**Шаги:**

1. Останови ручной запуск из урока 1.3, если он ещё работает (`Ctrl+C` в его терминале), иначе порт 8080 будет занят.
2. Создай конфиг и права:

   ```bash
   sudo mkdir -p /etc/notes
   sudo tee /etc/notes/notes.env >/dev/null <<'CFG'
   HOST=127.0.0.1
   PORT=8080
   NOTES_DATA=/var/lib/notes/notes.txt
   APP_VERSION=dev
   CFG
   sudo chown root:notes /etc/notes/notes.env
   sudo chmod 640 /etc/notes/notes.env
   ls -l /etc/notes/notes.env
   ```

3. В репозитории проекта создай unit-файл в редакторе (vim или nano):

   ```bash
   mkdir -p ~/notes/deploy/systemd
   vim ~/notes/deploy/systemd/notes.service
   ```

   Содержимое файла целиком:

   ```ini
   [Unit]
   Description=Сервис Заметки
   After=network.target

   [Service]
   User=notes
   Group=notes
   EnvironmentFile=/etc/notes/notes.env
   ExecStart=/usr/bin/python3 /opt/notes/app.py
   # Перезапуск после падения, пауза 2 секунды
   Restart=on-failure
   RestartSec=2
   # Ограничения: файловая система только для чтения, писать можно в данные
   ReadWritePaths=/var/lib/notes
   ProtectSystem=strict
   NoNewPrivileges=true

   [Install]
   WantedBy=multi-user.target
   ```

4. Проверь синтаксис до установки:

   ```bash
   systemd-analyze verify ~/notes/deploy/systemd/notes.service
   ```

**Что должно получиться:**

```text
-rw-r----- 1 root notes 68 Sep 29 10:00 /etc/notes/notes.env
```

`systemd-analyze verify` ничего не печатает, если всё в порядке (размер и дата у тебя другие). Замечание про отсутствие `/opt/notes/app.py` означало бы, что код не скопирован в `/opt/notes/` (урок 1.3).

**Объясни себе:** зачем разделять `notes.service` (в git) и `notes.env` (только на сервере)? Почему `ExecStart` не содержит `sudo -u notes`?

**Типичные ошибки:**
- `Unknown key name 'ExecStar' in section 'Service', ignoring.`: опечатка в имени ключа. Исправь и повтори `verify`.
- `Failed to parse ... Assignment outside of section`: строка вне секции `[...]`, обычно потерян заголовок.
- `Command /usr/bin/python3 is not executable`: python3 стоит в другом месте, проверь `command -v python3`.

### Задание 3. Запуск, автозапуск, самовосстановление

**Цель:** установить сервис, проверить его состояние, убить и убедиться, что systemd его поднимает.

**Предскажи:** после `kill -9` у сервиса изменится PID или нет? Что покажет `systemctl status` в строке `Active:`?

<details markdown="1">
<summary>Ответ</summary>

PID станет другим: это новый процесс. Сервис будет `active (running)`, но время в `since` свежее. В журнале появится строка про `code=killed, signal=KILL` и `Scheduled restart job`.

</details>

**Шаги:**

1. Установи юнит и запусти:

   ```bash
   sudo install -m 644 ~/notes/deploy/systemd/notes.service /etc/systemd/system/notes.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now notes
   systemctl status notes --no-pager
   curl -s http://127.0.0.1:8080/healthz
   ```

2. Убей процесс жёстко и проверь:

   ```bash
   systemctl show notes -p MainPID
   sudo kill -9 "$(systemctl show notes -p MainPID --value)"
   sleep 3
   systemctl show notes -p MainPID
   systemctl is-active notes
   ```

3. Проверь, что остановка не перезапускает:

   ```bash
   sudo systemctl stop notes
   systemctl is-active notes
   sudo systemctl start notes
   ```

4. Проверь автозапуск перезагрузкой: `sudo reboot`, после входа `systemctl is-active notes` и `curl -s http://127.0.0.1:8080/healthz`.

**Что должно получиться:**

```text
● notes.service - Сервис Заметки
     Loaded: loaded (/etc/systemd/system/notes.service; enabled; preset: enabled)
     Active: active (running) since Mon 2026-09-29 10:00:00 UTC; 2s ago
   Main PID: 2311 (python3)
ok
MainPID=2311
MainPID=2340
active
inactive
```

Идентификаторы процессов и время у тебя будут другими; важно, что второй `MainPID` отличается от первого, а после `stop` статус `inactive`.

**Объясни себе:** почему после `stop` сервис не поднялся, а после `kill -9` поднялся? Чем `is-active` удобнее `status` в скрипте?

**Типичные ошибки:**
- `OSError: [Errno 98] Address already in use`: порт 8080 занят ручным запуском. Найди: `sudo ss -ltnp | grep 8080` и останови процесс.
- `Failed to enable unit: Unit file notes.service does not exist.`: файл не в `/etc/systemd/system/` или имя неверное.
- `System has not been booted with systemd as init system (PID 1). Can't operate.`: это WSL2 без systemd, см. начало практики.

### Задание 4. Журнал: читать и искать

**Цель:** научиться доставать из журнала нужное за секунды.

**Предскажи:** сколько строк на один запрос `curl /healthz` появится в журнале? Попадёт ли туда что-то из `/healthz` при уровне `info`?

<details markdown="1">
<summary>Ответ</summary>

По контракту приложения служебные пути `/healthz`, `/readyz` в access-лог на уровне `info` не пишутся, поэтому запрос `/healthz` строки не даст, а запрос `/notes` даст. Проверь сам.

</details>

**Шаги:**

1. Сгенерируй события и посмотри:

   ```bash
   curl -s http://127.0.0.1:8080/notes >/dev/null
   curl -s http://127.0.0.1:8080/net-takoj-stranicy >/dev/null
   journalctl -u notes -n 10 --no-pager
   ```

2. Отфильтруй: только 404 за последние 5 минут, только текущая загрузка, только ошибки:

   ```bash
   journalctl -u notes --since "5 min ago" --no-pager | grep 'status=404'
   journalctl -u notes -b --no-pager | wc -l
   journalctl -u notes -p err --no-pager
   ```

**Что должно получиться:**

```text
Sep 29 10:00:05 srv python3[2340]: 2026-09-29 10:00:05,123 INFO method=GET path=/notes status=200 dur_ms=1
Sep 29 10:00:06 srv python3[2340]: 2026-09-29 10:00:06,321 INFO method=GET path=/net-takoj-stranicy status=404 dur_ms=0
```

Имя хоста, время и PID у тебя отличаются.

**Объясни себе:** зачем `--no-pager` в конвейерах? Как узнать, сколько журнал занимает на диске (`journalctl --disk-usage`) и почему это важно после урока 1.5?

**Типичные ошибки:**
- `-- No entries --`: неверное имя юнита или журнал за другое время. Проверь `systemctl list-units 'notes*'` и `--since`.
- `Hint: You are currently not seeing messages from other users and the system.`: пользователь не в группах `systemd-journal` или `adm`. Используй `sudo journalctl` или добавь себя в группу `systemd-journal`.

### Задание 5. Шаг проекта: hardening и проверка границ

**Цель:** убедиться, что ограничения из unit-файла действительно работают, и зафиксировать состояние проекта.

**Предскажи:** сможет ли сервис после `ProtectSystem=strict` записывать заметки в `/var/lib/notes/notes.txt`? А если убрать `ReadWritePaths`?

<details markdown="1">
<summary>Ответ</summary>

С `ReadWritePaths=/var/lib/notes` сможет. Без него запись даст `Read-only file system`, `POST /notes` вернёт 500, а `/readyz` станет 503.

</details>

**Шаги:**

1. Запиши заметку и убедись, что она лежит в файле данных:

   ```bash
   curl -s -X POST http://127.0.0.1:8080/notes -d '{"text":"Заметка из-под systemd"}'
   sudo tail -n 1 /var/lib/notes/notes.txt
   ```

2. Оцени защиту и посмотри, каким пользователем идёт процесс:

   ```bash
   systemd-analyze security notes --no-pager | tail -n 3
   ps -o user,group,cmd -p "$(systemctl show notes -p MainPID --value)"
   ```

3. Проверь, что сервис не видит домашние каталоги, если добавить `ProtectHome=true`: открой unit-файл в репозитории, добавь в `[Service]` строки `ProtectHome=true` и `PrivateTmp=true` (порядок любой), затем переустанови и перезапусти:

   ```bash
   sudo install -m 644 ~/notes/deploy/systemd/notes.service /etc/systemd/system/notes.service
   sudo systemctl daemon-reload
   sudo systemctl restart notes
   systemd-analyze security notes --no-pager | tail -n 1
   ```

   Убедись, что после правки `curl -s http://127.0.0.1:8080/healthz` по-прежнему отвечает `ok`, а оценка экспозиции стала меньше.
4. Зафиксируй в git:

   ```bash
   cd ~/notes
   git add deploy/systemd/notes.service
   git commit -m "Добавлен unit-файл notes.service" 2>&1 | tail -n 2
   ```

   Файл `/etc/notes/notes.env` в git не добавляется: он живёт только на сервере (в репозитории появится пример `notes.env.example`, но позже, в уроках про конфигурацию).

**Что должно получиться:**

```text
2026-09-29T10:03:11+00:00	Заметка из-под systemd
notes notes /usr/bin/python3 /opt/notes/app.py
→ Overall exposure level for notes.service: 5.2 MEDIUM
```

Оценка (число и слово) у тебя может отличаться: важно, что после добавления `ProtectHome` и `PrivateTmp` число уменьшилось.

**Состояние проекта после урока:** сервис `notes` управляется systemd, слушает 127.0.0.1:8080, данные в файле `/var/lib/notes/notes.txt`, приложение версии v2.2. Долги: нет HTTPS, нет прокси.

**Объясни себе:** почему числовая оценка не должна доходить до 0? Что бы ты сделал, если бы сервису понадобилось писать логи в отдельный каталог?

**Типичные ошибки:**
- `Failed to restart notes.service: Unit notes.service has a bad unit file setting.`: опечатка в ключе, смотри `journalctl -xeu notes` и `systemd-analyze verify`.
- `nothing to commit, working tree clean`: файл уже был добавлен раньше, проверь `git log --oneline -3`.

## Сломай и почини

Скачай и запусти сценарий поломки. Файл `break.sh` не читай: цель в том, чтобы найти причину диагностикой.

```bash
curl -fsSLO https://raw.githubusercontent.com/distinguished-sre/devops/devops/project/notes/break/1.8/break.sh
sudo bash break.sh random
```

### Симптом

После запуска `curl -s http://127.0.0.1:8080/healthz` не отвечает или отвечает ошибкой, а `systemctl is-active notes` показывает не `active`. Сервис нужно вернуть в рабочее состояние, не пересоздавая его с нуля.

### Гипотезы

1. Неверный путь в `ExecStart` (status `203/EXEC`).
2. Пользователь из `User=` не существует (status `217/USER`).
3. Сервис падает при старте, и systemd исчерпал попытки (`Start request repeated too quickly`).
4. Правки в файле юнита есть, но `daemon-reload` не сделан: действует старая версия.
5. Приложение не может писать вне `ReadWritePaths`: запись падает, а сервис при этом «жив».

### Проверки

```bash
systemctl status notes --no-pager          # код в строке Process/status=
journalctl -xeu notes --no-pager | tail -n 30
systemd-analyze verify /etc/systemd/system/notes.service
systemctl cat notes                        # какой файл реально применён
id notes                                   # существует ли пользователь
ls -ld /var/lib/notes /opt/notes/app.py
```

### Исправление

<details markdown="1">
<summary>Разбор сценариев</summary>

1. **`status=203/EXEC`**: в `ExecStart` неверный путь или нет права на исполнение. `command -v python3`, исправь юнит, затем `sudo systemctl daemon-reload && sudo systemctl restart notes`.
2. **`status=217/USER`**: пользователя `notes` нет. Создай как в уроке 1.3: `sudo useradd --system --home /var/lib/notes --shell /usr/sbin/nologin notes`, проверь владельца `/var/lib/notes` и перезапусти.
3. **`Start request repeated too quickly`**: это следствие, а не причина. Сначала найди реальную ошибку в `journalctl -u notes`, почини, затем `sudo systemctl reset-failed notes && sudo systemctl start notes`.
4. **Забыт `daemon-reload`**: `systemctl status` предупреждает `Warning: The unit file, source configuration file or drop-ins of notes.service changed on disk`. Выполни `sudo systemctl daemon-reload && sudo systemctl restart notes`.
5. **Запись вне `ReadWritePaths`**: в журнале `Read-only file system` и `POST /notes` возвращает 500. Пропиши каталог данных в `ReadWritePaths=` (или верни `NOTES_DATA=/var/lib/notes/notes.txt` в `/etc/notes/notes.env`), затем `daemon-reload` и `restart`.

После починки проверь: `systemctl is-active notes`, `curl -s http://127.0.0.1:8080/healthz`.

</details>

## Вопросы с собеседований

### 1. [junior] Ты поправил unit-файл, `systemctl restart` не изменил поведение. Почему?

Скорее всего, я не сделал `systemctl daemon-reload`, и systemd держит старую версию юнита в памяти. Проверяю `systemctl status` (там будет предупреждение) и `systemctl cat`, затем перезагружаю конфигурацию и перезапускаю сервис.

**Что хотят услышать:** `daemon-reload`, `systemctl cat`, отличие drop-in от основного файла, `systemctl edit`.

**Красный флаг:** «перезагружу сервер» или не знает, что systemd кэширует юниты.

### 2. [junior] Сервис в статусе `failed`, `status=203/EXEC`. Что делаешь?

Смотрю `journalctl -xeu <сервис>` и `systemctl cat`. `203/EXEC` значит, systemd не смог выполнить команду из `ExecStart`: неверный путь, нет прав на исполнение или нет интерпретатора в shebang. Проверяю путь `ls -l` и `command -v`, исправляю, делаю `daemon-reload`, `restart`.

**Что хотят услышать:** коды 203 и 217, абсолютный путь, права `x`, чтение журнала.

**Красный флаг:** запускает `ExecStart` руками под root и делает вывод «у меня работает».

### 3. [junior] Чем `enable` отличается от `start`?

`start` запускает сейчас, `enable` включает автозапуск при загрузке через симлинк в `.wants`. `enable --now` делает обе вещи. Обратное: `disable` и `stop`.

**Что хотят услышать:** независимость двух действий, `is-enabled` и `is-active`.

**Красный флаг:** считает, что `enable` запускает сервис.

### 4. [junior] Как выйти из vim без сохранения? Ты случайно набрал текст в обычном режиме.

`Esc`, затем `:q!`. Если хочу отменить только последние действия, `u`. Если файл был в режиме только для чтения и я его уже изменил, сохранять нужно через `sudoedit` или `:w !sudo tee %`.

**Что хотят услышать:** режимы vim, `:q!`, `:wq`, `sudoedit`.

**Красный флаг:** «перезагружу терминал» или паника без вариантов.

### 5. [middle] Сервис падает и перезапускается каждые две секунды, потом systemd пишет `Start request repeated too quickly`. Твои действия?

Это предохранитель `StartLimitBurst` и `StartLimitIntervalSec`. Сначала не «лечу» лимит, а ищу причину падения: `journalctl -u`, код завершения, `coredump` при необходимости. Починив, делаю `reset-failed`. Временно ослаблять лимит можно, но постоянно это маскирует проблему.

**Что хотят услышать:** предохранитель как следствие, `reset-failed`, `RestartSec`, поиск причины в журнале.

**Красный флаг:** отключает лимит или ставит `Restart=always` с `RestartSec=0` «чтобы работало».

### 6. [middle] Приложение живо, `systemctl status` зелёный, но данные не пишутся. Где искать?

Проверяю, что реально применил systemd: `systemctl cat`, `systemctl show -p ReadWritePaths,ProtectSystem`. При `ProtectSystem=strict` запись вне `ReadWritePaths` падает с `Read-only file system`, хотя права Unix в порядке. Ещё проверяю владельца каталога и права пользователя из `User=`, затем читаю журнал.

**Что хотят услышать:** песочница systemd поверх прав Unix, `ReadWritePaths`, `ProtectHome`, `PrivateTmp`, журнал.

**Красный флаг:** делает `chmod 777` на каталог данных.

### 7. [middle] Как передать сервису пароль от БД? Что нельзя делать?

Класть его в `EnvironmentFile` с правами 640 `root:<группа сервиса>`, а не в юнит-файл: `Environment=` виден всем через `systemctl show`. Лучше `LoadCredential=` или внешний менеджер секретов. В git секрет не попадает.

**Что хотят услышать:** `EnvironmentFile`, права 640, `LoadCredential`, секреты не в юните и не в git.

**Красный флаг:** пароль в `ExecStart` командной строкой (виден в `ps`).

### 8. [middle] Сервис жив, но за ночь съел всю память и его убил OOM-killer. Как сделать, чтобы это не тронуло остальной сервер?

Задаю лимиты cgroup в юните: `MemoryMax=`, `MemoryHigh=`, при необходимости `TasksMax=`. При превышении убивается только этот сервис, а `Restart=on-failure` его поднимет. Причину утечки ищу отдельно (метрики памяти, профилирование).

**Что хотят услышать:** cgroups через systemd, `MemoryMax`, `journalctl -k | grep -i oom`, `systemd-cgtop`, различие лимита и лечения.

**Красный флаг:** «добавлю RAM» или «поставлю cron, который перезапускает раз в сутки» как единственное решение.

### 9. [middle] Нужно найти, что произошло с сервисом вчера в 03:00. Как читаешь логи?

`journalctl -u <сервис> --since "yesterday 02:50" --until "yesterday 03:10" --no-pager`. Если сервис перезагружался, добавляю `-b -1` (предыдущая загрузка). Для аварийного завершения смотрю ещё `journalctl -k` и `systemctl status`.

**Что хотят услышать:** `--since` и `--until`, `-b -1`, постоянный журнал (`/var/log/journal`), `-p` для фильтра.

**Красный флаг:** говорит, что журнал «пропал после перезагрузки» и не знает про `Storage=persistent`.

### 10. [junior] Чем сервис под systemd лучше запуска через `nohup` или `tmux`?

`nohup` и `tmux` переживают закрытие терминала, но не перезагрузку и не падение. systemd поднимает при загрузке, перезапускает по политике, собирает логи, ограничивает ресурсы и права, показывает состояние.

**Что хотят услышать:** автозапуск, `Restart`, журнал, изоляция, единый интерфейс управления.

**Красный флаг:** «и так работает, зачем усложнять».

## Проверено на версиях

- Ubuntu: 26.04 LTS и 24.04 LTS
- systemd: версия из репозитория Ubuntu (проверь `systemctl --version`)
- Python: 3.13 (`python3 --version`), приложение «Заметки» v2.2
- vim и nano: версии из репозитория Ubuntu, для темы урока различия несущественны

## Итог урока: ты умеешь

- [ ] умею написать unit-файл с `User`, `EnvironmentFile`, `Restart=on-failure` и установить его в `/etc/systemd/system/`
- [ ] умею выполнить `daemon-reload`, `enable --now` и проверить состояние `status` и `is-active`
- [ ] умею убить сервис и показать, что systemd его поднял, а после `stop` не поднял
- [ ] умею читать журнал: `journalctl -u`, `-f`, `--since`, `-p`, `-b`
- [ ] умею по коду `203/EXEC`, `217/USER` и `Start request repeated too quickly` найти причину
- [ ] умею ограничить сервис: `ProtectSystem=strict`, `ReadWritePaths`, `NoNewPrivileges`, проверить `systemd-analyze security`
- [ ] умею править файлы в vim и nano, выходить с сохранением и без, использовать `sudoedit`

**Дальше:** [Тема 2: Сеть, HTTP, DNS, nginx и TLS](../02-network/index.md)
