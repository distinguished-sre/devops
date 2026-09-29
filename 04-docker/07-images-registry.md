---
layout: lesson
title: "Образы: multi-stage, теги и реестр ghcr.io"
topic: 4
lesson: "4.7"
time: "2 ч"
---

## Зачем это нужно

Образ, собранный на твоём ноутбуке командой `docker build`, нельзя раздать другим: сервер, Kubernetes и коллеги не видят твой локальный кэш. Нужен реестр (registry), куда образ публикуют один раз, а тянут откуда угодно. На работе почти любой релиз выглядит так: тег в git, CI собирает образ, кладёт в реестр, а деплой берёт образ по тегу.

Второй вопрос: размер и состав. Образ с компилятором, pip-кэшем и заголовочными файлами в разы больше и уязвимее, чем образ с одним рабочим кодом. Это лечит multi-stage сборка.

Шаг проекта: `Dockerfile` «Заметок» становится multi-stage, workflow `image.yml` по тегу `v0.4.0` публикует `ghcr.io/<user>/notes:0.4.0`.

## Что нужно знать

- [Урок 3.3: GitHub Actions и CI](../03-git-ci/03-actions-ci.md) - workflow, `on`, `steps`, `secrets`, `permissions`
- [Урок 3.5: релизный поток](../03-git-ci/05-release-flow.md) - теги `vX.Y.Z` и запуск workflow по тегу
- [Урок 4.2: Dockerfile](02-dockerfile.md) - слои, кэш, `USER 10001`, `HEALTHCHECK`
- [Урок 4.5: Compose и PostgreSQL](05-compose-postgres.md) - приложение v4 ставит `psycopg` из `requirements.txt`
- [Урок 4.6: nginx и TLS в Compose](06-compose-nginx-tls.md) - стек, который мы теперь упаковываем в реестр

## Теория

### Multi-stage: собираем в одном образе, запускаем в другом

Обычный образ несёт всё, что понадобилось при сборке: pip, кэш загрузок, иногда компилятор. Для запуска приложения это балласт и лишняя поверхность атаки. Multi-stage сборка (multi-stage build) делит `Dockerfile` на несколько стадий `FROM`. Каждая стадия начинается с чистого базового образа, а из предыдущей можно забрать только выбранные файлы командой `COPY --from=<стадия>`.

Схема для Python: стадия `builder` создаёт виртуальное окружение (venv) в `/opt/venv` и ставит туда зависимости. Итоговая стадия берёт тот же базовый образ, копирует готовый `/opt/venv` и код. Ни pip-кэша, ни временных файлов сборки в итоговом образе нет. Если зависимость надо компилировать (в нашем `psycopg[binary]` готовое колесо, компиляции нет), компилятор остаётся в `builder` и в релиз не попадает.

Порядок слоёв из урока 4.2 сохраняется: сначала `requirements.txt` и установка, потом код, тогда правка `app.py` не пересобирает зависимости.

> **Проверь понимание:** почему venv из `builder` можно копировать в итоговый образ, а не ставить зависимости заново?

<details markdown="1">
<summary>Ответ</summary>

Venv это обычный каталог с файлами. Пока базовый образ и версия Python те же, каталог работает на новом месте, потому что путь `/opt/venv` совпадает в обеих стадиях (скрипты внутри venv хранят абсолютные пути). Поэтому базовый образ обеих стадий один и тот же, `python:3.13-slim`.

</details>

### Теги и digest: что именно ты запускаешь

Имя образа полностью выглядит так: `ghcr.io/alice/notes:0.4.0`. Части: реестр (`ghcr.io`), владелец и репозиторий (`alice/notes`), тег (tag, `0.4.0`). Тег это подвижная метка: её можно перепривязать к другому образу, если пушишь под тем же тегом. Поэтому `nginx:1.30` сегодня и через полгода могут быть разными образами (пришли патчи).

Неизменяемый идентификатор образа это digest, хеш SHA256 манифеста: `ghcr.io/alice/notes@sha256:...`. Образ по digest гарантированно тот же байт в байт. Практика:

- тег `latest` в курсе не используется никогда: непонятно, что за версия, и откат невозможен;
- тег образа равен версии в git: git-тег `v0.4.0` даёт образ `0.4.0` (без `v`);
- в проде важное фиксируют по digest или считают теги релизов неизменяемыми по договорённости команды (immutable tags).

> **Проверь понимание:** ты запушил `notes:0.4.0`, потом нашёл баг, поправил код и запушил снова `notes:0.4.0`. Что увидит сервер, который уже скачал этот тег вчера?

<details markdown="1">
<summary>Ответ</summary>

Ничего не изменится, пока он не сделает `docker pull` заново: локальный тег указывает на старый образ. Новый `pull` подтянет уже другой образ под тем же именем, и два сервера с одним тегом будут запускать разный код. Отсюда правило: баг чинишь новой версией `0.4.1`, а не перезаписью тега.

</details>

### Реестр ghcr.io и аутентификация

ghcr.io это реестр контейнеров GitHub (GitHub Container Registry). Образы лежат в пакетах (packages) владельца, имя владельца пишется строчными буквами. Для входа используется токен: в CI это встроенный `GITHUB_TOKEN`, локально личный токен (PAT) со scope `write:packages`. Пароль от аккаунта не подходит.

Чтобы `GITHUB_TOKEN` мог писать пакеты, workflow должен запросить право: `permissions: packages: write`. По умолчанию (и после урока 3.4, где мы сузили права) этого права нет, и push кончится `denied`.

Новый пакет создаётся приватным. Чтобы другие (и kind в теме 5) могли тянуть образ без секрета, его один раз делают публичным в настройках пакета: GitHub, профиль, Packages, `notes`, Package settings, Change visibility. Приватный образ и `imagePullSecrets` разберём в теме 5.

> **Проверь понимание:** чем `GITHUB_TOKEN` в workflow лучше личного токена, лежащего в secrets?

<details markdown="1">
<summary>Ответ</summary>

Он создаётся на время одного запуска, живёт короткое время и ограничен правами из `permissions:` и одним репозиторием. Личный токен долгоживущий и обычно шире по правам: утечка опаснее.

</details>

## Практика

### Задание 1. Multi-stage и сравнение размера

**Цель:** переписать `Dockerfile` в multi-stage и увидеть, что образ стал меньше и чище.

**Предскажи:** итоговый образ станет меньше или больше одностадийного? Останется ли в нём `pip` от кэша загрузок (`/root/.cache`)?

<details markdown="1">
<summary>Ответ</summary>

Меньше на десятки мегабайт (нет кэша и временных файлов сборки). Кэша pip в итоговом образе не будет вообще: он остался в стадии `builder`, которую в итог не копируют. Сам `pip` в `python:3.13-slim` есть в базе, он нужен не нам, но и не мешает.

</details>

**Шаги:**

1. Запомни размер текущего образа из урока 4.2 (или пересобери старый `Dockerfile`):

```bash
cd ~/notes
docker build -t notes:single .
docker image ls notes:single --format 'размер: {% raw %}{{.Size}}{% endraw %}'
```

2. Замени `Dockerfile` целиком:

```dockerfile
# Стадия 1: сборка зависимостей в виртуальное окружение
FROM python:3.13-slim AS builder
WORKDIR /build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
# Сначала только зависимости: слой кэшируется, пока requirements.txt не менялся
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Стадия 2: итоговый образ, только venv и код
FROM python:3.13-slim
WORKDIR /app
ENV PATH="/opt/venv/bin:$PATH" \
    HOST=0.0.0.0 PORT=8080 NOTES_DATA=/data/notes.txt
COPY --from=builder /opt/venv /opt/venv
COPY app.py .
RUN mkdir /data && chown 10001:10001 /data
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/healthz')"
CMD ["python", "app.py"]
```

3. Собери, сравни размер и проверь, что кэша pip нет:

```bash
docker build -t notes:multi .
docker image ls notes --format '{% raw %}{{.Tag}}: {{.Size}}{% endraw %}'
docker run --rm --entrypoint sh notes:multi -c 'ls /root/.cache 2>&1; id -u'
```

**Что должно получиться:**

```text
multi: 158MB
single: 171MB
ls: cannot access '/root/.cache': No such file or directory
10001
```

Точные числа зависят от версии зависимостей, важно направление: `multi` меньше.

**Объясни себе:**

- Почему в итоговой стадии снова задан `ENV PATH`, ведь в `builder` он уже есть?
- Что будет с кэшем сборки, если поменять только `app.py`?

**Типичные ошибки:**

- `failed to compute cache key: "/requirements.txt": not found`: в `.dockerignore` попал `requirements.txt` или сборка идёт не из корня проекта: проверь `.dockerignore` и что команда запущена в `~/notes` с контекстом `.`.
- `exec: "python": executable file not found in $PATH`: в итоговой стадии забыт `ENV PATH="/opt/venv/bin:$PATH"`: добавь.
- `ModuleNotFoundError: No module named 'psycopg'`: `COPY --from=builder` указывает не тот путь или venv создан не в `/opt/venv`: сверь пути в обеих стадиях.

### Задание 2. Теги, digest и pull

**Цель:** увидеть разницу между тегом и digest на живом образе.

**Предскажи:** если перепривязать тег `notes:test` к другому образу, изменится ли `IMAGE ID` у имени `notes:test`? А у digest?

<details markdown="1">
<summary>Ответ</summary>

У имени изменится: тег просто указывает на новый образ. Идентификатор (digest) самого образа не меняется никогда, потому что это хеш его содержимого. Digest для локально собранного образа появляется только после push в реестр.

</details>

**Шаги:**

```bash
# Один образ, два имени: тег это просто ссылка
docker tag notes:multi notes:0.4.0-rc1
docker tag notes:single notes:test
docker image ls notes --format '{% raw %}{{.Repository}}:{{.Tag}} {{.ID}}{% endraw %}'

# Перепривязываем тег на другой образ
docker tag notes:multi notes:test
docker image ls notes --format '{% raw %}{{.Repository}}:{{.Tag}} {{.ID}}{% endraw %}'

# Digest публичного образа: тянем по тегу и смотрим, какой хеш за ним стоит
docker pull nginx:1.30
docker image inspect nginx:1.30 --format '{% raw %}{{index .RepoDigests 0}}{% endraw %}'
```

**Что должно получиться:**

```text
notes:0.4.0-rc1 3f2a9c1d7b44
notes:multi 3f2a9c1d7b44
notes:single 8e10b5aa02c9
notes:test 8e10b5aa02c9
notes:0.4.0-rc1 3f2a9c1d7b44
notes:multi 3f2a9c1d7b44
notes:single 8e10b5aa02c9
notes:test 3f2a9c1d7b44
nginx@sha256:6a1f...e9c2
```

ID и хеши у тебя будут другими. Смотри на совпадения: у `notes:test` ID сменился на ID `notes:multi`.

**Объясни себе:**

- Почему `docker tag` не копирует данные и не увеличивает занятое место?
- Как бы ты зафиксировал `nginx` в `compose.yml`, чтобы он не менялся при новых патчах?

**Типичные ошибки:**

- `Error response from daemon: No such image: notes:0.4.0`: тег не создан, а ты его запускаешь: сначала `docker tag` или `docker build -t`.
- `invalid reference format: repository name must be lowercase`: в имени есть заглавные буквы (имя GitHub-пользователя `Alice`): пиши `alice`.

### Задание 3. Вручную запушить образ в ghcr.io

**Цель:** пройти путь `login`, `tag`, `push`, `pull` руками, прежде чем автоматизировать.

**Предскажи:** что ответит `docker push`, если ты не выполнил `docker login`?

<details markdown="1">
<summary>Ответ</summary>

Строку вида `denied: permission_denied` или `unauthorized`: реестр не знает, кто ты. Ниже в «Сломай и почини» этот же текст встретится в CI, причина там другая.

</details>

**Шаги:**

1. Создай личный токен: GitHub, Settings, Developer settings, Personal access tokens (classic), scope `write:packages`. Сохрани в переменную для сессии и не пиши в историю оболочки:

```bash
# Токен читается без эха, в файлы и историю не попадает
read -rs GHCR_TOKEN
export GH_USER=<твой-github-логин-строчными>
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GH_USER" --password-stdin
```

2. Проставь тег и запушь черновой образ (`rc1`, не релиз):

```bash
docker tag notes:multi ghcr.io/$GH_USER/notes:0.4.0-rc1
docker push ghcr.io/$GH_USER/notes:0.4.0-rc1
```

3. Удали локальную копию и подтяни из реестра:

```bash
docker rmi ghcr.io/$GH_USER/notes:0.4.0-rc1
docker pull ghcr.io/$GH_USER/notes:0.4.0-rc1
docker logout ghcr.io
unset GHCR_TOKEN
```

**Что должно получиться:**

```text
Login Succeeded
The push refers to repository [ghcr.io/alice/notes]
0.4.0-rc1: digest: sha256:9b0c...41d7 size: 1362
0.4.0-rc1: Pulling from alice/notes
Status: Downloaded newer image for ghcr.io/alice/notes:0.4.0-rc1
```

После push пакет `notes` виден в профиле GitHub, вкладка Packages.

**Объясни себе:**

- Куда `docker login` записал токен и почему это важно помнить на общем сервере?
- Что такое `digest: sha256:...` в конце push?

**Типичные ошибки:**

- `Error response from daemon: Get "https://ghcr.io/v2/": denied: denied`: токен без scope `write:packages` или неверный логин: создай токен заново с нужным scope.
- `unauthorized: unauthenticated`: не выполнен `docker login ghcr.io`.
- `name unknown: repository name not known to registry`: опечатка в имени или пакет принадлежит другому владельцу.

### Задание 4. CI по тегу: image.yml

**Цель:** чтобы образ публиковал робот, а не человек: тег `vX.Y.Z` в git автоматически даёт образ `X.Y.Z`.

**Предскажи:** если в workflow не указать `permissions: packages: write`, упадёт ли сборка или только push?

<details markdown="1">
<summary>Ответ</summary>

Сборка пройдёт, упадёт именно push, с `denied: permission_denied`. Токену хватает прав читать код, но не писать пакеты.

</details>

**Шаги:**

1. Создай `.github/workflows/image.yml`. Синтаксис выражений GitHub Actions (двойные фигурные скобки) в файле обёрнут в raw, чтобы Jekyll его не трогал:

{% raw %}
```yaml
name: image

on:
  push:
    tags: ['v*']

# Минимум прав: читать код и писать пакеты
permissions:
  contents: read
  packages: write

jobs:
  image:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7.0.1

      - uses: docker/setup-buildx-action@v4.4.1

      - uses: docker/login-action@v4.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      # Тег образа = тег git без буквы v: v0.4.0 -> 0.4.0; имя в нижнем регистре
      - name: Вычислить имя образа
        id: meta
        run: |
          echo "image=ghcr.io/${GITHUB_REPOSITORY,,}" >> "$GITHUB_OUTPUT"
          echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"

      - uses: docker/build-push-action@v7.4.0
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.image }}:${{ steps.meta.outputs.version }}
```
{% endraw %}

2. Закоммить, запушь ветку, открой PR и влей его (процесс из урока 3.2). Workflow по тегу сам ничего не запустит, пока нет тега.

**Что должно получиться:** файл `.github/workflows/image.yml` в `main`, во вкладке Actions нет красных ошибок конфигурации.

**Объясни себе:**

- Зачем `${GITHUB_REPOSITORY,,}` и что было бы при `Alice/notes`?
- Почему тег образа не выбирается вручную, а берётся из `GITHUB_REF_NAME`?

**Типичные ошибки:**

- `Invalid workflow file: .github/workflows/image.yml#L14`: сломан отступ YAML: сверь отступы с примером, в YAML только пробелы.
- `Unable to resolve action docker/login-action@v4, unable to find version v4`: версия действия написана неверно: используй полный вид `v4.6.0`.
- `repository name must be lowercase`: имя репозитория с заглавными в тегах образа: используй `${GITHUB_REPOSITORY,,}`.

### Задание 5. Шаг проекта: релиз 0.4.0

**Цель:** выпустить `v0.4.0`: multi-stage `Dockerfile`, `image.yml`, образ `ghcr.io/<user>/notes:0.4.0`. Состояние проекта после задания: app v4, образ 0.4.0, git-тег v0.4.0.

**Предскажи:** сколько образов получится в реестре после тега `v0.4.0`, если раньше ты пушил `0.4.0-rc1` руками?

<details markdown="1">
<summary>Ответ</summary>

Два тега в одном пакете: `0.4.0-rc1` (ручной) и `0.4.0` (от CI). Это разные теги, а «рабочим» считается только тот, что от тега git. `rc1` можно удалить в настройках пакета.

</details>

**Шаги:**

1. Убедись, что `Dockerfile` (задание 1) и `image.yml` (задание 4) в `main`:

```bash
cd ~/notes
git switch main && git pull
git log --oneline -3
```

2. Поставь аннотированный тег и отправь его:

```bash
git tag -a v0.4.0 -m "Заметки 0.4.0: multi-stage образ, публикация в ghcr.io"
git push origin v0.4.0
```

3. Дождись зелёного запуска во вкладке Actions (workflow `image`), потом открой пакет и сделай его публичным (Package settings, Change visibility, Public).
4. С другой машины или после `docker logout` проверь, что образ тянется без токена, и запусти его:

```bash
docker pull ghcr.io/$GH_USER/notes:0.4.0
docker run -d --name notes-r --rm -e STORE=file -p 127.0.0.1:8080:8080 ghcr.io/$GH_USER/notes:0.4.0
sleep 2
curl -s http://127.0.0.1:8080/healthz
docker stop notes-r
```

**Что должно получиться:**

```text
0.4.0: Pulling from alice/notes
Status: Downloaded newer image for ghcr.io/alice/notes:0.4.0
ok
```

Эталон файлов: [project/notes в репозитории курса](https://github.com/distinguished-sre/devops/tree/devops/project/notes).

**Объясни себе:**

- Как по образу в реестре понять, из какого коммита он собран? (Подсказка: тег указывает на коммит.)
- Что произойдёт, если сделать `git push origin v0.4.0` ещё раз с другого коммита?

**Типичные ошибки:**

- `error: src refspec v0.4.0 does not match any`: тег не создан локально: сначала `git tag -a`.
- `! [rejected] v0.4.0 -> v0.4.0 (already exists)`: тег уже есть на сервере: новый релиз делай под `v0.4.1`, тег не перезаписывай.
- `Error response from daemon: pull access denied for ghcr.io/alice/notes, repository does not exist or may require 'docker login'`: пакет ещё приватный: сделай его публичным.

## Сломай и почини

Запусти сломанный сценарий и найди причину сам, не читая скрипт:

```bash
cd ~/notes
bash break/4.7/break.sh random
```

Проверка исправления: по `v0.4.x` собирается образ и он тянется по тегу без ошибок.

### Симптом

Сценарий 1: workflow `image` красный, в шаге push сообщение `denied: permission_denied: write_package`. Сценарий 2: образ есть в реестре, но тег не совпадает с git-тегом релиза (в реестре `0.4.0`, а вышел `v0.4.1`, или тег вида `refs/tags/v0.4.1`). Сценарий 3: сборка падает на `COPY`, файлов «нет», хотя они в репозитории.

### Гипотезы

Что может дать `denied` при push: нет права `packages: write`, неверный токен, пакет принадлежит другому владельцу, имя в верхнем регистре. Что может дать несовпадение тега: тег зашит в workflow вручную, берётся не та переменная, забыт срез `v`. Что может дать `COPY failed`: неверный `context`, файл в `.dockerignore`, workflow запущен из подкаталога.

### Проверки

```bash
# Права токена в workflow и вычисленные теги смотри в логе шага
grep -n 'permissions' -A3 .github/workflows/image.yml
grep -n 'context\|tags:' .github/workflows/image.yml
# Что реально лежит в реестре
docker buildx imagetools inspect ghcr.io/$GH_USER/notes:0.4.1 | head -5
git tag --list 'v0.4*'
```

### Исправление

<details markdown="1">
<summary>Разбор трёх сценариев</summary>

1. `denied: permission_denied`. В `image.yml` нет `permissions: packages: write` (или в настройках репозитория, Actions, General, Workflow permissions стоит read-only и пакет привязан к другому репозиторию). Добавь `permissions: packages: write` на уровне job или файла и перезапусти workflow. Если пакет уже создан вручную под личным токеном, в Package settings дай репозиторию `notes` роль Write в разделе Manage Actions access.
2. Тег не совпал с git-тегом. Вместо `tags: ...:0.4.0` из жёсткой строки бери `${GITHUB_REF_NAME#v}`. Признак: в Actions успешный запуск, а образа нужной версии нет. Чини workflow, ставь новый тег `v0.4.1`, старый неверный образ удали в настройках пакета.
3. Неверный `context`. В `build-push-action` стоит `context: ./app` или подобное, а `Dockerfile` и `requirements.txt` лежат в корне. Верни `context: .` и проверь `.dockerignore`: в нём не должно быть `requirements.txt` и `app.py`.

</details>

## Вопросы с собеседований

### 1. [junior] Зачем нужна multi-stage сборка и что она даёт на практике?

Разделяю сборку и запуск. В первой стадии есть pip, компилятор, заголовки, во второй остаётся только то, что нужно приложению: venv и код. Образ меньше, быстрее скачивается и запускается, в нём меньше пакетов, значит меньше CVE.

**Что хотят услышать:** `COPY --from`, отказ от компилятора и кэшей в итоговом образе, размер и поверхность атаки, кэш слоёв.

**Красный флаг:** «это чтобы образ был красивее» или путаница со слоями и несколькими образами.

### 2. [junior] Чем тег образа отличается от digest?

Тег это подвижная метка, её можно перепривязать. Digest это SHA256 манифеста, он неизменяем и однозначно определяет содержимое. Для воспроизводимости я фиксирую digest или договариваюсь, что релизные теги не перезаписываются.

**Что хотят услышать:** тег мутабелен, digest иммутабелен, `image@sha256:...`, immutable tags.

**Красный флаг:** «`latest` всегда самый свежий, его и использую».

### 3. [middle] Прод начал вести себя по-другому, хотя версия в манифесте `notes:0.4.0` не менялась. Что проверишь?

Подозреваю, что тег перезаписали. Сравню digest запущенного контейнера (`docker inspect`, `RepoDigests`) с digest в реестре. Если разошлись, значит кто-то запушил под тем же тегом, а сервер после рестарта потянул новый образ.

**Что хотят услышать:** проверка digest, `pull` при пересоздании, запрет перезаписи релизных тегов, фиксация по digest.

**Красный флаг:** «перезапущу контейнер и посмотрю».

### 4. [junior] CI при push в ghcr.io пишет `denied: permission_denied`. Твои действия?

Читаю лог шага. Проверяю `permissions: packages: write` в workflow, настройки Workflow permissions репозитория, владельца пакета и регистр в имени образа. Если пакет создан раньше вручную, проверяю, что у репозитория есть доступ Write к пакету.

**Что хотят услышать:** `packages: write`, `GITHUB_TOKEN`, привязка пакета к репозиторию, нижний регистр.

**Красный флаг:** «положу личный токен админа в secrets и забуду».

### 5. [middle] Как связать тег в git и тег образа, чтобы они не расходились?

Образ собирает workflow по событию `push` с тегом `v*`, а тег образа вычисляется из `GITHUB_REF_NAME` без `v`. Человек тег образа руками не вводит. Так один источник правды: git-тег.

**Что хотят услышать:** триггер по тегу, вычисление из переменной, отсутствие ручных тегов, откат новой версией.

**Красный флаг:** тег образа задан константой в workflow.

### 6. [middle] Образ вырос с 150 до 700 МБ после последнего коммита. Как найдёшь причину?

Смотрю `docker history` и `docker image ls`, ищу слой-«толстяка». Подозреваю `COPY . .` без `.dockerignore` (данные, `.git`, `.venv`), установку лишних пакетов и отсутствие multi-stage. Проверяю содержимое слоя и правлю `.dockerignore` и порядок команд.

**Что хотят услышать:** `docker history`, `dive`, `.dockerignore`, удаление в другом слое не уменьшает образ, multi-stage.

**Красный флаг:** «удалю файлы командой `RUN rm` в конце».

### 7. [junior] `docker pull` пишет `pull access denied ... repository does not exist or may require 'docker login'`. Что это может быть?

Либо опечатка в имени или теге, либо приватный пакет, а я не залогинен. Проверяю имя в UI реестра и делаю `docker login`, если пакет приватный. Для публичного образа логин не нужен.

**Что хотят услышать:** два разных случая под одной ошибкой, видимость пакета, регистр.

**Красный флаг:** сразу «реестр упал».

### 8. [middle] Сборка в CI занимает 6 минут на каждый коммит, хотя зависимости не менялись. Что сделаешь?

Проверю порядок слоёв: `requirements.txt` копируется до кода, и установка зависимостей в отдельном слое. Включу кэш сборки в Actions (`cache-from`, `cache-to` у `build-push-action`), чтобы слои переиспользовались между запусками на чистых раннерах.

**Что хотят услышать:** порядок слоёв, что раннер каждый раз чистый, кэш buildx (`type=gha`).

**Красный флаг:** «возьму раннер помощнее».

### 9. [middle] Почему нельзя передавать секрет в образ через `ARG` или `ENV` при сборке?

Значения остаются в истории и метаданных образа (`docker history`, `inspect`), и любой с доступом к образу их прочитает. Для сборки использую `RUN --mount=type=secret`: файл секрета доступен только на время шага и в слой не попадает.

**Что хотят услышать:** `--mount=type=secret`, история слоёв, что удаление файла следующим слоем не помогает.

**Красный флаг:** «`ARG` же не попадает в контейнер».

### 10. [junior] Зачем в CI использовать `GITHUB_TOKEN`, а не личный токен?

Он временный, создаётся на запуск, ограничен `permissions:` и репозиторием. Личный токен долгоживущий, привязан к человеку и обычно шире по правам, при утечке урон больше, а при уходе сотрудника пайплайн ломается.

**Что хотят услышать:** короткая жизнь, минимум прав, не привязано к человеку, OIDC как следующий шаг.

**Красный флаг:** «так проще, токен и так у всех есть».

## Проверено на версиях

- Docker Engine: 29.x (apt-репозиторий Docker), Buildx из комплекта
- python: 3.13-slim (образ)
- nginx: 1.30 (образ, в задании 2)
- actions/checkout: v7.0.1
- docker/setup-buildx-action: v4.4.1
- docker/login-action: v4.6.0
- docker/build-push-action: v7.4.0
- psycopg: версия не закреплена, проверь актуальную версию на странице проекта
- ghcr.io: интерфейс настроек пакета меняется, проверь актуальную версию на странице проекта

## Итог урока: ты умеешь

- [ ] умею переписать `Dockerfile` в multi-stage и объяснить, что остаётся в итоговом образе
- [ ] умею сравнить размер образов и найти толстый слой командой `docker history`
- [ ] умею отличать тег от digest и знаю, почему тег релиза не перезаписывают
- [ ] умею войти в ghcr.io токеном через `--password-stdin` и запушить образ
- [ ] умею написать workflow, который по тегу `v*` публикует образ с тегом без буквы `v`
- [ ] умею разобрать `denied: permission_denied` при push в реестр
- [ ] умею выпустить релиз `v0.4.0` и проверить, что образ тянется из публичного пакета

**Дальше:** [Урок 4.8: Безопасность образов: Trivy, Hadolint, SBOM](08-image-security.md)
