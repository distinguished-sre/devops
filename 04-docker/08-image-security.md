---
layout: lesson
title: "Безопасность образов: Trivy, Hadolint, SBOM"
topic: 4
lesson: "4.8"
time: "2 ч"
---

## Зачем это нужно

Образ - это чужой код: база (`python:3.13-slim`), системные пакеты, зависимости из `pip` и твой `app.py`. В любом слое может сидеть известная уязвимость (CVE), а контейнер, запущенный с лишними правами, превращает маленькую дыру в приложении в захват хоста. На работе это стандартный «шлюз» перед продом: образ с CRITICAL не выкатывают, а безопасность проверяет не человек, а CI.
Ты научишься искать уязвимости и ошибки в Dockerfile автоматически, получать список состава образа (SBOM) и запускать контейнер с минимумом прав.

Шаг проекта: `image.yml` получает шаги `hadolint`, `trivy image` и SBOM, в репозитории появляется `.hadolint.yaml`; образ `notes:0.4.0` проходит проверки.

## Что нужно знать

- [Урок 1.3: права и владельцы](../01-linux/03-users-permissions.md) - uid, root и почему процессу не нужны лишние права.
- [Урок 1.4: процессы и сигналы](../01-linux/04-processes-signals.md) - контейнер это процесс, а capabilities это права процесса.
- [Урок 3.4: качество и безопасность в CI](../03-git-ci/04-quality-security-ci.md) - `trivy fs`, `permissions:` и идея shift-left.
- [Урок 4.2: Dockerfile](02-dockerfile.md) - слои, `USER 10001:10001`, `HEALTHCHECK`.
- [Урок 4.7: multi-stage, теги и ghcr.io](07-images-registry.md) - образ `notes:0.4.0` и `image.yml`, который мы сейчас расширяем.

## Теория

### Откуда берутся уязвимости в образе

CVE (Common Vulnerabilities and Exposures) - публичный номер известной уязвимости, например `CVE-2025-XXXXX`. У каждой есть оценка тяжести CVSS и уровень: LOW, MEDIUM, HIGH, CRITICAL. Образ состоит из слоёв, и уязвимости попадают из трёх мест:

1. **Базовый образ.** `python:3.13-slim` это Debian с пакетами (`libc`, `openssl`, `zlib`). Больше всего находок обычно здесь, и исправляет их не ты, а мейнтейнеры Debian. Твоя работа: пересобрать образ на свежей базе.
2. **Зависимости приложения.** Пакеты из `requirements.txt` (например `psycopg`).
3. **Твой код и конфиги.** Секреты в слоях, root, лишние порты.

Ключевое свойство: образ иммутабелен (неизменяем). Уязвимость, найденная через месяц после сборки, остаётся в образе, хотя ты ничего не менял. Поэтому сканируют не только при сборке, но и регулярно уже собранные образы.

Важно различать «есть CVE» и «есть проблема». Часть находок не эксплуатируется: библиотека есть в образе, но приложение её не вызывает. Поле `Status: fixed` значит, что исправленная версия пакета уже существует и достаточно пересобрать. `will_not_fix` или `affected` без фикса: исправления пока нет.

> **Проверь понимание:** ты собрал образ месяц назад, код не менялся, а сегодняшний скан показал новый CRITICAL. Как это возможно и что делать?

<details markdown="1">
<summary>Ответ</summary>

Кода не менялось, но выросла база знаний об уязвимостях: CVE опубликовали уже после сборки. Образ иммутабелен, поэтому находка живёт в старых слоях. Действие: обновить базу образа (пересобрать `docker build --pull` на свежем `python:3.13-slim`), прогнать скан снова. Если исправления в базе ещё нет, оценить эксплуатируемость и записать исключение с обоснованием и сроком.

</details>

### Trivy: сканер образов

Trivy (проект Aqua Security) сканирует образ, файловую систему, Dockerfile и манифесты. Для образа он делает три вещи: находит ОС и пакеты, сверяет их с базой уязвимостей (скачивается при первом запуске и кэшируется), печатает таблицу. Курс использует Trivy v0.74.0.

Главные флаги:

- `--severity HIGH,CRITICAL` - показать только серьёзное.
- `--ignore-unfixed` - скрыть находки, для которых нет исправленной версии (по ним ты ничего не сделаешь).
- `--exit-code 1` - вернуть код 1, если что-то найдено. Так скан превращается в «шлюз» CI: без этого флага Trivy всегда выходит с 0.
- `--format table|json|cyclonedx|spdx-json` - формат вывода.
- `trivy config` - проверка Dockerfile и манифестов на неправильную конфигурацию (например, запуск от root). В уроке 3.4 ты использовал `trivy fs` по репозиторию; `trivy image` смотрит уже собранный образ.

Ставить Trivy на хост не нужно: запускаем официальный образ `aquasec/trivy:0.74.0`. Ему нужен доступ к образам Docker (сокет) и каталог под кэш базы.

> **Проверь понимание:** пайплайн зелёный, хотя в логе Trivy видна таблица с CRITICAL. Какая ошибка в настройке?

<details markdown="1">
<summary>Ответ</summary>

Не указан `--exit-code 1`: по умолчанию Trivy печатает находки, но завершается с кодом 0, и CI считает шаг успешным. Нужно `--exit-code 1 --severity HIGH,CRITICAL`, а шум сокращать через `--ignore-unfixed`.

</details>

### Hadolint: линтер Dockerfile

Hadolint (Haskell Dockerfile Linter) разбирает Dockerfile и проверяет его по правилам вида `DL3008`, а встроенный ShellCheck проверяет команды в `RUN` (правила `SC2086`). Он ловит то, что Trivy по образу не увидит: `apt-get install` без закрепления версий, `ADD` вместо `COPY`, отсутствие `--no-cache-dir` у `pip`, забытый `USER`. Курс использует Hadolint v2.15.1, запуск через образ `hadolint/hadolint:v2.15.1`.

Правила иногда приходится отключать осознанно. Делается это в файле `.hadolint.yaml` с комментарием «почему», а не молча в командной строке: через полгода никто не вспомнит причину.

Разделение труда: Hadolint проверяет **как написан** Dockerfile (до сборки, за секунды), Trivy image проверяет **что оказалось** в образе (после сборки), `trivy config` пересекается с Hadolint по конфигурации, но смотрит и на Compose, Kubernetes и Terraform.

> **Проверь понимание:** зачем и Hadolint, и Trivy, если оба «что-то сканируют»?

<details markdown="1">
<summary>Ответ</summary>

Hadolint читает исходник (Dockerfile) и находит плохие практики до сборки. Trivy читает результат (слои образа) и находит уязвимые пакеты, о существовании которых Dockerfile не говорит. Уязвимость в `libc` не видна в Dockerfile, а `USER root` не видна в списке пакетов.

</details>

### SBOM: опись образа

SBOM (Software Bill of Materials) - машиночитаемый список всего, что находится в образе: пакеты ОС, библиотеки Python, их версии и лицензии. Формат (format) один из двух стандартов: CycloneDX и SPDX. Зачем он нужен:

- Когда выходит громкая CVE (вспомни историю с Log4Shell), по SBOM за минуту видно, в каких образах сидит нужный пакет, без повторной сборки и скана.
- Клиенты и аудиторы требуют опись состава поставки.
- Скан можно делать по SBOM, а не по образу: `trivy sbom sbom.cdx.json`.

SBOM хранят как артефакт релиза рядом с образом. Подпись образа (cosign) и provenance (происхождение сборки) это следующий шаг цепочки поставки (supply chain); подробнее в теме 9.

> **Проверь понимание:** в понедельник объявили CVE в `zlib`. Как за 5 минут найти, какие из 40 ваших образов затронуты?

<details markdown="1">
<summary>Ответ</summary>

Если для каждого релиза сохранён SBOM, ищем `zlib` по всем описям (`grep` или `jq`), а не пересобираем и сканируем 40 образов. Затем `trivy sbom` по найденным файлам подтверждает версию, и только для затронутых запускается пересборка.

</details>

### Минимум прав при запуске

Даже безопасный образ можно запустить небезопасно. Защиты ставятся на этапе `docker run`:

- **Не root.** В образе `USER 10001:10001` уже есть (урок 4.2). Проверка: `docker run --rm notes:0.4.0 id`.
- **`--read-only`** - корневая файловая система контейнера только для чтения. Записать что-то в `/app` или подсадить вредонос нельзя. Для места, куда приложению нужно писать, монтируют том (`/data`) или `--tmpfs /tmp`.
- **`--cap-drop ALL`** - убрать все Linux capabilities (права root, разбитые на части: `NET_BIND_SERVICE`, `CHOWN`, `SYS_ADMIN`...). Приложению на порту 8080 не нужна ни одна. Нужную можно вернуть точечно: `--cap-add NET_BIND_SERVICE`.
- **`--security-opt no-new-privileges`** - процесс не может получить больше прав через setuid-бинарники.
- **Не `--privileged`**, не пробрасывать `/var/run/docker.sock`: это фактически root на хосте (урок 4.1).

> **Проверь понимание:** приложение запущено с `--read-only` и падает с `OSError: [Errno 30] Read-only file system`. Что делать: снять `--read-only`?

<details markdown="1">
<summary>Ответ</summary>

Нет. Найти, куда приложение пишет (`docker logs`, путь в ошибке), и дать только этот путь: том для данных или `--tmpfs` для временных файлов. Защита остаётся, добавляется узкое исключение.

</details>

### Podman: то же самое без демона

Podman (от Red Hat) запускает контейнеры без постоянного демона и по умолчанию без root (rootless): контейнер работает от твоего обычного пользователя, а root внутри контейнера отображается на непривилегированный uid хоста. CLI почти совпадает с Docker: `podman run`, `podman build`, `podman ps`. Образы и Dockerfile те же, поэтому всё из этого урока (Trivy, Hadolint, SBOM, флаги прав) работает и там. В RHEL-семействе Podman стоит из коробки, поэтому на собеседованиях спрашивают о нём. Отдельного урока нет: в проекте «Заметки» его файлов не будет.

## Практика

Рабочий каталог для экспериментов: `~/lab48`, проект `~/notes` трогаем только в последнем задании. Нужен собранный образ `notes:0.4.0` из урока 4.7. Если его нет: `cd ~/notes && docker build -t notes:0.4.0 .`.

### Задание 1. Читаем отчёт Trivy

**Цель:** просканировать образ, отличить критичное от шума и найти, что можно исправить.

**Предскажи:** (1) у `python:3.9.5-slim` (старый образ трёхлетней давности) будет больше или меньше находок HIGH и CRITICAL, чем у `notes:0.4.0`? (2) какой код выхода вернёт Trivy без `--exit-code`?

<details markdown="1">
<summary>Ответ</summary>

(1) Заметно больше: база устарела, а после неё вышли сотни исправлений. (2) 0: без `--exit-code` Trivy не считает находки ошибкой.

</details>

**Шаги:**

1. Подготовь каталог и кэш базы уязвимостей (чтобы не качать её при каждом запуске):

```bash
mkdir -p ~/lab48 ~/.cache/trivy
cd ~/lab48
```

2. Просканируй свой образ. Первый запуск скачает базу (около минуты):

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.cache/trivy:/root/.cache/trivy \
  aquasec/trivy:0.74.0 image --severity HIGH,CRITICAL --ignore-unfixed notes:0.4.0
```

3. Сравни со старым образом и проверь код выхода шлюза (`--exit-code 1`):

```bash
docker pull python:3.9.5-slim
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.cache/trivy:/root/.cache/trivy \
  aquasec/trivy:0.74.0 image --severity CRITICAL --exit-code 1 --ignore-unfixed python:3.9.5-slim
echo "код выхода: $?"
```

**Что должно получиться:** у свежего образа таблица пустая или короткая, у старого длинная; числа у тебя будут другими, так как база обновляется ежедневно. Формат отчёта:

```text
Report Summary

┌──────────────────────────────┬────────┬─────────────────┐
│            Target            │  Type  │ Vulnerabilities │
├──────────────────────────────┼────────┼─────────────────┤
│ python:3.9.5-slim (debian 11)│ debian │       12        │
└──────────────────────────────┴────────┴─────────────────┘

Library │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version
libssl3 │ CVE-XXXX-XXXXX │ CRITICAL │ fixed  │ 1.1.1k-1          │ 1.1.1n-0+deb11u1
```

Последняя строка вывода:

```text
код выхода: 1
```

**Объясни себе:** чем `Installed Version` отличается от `Fixed Version` и что из этого делать? Почему `--ignore-unfixed` уместен в шлюзе CI? Почему скан образа `notes:0.4.0` через месяц может дать другой результат?

**Типичные ошибки:**

- `permission denied while trying to connect to the Docker daemon socket`: пользователь не в группе `docker` (урок 4.1): добавь себя в группу и перезайди.
- `FATAL Fatal error init error: DB error: failed to download vulnerability DB`: нет доступа к интернету или скачивание прервано: повтори, проверь прокси и DNS.
- `unable to find the specified image "notes:0.4.0" in ["docker" "containerd" "podman" "remote"]`: образа нет локально: собери его (`docker build -t notes:0.4.0 ~/notes`).

### Задание 2. Hadolint: находим ошибки в Dockerfile

**Цель:** прогнать линтер по плохому Dockerfile, исправить замечания и отключить одно правило осознанно.

**Предскажи:** какие три плохих практики ты бы нашёл в этом Dockerfile за 30 секунд? Сколько из них увидит Trivy по собранному образу?

**Шаги:**

1. Создай намеренно плохой файл:

```bash
cd ~/lab48
cat > Dockerfile.bad <<'EOF'
FROM python:3.13
RUN apt-get update && apt-get install -y curl
RUN pip install flask
ADD app.py /app/app.py
WORKDIR /app
CMD python app.py
EOF
```

2. Запусти линтер:

```bash
docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile.bad
```

3. Исправь: закрепи тег базы, добавь `--no-install-recommends`, очисти кэш apt, `--no-cache-dir`, замени `ADD` на `COPY`, добавь `USER`, CMD в exec-форму. Получится:

```dockerfile
FROM python:3.13-slim
# Версию curl закреплять не будем: в Debian она меняется с каждым обновлением (DL3008 отключено в .hadolint.yaml)
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir flask==3.1.0
WORKDIR /app
COPY app.py /app/app.py
USER 10001:10001
CMD ["python", "app.py"]
```

Сохрани его как `Dockerfile.good` (например, через `cat > Dockerfile.good <<'EOF'`) и создай `.hadolint.yaml` с осознанным исключением:

```yaml
# Правила, отключённые осознанно. Каждое с причиной.
ignored:
  # DL3008: закрепление версий apt-пакетов. В python:3.13-slim (Debian) старые версии
  # быстро исчезают из репозитория, сборка ломалась бы без изменений в коде.
  # Вместо этого базу обновляет Dependabot, а состав проверяет Trivy.
  - DL3008
```

4. Проверь исправленный файл (конфиг подхватывается из текущего каталога, поэтому монтируем его):

```bash
docker run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml" \
  hadolint/hadolint:v2.15.1 < Dockerfile.good
echo "код выхода: $?"
```

**Что должно получиться:** на плохом файле несколько строк вида `DL3006`, `DL3008`, `DL3013`, `DL3042`, `DL3020`, `DL3025`; на исправленном пустой вывод и код 0.

```text
-:1 DL3006 warning: Always tag the version of an image explicitly
-:2 DL3008 warning: Pin versions in apt get install. Instead of `apt-get install <package>` use `apt-get install <package>=<version>`
-:2 DL3015 info: Avoid additional packages by specifying `--no-install-recommends`
-:3 DL3013 warning: Pin versions in pip. Instead of `pip install <package>` use `pip install <package>==<version>`
-:3 DL3042 warning: Avoid use of cache directory with pip. Use `pip install --no-cache-dir <package>`
-:4 DL3020 error: Use COPY instead of ADD for files and folders
-:6 DL3025 warning: Use arguments JSON notation for CMD and ENTRYPOINT arguments
```

```text
код выхода: 0
```

Точный набор правил и формулировки зависят от версии Hadolint, ориентируйся на код правила и смысл.

**Объясни себе:** почему `rm -rf /var/lib/apt/lists/*` стоит в том же `RUN`, что и `install`? (подсказка: слои из урока 4.2). Чем плох `CMD python app.py` (shell-форма)? (подсказка: PID 1 и сигналы, урок 1.4). Почему исключение лежит в файле с комментарием, а не в аргументе командной строки?

**Типичные ошибки:**

- `hadolint: error while loading shared libraries`: запущен бинарник не под ту платформу: используй образ, как в задании.
- `-:1 DL3006 warning: Always tag the version of an image explicitly`: у `FROM` нет тега: укажи `python:3.13-slim`.
- `.hadolint.yaml` игнорируется: файл лежит не там, где его ищет Hadolint: смонтируй в `/.config/hadolint.yaml` или передай `-c .hadolint.yaml`.

### Задание 3. Запуск с минимумом прав

**Цель:** запустить `notes:0.4.0` под `--read-only`, `--cap-drop ALL` и `no-new-privileges` и убедиться, что приложение работает, а запись вне разрешённых мест блокируется.

**Предскажи:** (1) от какого пользователя работает процесс в контейнере? (2) запись в `/app/x` в режиме `--read-only` пройдёт? (3) а в `/tmp` без `--tmpfs`?

<details markdown="1">
<summary>Ответ</summary>

(1) От uid 10001, как задано `USER` в Dockerfile. (2) Нет: корневая ФС только для чтения. (3) Тоже нет, `/tmp` часть корневой ФС; нужен `--tmpfs /tmp`.

</details>

**Шаги:**

1. Проверь пользователя в образе:

```bash
docker run --rm notes:0.4.0 id
```

2. Запусти жёстко ограниченный контейнер. Данные пишем в том `notes-data` (урок 4.3), временные файлы в `tmpfs`:

```bash
docker run -d --name notes-hard \
  --read-only \
  --tmpfs /tmp \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  -v notes-data:/data \
  -p 127.0.0.1:8080:8080 \
  notes:0.4.0
sleep 3
curl -fsS http://127.0.0.1:8080/healthz
```

3. Попробуй записать в запрещённое и в разрешённое место:

```bash
docker exec notes-hard python -c "open('/app/x','w')"
docker exec notes-hard python -c "open('/tmp/x','w'); print('tmp ok')"
```

4. Посмотри, какие права остались у процесса, и убери контейнер:

```bash
docker exec notes-hard grep CapEff /proc/1/status
docker rm -f notes-hard
```

Если приложение в твоей версии `app.py` при старте требует PostgreSQL, добавь в `docker run` те же переменные окружения, что в `compose.yml` (урок 4.5), или подними стек через Compose: смысл задания не меняется.

**Что должно получиться:**

```text
uid=10001 gid=10001 groups=10001
```

```text
ok
```

```text
Traceback (most recent call last):
  File "<string>", line 1, in <module>
OSError: [Errno 30] Read-only file system: '/app/x'
tmp ok
CapEff:	0000000000000000
```

**Объясни себе:** почему `CapEff` нулевой и приложение всё равно слушает порт 8080? Что изменилось бы, если бы приложение слушало порт 80? Зачем нужен `no-new-privileges`, если процесс и так не root?

**Типичные ошибки:**

- `OSError: [Errno 30] Read-only file system: '/data/notes.txt'`: том не смонтирован и `/data` часть корневой ФС: добавь `-v notes-data:/data`.
- `PermissionError: [Errno 13] Permission denied: '/data/notes.txt'`: том создан от root: см. урок 4.3, владелец каталога должен быть 10001.
- `Error response from daemon: Conflict. The container name "/notes-hard" is already in use`: остался старый контейнер: `docker rm -f notes-hard`.
- `OSError: [Errno 98] Address already in use` / `Bind for 127.0.0.1:8080 failed: port is already allocated`: порт занят Compose-стеком из 4.6: `docker compose down`.

### Задание 4. Шаг проекта: проверки образа в CI

**Цель:** добавить в `image.yml` проверки Hadolint, Trivy и SBOM так, чтобы образ с CRITICAL или замечаниями Dockerfile не попадал в ghcr.io.

**Предскажи:** в каком порядке должны идти шаги: сборка, скан, push? Что произойдёт, если сначала сделать push?

<details markdown="1">
<summary>Ответ</summary>

Hadolint (до сборки, дёшево), сборка в локальный Docker без push, скан, и только затем push. Если push первым, уязвимый образ уже опубликован, и красный CI ничего не отменит: его успеют скачать.

</details>

**Шаги:**

1. В `~/notes` создай `.hadolint.yaml` (по образцу из задания 2, только правила, которые реально нужны проекту):

```yaml
# Правила Hadolint, отключённые осознанно (причина в комментарии к каждому).
ignored:
  # DL3008: закрепление версий apt-пакетов. В базовом python:3.13-slim (Debian)
  # старые версии пакетов удаляются из репозитория, и сборка ломалась бы без
  # изменений в коде. Базу обновляет Dependabot, состав проверяет Trivy в CI.
  - DL3008
```

2. Замени `.github/workflows/image.yml` (версии действий из курса; шаги логина и сборки остались из урока 4.7, добавлены проверки). Файл целиком:

{% raw %}
```yaml
name: image

on:
  push:
    tags: ['v*']

permissions:
  contents: read
  packages: write

env:
  IMAGE: ghcr.io/${{ github.repository_owner }}/notes

jobs:
  image:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7.0.1

      # Версия образа = тег git без буквы v: v0.4.0 -> 0.4.0
      - name: Версия из тега
        run: echo "VERSION=${GITHUB_REF_NAME#v}" >> "$GITHUB_ENV"

      # 1. Линтер Dockerfile: падает при замечаниях, до сборки
      - name: Hadolint
        run: docker run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml" hadolint/hadolint:v2.15.1 < Dockerfile

      - uses: docker/setup-buildx-action@v4.4.1

      # 2. Сборка в локальный Docker (push: false), чтобы просканировать до публикации
      - name: Сборка (без push)
        uses: docker/build-push-action@v7.4.0
        with:
          context: .
          load: true
          push: false
          tags: ${{ env.IMAGE }}:${{ env.VERSION }}

      # 3. Шлюз: HIGH и CRITICAL с доступным исправлением останавливают релиз
      - name: Trivy: уязвимости
        run: |
          docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            aquasec/trivy:0.74.0 image \
            --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
            "$IMAGE:$VERSION"

      # 4. Опись состава образа как артефакт релиза
      - name: SBOM
        run: |
          docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            aquasec/trivy:0.74.0 image --format cyclonedx \
            "$IMAGE:$VERSION" > sbom.cdx.json

      - uses: actions/upload-artifact@v5.0.0
        with:
          name: sbom-${{ env.VERSION }}
          path: sbom.cdx.json

      # 5. Публикация только после зелёных проверок
      - uses: docker/login-action@v4.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Push
        run: docker push "$IMAGE:$VERSION"
```
{% endraw %}

3. Проверь локально те же шаги, что выполнит CI, до пуша тега:

```bash
cd ~/notes
docker run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml" hadolint/hadolint:v2.15.1 < Dockerfile
echo "hadolint: $?"
```

4. Закоммить через ветку и Pull Request (процесс из урока 3.2):

```bash
git checkout -b ci/image-scan
git add .hadolint.yaml .github/workflows/image.yml
git commit -m "ci: hadolint, trivy image и SBOM в image.yml"
git push -u origin ci/image-scan
```

Слей Pull Request, затем выпусти проверочный релиз по правилам урока 3.5 и следи за вкладкой Actions. Если тег `v0.4.0` уже опубликован в ghcr.io, образ иммутабелен: используй следующий патч-тег, а не перезаписывай старый.

**Что должно получиться:** локально `hadolint: 0`; в Actions шаги по порядку зелёные, в артефактах запуска есть `sbom-0.4.0`, образ появился в ghcr.io только после зелёного Trivy.

```text
hadolint: 0
```

```text
✓ Hadolint
✓ Сборка (без push)
✓ Trivy: уязвимости
✓ SBOM
✓ Push
```

**Объясни себе:** почему в `permissions` остались только `contents: read` и `packages: write`? Что теряется, если убрать `--ignore-unfixed`? Чем проверка Trivy в этом workflow отличается от `trivy fs` из урока 3.4?

**Типичные ошибки:**

- `Error: Unable to resolve action docker/build-push-action@v7.4.0`: опечатка в версии действия: сверь с таблицей версий курса.
- `denied: permission_denied: write_package`: нет `packages: write` в `permissions` (см. урок 4.7).
- `exec: "-": executable file not found` или пустой вывод Hadolint: не указан `-i` при передаче Dockerfile через stdin: нужен `docker run --rm -i`.
- `Error: Process completed with exit code 1` на шаге Trivy: это не сбой, а сработавший шлюз: смотри таблицу выше в логе и обновляй базу образа.

## Сломай и почини

Скачай сценарии и запусти один. Скрипт не читай: цель в том, чтобы найти причину по симптомам.

```bash
cd ~/lab48
curl -fsSLO https://raw.githubusercontent.com/distinguished-sre/devops/devops/project/notes/break/4.8/break.sh
bash break.sh random
```

### Симптом

Скрипт печатает, какой контейнер или образ подготовлен. Возможные симптомы (по одному за запуск): (1) шлюз Trivy красный, в базовом образе CRITICAL; (2) контейнер стартует и падает при первой записи, в логе `Read-only file system`; (3) Hadolint и `trivy config` ругаются на запуск от root.

### Гипотезы

Запиши до проверок, что из следующего может быть причиной:

- уязвим базовый образ, а Dockerfile ни при чём;
- приложение пишет в место, которое закрыто `--read-only`;
- в Dockerfile нет `USER` или он стоит не там;
- ошибка в сети или в образе (отбрасываем: симптом другой).

### Проверки

```bash
# Что показывает скан и какой у уязвимости статус исправления
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v ~/.cache/trivy:/root/.cache/trivy \
  aquasec/trivy:0.74.0 image --severity CRITICAL <образ из вывода скрипта>

# Куда пишет приложение
docker logs <имя контейнера>
# С какими флагами запущен контейнер: read-only и пользователь
docker inspect <имя контейнера> | jq '.[0] | {ro: .HostConfig.ReadonlyRootfs, user: .Config.User}'

# Что скажут линтеры про Dockerfile
docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile
docker run --rm -v "$PWD:/w" aquasec/trivy:0.74.0 config /w
```

### Исправление

<details markdown="1">
<summary>Разбор сценариев</summary>

**1. CRITICAL в базе.** В таблице Trivy колонка `Fixed Version` заполнена: значит исправление есть. Обнови базу: `docker build --pull -t <образ> .` на свежем теге. Если исправления нет (`Status: affected`), оцени, вызывается ли уязвимый код, и внеси исключение в `.trivyignore` с CVE, причиной и датой пересмотра. Профилактика: Dependabot для Dockerfile и регулярный скан по расписанию.

**2. `Read-only file system`.** В `docker logs` виден путь, куда пишет приложение. Не снимай `--read-only`: добавь том для этого пути (`-v notes-data:/data`) или `--tmpfs /tmp` для временных файлов. Проверка: `docker exec <имя> python -c "open('/tmp/x','w')"`.

**3. Root.** Hadolint не нашёл `USER`, `trivy config` показал `DS002 Image user should not be 'root'`. Добавь в конец Dockerfile `USER 10001:10001`, убедись, что каталог данных принадлежит этому uid (урок 4.2), пересобери. Проверка: `docker run --rm <образ> id` даёт `uid=10001`.

</details>

## Вопросы с собеседований

### 1. [junior] Trivy нашёл CRITICAL в базовом образе. Что делаешь?

Сначала смотрю, есть ли исправленная версия (`Fixed Version`). Если есть, пересобираю образ на обновлённой базе (`docker build --pull`) и сканирую снова. Если исправления нет, оцениваю, достижим ли уязвимый код из нашего приложения, и решаю: сменить базу, смягчить (`--read-only`, сеть) или принять риск с записью и сроком пересмотра.

**Что хотят услышать:** проверка Fixed Version, пересборка на свежей базе, исключение с обоснованием и сроком, а не молчаливое игнорирование.

**Красный флаг:** «добавлю CVE в игнор, чтобы пайплайн позеленел».

### 2. [junior] Что такое SBOM и когда он реально выручает?

Это машиночитаемая опись состава образа: пакеты, версии, лицензии (CycloneDX или SPDX). Выручает, когда выходит новая громкая CVE: по хранимым описям за минуты видно, в каких сервисах уязвимый пакет, без пересборки и скана всего парка.

**Что хотят услышать:** пример с новой CVE, хранение SBOM с релизом, форматы CycloneDX и SPDX, скан по SBOM.

**Красный флаг:** «это то же самое, что Dockerfile».

### 3. [junior] Почему контейнер нельзя запускать от root, если он всё равно изолирован?

Изоляция не абсолютная: ядро общее. Уязвимость в приложении даёт атакующему uid процесса. Root в контейнере плюс ошибка настройки (монтирование сокета Docker, лишние capabilities) заметно ближе к root на хосте. Непривилегированный пользователь делает такую цепочку сложнее.

**Что хотят услышать:** общее ядро, `USER` в Dockerfile, uid не 0, глубокая защита (несколько слоёв).

**Красный флаг:** «контейнер изолирован, значит безопасно».

### 4. [junior] Чем `docker run --read-only` помогает и что ломается первым?

Корневая ФС становится только для чтения: нельзя записать вредоносный файл или изменить код приложения. Ломается всё, что пишет в неожиданные места: `/tmp`, кэши, PID-файлы. Решение: точечно давать `--tmpfs /tmp` и тома для данных.

**Что хотят услышать:** tmpfs и том вместо отключения защиты, диагностика по `Read-only file system` в логе.

**Красный флаг:** «просто не буду её включать».

### 5. [junior] Пайплайн со сканом зелёный, но в логе видны CRITICAL. Как так?

Trivy по умолчанию возвращает код 0. Чтобы шаг падал, нужен `--exit-code 1` вместе с `--severity`. Без него сканер только печатает отчёт и ничего не блокирует.

**Что хотят услышать:** `--exit-code`, фильтр severity, `--ignore-unfixed`, что «сканер запущен» не равно «шлюз работает».

**Красный флаг:** «значит, уязвимости не критичны».

### 6. [middle] Образ месяц назад проходил скан, сегодня красный, код не менялся. Разбери.

Образ иммутабелен, но база CVE обновляется: новые уязвимости публикуют уже после сборки. Смотрю таблицу: есть ли Fixed Version, пересобираю на свежей базе. Чтобы такое не было сюрпризом на релизе, настраиваю плановый скан (cron в CI) уже опубликованных образов и уведомление.

**Что хотят услышать:** обновление базы знаний, плановый скан, автообновление базы Dependabot, отделение «регресс кода» от «новая CVE».

**Красный флаг:** «кто-то поменял образ».

### 7. [middle] Образ прошёл скан, но на проде контейнер захватили. Что в цепочке ты мог пропустить?

Скан ищет известные CVE в пакетах. Он не ловит: 0-day, ошибки логики приложения, секреты в переменных, избыточные права запуска (root, `--privileged`, сокет Docker, лишние capabilities), открытые наружу порты. Проверяю флаги запуска, `docker inspect`, сеть и логи, а не только отчёт сканера.

**Что хотят услышать:** пределы сканера, права запуска, no-new-privileges, cap-drop, read-only, сетевые ограничения.

**Красный флаг:** «сканер сказал, что чисто, значит, дело не в образе».

### 8. [middle] Как убедиться, что в CI не публикуется образ, который не прошёл проверки?

Порядок шагов: сборка в локальный Docker (`load`, без push), скан, и только затем push. Публикация выполняется только после зелёного шага-шлюза. Дополнительно: права `GITHUB_TOKEN` минимальны (`packages: write` только в этом workflow), теги иммутабельны, деплой берёт образ по digest.

**Что хотят услышать:** «сначала скан, потом push», минимальные permissions, digest.

**Красный флаг:** «пушим, а потом сканируем, чтобы быстрее».

### 9. [junior] Чем Podman отличается от Docker и что для тебя изменится при переходе?

Podman не использует постоянный демон и по умолчанию запускает контейнеры без root от обычного пользователя. CLI почти тот же (`podman run`, `podman build`), Dockerfile и образы совместимы, поэтому Trivy, Hadolint и флаги прав работают так же. Отличия ловлю на сетях, портах ниже 1024 и Compose.

**Что хотят услышать:** daemonless, rootless, совместимость образов, знание, что в RHEL-семействе это стандарт.

**Красный флаг:** «это другая технология, всё придётся переучивать».

### 10. [middle] Как не хранить секрет в слоях образа при сборке?

Секрет в `ENV`, `ARG` или `COPY` остаётся в истории слоёв, `docker history` его покажет. Использую `RUN --mount=type=secret` (секрет доступен только на время шага), а в рантайме передаю через переменные окружения или менеджер секретов. Trivy тоже ищет секреты в слоях, но лучше не допускать их появления.

**Что хотят услышать:** `--mount=type=secret`, `docker history`, разница между сборкой и запуском, ротация просочившегося секрета.

**Красный флаг:** «удалю файл следующей командой RUN rm».

## Проверено на версиях

- Trivy: v0.74.0 (образ `aquasec/trivy:0.74.0`)
- Hadolint: v2.15.1 (образ `hadolint/hadolint:v2.15.1`)
- Docker Engine: версия из урока 4.1, на Ubuntu 26.04 LTS и 24.04
- Python: 3.13 (`python:3.13-slim`)
- actions/checkout: v7.0.1
- docker/setup-buildx-action: v4.4.1
- docker/build-push-action: v7.4.0
- docker/login-action: v4.6.0
- actions/upload-artifact: версия не закреплена, проверь актуальную версию на странице проекта
- Podman: версия не закреплена, проверь актуальную версию на странице проекта

## Итог урока: ты умеешь

- [ ] умею просканировать образ Trivy и прочитать таблицу: пакет, серьёзность, исправленная версия
- [ ] умею превратить скан в шлюз CI через `--exit-code 1`, `--severity` и `--ignore-unfixed`
- [ ] умею проверить Dockerfile Hadolint и оформить исключение в `.hadolint.yaml` с причиной
- [ ] умею получить SBOM (CycloneDX) в CI и объяснить, зачем его хранить
- [ ] умею запустить контейнер с `--read-only`, `--tmpfs`, `--cap-drop ALL` и `no-new-privileges`
- [ ] умею расположить шаги в `image.yml` так, чтобы push шёл только после сканирования
- [ ] умею объяснить, чем Podman отличается от Docker (daemonless, rootless)

**Дальше:** [Урок 4.9: отладка контейнеров и уборка диска](09-docker-troubleshooting.md)
