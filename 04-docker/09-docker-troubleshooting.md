---
layout: lesson
title: "Отладка контейнеров и уборка диска"
topic: 4
lesson: "4.9"
time: "1.5 ч"
---

## Зачем это нужно

Контейнер упал в три часа ночи, и единственное, что у тебя есть, это код выхода, логи и `docker inspect`. Плюс типичная беда любого Docker-хоста: диск заполнился логами и старыми образами, а сервис умер с `no space left on device`.
На собеседовании «контейнер в Exited, твои действия» и «диск полный, а `du` показывает мало» спрашивают почти всегда.
Мы соберём один порядок диагностики: код выхода, логи, `inspect`, `exec`, ресурсы, диск. Тот же порядок потом пригодится в Kubernetes.

Шаг проекта: в `~/notes` появляется `Makefile` с целями `build`, `up`, `down`, `logs`, `ps`, `test`, `clean`, и типовые команды больше не набираются руками.

## Что нужно знать

- [Урок 1.4: процессы и сигналы](../01-linux/04-processes-signals.md) - SIGTERM, SIGKILL и коды выхода 143 и 137
- [Урок 1.5: диск, память, CPU](../01-linux/05-disk-memory-cpu.md) - `df`, `du`, OOM-killer, демонстрационный эндпоинт `/leak`
- [Урок 1.6: основы Bash](../01-linux/06-bash-basics.md) - `Makefile`, TAB в рецептах, переменные
- [Урок 4.2: Dockerfile](02-dockerfile.md) - образ `notes`, пользователь 10001, `CMD`
- [Урок 4.3: тома и сети](03-storage-networks.md) - тома, и почему `prune --volumes` опасен
- [Урок 4.5: Compose и PostgreSQL](05-compose-postgres.md) - стек `notes` + `db`
- [Урок 4.7: образы и реестр](07-images-registry.md) - образ `notes:0.4.0`

## Теория

### Порядок диагностики

Не гадай, иди по лестнице. Каждая ступень отвечает на свой вопрос.

| Ступень | Команда | Вопрос |
|---|---|---|
| 1. Состояние | `docker ps -a` | жив ли контейнер, какой код выхода |
| 2. Логи | `docker logs --tail 50 <имя>` | что он успел сказать перед смертью |
| 3. Причина | `docker inspect <имя>` | OOM, перезапуски, команда, смонтированные тома |
| 4. Внутри | `docker exec -it <имя> sh` | что видит процесс: файлы, сеть, переменные |
| 5. Ресурсы | `docker stats --no-stream` | CPU, память, сеть |
| 6. Хост | `docker system df`, `df -h` | не кончилось ли место |

Логи (logs) это то, что процесс написал в stdout и stderr. Если приложение пишет в файл внутри контейнера, `docker logs` пуст. Поэтому «Заметки» пишут в консоль.

> **Проверь понимание:** `docker logs` пуст, а контейнер в статусе `Exited (1)`. Какие две причины самые вероятные?

<details>
<summary>Ответ</summary>

Первая: процесс упал раньше, чем успел что-то напечатать (например, не нашёл `ENTRYPOINT` или бинарник). Тогда смотри код выхода (126, 127) и запускай образ с другой командой: `docker run --rm -it --entrypoint sh <образ>`.
Вторая: приложение пишет логи в файл, а не в stdout. Тогда `docker exec`/`docker cp` и чтение файла, а в образе стоит переправить лог в stdout.

</details>

### Коды выхода

Код выхода (exit code) процесса виден в `docker ps -a` и в `docker inspect`. Запомни таблицу:

| Код | Смысл |
|---|---|
| 0 | штатное завершение (для сервиса это тоже странно: он должен работать вечно) |
| 1 | ошибка приложения, читай логи |
| 125 | сам `docker run` не смог запуститься (неверный флаг, порт занят) |
| 126 | команда найдена, но не исполняется (нет права `x`) |
| 127 | команда не найдена (опечатка в `CMD`, нет бинарника в образе) |
| 137 | 128 + 9: SIGKILL. Либо OOM-killer, либо `docker kill`, либо `stop` не дождался и добил |
| 143 | 128 + 15: SIGTERM, штатная остановка `docker stop` |

Код 137 сам по себе не говорит про память. Различает `State.OOMKilled` в `inspect`: `true` значит убило ядро за превышение лимита памяти cgroup, `false` значит кто-то послал SIGKILL. Напомню из урока 1.4: `docker stop` шлёт SIGTERM, ждёт 10 секунд и шлёт SIGKILL. Если процесс не PID 1 в exec-форме `CMD`, он SIGTERM не получит и будет убит по таймауту с кодом 137.

> **Проверь понимание:** контейнер завершился с кодом 137, и `OOMKilled: false`. Что это значит?

<details>
<summary>Ответ</summary>

Процесс убит сигналом SIGKILL, но не за память. Чаще всего это `docker stop`, который не дождался завершения (приложение игнорирует SIGTERM, например, из-за shell-формы `CMD`), или ручной `docker kill`, или оркестратор. Ищи, кто послал сигнал, и чини обработку SIGTERM.

</details>

### inspect, exec и отладочный контейнер

`docker inspect` отдаёт JSON про всё. Читать его целиком не нужно, берут поля шаблоном `--format` (Go template) или через `jq`. Поля, которые нужны чаще всего: `.State.Status`, `.State.ExitCode`, `.State.OOMKilled`, `.RestartCount`, `.HostConfig.Memory`, `.LogPath`, `.Mounts`.

`docker exec` запускает второй процесс в тех же пространствах имён (namespaces) и cgroup. В нашем образе `python:3.13-slim` нет `curl` и `ps`, зато есть Python, им можно проверять сеть: `python -c "import urllib.request; ..."`. Если внутри вообще нет оболочки (distroless), помогает отладочный контейнер в сети или PID-пространстве целевого: `docker run --rm -it --network container:<имя> alpine:3.22 sh`.

Ограничения памяти задаются флагом `-m 64m` (или `mem_limit` в Compose). Превысил лимит, ядро внутри cgroup убивает процесс. Хостовая память при этом может быть свободна: лимит контейнера и память хоста разные вещи.

### Куда уходит диск

Docker хранит всё в `/var/lib/docker`. Четыре главных потребителя, их показывает `docker system df`:

- образы (images): старые теги и слои без имени (`<none>`, dangling);
- контейнеры: слой записи остановленных контейнеров;
- тома (volumes): данные, самое ценное;
- логи: драйвер `json-file` (по умолчанию) пишет stdout контейнера в JSON-файл `/var/lib/docker/containers/<id>/<id>-json.log` и без ротации растёт бесконечно.

Ротация включается опциями `max-size` и `max-file` у контейнера или глобально в `/etc/docker/daemon.json`. В уроке 4.6 ты уже включил её для nginx, теперь сделаем это осознанно для всех.

Чистка по уровням опасности:

| Команда | Что удаляет | Риск |
|---|---|---|
| `docker container prune` | остановленные контейнеры | низкий |
| `docker image prune` | образы без тега (dangling) | низкий |
| `docker image prune -a` | все образы, не используемые контейнерами | средний: придётся заново скачивать |
| `docker builder prune` | кэш сборки | низкий |
| `docker system prune` | контейнеры, сети, dangling-образы, кэш | средний |
| `docker system prune -a --volumes` | всё выше, плюс образы и ТОМА | высокий: потеря данных БД |

Том считается неиспользуемым, если к нему не подключён ни один контейнер, даже остановленный. Стоило сделать `compose down` и `system prune --volumes`, и `pgdata` исчез вместе с заметками. Это сценарий из урока 4.3.

> **Проверь понимание:** `df -h` показывает `/var` на 100%, а `du -sh /var/lib/docker/*` суммарно даёт мало. Что проверишь?

<details>
<summary>Ответ</summary>

Сначала `docker system df`: он считает образы, контейнеры и тома. Потом размер логов: `sudo du -sh /var/lib/docker/containers/*/*-json.log`. Если места нет и `du` его не видит, на диске могут быть удалённые, но открытые файлы (`sudo lsof +L1`) или исчерпаны inodes (`df -i`, урок 1.5).

</details>

## Практика

### Задание 1. OOM: ловим убийство за память

**Цель:** отличить OOM-kill от других причин 137 и увидеть это в `inspect`.

**Предскажи:** контейнер `notes:0.4.0` с лимитом 64 МБ просят удержать 100 МБ через `/leak?mb=100`. Что вернёт `curl`, какой будет код выхода и значение `OOMKilled`?

<details>
<summary>Ответ</summary>

`curl` получит обрыв соединения (`Empty reply from server`), процесс умрёт с кодом 137, `OOMKilled` будет `true`.

</details>

**Шаги**

1. Останови стек Compose, если он занимает 8080 (`docker compose down` в `~/notes`). Запусти контейнер только с файловым хранилищем и лимитом:

```bash
# лимит памяти 64 МБ, без перезапуска, порт 8081 снаружи
docker run -d --name t-oom -m 64m -p 127.0.0.1:8081:8080 notes:0.4.0
```

2. Проверь, что живой, и вызови демонстрационный эндпоинт (в реальном сервисе его бы не было):

```bash
curl -s http://127.0.0.1:8081/healthz
curl -s "http://127.0.0.1:8081/leak?mb=100"
```

3. Найди причину:

```bash
docker ps -a --filter name=t-oom --format '{% raw %}{{.Status}}{% endraw %}'
docker inspect -f '{% raw %}exit={{.State.ExitCode}} oom={{.State.OOMKilled}} mem={{.HostConfig.Memory}}{% endraw %}' t-oom
docker logs --tail 5 t-oom
```

**Что должно получиться**

```text
ok
curl: (52) Empty reply from server
Exited (137) 3 seconds ago
exit=137 oom=true mem=67108864
```

`docker logs` покажет только обычные строки старта: приложение убито мгновенно и не успело ничего написать. Это нормально для OOM.

**Объясни себе**

- Почему в логах нет причины смерти, а в `inspect` есть?
- Что изменится, если добавить `--restart unless-stopped`? Как заметишь проблему по `RestartCount`?
- Что делать в реальном инциденте: поднять лимит или искать утечку? (Подсказка: смотри `docker stats` во времени.)

**Типичные ошибки**

- `curl: (7) Failed to connect to 127.0.0.1 port 8081`: контейнер уже упал или порт не опубликован. Смотри `docker ps -a`.
- `Bind for 127.0.0.1:8081 failed: port is already allocated`: порт занят старым `t-oom`. Удали: `docker rm -f t-oom`.
- `WARNING: Your kernel does not support memory limit capabilities`: на WSL2 или старом ядре лимиты не включены. Проверь `docker info` и cgroup v2.

Уборка: `docker rm -f t-oom`.

### Задание 2. Логи, которые съедают диск

**Цель:** найти лог-файл контейнера и ограничить его рост.

**Предскажи:** контейнер печатает 200 тысяч строк. Где лежит их файл на хосте и сколько он весит примерно? Изменится ли размер после `docker restart`?

<details>
<summary>Ответ</summary>

Файл `/var/lib/docker/containers/<id>/<id>-json.log`, около 2-3 МБ (каждая строка оборачивается в JSON с временем и потоком). После `restart` тот же файл продолжает расти, лог живёт, пока контейнер не удалён (`docker rm`).

</details>

**Шаги**

1. Контейнер без ротации:

```bash
docker run -d --name t-log1 alpine:3.22 sh -c 'yes "строка лога для проверки" | head -n 200000; sleep 300'
sleep 3
sudo ls -lh "$(docker inspect -f '{% raw %}{{.LogPath}}{% endraw %}' t-log1)"
```

2. Контейнер с ротацией: максимум 3 файла по 1 МБ:

```bash
docker run -d --name t-log2 \
  --log-opt max-size=1m --log-opt max-file=3 \
  alpine:3.22 sh -c 'yes "строка лога для проверки" | head -n 200000; sleep 300'
sleep 3
sudo ls -lh "$(dirname "$(docker inspect -f '{% raw %}{{.LogPath}}{% endraw %}' t-log2)")"
```

3. Найди самые тяжёлые логи на хосте:

```bash
sudo du -h /var/lib/docker/containers/*/*-json.log | sort -h | tail -5
docker system df
```

**Что должно получиться**

```text
-rw-r----- 1 root root 8.6M ... /var/lib/docker/containers/<id>/<id>-json.log
-rw-r----- 1 root root 1.0M ... <id>-json.log
-rw-r----- 1 root root 1.0M ... <id>-json.log.1
-rw-r----- 1 root root 1.0M ... <id>-json.log.2
```

Размер первого файла зависит от длины строки; важно, что он один и растёт без предела, а у второго контейнера файлов не больше трёх по 1 МБ.

**Объясни себе**

- Почему `docker logs` работает и после ротации, но видит только оставшиеся файлы?
- Как включить ту же ротацию для всех новых контейнеров? (Подсказка: `/etc/docker/daemon.json`, ключ `log-opts`, нужен `sudo systemctl restart docker`; действует только на новые контейнеры.)
- Почему удаление лог-файла руками (`rm`) на работающем контейнере не освобождает место?

**Типичные ошибки**

- `ls: cannot access '/var/lib/docker/containers/...': Permission denied`: каталог принадлежит root. Используй `sudo`.
- `unknown log opt 'max-size' for journald log driver`: драйвер логов не `json-file`. Проверь `docker info --format '{% raw %}{{.LoggingDriver}}{% endraw %}'`.

Уборка: `docker rm -f t-log1 t-log2`.

### Задание 3. Безопасная уборка диска

**Цель:** освободить место, не потеряв тома с данными.

**Предскажи:** какая из команд `docker image prune`, `docker image prune -a`, `docker system prune --volumes` удалит образ `notes:0.4.0`, если запущен только стек PostgreSQL, а `notes` остановлен?

<details>
<summary>Ответ</summary>

`image prune` (без `-a`) не тронет: у образа есть тег, он не dangling. `image prune -a` удалит, потому что ни один запущенный контейнер его не использует (и остановленный, если контейнера нет вовсе). `system prune --volumes` без `-a` образ оставит, но удалит неподключённые тома. Первая по риску безопаснее всех, третья опаснее.

</details>

**Шаги**

1. Посмотри, что занимает место, подробно:

```bash
docker system df
docker system df -v | head -30
```

2. Создай мусор: пересобери образ с тем же тегом, старый станет `<none>`:

```bash
cd ~/notes
echo "# правка" >> Dockerfile
docker build -t notes:0.4.0 .
sed -i '$ d' Dockerfile          # убрать добавленную строку (на macOS: sed -i '')
docker images --filter dangling=true
```

3. Убери только безопасное и сравни размеры:

```bash
docker container prune -f
docker image prune -f
docker builder prune -f
docker system df
```

4. Убедись, что том с данными на месте:

```bash
docker volume ls
```

**Что должно получиться**

```text
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          4         2         610MB     240MB (39%)
Containers      3         2         1.2MB     0B (0%)
Local Volumes   2         2         52MB      0B (0%)
Build Cache     18        0         180MB     180MB
```

Цифры у тебя другие. После шага 3 в `RECLAIMABLE` для образов и кэша остаётся близко к нулю, а `docker volume ls` по-прежнему показывает `notes_pgdata` (имя зависит от имени каталога проекта).

**Объясни себе**

- Почему в колонке «Local Volumes» нельзя ориентироваться на `RECLAIMABLE`?
- Чем `docker system prune -a` хуже последовательности из трёх команд выше?
- Как часто и чем ты бы чистил CI-runner, а как прод?

**Типичные ошибки**

- `Total reclaimed space: 0B`: всё нужное используется или места уже нет. Проверь `docker images -a`.
- `Error response from daemon: conflict: unable to delete <id> (must be forced) - image is being used by stopped container`: остановленный контейнер держит образ. Удали контейнер (`docker rm`), потом образ.
- `no space left on device` во время самой сборки: чисти по ступеням выше, а если пусто, ищи логи (задание 3).

### Задание 4. Шаг проекта: Makefile для Docker

**Цель:** добавить в `~/notes/Makefile` цели для сборки и запуска, чтобы команды из уроков 4.5-4.8 запускались одним словом.

Состояние после урока: `Makefile` с целями `build`, `up`, `down`, `logs`, `ps`, `test`, `clean` (цели `run` и `lint` остаются из 1.6). Целей `infra-*` пока нет. Эталон: [project/notes/Makefile](https://github.com/distinguished-sre/devops/tree/devops/project/notes/Makefile).

**Предскажи:** что сделает `make clean`, если в нём есть `docker compose down` без `-v`, и потеряется ли БД?

<details>
<summary>Ответ</summary>

Контейнеры и сеть удалятся, том `pgdata` останется: без `-v` тома `compose down` не трогает. БД не потеряется. Поэтому в `clean` мы осознанно не пишем `-v`.

</details>

**Шаги**

1. Открой `~/notes/Makefile` и приведи его к такому виду (в рецептах строго TAB, не пробелы, урок 1.6):

```make
# Версия образа: та же, что тег релиза (урок 4.7)
VERSION := 0.4.0
IMAGE   := notes:$(VERSION)

.PHONY: run test lint build up down logs ps clean

# Запуск приложения локально, без контейнера
run:
	python app.py

# Юнит-тесты
test:
	python -m unittest -v

# Проверка стиля (ruff из requirements-dev.txt)
lint:
	ruff check .

# Сборка образа с закреплённым тегом
build:
	docker build -t $(IMAGE) .

# Поднять стек Compose (notes, db, proxy) в фоне
up:
	docker compose up -d

# Остановить стек; тома с данными не трогаем
down:
	docker compose down

# Последние 50 строк логов и дальше в реальном времени
logs:
	docker compose logs --tail=50 -f

# Состояние сервисов и проверок здоровья
ps:
	docker compose ps

# Безопасная уборка: остановленные контейнеры, dangling-образы, кэш сборки; тома не удаляются
clean:
	docker compose down --remove-orphans
	docker container prune -f
	docker image prune -f
	docker builder prune -f
```

2. Проверь:

```bash
make test
make build
make up
make ps
make clean
docker volume ls
```

3. Зафиксируй в git:

```bash
git add Makefile
git commit -m "Makefile: цели docker (build, up, down, logs, ps, clean)"
```

**Что должно получиться**

```text
Ran 9 tests in 0.05s

OK
...
NAME            IMAGE        SERVICE   STATUS                    PORTS
notes-db-1      postgres:18  db        Up 20 seconds (healthy)   5432/tcp
notes-notes-1   notes:0.4.0  notes     Up 15 seconds (healthy)
notes-proxy-1   nginx:1.30   proxy     Up 14 seconds             0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
```

Число тестов у тебя может отличаться. После `make clean` том `pgdata` присутствует в `docker volume ls`.

**Объясни себе**

- Почему `clean` не содержит `docker system prune -a --volumes`?
- Зачем `.PHONY`? Что случится, если в каталоге появится файл `build`?
- Почему `VERSION` вынесена в переменную, а не вписана в каждую цель?

**Типичные ошибки**

- `Makefile:12: *** missing separator.  Stop.`: в рецепте пробелы вместо TAB. Замени отступ на TAB.
- `make: *** No rule to make target 'clean'.  Stop.`: цель не добавлена или опечатка в имени.
- `docker: unknown command: docker compose`: не установлен плагин Compose v2 (урок 4.1).
- `make: 'build' is up to date.`: нет `.PHONY` и есть файл `build`.

## Сломай и почини

Запусти скрипт и не читай его (это твоя тренировка диагностики):

```bash
bash break/4.9/break.sh random
```

Если скрипта нет в твоём репозитории, возьми его из [эталона курса](https://github.com/distinguished-sre/devops/tree/devops/project/notes/break/4.9) и не открывай. Номера сценариев 1, 2, 3 можно указать вместо `random`.

### Симптом

Один из трёх: (1) хост почти без места, сервисы на нём падают, а вроде «ничего не менялось»; (2) `docker build` или `docker pull` заканчивается `no space left on device`; (3) `notes` постоянно перезапускается, приложение отвечает урывками, а `docker logs` чист.

### Гипотезы

- Диск забит логами контейнера без ротации.
- Диск забит старыми образами, кэшем сборки, остановленными контейнерами.
- Контейнер убивается по памяти (OOM-kill) и его перезапускает политика `restart`.

### Проверки

По ступеням лестницы из теории. Выполни те, что подходят к твоему симптому:

```bash
df -h /var/lib/docker
df -i /var/lib/docker
docker system df
sudo du -h /var/lib/docker/containers/*/*-json.log | sort -h | tail -3
docker ps -a --format 'table {% raw %}{{.Names}}\t{{.Status}}{% endraw %}'
docker inspect -f '{% raw %}{{.Name}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} mem={{.HostConfig.Memory}}{% endraw %}' $(docker ps -aq)
```

### Исправление

<details>
<summary>Разбор трёх сценариев</summary>

**1. Диск 100% из-за логов.** `df` показывает заполненный раздел, `docker system df` мало, а `du` по `*-json.log` выдаёт один файл на гигабайты. Починка: пересоздать контейнер с `--log-opt max-size=10m --log-opt max-file=3` (в Compose ключ `logging: driver: json-file, options: max-size, max-file`), либо обнулить файл `sudo truncate -s 0 <LogPath>` как срочную меру. Постоянно: `log-opts` в `/etc/docker/daemon.json`. Ещё стоит найти, почему контейнер пишет так много (цикл ошибок), иначе ротация только скроет проблему.

**2. `no space left on device` из-за образов.** `docker system df` показывает большой `RECLAIMABLE` у Images и Build Cache. Починка: `docker container prune -f`, `docker image prune -f`, `docker builder prune -f`, затем при необходимости `docker image prune -a` (понимая, что образы придётся скачать заново). Тома не трогать. Профилактика: чистка по расписанию, не хранить сотни тегов в CI.

**3. OOM-killed.** `inspect` даёт `oom=true`, растёт `RestartCount`, в `docker logs` пусто. Причина: `/leak` (или реальная утечка) выше лимита `mem_limit`. Починка: найти источник роста памяти в приложении; если лимит просто мал, поднять его осознанно, ориентируясь на `docker stats`. Не лечить отключением лимита.

Общий вывод: сначала измеряй (`df`, `system df`, `inspect`), потом удаляй.

</details>

## Вопросы с собеседований

### 1. [junior] Контейнер в статусе Exited. С чего начнёшь?

`docker ps -a`, смотрю код выхода. Потом `docker logs --tail 100`, потом `docker inspect` (OOMKilled, команда, монтирования). Если логов нет, запускаю образ с `--entrypoint sh` и повторяю команду руками.

**Что хотят услышать:** порядок «код, логи, inspect, exec», знание кодов 1, 127, 137, 143.

**Красный флаг:** «перезапущу и посмотрю, поднимется ли».

### 2. [junior] Что значит код выхода 137 и чем он отличается от 143?

137 это 128 плюс 9, SIGKILL. 143 это 128 плюс 15, SIGTERM. 143 штатная остановка, 137 либо OOM, либо `docker stop` добил по таймауту, либо `kill -9`. Различаю по `State.OOMKilled` в `inspect`.

**Что хотят услышать:** формула 128+сигнал, проверка OOMKilled, связь с обработкой SIGTERM.

**Красный флаг:** «137 это всегда нехватка памяти».

### 3. [junior] Диск на Docker-хосте заполнен. Что смотришь и что можно чистить без риска?

`df -h`, `docker system df`, размер логов контейнеров. Безопасно: `container prune`, `image prune`, `builder prune`. Тома и `-a --volumes` не трогаю без проверки, чьи это данные.

**Что хотят услышать:** измерять до удаления, уровни риска, тома с данными.

**Красный флаг:** `docker system prune -a --volumes` «на всякий случай».

### 4. [middle] Прод отвечает 502, за nginx стоит контейнер приложения. Твои действия?

Смотрю `docker ps`: жив ли контейнер и healthy ли. Если перезапускается, читаю `logs` и `inspect` (OOM, RestartCount). Проверяю с nginx-контейнера, что имя `notes:8080` резолвится и порт отвечает. Проверяю, не поменялся ли IP контейнера при пересоздании (кэш nginx, урок 4.6). Затем ищу, что менялось в последний релиз.

**Что хотят услышать:** цепочка клиент, nginx, upstream; логи обоих; проверка DNS и порта из соседнего контейнера; откат как быстрая мера.

**Красный флаг:** сразу править конфиг nginx, не посмотрев состояние приложения.

### 5. [middle] `df` показывает диск 100%, а `du` по `/var/lib/docker` даёт заметно меньше. Причины?

Удалённые, но открытые процессом файлы (`lsof +L1`), исчерпанные inodes (`df -i`), резерв ФС root, другой раздел (логи или данные на отдельном диске), overlay-слои, которые `du` считает иначе. Начинаю с `df -i` и `lsof +L1`, потом с `docker system df`.

**Что хотят услышать:** inodes, deleted-but-open, отличие `df` от `du` (урок 1.5).

**Красный флаг:** «`du` врёт, перезагружу сервер».

### 6. [middle] Контейнер периодически перезапускается, `docker logs` чист. Что это может быть?

OOM-kill (ядро убивает мгновенно, приложение ничего не пишет). Смотрю `RestartCount` и `OOMKilled` в `inspect`, `docker stats` для динамики памяти, `dmesg | grep -i oom` на хосте. Дальше либо утечка, либо мал лимит.

**Что хотят услышать:** OOMKilled, `dmesg`, отличие лимита cgroup от свободной памяти хоста, `restart`-политика маскирует проблему.

**Красный флаг:** «увеличу лимит до 8 ГБ и всё».

### 7. [junior] Как понять, что приложение в контейнере пишет логи не туда?

Если `docker logs` пуст, а внутри есть файл лога (`docker exec ... ls /var/log`), приложение пишет в файл, а не в stdout. Для контейнеров правильно писать в stdout и stderr, а сборкой и хранением логов занимается платформа.

**Что хотят услышать:** stdout/stderr как контракт контейнера, связь с драйвером логов.

**Красный флаг:** «настрою logrotate внутри контейнера».

### 8. [middle] Сборка образа падает с `no space left on device`. Что делаешь?

Смотрю `df -h` и `docker system df`. Чищу кэш сборки и dangling-образы (`builder prune`, `image prune`). Ищу логи-гиганты. Если CI-runner, настраиваю чистку по расписанию и лимит размера кэша.

**Что хотят услышать:** уровни чистки, логи как частый виновник, профилактика, а не разовая уборка.

**Красный флаг:** удалить `/var/lib/docker` руками.

### 9. [middle] После `docker compose down` и очистки пропала база. Что произошло и как избежать?

Том `pgdata` удалили: `compose down -v` или `system prune --volumes` при остановленном стеке (неподключённый том считается неиспользуемым). Избегаю: не использую `-v` и `--volumes` на живых данных, делаю резервные копии БД (`pg_dump`), тома с важными данными помечаю и проверяю перед чисткой.

**Что хотят услышать:** правило тома, бэкап отдельно от тома, осторожность с `prune`.

**Красный флаг:** «том это тоже кэш, его можно чистить».

### 10. [middle] Деплой новой версии: `docker stop` каждый раз висит 10 секунд, потом код 137. Почему?

Приложение не получает SIGTERM: команда в shell-форме (`CMD python app.py`), и сигнал достаётся оболочке, а не процессу, либо процесс его игнорирует. Через таймаут Docker шлёт SIGKILL, отсюда 137 и обрыв запросов. Чиню: exec-форма `CMD ["python","app.py"]`, обработчик SIGTERM, при необходимости `--init`.

**Что хотят услышать:** PID 1 и сигналы (урок 1.4), exec-форма против shell-формы, graceful shutdown.

**Красный флаг:** «увеличу `stop_grace_period` и забуду».

## Проверено на версиях

- Ubuntu: 26.04 LTS и 24.04 LTS
- Docker Engine и Docker Compose: версия не закреплена, проверь актуальную версию на странице проекта
- Python: 3.13 (образ `python:3.13-slim`)
- PostgreSQL: 18 (`postgres:18`)
- nginx: 1.30 (`nginx:1.30`)
- Alpine для отладочных контейнеров: 3.22 (`alpine:3.22`)
- GNU Make: версия из apt Ubuntu
- Образ «Заметок»: `notes:0.4.0`

## Итог урока: ты умеешь

- [ ] умею по `docker ps -a` и коду выхода (1, 127, 137, 143) определить класс проблемы
- [ ] умею отличить OOM-kill от других причин 137 через `docker inspect`
- [ ] умею достать из `inspect` нужные поля шаблоном `--format`
- [ ] умею зайти в контейнер через `exec` или отладочный контейнер в его сети
- [ ] умею найти лог-файл контейнера и включить ротацию `max-size` и `max-file`
- [ ] умею читать `docker system df` и чистить диск по уровням риска, не задев тома
- [ ] умею собрать `Makefile` с целями `build`, `up`, `down`, `logs`, `ps`, `test`, `clean`

**Дальше:** [Тема 5: Kubernetes и Helm](../05-kubernetes/index.md)
