---
layout: lesson
title: "GitLab CI и Jenkins: тот же конвейер на других платформах"
topic: 3
lesson: "3.6"
time: "2 ч"
---

## Зачем это нужно

Ты уже умеешь конвейер (pipeline) на GitHub Actions. Но в компаниях, где код живёт на своём сервере, встречаются GitLab CI и Jenkins, а в описании вакансии DevOps их называют чаще, чем Actions. Сменить платформу для инженера это не «учить всё заново»: идея конвейера та же (проверить код на чистой машине при каждом изменении), меняются синтаксис и словарь.
Ты перенесёшь конвейер «Заметок» (lint и test) на GitLab CI, поднимешь свой раннер (runner), затем запустишь Jenkins в Docker и опишешь тот же конвейер в `Jenkinsfile`. GitHub останется основным местом жизни проекта.

Шаг проекта: в `~/notes` появятся `.gitlab-ci.yml` и `Jenkinsfile`, оба выполняют те же две проверки, что и `ci.yml` из урока 3.3.

## Что нужно знать

- [Урок 1.6: bash и Make](../01-linux/06-bash-basics.md) - команды `ruff check .` и `python -m unittest` ты запускал руками, теперь их запускает робот
- [Урок 3.2: удалённые репозитории](02-remotes-workflow.md) - второй remote, push, Pull Request
- [Урок 3.3: CI в GitHub Actions](03-actions-ci.md) - jobs, runner, matrix, кэш: эталон, с которым мы сравниваем
- [Урок 3.4: качество и безопасность в CI](04-quality-security-ci.md) - секреты в CI и почему их нельзя держать в репозитории
- [Урок 3.5: релизы](05-release-flow.md) - теги как триггер конвейера

## Теория

### Один конвейер, три словаря

Любая CI-система делает одно: по событию (push, Pull Request, тег) берёт чистую среду, скачивает код, выполняет команды и показывает зелёный или красный результат. Отличаются три вещи: где лежит описание, как называются понятия и кто исполняет команды.

| Идея | GitHub Actions | GitLab CI | Jenkins |
|---|---|---|---|
| Файл конвейера | `.github/workflows/ci.yml` (файлов может быть много) | `.gitlab-ci.yml` (один в корне) | `Jenkinsfile` (в корне, путь настраивается) |
| Конвейер | workflow | pipeline | Pipeline |
| Единица работы | job | job | stage (внутри `steps`) |
| Порядок | `needs:` между jobs | `stages:` (jobs одного этапа идут параллельно) | stages идут последовательно, параллель через `parallel` |
| Кто исполняет | runner (GitHub-hosted или self-hosted) | runner (shared или свой) | agent (узел, подключённый к controller) |
| Среда | `runs-on:` | `image:` (для Docker executor) | `agent { docker { image '...' } }` |
| Когда запускать | `on:` | `rules:` | `when {}` и триггеры в настройках job |
| Файлы между jobs | artifacts | `artifacts:` | `archiveArtifacts` |
| Кэш | `actions/cache` | `cache:` | кэш на агенте или том |
| Секреты | Secrets | CI/CD variables (masked, protected) | Credentials |

> **Проверь понимание:** как в GitLab CI выразить то, что в Actions делает `needs: lint`?

<details>
<summary>Ответ</summary>

Два способа. Обычный: положить jobs в разные `stages`, тогда этап `test` начнётся только после успеха всех jobs этапа `lint`. Точный: ключ `needs: [lint]` в job, тогда она стартует сразу после `lint`, не дожидаясь остальных jobs этапа.

</details>

### GitLab CI: stages, jobs, rules, runner

Весь конвейер описан одним файлом. Верхний уровень: список `stages` (порядок этапов), общие настройки (`default`, `variables`, `cache`) и jobs. Job это любой ключ верхнего уровня, у которого есть `script`. Если этап не указан, job попадает в `test`.

Главные ключи job: `stage`, `image` (образ Docker, в котором пойдёт `script`), `script` (команды; ненулевой код выхода делает job красной, как в Actions), `rules` (когда запускать), `artifacts` (что сохранить и с каким `expire_in`), `cache` (что переиспользовать между запусками), `needs`, `tags` (на каком раннере), `when: manual` (кнопка).

Раннер (runner) это отдельная программа GitLab Runner, которая забирает jobs у сервера GitLab и исполняет их. Сам GitLab jobs не выполняет. Как исполнять, задаёт executor: `docker` (каждая job в новом контейнере из `image`, самый частый), `shell` (прямо на машине раннера, грязно и опасно), `kubernetes` (под на job, тема 5). Раннер бывает общий (shared, предоставляет платформа) и свой (project или group runner). Ключевая связь: если у job указаны `tags`, её возьмёт только раннер, у которого есть эти теги; если у раннера включено «run untagged jobs», он берёт и job без тегов. Отсюда самая частая беда новичка: job висит в состоянии pending, потому что подходящего раннера нет.

Секреты живут в Settings, CI/CD, Variables: флаг `masked` прячет значение в логах, `protected` отдаёт его только защищённым веткам и тегам. В репозиторий токены не кладут (урок 3.4). Предопределённые переменные (`CI_COMMIT_SHA`, `CI_COMMIT_REF_NAME`, `CI_PROJECT_DIR`) GitLab подставляет сам.

> **Проверь понимание:** в конвейере две job без `stage:`, и `stages:` не задан. Сколько этапов и в каком порядке они пойдут?

<details>
<summary>Ответ</summary>

Обе job попадут в этап `test` по умолчанию и пойдут параллельно, если раннеров хватает. Список этапов по умолчанию: `.pre`, `build`, `test`, `deploy`, `.post`. Поэтому явное `stages:` в проекте лучше писать: читателю сразу видно порядок.

</details>

### Jenkins: controller, agent, Jenkinsfile

Jenkins старше GitHub Actions и GitLab CI на десять с лишним лет, это самостоятельный сервер, который ты ставишь и обслуживаешь сам. Устройство: controller (раньше «master») хранит настройки, историю и раздаёт задания, а agent (узел) исполняет. Всё состояние controller лежит в каталоге `JENKINS_HOME`: потеряешь его без бэкапа, потеряешь всё. Функциональность даёт плагины (Git, Pipeline, Docker Pipeline, Credentials); плагины надо обновлять, через них чаще всего находят уязвимости.

Современный способ описания это Pipeline as code: файл `Jenkinsfile` в репозитории. Он бывает declarative (структура `pipeline { agent, stages, steps }`, проверяется парсером, его и используем) и scripted (сырой Groovy, гибче, но легче наломать дров). Блок `agent { docker { image '...' } }` говорит: выполни stages внутри контейнера этого образа. Для этого на агенте должны быть Docker и плагин Docker Pipeline. Рабочий каталог (workspace) Jenkins сам не чистит: если нужна чистота, проси об этом в конвейере.

> **Проверь понимание:** почему `Jenkinsfile` в репозитории лучше, чем job, настроенная кликами в веб-интерфейсе?

<details>
<summary>Ответ</summary>

Файл версионируется вместе с кодом: видно кто и когда менял конвейер, работают Pull Request и ревью, старую ветку можно собрать старым конвейером, при потере сервера конвейер не пропадает. Клики в UI живут только в `JENKINS_HOME`.

</details>

### Когда что выбирают

GitHub Actions удобен там, где код на GitHub. GitLab CI встроен в GitLab: репозиторий, реестр образов, окружения и конвейеры в одной системе, поэтому его выбирают компании со своим GitLab в контуре. Jenkins чаще всего достаётся «в наследство»: много старых jobs, плагины под нестандартные системы, а платформа не заменена. Для нового проекта Jenkins обычно не выбирают из-за стоимости обслуживания, но читать и мигрировать его ты должен уметь.

## Практика

Понадобятся: репозиторий `~/notes` с `ci.yml` из 3.3, аккаунт на gitlab.com (бесплатный) и Docker. Docker Engine подробно ставится в [уроке 4.1](../04-docker/01-containers-idea.md); если его ещё нет, поставь по официальной инструкции для Ubuntu на docs.docker.com/engine/install/ubuntu (через apt-репозиторий, без `curl | bash`).

### Задание 1. Конвейер «Заметок» в GitLab CI

**Цель:** описать lint и test в `.gitlab-ci.yml` и увидеть зелёный pipeline на gitlab.com.

**Предскажи:** ты добавишь job `lint` в этап `lint` и `test` в этап `test`. Что произойдёт с `test`, если `lint` упадёт из-за замечания ruff? Запустится ли `test` вообще?

<details>
<summary>Ответ</summary>

Не запустится. Этап `test` стартует только после успеха всех jobs предыдущего этапа. Pipeline покажет `lint` красным, а `test` серым (не запускался).

</details>

**Шаги:**

1. Создай пустой проект на gitlab.com (New project, Create blank project, имя `notes`, без README). Скопируй адрес SSH. Публичный ключ добавь в профиле (Preferences, SSH Keys), как в уроке 2.2.
2. Добавь GitLab вторым remote (GitHub остаётся `origin`):

```bash
cd ~/notes
# замени <gitlab-user> на свой логин на gitlab.com
git remote add gitlab git@gitlab.com:<gitlab-user>/notes.git
git remote -v
```

3. Создай ветку и файл конвейера:

```bash
git switch -c ci/gitlab
cat > .gitlab-ci.yml <<'YAML'
# Тот же конвейер, что и в .github/workflows/ci.yml, на языке GitLab CI
stages:
  - lint
  - test

default:
  image: python:3.13-slim   # образ, в котором исполняется каждый script

variables:
  PIP_CACHE_DIR: "$CI_PROJECT_DIR/.cache/pip"   # кэш pip внутри проекта, чтобы GitLab мог его сохранить
  PIP_DISABLE_PIP_VERSION_CHECK: "1"

cache:
  key: pip-py313
  paths:
    - .cache/pip

lint:
  stage: lint
  script:
    - pip install -r requirements-dev.txt
    - ruff check .

test:
  stage: test
  script:
    - python -m unittest -v
YAML
git add .gitlab-ci.yml
git commit -m "ci: конвейер lint и test для GitLab CI"
```

4. Отправь ветку в GitLab (не в GitHub) и открой в браузере Build, Pipelines:

```bash
git push -u gitlab ci/gitlab
```

Если у аккаунта нет доступа к общим раннерам (на бесплатном тарифе gitlab.com для них может потребоваться подтверждение аккаунта, проверь актуальные условия), pipeline повиснет в pending. Тогда переходи к заданию 2 и подними свой раннер.

**Что должно получиться:** в Pipelines строка со статусом passed и двумя зелёными кружками. В логе job `test`:

```text
$ python -m unittest -v
test_health (test_app.NotesTest.test_health) ... ok
...
----------------------------------------------------------------------
Ran 5 tests in 0.312s

OK
Job succeeded
```

Число и имена тестов у тебя свои, важны `OK` и `Job succeeded`.

**Объясни себе:**

- Откуда в контейнере взялся код репозитория, если в `script` нет `git clone`?
- Зачем `PIP_CACHE_DIR` внутри `$CI_PROJECT_DIR`, а не в `~/.cache/pip`?
- Почему в `test` нет `pip install`, а в `lint` есть?

**Типичные ошибки:**

- `ERROR: Job failed: failed to pull image "python:3.13-slimm" with specified policies [always]: ... manifest unknown`: опечатка в имени образа или тега: сверь с Docker Hub и поправь `image:`.
- `fatal: Could not read from remote repository. Permission denied (publickey).` при `git push gitlab`: ключ не добавлен в профиль GitLab: добавь публичный ключ и проверь `ssh -T git@gitlab.com`.
- `jobs:lint config should implement a script: or a trigger: keyword` (вкладка Pipelines, `yaml invalid`): отступ или опечатка в ключе, `script` не на своём уровне: сверь отступы (два пробела, без табуляций).
- Pipeline не создался вообще: файл называется не `.gitlab-ci.yml` (например `.gitlab-ci.yaml` или `gitlab-ci.yml`): переименуй.

### Задание 2. Свой раннер, теги и правила запуска

**Цель:** понять связь job, tags и runner на живом примере: зарегистрировать раннер в Docker и добавить `rules`.

**Предскажи:** ты добавишь в job `lint` строку `tags: [docker]`, а раннер зарегистрируешь без тегов и без «run untagged jobs». Что покажет pipeline: зелёный, красный или pending?

<details>
<summary>Ответ</summary>

Pending. Job требует раннер с тегом `docker`, такого нет, ошибки нет, job просто ждёт. В интерфейсе: `This job is stuck because you don't have any active runners online with any of these tags assigned to them: docker`.

</details>

**Шаги:**

1. В GitLab: Settings, CI/CD, Runners, New project runner. Теги: `docker`. Создай раннер и скопируй токен `glrt-...` (показывается один раз, это секрет).
2. Запусти контейнер GitLab Runner. Тег образа проверь на странице проекта GitLab Runner (Docker Hub, `gitlab/gitlab-runner`), версия в курсе не закреплена:

```bash
# подставь актуальный тег, например ubuntu-v18.x.y, тег latest не используем
export RUNNER_TAG=ЗАМЕНИ_НА_АКТУАЛЬНЫЙ_ТЕГ
docker volume create gitlab-runner-config
docker run -d --name gitlab-runner --restart unless-stopped \
  -v gitlab-runner-config:/etc/gitlab-runner \
  -v /var/run/docker.sock:/var/run/docker.sock \
  gitlab/gitlab-runner:"$RUNNER_TAG"
```

3. Зарегистрируй раннер (токен только через переменную окружения, чтобы он не остался в истории команд):

```bash
read -rs RUNNER_TOKEN   # вставь glrt-... и Enter, ввод не отображается
docker exec gitlab-runner gitlab-runner register --non-interactive \
  --url https://gitlab.com --token "$RUNNER_TOKEN" \
  --executor docker --docker-image python:3.13-slim
unset RUNNER_TOKEN
docker exec gitlab-runner gitlab-runner list
```

4. Добавь в оба job строку `tags: [docker]` и правило: конвейер только для merge request и для ветки по умолчанию. Для `lint`:

```yaml
lint:
  stage: lint
  tags: [docker]
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  script:
    - pip install -r requirements-dev.txt
    - ruff check .
```

Для `test` сделай то же самое. `rules` заменяет старые `only` и `except`, пиши по-новому.

5. Закоммить и запушь в ветку по умолчанию GitLab (или открой merge request), проверь, что job взял именно твой раннер (в шапке лога `Running with gitlab-runner ...`).

**Что должно получиться:**

```text
Runtime platform    arch=amd64 os=linux pid=... revision=... version=...
notes-runner-1  Executor=docker Token=glrt-*** URL=https://gitlab.com
```

и pipeline passed. Push обычной ветки без merge request pipeline теперь не создаёт: так экономят минуты раннеров.

**Объясни себе:**

- Чем `executor = docker` безопаснее `shell`, если на раннере запускают чужие MR?
- Что даёт монтирование `/var/run/docker.sock` в контейнер раннера и почему это почти root на хосте?
- Зачем `rules` разрешает ветку по умолчанию, а не только MR?

**Типичные ошибки:**

- `This job is stuck because you don't have any active runners online with any of these tags assigned to them: docker`: у раннера нет тега или он выключен: добавь тег в настройках раннера или включи «Run untagged jobs».
- `ERROR: Registering runner... forbidden (check registration token)`: токен использован повторно или скопирован с ошибкой: создай раннер заново через New project runner и используй новый `glrt-` токен.
- `Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?`: сокет не смонтирован или демон остановлен: проверь `-v /var/run/docker.sock:/var/run/docker.sock` и `systemctl status docker`.

### Задание 3. Jenkins в Docker и Jenkinsfile

**Цель:** поднять Jenkins, подключить `~/notes` и получить зелёную сборку по `Jenkinsfile` с агентом `docker`.

**Предскажи:** ты запустишь стандартный образ Jenkins, смонтируешь сокет Docker и попробуешь `agent { docker {...} }`. Сработает ли?

<details>
<summary>Ответ</summary>

Нет. В образе Jenkins нет клиента `docker`, а плагина Docker Pipeline может не быть. Сборка упадёт с `docker: not found`. Поэтому делаем свой образ: Jenkins плюс клиент Docker плюс плагины.

</details>

**Шаги:**

1. Собери образ Jenkins с клиентом Docker. Каталог вне `~/notes` (эти файлы в проект не входят). Тег базового образа проверь на странице `jenkins/jenkins` (берём ветку LTS, точный тег в курсе не закреплён):

```bash
mkdir -p ~/jenkins-lab && cd ~/jenkins-lab
cat > Dockerfile <<'EOF'
# Тег LTS проверь на hub.docker.com/r/jenkins/jenkins (пример: lts-jdk21)
FROM jenkins/jenkins:lts-jdk21
USER root
# клиент Docker нужен, чтобы Jenkins мог запускать агентов в контейнерах
RUN apt-get update && apt-get install -y --no-install-recommends docker.io \
    && rm -rf /var/lib/apt/lists/*
USER jenkins
# плагины: Pipeline, Git и Docker Pipeline
RUN jenkins-plugin-cli --plugins workflow-aggregator git docker-workflow
EOF
docker build -t jenkins-notes:lab .
```

2. Запусти. Порт 8081, потому что 8080 занят под «Заметки». Группа сокета даёт Jenkins право говорить с демоном:

```bash
docker run -d --name jenkins -p 8081:8080 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add "$(stat -c %g /var/run/docker.sock)" \
  jenkins-notes:lab
sleep 45
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

3. Открой `http://localhost:8081`, введи пароль, создай администратора. Плагины по умолчанию ставить не нужно (Select plugins to install, none): нужные уже вшиты в образ.
4. В `~/notes` создай `Jenkinsfile`:

```bash
cd ~/notes
cat > Jenkinsfile <<'EOF'
// Тот же конвейер: lint и test в контейнере python:3.13-slim
pipeline {
    agent {
        docker { image 'python:3.13-slim' }
    }
    options {
        timeout(time: 10, unit: 'MINUTES')   // зависшая сборка не держит агента вечно
    }
    stages {
        stage('Lint') {
            steps {
                // venv в рабочем каталоге: у пользователя контейнера нет прав писать в /
                sh '''
                    python -m venv .venv
                    . .venv/bin/activate
                    pip install -r requirements-dev.txt
                    ruff check .
                '''
            }
        }
        stage('Test') {
            steps {
                sh 'python -m unittest -v'
            }
        }
    }
}
EOF
git add Jenkinsfile && git commit -m "ci: Jenkinsfile для Jenkins (declarative, agent docker)"
git push -u origin ci/gitlab
```

5. В Jenkins: New Item, Pipeline, Definition: Pipeline script from SCM, SCM: Git, Repository URL: `https://github.com/<github-user>/notes.git`, Branch: `*/ci/gitlab`, Script Path: `Jenkinsfile`. Save, Build Now. Репозиторий публичный, ключи не нужны.

**Что должно получиться:** в Console Output:

```text
[Pipeline] { (Lint)
+ python -m venv .venv
+ pip install -r requirements-dev.txt
+ ruff check .
All checks passed!
[Pipeline] { (Test)
+ python -m unittest -v
OK
Finished: SUCCESS
```

**Объясни себе:**

- Кто в этой схеме controller, а кто agent? Где физически выполнился `ruff`?
- Зачем в `Jenkinsfile` venv, а в `.gitlab-ci.yml` его нет?
- Что сделал бы посторонний, получив доступ к Jenkins с примонтированным `docker.sock`?

**Типичные ошибки:**

- `docker: not found`: в образе Jenkins нет клиента Docker: собери образ с `docker.io`, как в шаге 1.
- `permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock`: у пользователя jenkins нет группы сокета: добавь `--group-add "$(stat -c %g /var/run/docker.sock)"`.
- `Missing required section "stages"` или `Expected a step`: синтаксис declarative: сверь скобки и что `steps` лежат внутри `stage`.
- `No such DSL method 'docker' found among steps`: не установлен плагин Docker Pipeline: пересобери образ с `docker-workflow`.

### Задание 4. Шаг проекта: два конвейера рядом с GitHub

**Цель:** оформить `.gitlab-ci.yml` и `Jenkinsfile` как обычное изменение через Pull Request в GitHub и убедиться, что основной `ci.yml` их не ломает.

**Предскажи:** в Pull Request добавляются только `.gitlab-ci.yml` и `Jenkinsfile`, код не меняется. Запустится ли GitHub Actions и каким будет результат?

<details>
<summary>Ответ</summary>

Запустится (триггер `pull_request` срабатывает на любой PR) и будет зелёным: `ruff` и `unittest` те же, а новые файлы Python не содержат. GitHub не читает `.gitlab-ci.yml` и `Jenkinsfile`, они просто лежат в репозитории.

</details>

**Шаги:**

1. Убедись, что ветка `ci/gitlab` содержит оба файла, и открой Pull Request на GitHub:

```bash
cd ~/notes
git status --short
git log --oneline -3
gh pr create --base main --title "ci: конвейер для GitLab CI и Jenkins" \
  --body "Тот же lint и test на других платформах. GitHub Actions остаётся основным."
```

2. Дождись зелёных `lint` и `test` в Actions, влей PR (Squash and merge), обнови локальную main:

```bash
git switch main
git pull
ls -a | grep -E 'gitlab-ci|Jenkinsfile'
```

3. Убедись, что три конвейера выполняют одни и те же команды:

```bash
grep -n 'ruff check\|unittest' .github/workflows/ci.yml .gitlab-ci.yml Jenkinsfile
```

**Что должно получиться:**

```text
.gitlab-ci.yml
Jenkinsfile
.github/workflows/ci.yml:...:        run: ruff check .
.github/workflows/ci.yml:...:        run: python -m unittest -v
.gitlab-ci.yml:...:    - ruff check .
.gitlab-ci.yml:...:    - python -m unittest -v
Jenkinsfile:...:                    ruff check .
Jenkinsfile:...:                sh 'python -m unittest -v'
```

Номера строк и точная форма шагов в `ci.yml` у тебя могут отличаться, важно что везде те же две команды. Состояние проекта после урока: в `~/notes` GitHub Actions, `.gitlab-ci.yml` и `Jenkinsfile`, `app.py` не менялся (v3), тег остаётся `v0.2.0`. Эталон: [project/notes](https://github.com/distinguished-sre/devops/tree/devops/project/notes).

**Объясни себе:**

- Где живёт «источник истины» про то, что значит «проверка прошла»: в каждом файле отдельно или в командах `make lint` и `make test`?
- Что произойдёт, если завтра поменять правило линтера только в `ci.yml`?

**Типичные ошибки:**

- `fatal: 'gitlab' does not appear to be a git repository`: нет remote `gitlab`: выполни `git remote add gitlab ...` из задания 1.
- `! [rejected] main -> main (fetch first)` при push в GitLab: в GitLab-проекте уже есть коммиты (например README при создании): создай проект пустым или сделай `git pull --rebase gitlab main`.

## Сломай и почини

Сборка красная или не стартует. Выбери одну поломку из трёх командой `shuf -i 1-3 -n 1`, внеси её на отдельной ветке и не открывай разбор. Как внести, написано в конце раздела в свёрнутом блоке.

### Симптом

В зависимости от номера ты увидишь одно из трёх:

- pipeline на GitLab не стартует и висит в pending;
- job на GitLab красная в первую секунду, лог короткий;
- Jenkins падает сразу после `Started by user`, до стадии `Lint`.

### Гипотезы

Запиши минимум три причины до проверки. Например: нет подходящего раннера; неверное имя образа; нет клиента Docker; отступ YAML; нет прав на сокет; кончились минуты. Отсортируй по вероятности и по цене проверки.

### Проверки

Иди от дешёвого к дорогому: сначала текст ошибки в интерфейсе (он обычно точно называет причину), затем Settings, CI/CD, Runners (онлайн ли раннер, какие у него теги), затем `docker exec gitlab-runner gitlab-runner list` и `docker logs gitlab-runner --tail 30`. Для Jenkins: `docker exec jenkins docker version` и `docker logs jenkins --tail 50`.

### Исправление

<details>
<summary>Разбор трёх сценариев</summary>

**1. Раннер без тега.** В job стоит `tags: [docker]`, а у раннера тега нет и «Run untagged jobs» выключено. Симптом: `This job is stuck because you don't have any active runners online with any of these tags assigned to them: docker`. Починка: в настройках раннера добавить тег `docker` (или убрать `tags` из job, если раннер один). Урок: pending без ошибки означает «нет подходящего исполнителя», а не «сломан код».

**2. Неверный образ в job.** В `image:` опечатка `python:3.13-slimm`. Симптом: `ERROR: Job failed: failed to pull image "python:3.13-slimm" with specified policies [always]: ... manifest unknown`. Починка: исправить имя. Проверка до пуша: `docker pull python:3.13-slim` на своей машине.

**3. Jenkinsfile: агент без docker.** Jenkins запущен из обычного образа `jenkins/jenkins`, без клиента Docker. Симптом: `docker: not found` в логе первой стадии. Починка: образ из задания 3 (плюс сокет и группа). Урок: `agent { docker }` требует Docker на самом агенте, а не в целевом образе.

**Как воспроизвести:** (1) в `.gitlab-ci.yml` оставить `tags: [docker]`, а в настройках раннера убрать тег; (2) в `image:` дописать лишнюю букву `m`; (3) запустить второй контейнер `docker run -d --name jenkins-plain -p 8082:8080 jenkins/jenkins:lts-jdk21`, создать в нём такую же job и запустить сборку. После разбора удали: `docker rm -f jenkins-plain`.

</details>

## Вопросы с собеседований

### 1. [junior] Pipeline в GitLab висит в pending и не стартует. Что делаешь?

Открываю job: если написано `stuck ... no active runners online with any of these tags`, значит подходящего раннера нет. Смотрю Settings, CI/CD, Runners: есть ли онлайн-раннеры, какие у них теги, включён ли запуск job без тегов, не выключен ли раннер. Сверяю `tags:` в job с тегами раннера. Если раннер свой, проверяю его процесс и логи.

**Что хотят услышать:** pending это про отсутствие исполнителя, а не про код; теги; shared против project runner; проверка `gitlab-runner list` и логов.

**Красный флаг:** «перезапущу pipeline несколько раз» или «перепишу скрипт» без взгляда на раннеры.

### 2. [junior] Чем GitLab CI отличается от GitHub Actions по устройству?

В GitLab одна платформа держит код, реестр и конвейеры, а весь конвейер описан одним `.gitlab-ci.yml` вокруг stages и jobs; переиспользование через `include` и шаблоны. В Actions несколько workflow-файлов и готовые actions из каталога. Идея та же: событие, чистая среда, команды, статус.

**Что хотят услышать:** соответствие терминов (workflow и pipeline, secrets и variables), `stages` против `needs`, `include`.

**Красный флаг:** «GitLab лучше, Actions хуже» без аргументов; не знает, где хранится файл конвейера.

### 3. [junior] Job упала на `pip install` в CI, а локально всё работает. Действия?

Сначала читаю первую ошибку в логе. Затем воспроизвожу в той же среде: `docker run --rm -it -v "$PWD":/w -w /w python:3.13-slim bash` и повторяю команды. Обычно причина в версии Python, недостающей системной библиотеке или файле, которого нет в репозитории (он в `.gitignore`).

**Что хотят услышать:** воспроизвести в том же образе, что и CI; сравнить версии; «у меня работает» не аргумент.

**Красный флаг:** правит версию в пайплайне наугад, пока не позеленеет.

### 4. [junior] Где хранить токен для деплоя в GitLab CI?

В CI/CD Variables проекта или группы с флагами masked и protected: значение не попадёт в логи и будет доступно только защищённым веткам. Не в `.gitlab-ci.yml` и не в коде. Лучше короткоживущие токены и внешний менеджер секретов (Vault, тема 9).

**Что хотят услышать:** masked, protected, ограничение по окружениям, ротация; секрет попал в историю, значит его считают скомпрометированным.

**Красный флаг:** «положу в репозиторий, он же приватный».

### 5. [junior] Pipeline идёт 15 минут. Как ускорить, не теряя проверок?

Сначала смотрю, что именно долго. Кэширую зависимости (`cache:` с ключом по `requirements*.txt`), беру лёгкий образ, независимые job кладу в один этап, чтобы шли параллельно, добавляю `needs`, чтобы не ждать этап целиком, тяжёлое запускаю только по `rules` (MR, main).

**Что хотят услышать:** сначала измерить; кэш против artifacts; параллельность; `rules` и `needs`.

**Красный флаг:** «уберу тесты» или «добавлю раннеров», не выяснив узкое место.

### 6. [middle] Jenkins-сборка с `agent { docker }` падает: `docker: not found` или `permission denied ... docker.sock`. Разбор?

Первое: на агенте нет клиента Docker или плагина Docker Pipeline. Второе: пользователь Jenkins не в группе, владеющей сокетом. Проверяю `docker version` от имени jenkins на агенте и чиню образом с клиентом и группой сокета. Отдельно поднимаю вопрос безопасности: доступ к `docker.sock` это фактически root на хосте, для боевого Jenkins нужны отдельные агенты или rootless-сборка.

**Что хотят услышать:** различие ошибок, проверка от нужного пользователя, риск `docker.sock`, отдельные агенты.

**Красный флаг:** `chmod 666 /var/run/docker.sock` как решение.

### 7. [middle] Сервер Jenkins умер, диск потерян. Что будет с конвейерами и как к этому готовиться?

Если конвейеры лежат в `Jenkinsfile` в репозитории, они живы: нужно восстановить сервер и подключить репозитории. Потеряются история сборок, credentials и настройки из `JENKINS_HOME`. Готовиться: бэкап `JENKINS_HOME` (или тома), Jenkins Configuration as Code для настроек, плагины списком в коде (образ), секреты в Vault, а не только в Jenkins.

**Что хотят услышать:** Pipeline as code, JCasC, бэкап, воспроизводимый образ, учёт плагинов.

**Красный флаг:** «настрою заново руками, это же быстро».

### 8. [middle] Тебя просят перевести конвейеры с Jenkins на GitLab CI. План?

Инвентаризация jobs: что нужно, что мёртвое. Раскладываю по классам: сборка, тесты, деплой, ночные. Переношу по одной, простые первыми, запускаю обе системы параллельно и сравниваю результат. Секреты переношу в CI/CD Variables или Vault. Проверяю эквивалентность (те же команды и версии), выключаю Jenkins job после недели стабильной работы.

**Что хотят услышать:** параллельная работа, поэтапность, замена плагинов, секреты, откат, критерий «готово».

**Красный флаг:** «в выходные перепишу всё сразу».

### 9. [middle] Merge request из форка запускает конвейер, где есть секреты деплоя. Что не так?

Чужой код в MR может вывести секреты в лог или отправить наружу. Защита: секреты только protected и только для защищённых веток и тегов; MR из форка не получает protected-переменные; пайплайны форков идут на отдельных раннерах без доступа во внутреннюю сеть; деплой только с main и тегов по `rules`.

**Что хотят услышать:** protected variables, изоляция раннеров, `rules` для деплоя, ревью изменений в файле конвейера.

**Красный флаг:** «у нас все свои, доверяем».

### 10. [junior] Что такое runner и executor? Чем docker executor отличается от shell?

Runner это программа, которая берёт job у сервера и запускает её. Executor определяет способ: `docker` запускает каждую job в новом контейнере из образа (чистота, воспроизводимость), `shell` выполняет команды прямо на машине раннера (остаются следы прошлых сборок, всё зависит от установленного на хосте, чужая job получает доступ к машине).

**Что хотят услышать:** чистая среда на каждую job, воспроизводимость, риски shell, kubernetes executor как вариант.

**Красный флаг:** не различает сервер GitLab и раннер.

## Проверено на версиях

- Python (образ `python:3.13-slim`): 3.13
- Ubuntu: 26.04 LTS и 24.04
- GitLab Runner: версия не закреплена, проверь актуальную версию на странице проекта
- Jenkins (образ `jenkins/jenkins`, ветка LTS): версия не закреплена, проверь актуальную версию на странице проекта
- ruff: версия не закреплена, проверь актуальную версию на странице проекта

## Итог урока: ты умеешь

- [ ] умею перенести конвейер lint и test с Actions на `.gitlab-ci.yml` и запустить его
- [ ] умею объяснить связь job, tags и runner и найти, почему job висит в pending
- [ ] умею зарегистрировать свой GitLab Runner с docker executor
- [ ] умею ограничить запуск конвейера через `rules`
- [ ] умею поднять Jenkins в Docker с клиентом Docker и плагинами
- [ ] умею написать declarative `Jenkinsfile` с `agent { docker }`
- [ ] умею сравнить GitHub Actions, GitLab CI и Jenkins по словарю и по цене обслуживания
- [ ] умею назвать риск монтирования `docker.sock` и защитить секреты от MR из форков

**Дальше:** [Тема 4: Docker и Compose](../04-docker/index.md)
