---
layout: lesson
title: "nginx как reverse proxy для «Заметок»"
topic: 2
lesson: "2.5"
time: "2 ч"
---

## Зачем это нужно

Приложение слушает 127.0.0.1:8080, и напрямую в интернет его не выставляют: оно не умеет держать тысячи медленных клиентов, терминировать TLS, отдавать статику и ограничивать нагрузку. Перед ним ставят веб-сервер, который принимает трафик на 80 порту и передаёт приложению. Такой веб-сервер называется обратным прокси (reverse proxy).
На работе 502 и 504 за nginx - самая частая жалоба на «сайт лежит», и разбор начинается с `error.log`, а не с перезапуска всего подряд.
Шаг проекта: «Заметки» доступны на `http://notes.lab/` через nginx на порту 80, приложение получает настоящие адрес и схему клиента в заголовках `X-Forwarded-*`.

## Что нужно знать

- [Урок 1.2: логи и потоки](../01-linux/02-text-pipes.md) - читать `access.log` через `grep`, `awk`, `sort`, `uniq -c`.
- [Урок 1.8: systemd](../01-linux/08-systemd-editors.md) - `systemctl`, `journalctl`, сервис `notes.service`.
- [Урок 2.2: порты и TCP](02-ports-tcp-ssh.md) - что такое `Connection refused`, как смотреть слушающие порты через `ss`.
- [Урок 2.3: DNS](03-dns.md) - запись `notes.lab` в `/etc/hosts`.
- [Урок 2.4: HTTP](04-http.md) - методы, заголовки, коды ответов, `curl -i`, эндпоинты `/headers`, `/slow`, `/error`.

## Теория

### Что делает nginx перед приложением

Клиент открывает соединение с nginx на порту 80. nginx читает запрос, выбирает подходящий блок `server` и внутри него блок `location`, открывает второе соединение к приложению (upstream, «вышестоящий сервер») и пересылает запрос. Ответ приложения он отдаёт клиенту. Получается два независимых TCP-соединения: клиент - nginx и nginx - приложение.

Зачем это нужно:

- приложение перезапускают, переписывают и переносят на другой порт, а снаружи адрес не меняется;
- медленных клиентов держит nginx (он рассчитан на десятки тысяч соединений), а не однопоточный Python;
- TLS сертификат подключается в одном месте (урок 2.6);
- есть единая точка логов, таймаутов и ограничений.

Устройство процессов: главный процесс (master) читает конфиг и управляет рабочими (worker), которые обслуживают запросы. `reload` заставляет master запустить новых worker с новым конфигом, а старые дорабатывают текущие запросы и завершаются. Поэтому `reload` не рвёт соединения, а `restart` рвёт.

> **Проверь понимание:** почему после `nginx -s reload` уже идущий долгий запрос не обрывается?

<details markdown="1">
<summary>Ответ</summary>

Master запускает новых worker с новым конфигом и просит старых завершиться после обработки текущих запросов. Обрыва нет, пока старый worker не закончит свои соединения.

</details>

### Конфиг: контексты и директивы

Конфиг nginx состоит из директив и блоков. Главный файл `/etc/nginx/nginx.conf` в блоке `http` подключает `/etc/nginx/sites-enabled/*`. В Ubuntu принято класть конфиг в `sites-available/`, а включать симлинком в `sites-enabled/`: удалить симлинк значит выключить сайт, не теряя файл.

Минимум для прокси:

- `listen 80;` порт, на котором принимаем;
- `server_name notes.lab;` имя из заголовка `Host`, для которого этот блок;
- `location / { ... }` путь запроса;
- `proxy_pass http://127.0.0.1:8080;` куда передать.

Без `proxy_set_header` приложение видит запрос от 127.0.0.1 и с `Host: 127.0.0.1:8080`. Поэтому nginx явно добавляет заголовки: `Host` (исходное имя), `X-Real-IP` (адрес клиента), `X-Forwarded-For` (цепочка адресов, каждый прокси дописывает свой), `X-Forwarded-Proto` (`http` или `https`). Приложению можно доверять этим заголовкам только когда они пришли от вашего nginx, а не от клиента напрямую: клиент способен подделать `X-Forwarded-For` сам.

> **Проверь понимание:** зачем приложению `X-Forwarded-Proto`, если оно всегда слушает обычный HTTP?

<details markdown="1">
<summary>Ответ</summary>

Между nginx и приложением всегда HTTP, а клиент мог прийти по HTTPS (урок 2.6). Приложение по этому заголовку узнаёт исходную схему и строит правильные ссылки и редиректы.

</details>

### Выбор location

Запрос попадает в один `location`. Правила приоритета:

1. `location = /path` точное совпадение, выигрывает сразу;
2. `location ^~ /prefix` самый длинный префикс, после которого регулярки не проверяются;
3. `location ~ regex` (регистрозависимая) и `~*` (без учёта регистра): первая подошедшая в порядке записи в файле;
4. `location /prefix` обычный префикс: если ничего сильнее не подошло, берётся самый длинный из них.

Ещё одна ловушка `proxy_pass`: `proxy_pass http://127.0.0.1:8080;` (без пути) передаёт URI как есть, а `proxy_pass http://127.0.0.1:8080/;` (со слэшем) заменяет совпавший префикс location. Для `location /api/` это разница между `/api/notes` и `/notes` на стороне приложения.

> **Проверь понимание:** есть `location /` и `location = /healthz`. В какой попадёт `GET /healthz` и в какой `GET /healthz/`?

<details markdown="1">
<summary>Ответ</summary>

`/healthz` попадёт в точный `= /healthz`. `/healthz/` не равен точному пути, поэтому попадёт в `location /`.

</details>

### Таймауты и коды 502, 504

Коды, которые генерирует сам nginx, а не приложение:

| Код | Что случилось | Что искать в error.log |
|---|---|---|
| 502 Bad Gateway | nginx не смог получить нормальный ответ: приложение не слушает порт или оборвало соединение | `connect() failed (111: Connection refused) while connecting to upstream` |
| 504 Gateway Timeout | приложение приняло соединение, но не ответило за `proxy_read_timeout` (по умолчанию 60 с) | `upstream timed out (110: Connection timed out) while reading response header from upstream` |
| 404, 403 без приложения | не подошёл `location`, нет файла или прав | `open() ... failed` |

Диагностика: `curl -i` показывает, кто ответил (заголовок `Server: nginx` у ошибок nginx), а причину называет только `/var/log/nginx/error.log`. Приложение при 502 может быть вообще ни при чём: оно просто остановлено.

> **Проверь понимание:** приложение остановлено. Какой код увидит клиент и какая строка появится в `error.log`?

<details markdown="1">
<summary>Ответ</summary>

502. В `error.log`: `connect() failed (111: Connection refused) while connecting to upstream`. Порт закрыт, ядро сразу отвечает отказом (урок 2.2).

</details>

## Практика

Все задания выполняются на сервере или ВМ с Ubuntu 26.04 или 24.04. Приложение из урока 1.8 работает как `notes.service`, а в `/etc/hosts` есть `notes.lab` (урок 2.3). Приложение обновлено до версии v3 (уроки 2.4) с эндпоинтами `/headers`, `/slow` и `/error`.

### Задание 1. Установка nginx и разбор дефолтной конфигурации

**Цель:** поставить nginx, увидеть страницу по умолчанию и найти, откуда она берётся.

**Предскажи:** сколько процессов nginx запустится и какой порт они займут? Что вернёт `curl -sI http://127.0.0.1/`?

<details markdown="1">
<summary>Ответ</summary>

Один master от root и несколько worker от `www-data` (по числу ядер), порт 80. `curl -sI` вернёт `HTTP/1.1 200 OK` и заголовок `Server: nginx/...`.

</details>

**Шаги:**

1. Останови всё, что занимает 80 порт, и поставь nginx из репозитория Ubuntu:

   ```bash
   sudo apt update
   sudo apt install -y nginx
   systemctl is-active nginx
   ```

2. Посмотри процессы и порт:

   ```bash
   ps -o pid,user,cmd -C nginx
   sudo ss -ltnp 'sport = :80'
   ```

3. Проверь ответ и найди, какой конфиг его отдаёт:

   ```bash
   curl -sI http://127.0.0.1/
   ls -l /etc/nginx/sites-enabled/
   ```

**Что должно получиться:**

```text
active
    PID USER     CMD
    712 root     nginx: master process /usr/sbin/nginx -g daemon on; master_process on;
    713 www-data nginx: worker process
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      511          0.0.0.0:80        0.0.0.0:*     users:(("nginx",pid=712,fd=5),...)
HTTP/1.1 200 OK
Server: nginx/1.24.0 (Ubuntu)
lrwxrwxrwx 1 root root 34 ... default -> /etc/nginx/sites-available/default
```

Номера PID и версия у тебя будут свои.

**Объясни себе:**

- Почему master работает от root, а worker от `www-data`? (подсказка: порт 80 меньше 1024, урок 1.3)
- Что даст удаление симлинка `sites-enabled/default`?

**Типичные ошибки:**

- `nginx: [emerg] bind() to 0.0.0.0:80 failed (98: Address already in use)`: порт 80 занят другим процессом (Apache, чужой контейнер): найди `sudo ss -ltnp 'sport = :80'` и останови.
- `curl: (7) Failed to connect to 127.0.0.1 port 80`: nginx не запущен: `sudo systemctl start nginx` и `journalctl -u nginx -n 20`.

### Задание 2. Конфиг reverse proxy для «Заметок»

**Цель:** написать `deploy/nginx/notes.conf` в репозитории, подключить его в nginx и получить ответ приложения на порту 80.

**Предскажи:** что покажет `curl http://notes.lab/headers`: адрес клиента 127.0.0.1 в `X-Real-Ip` или пустое значение? Почему `Host` будет `notes.lab`, а не `127.0.0.1:8080`?

<details markdown="1">
<summary>Ответ</summary>

`X-Real-Ip: 127.0.0.1`, если ты запрашиваешь с того же сервера (nginx видит клиента 127.0.0.1). Приложение получит заголовки из `proxy_set_header`. `Host` будет `notes.lab`, потому что мы прокидываем `$host` (исходное имя из запроса), а не подставляем адрес upstream.

</details>

**Шаги:**

1. Создай файл в репозитории `~/notes/deploy/nginx/notes.conf`:

   ```nginx
   # Прокси перед «Заметками»: nginx :80 -> приложение 127.0.0.1:8080
   server {
       listen 80;
       server_name notes.lab;

       access_log /var/log/nginx/notes-access.log;
       error_log  /var/log/nginx/notes-error.log;

       location / {
           proxy_pass http://127.0.0.1:8080;

           # Приложение за прокси не видит клиента, поэтому передаём явно
           proxy_set_header Host              $host;
           proxy_set_header X-Real-IP         $remote_addr;
           proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;

           proxy_connect_timeout 3s;
           proxy_read_timeout    30s;
       }
   }
   ```

2. Установи конфиг, включи сайт, выключи дефолтный и проверь синтаксис:

   ```bash
   sudo cp ~/notes/deploy/nginx/notes.conf /etc/nginx/sites-available/notes
   sudo ln -s /etc/nginx/sites-available/notes /etc/nginx/sites-enabled/notes
   sudo rm /etc/nginx/sites-enabled/default
   sudo nginx -t
   ```

3. Примени без разрыва соединений и проверь:

   ```bash
   sudo systemctl reload nginx
   curl -i http://notes.lab/
   curl -s http://notes.lab/headers
   ```

**Что должно получиться:**

```text
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
HTTP/1.1 200 OK
Server: nginx/1.24.0 (Ubuntu)
Content-Type: text/plain; charset=utf-8
Content-Length: 20

Notes service vdev
{"Host": "notes.lab", "X-Real-Ip": "127.0.0.1", "X-Forwarded-For": "127.0.0.1", "X-Forwarded-Proto": "http", ...}
```

Строка версии зависит от `APP_VERSION` в `/etc/notes/notes.env`, точный порядок ключей JSON может отличаться.

**Объясни себе:**

- Чем `$remote_addr` отличается от `$proxy_add_x_forwarded_for`?
- Почему сначала `nginx -t`, а потом `reload`?
- Что изменится, если удалить строку `proxy_set_header Host $host;`? (по умолчанию nginx подставит `Host: 127.0.0.1:8080`, проверь через `/headers`)

**Типичные ошибки:**

- `nginx: [emerg] unknown directive "proxy_pas" in /etc/nginx/sites-enabled/notes:9`: опечатка в директиве: исправь и снова `nginx -t`.
- `nginx: [emerg] "server" directive is not allowed here`: конфиг лежит не там или не закрыта скобка выше: проверь `{` и `}`.
- `curl: (6) Could not resolve host: notes.lab`: нет записи в `/etc/hosts` (урок 2.3): `echo '127.0.0.1 notes.lab' | sudo tee -a /etc/hosts`.
- `ln: failed to create symbolic link '/etc/nginx/sites-enabled/notes': File exists`: симлинк уже есть, это нормально, проверь `ls -l`.

### Задание 3. Читаем access.log и разбираем формат

**Цель:** по логу отвечать на вопросы «кто, что и как быстро».

**Предскажи:** сколько строк добавится в `notes-access.log` после трёх запросов `curl`? Какой код будет у `GET /nope`?

<details markdown="1">
<summary>Ответ</summary>

Три строки, по одной на запрос. `/nope` даст 404: nginx передаёт запрос приложению, а приложение отвечает 404 (урок 2.4). Код пришёл от приложения, а не от nginx.

</details>

**Шаги:**

1. Сделай несколько запросов:

   ```bash
   curl -s -o /dev/null http://notes.lab/
   curl -s -o /dev/null http://notes.lab/nope
   curl -s -o /dev/null http://notes.lab/error
   ```

2. Прочитай последние строки и посчитай коды (приёмы из урока 1.2):

   ```bash
   sudo tail -n 3 /var/log/nginx/notes-access.log
   sudo awk '{print $9}' /var/log/nginx/notes-access.log | sort | uniq -c | sort -rn
   ```

**Что должно получиться:**

```text
127.0.0.1 - - [29/Sep/2026:10:15:01 +0000] "GET / HTTP/1.1" 200 20 "-" "curl/8.14.1"
127.0.0.1 - - [29/Sep/2026:10:15:01 +0000] "GET /nope HTTP/1.1" 404 22 "-" "curl/8.14.1"
127.0.0.1 - - [29/Sep/2026:10:15:02 +0000] "GET /error HTTP/1.1" 500 27 "-" "curl/8.14.1"
      1 500
      1 404
      1 200
```

Версия curl и время у тебя другие. Девятое поле по пробелам это код ответа, десятое размер тела.

**Объясни себе:**

- Как отличить 500, который вернуло приложение, от 502, которое сформировал nginx? (подсказка: смотри `error.log`, у 502 там есть запись)
- Какой процент 5xx в твоём логе и как посчитать его одной командой awk?

**Типичные ошибки:**

- `tail: cannot open '/var/log/nginx/notes-access.log' for reading: Permission denied`: логи читает группа `adm`, забыл `sudo`.
- `awk` считает не то поле: в логе поля разделены пробелами, но `[29/Sep/2026:10:15:01 +0000]` даёт два поля (дата и часовой пояс), код ответа именно `$9`.

### Задание 4. 502 и 504 своими руками

**Цель:** вызвать оба кода и найти причину в `error.log`, а не гадать.

**Предскажи:** какой код вернёт nginx, если остановить `notes.service`? А если приложение работает, но `/slow?sec=40` при `proxy_read_timeout 30s`?

<details markdown="1">
<summary>Ответ</summary>

Остановленное приложение: 502 сразу (`Connection refused`). `/slow?sec=40`: 504 через 30 секунд (`upstream timed out`). Разница во времени ответа тоже диагностический признак.

</details>

**Шаги:**

1. 502:

   ```bash
   sudo systemctl stop notes
   curl -i http://notes.lab/
   sudo tail -n 2 /var/log/nginx/notes-error.log
   sudo systemctl start notes
   ```

2. 504 (замерь время, запрос будет висеть 30 секунд):

   ```bash
   time curl -s -o /dev/null -w '%{http_code}\n' 'http://notes.lab/slow?sec=40'
   sudo tail -n 1 /var/log/nginx/notes-error.log
   ```

3. Проверь, что при `sec=5` всё в порядке:

   ```bash
   curl -s 'http://notes.lab/slow?sec=5'
   ```

**Что должно получиться:**

```text
HTTP/1.1 502 Bad Gateway
Server: nginx/1.24.0 (Ubuntu)
...
2026/09/29 10:20:11 [error] 801#801: *5 connect() failed (111: Connection refused) while connecting to upstream, client: 127.0.0.1, server: notes.lab, request: "GET / HTTP/1.1", upstream: "http://127.0.0.1:8080/", host: "notes.lab"
504
real    0m30.0xxs
2026/09/29 10:21:02 [error] 801#801: *7 upstream timed out (110: Connection timed out) while reading response header from upstream, client: 127.0.0.1, server: notes.lab, request: "GET /slow?sec=40 HTTP/1.1", upstream: "http://127.0.0.1:8080/slow?sec=40", host: "notes.lab"
slept 5
```

**Объясни себе:**

- Почему 504 пришёл ровно через 30 секунд, а не через 40?
- Что произойдёт с приложением после 504: оно всё ещё считает `/slow`? (да, оно доработает запрос, nginx просто перестал ждать)
- Поднять `proxy_read_timeout` до 120 секунд: лечение или маскировка? Когда какое?

**Типичные ошибки:**

- `curl: (52) Empty reply from server`: соединение закрыто без ответа, это не 502: смотри, не оборвал ли приложение процесс (`journalctl -u notes`).
- Тайм-аут `504` в `error.log` отсутствует: нужный `error_log` указан внутри `server`, а ты смотришь в общий `/var/log/nginx/error.log`.

### Задание 5. Шаг проекта: «Заметки» за nginx

**Цель:** привести проект к состоянию после урока 2.5 и закрыть порт 8080 от внешнего мира.

**Предскажи:** приложение слушает `127.0.0.1:8080`, а nginx на `0.0.0.0:80`. Достучится ли внешний клиент до `:8080` напрямую?

<details markdown="1">
<summary>Ответ</summary>

Нет. `127.0.0.1` доступен только с самой машины (урок 2.1). Снаружи открыт только 80, и запрос идёт через nginx. Порт 8080 закрывается не файрволом, а привязкой к loopback.

</details>

**Шаги:**

1. Убедись, что в `/etc/notes/notes.env` стоит `HOST=127.0.0.1` и приложение слушает именно его:

   ```bash
   sudo grep ^HOST /etc/notes/notes.env
   sudo ss -ltn 'sport = :8080'
   ```

2. Убедись, что файл в репозитории и в `/etc/nginx/sites-available/notes` совпадают:

   ```bash
   diff ~/notes/deploy/nginx/notes.conf /etc/nginx/sites-available/notes && echo same
   ```

3. Проверь весь путь, включая POST через прокси:

   ```bash
   curl -s -X POST -H 'Content-Type: application/json' -d '{"text":"через nginx"}' http://notes.lab/notes
   curl -s http://notes.lab/notes
   ```

4. Убедись, что nginx стартует при загрузке:

   ```bash
   systemctl is-enabled nginx
   ```

5. Закоммить конфиг:

   ```bash
   cd ~/notes && git add deploy/nginx/notes.conf && git commit -m "Добавлен nginx reverse proxy"
   ```

**Что должно получиться:**

```text
HOST=127.0.0.1
LISTEN 0      5      127.0.0.1:8080      0.0.0.0:*
same
{"id":1}
[{"id":1,"text":"через nginx","created_at":"2026-09-29T10:30:00+00:00"}]
enabled
```

Если `git` в проекте ещё не подключён (урок 3.1), пропусти пятый шаг: коммит появится позже.

**Объясни себе:**

- Что увидит приложение в `X-Forwarded-For`, когда запрос придёт с другой машины?
- Почему конфиг хранится в репозитории, а не только в `/etc/nginx`?

**Типичные ошибки:**

- `nginx: [warn] conflicting server name "notes.lab" on 0.0.0.0:80, ignored`: два файла в `sites-enabled` объявляют одно имя: оставь один.
- Вместо «Заметок» открывается страница «Welcome to nginx!»: дефолтный сайт не выключен или `server_name` не совпал с `Host`: `sudo nginx -T | grep -n server_name`.

## Сломай и почини

Скачай сценарий и запусти один из четырёх случаев, не читая скрипт:

```bash
curl -fsSLO https://raw.githubusercontent.com/distinguished-sre/devops/devops/project/notes/break/2.5/break.sh
sudo bash break.sh 1     # или 2, 3, 4, random
```

### Симптом

После запуска сайт ведёт себя неправильно. Возможные проявления: `nginx -t` или `reload` пишут ошибку и сайт живёт на старом конфиге; `curl` возвращает 502; запрос висит 30 секунд и даёт 504; путь отвечает совсем не тем, что ожидалось.

### Гипотезы

Прежде чем что-то чинить, выпиши 2-3 версии для своего симптома: конфиг nginx, приложение остановлено или не слушает порт, таймаут, неверный `location`.

### Проверки

1. `sudo nginx -t`: синтаксис и номер строки с ошибкой.
2. `curl -i http://notes.lab/`: код и заголовок `Server`.
3. `sudo tail -n 5 /var/log/nginx/notes-error.log`: причина в тексте.
4. `systemctl status notes` и `sudo ss -ltn 'sport = :8080'`: жив ли upstream.
5. `time curl ...`: 502 приходит сразу, 504 после таймаута.
6. `sudo nginx -T | grep -n location`: какие location реально загружены.

### Исправление

<details markdown="1">
<summary>Разбор четырёх сценариев</summary>

**Сценарий 1. Синтаксическая ошибка.** `nginx -t` говорит `unknown directive` или `unexpected "}"` с номером строки. Исправь строку, повтори `nginx -t`, затем `reload`. Пока `-t` не прошёл, `reload` не применит конфиг, сайт продолжает работать по прошлому.

**Сценарий 2. 502.** В `error.log`: `connect() failed (111: Connection refused)`. Приложение остановлено. `sudo systemctl start notes`, затем `systemctl status notes` и `journalctl -u notes -n 20`, если оно снова падает.

**Сценарий 3. 504.** В `error.log`: `upstream timed out (110...)`, `curl` завис на 30 секунд. Приложение медленное (`/slow`). Разберись, законно ли долгое время: если нет, чини приложение, а не таймаут; если да, поднимай `proxy_read_timeout` только для нужного `location`.

**Сценарий 4. Приоритет location.** Запрос уходит не туда: например, регулярка `location ~ ^/healthz` перехватывает то, что должен обслужить `location = /healthz`, либо `^~` отключает проверку регулярок. Найди все location через `sudo nginx -T` и примени порядок из теории: `=`, затем `^~`, затем регулярки по порядку, затем самый длинный префикс.

Общий вывод: сначала код и заголовок `Server`, затем `error.log`, затем состояние upstream. Перезапуск ничего не объясняет.

</details>

## Вопросы с собеседований

### 1. [junior] Прод отвечает 502 Bad Gateway. Твои действия?

Проверяю, что 502 отдал именно nginx (`curl -i`, заголовок `Server`), открываю `error.log` и читаю причину. Обычно `Connection refused`: приложение остановлено или слушает другой порт. Смотрю `systemctl status`, `ss -ltn`, журнал приложения. Поднимаю сервис и ищу, почему он упал.

**Что хотят услышать:** порядок «код, error.log, состояние upstream», знание, что 502 это ответ nginx, а не приложения, упоминание `ss` и `journalctl`.

**Красный флаг:** «перезапустил nginx» без чтения логов.

### 2. [junior] Чем 502 отличается от 504 и как понять по времени ответа?

502: nginx не получил осмысленный ответ, обычно отказ соединения, ответ приходит сразу. 504: соединение есть, но приложение молчит дольше `proxy_read_timeout`, ответ приходит после таймаута. Причина 504 почти всегда в медленном приложении или зависимости (БД, внешний API).

**Что хотят услышать:** `connect() failed` против `upstream timed out`, таймауты `proxy_connect_timeout` и `proxy_read_timeout`.

**Красный флаг:** «оба значит сервер лёг».

### 3. [junior] Ты поправил конфиг nginx на проде. Как применить безопасно?

`nginx -t`, затем `systemctl reload nginx`. Перед правкой копия старого файла. После reload проверяю `curl` и `error.log`. Reload не рвёт текущие соединения, restart рвёт.

**Что хотят услышать:** `nginx -t` до применения, разница `reload` и `restart`, откат из копии.

**Красный флаг:** правка на проде и сразу `restart` без проверки синтаксиса.

### 4. [junior] Приложение за nginx видит у всех клиентов адрес 127.0.0.1. Как получить настоящий?

Прокси должен передавать адрес заголовками `X-Real-IP` и `X-Forwarded-For`, а приложение читать их. Доверять нужно только заголовкам от своего прокси, иначе клиент подделает адрес.

**Что хотят услышать:** `proxy_set_header`, `$remote_addr`, `$proxy_add_x_forwarded_for`, проблема доверия к заголовку.

**Красный флаг:** «в IP клиента можно всегда верить из X-Forwarded-For».

### 5. [middle] Сайт открывается медленно, в логе nginx много 504 по одному пути. Как разбираешься?

Считаю долю 504 и путь по `access.log`, смотрю `$request_time` и время upstream (добавляю их в `log_format`), проверяю приложение и зависимости в это время. Затем решаю, что чинить: запрос, БД или ресурсы. Увеличиваю `proxy_read_timeout` только осознанно и точечно.

**Что хотят услышать:** `$request_time`, `$upstream_response_time`, локализация по пути, разница между лечением и маскировкой.

**Красный флаг:** «подниму таймаут до 600 секунд».

### 6. [middle] После деплоя часть запросов даёт 502, а потом всё проходит. В чём может быть дело?

Приложение перезапускается и короткое время не слушает порт. Проверяю `journalctl` на рестарты, время старта и наличие проверки готовности. Решение: выкатывать без простоя (позже в курсе: Kubernetes, урок 5.7) или на время перезапуска держать резервный upstream.

**Что хотят услышать:** корреляция времени 502 с рестартами, понимание окна недоступности, идея graceful restart.

**Красный флаг:** «это nginx глючит».

### 7. [middle] `curl` на `/healthz` возвращает страницу от другого location, хотя есть точное совпадение. Что проверишь?

Смотрю загруженный конфиг `nginx -T`: возможно, другой файл в `sites-enabled` или `conf.d` перехватывает `server_name`, либо путь запрошен с косой чертой, что не равно `= /healthz`. Напоминаю приоритет: `=`, `^~`, регулярки по порядку, длинный префикс.

**Что хотят услышать:** `nginx -T`, порядок выбора location, конфликт `server_name`.

**Красный флаг:** «в nginx приоритет зависит от порядка строк во всех случаях».

### 8. [middle] Что такое `proxy_pass` со слэшем и без в конце? Приведи пример беды.

`location /api/ { proxy_pass http://app:8080; }` передаст `/api/notes` как есть, а `proxy_pass http://app:8080/;` отрежет `/api/` и передаст `/notes`. Кто-то добавил слэш, и приложение получает другие пути, отвечает 404.

**Что хотят услышать:** правило замены префикса, проверка через `/headers` или лог приложения.

**Красный флаг:** «слэш ни на что не влияет».

### 9. [junior] Сайт отдаёт страницу «Welcome to nginx!» вместо приложения. Причины?

Не подключён или не включён конфиг сайта (нет симлинка в `sites-enabled`), не совпало `server_name` и включился default, конфиг не перечитан после правки. Проверяю `nginx -T`, `ls sites-enabled`, `Host` в запросе.

**Что хотят услышать:** `sites-enabled`, выбор server по `Host`, `nginx -T`, reload.

**Красный флаг:** «переустановлю nginx».

### 10. [middle] Прод: nginx выдаёт 502, а приложение работает и отвечает на `curl 127.0.0.1:8080`. Что ещё проверишь?

Смотрю `error.log`: возможно, `Permission denied` при подключении (SELinux/AppArmor и сокет), приложение слушает IPv6 `::1`, а nginx ходит на `127.0.0.1`, либо `upstream sent too big header`. Читаю точный текст ошибки, а не гадаю.

**Что хотят услышать:** IPv4 против IPv6 на loopback, `upstream sent too big header`, права на сокет, вывод из текста ошибки.

**Красный флаг:** «если curl работает, то nginx неправ и его надо переставить».

### 11. [middle] Как найти самый частый источник 5xx по логу nginx за сегодня?

`awk` по полю кода и пути, отбор `$9 ~ /^5/`, `sort | uniq -c | sort -rn | head`. Для сложных случаев добавляю в `log_format` время upstream и идентификатор запроса.

**Что хотят услышать:** пайплайн из урока 1.2, отбор по коду, идея расширенного `log_format`.

**Красный флаг:** «открою лог и посмотрю глазами».

## Проверено на версиях

- Ubuntu: 26.04 LTS и 24.04 LTS
- nginx: версия из репозитория Ubuntu не закреплена, проверь актуальную версию на странице проекта (в примерах вывода 1.24.0 из Ubuntu 24.04)
- Python: 3.13
- curl: версия из репозитория Ubuntu (в примерах 8.14.1)

## Итог урока: ты умеешь

- [ ] умею установить nginx и включить сайт через `sites-available` и `sites-enabled`
- [ ] умею настроить `proxy_pass` с заголовками `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`
- [ ] умею проверять конфиг через `nginx -t` и применять через `reload` без разрыва соединений
- [ ] умею отличить 502 от 504 по времени ответа и найти причину в `error.log`
- [ ] умею предсказать, какой `location` обработает запрос
- [ ] умею читать `access.log` и считать коды ответов
- [ ] умею закрыть порт приложения привязкой к 127.0.0.1 и оставить наружу только 80

**Дальше:** [Урок 2.6: TLS и HTTPS](06-tls.md)
