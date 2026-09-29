---
layout: lesson
title: "Terraform + Ansible: конвейер с нуля, drift"
topic: 7
lesson: "7.7"
time: "2 ч"
---

## Зачем это нужно

Terraform умеет создать ВМ, но не знает, что внутри должен работать Docker и «Заметки». Ansible умеет настроить ВМ, но не знает, откуда она взялась и какой у неё адрес. В реальной работе нужна связка: одна команда строит сервер с нуля, вторая настраивает его, а ночью кто-то проверяет, что в облаке никто не поправил всё руками (это называется drift, дрейф конфигурации). Без такой проверки через полгода код описывает одну инфраструктуру, а работает другая.

На собеседованиях по IaC про это спрашивают почти всегда: «как связать Terraform и Ansible», «что такое drift и как его ловить», «immutable или mutable».

Шаг проекта: в корне `~/notes` появляется `Makefile` с целями `infra-up`, `infra-plan`, `infra-down`, а в `.github/workflows/terraform.yml` проверки `fmt`, `validate`, `trivy config` и ночной `plan` на drift.

## Что нужно знать

- [Урок 7.2: переменные, ВМ и outputs](02-terraform-vm-variables.md) - `terraform output`, output `public_ip`
- [Урок 7.3: remote state, модули, окружения](03-terraform-state-modules.md) - state в бакете, `envs/dev`, блокировка
- [Урок 7.4: инвентарь, модули, ad-hoc](04-ansible-basics.md) - `inventory.yml`, `ansible.cfg`, SSH-доступ
- [Урок 7.6: роли и деплой «Заметок»](06-ansible-roles.md) - `site.yml`, vault, идемпотентный запуск
- [Урок 3.3: GitHub Actions](../03-git-ci/03-actions-ci.md) - структура workflow, `on:`, `permissions`
- [Урок 3.4: безопасность CI](../03-git-ci/04-quality-security-ci.md) - `trivy`, минимальные права, OIDC вместо долгих ключей

## Теория

### Кто за что отвечает в связке

Разделение простое. Terraform отвечает за то, что существует: сеть, ВМ, диски, группы безопасности (security group), DNS. Ansible отвечает за то, что внутри: пакеты, конфиги, сервисы, стек «Заметок». Граница проходит по ВМ: как только у неё появился адрес, работа Terraform закончена.

Передаётся один факт: IP-адрес. Terraform отдаёт его через `output`, а Ansible получает inventory. Самый прозрачный способ: скрипт или цель Makefile читает `terraform output -raw public_ip` и пишет `inventory.yml`. Есть и динамические inventory-плагины, но для одной ВМ лишняя сложность вредит.

Порядок жёсткий: сначала `apply`, потом ожидание SSH (у свежей ВМ порт 22 открывается не сразу), потом `ansible-playbook`. Обратный порядок не работает: адреса ещё нет.

> **Проверь понимание:** почему нельзя описать Docker и «Заметки» в `user_data` ВМ и обойтись без Ansible?

<details>
<summary>Ответ</summary>

`user_data` выполняется один раз при создании ВМ, а изменение скрипта чаще всего пересоздаёт ВМ (см. урок 7.2). Правка конфига приведёт к пересозданию сервера. Ansible применяется к живой ВМ сколько угодно раз и показывает `--diff`. Короткий bootstrap в `user_data` допустим (ключи, пользователь), но полноценная настройка живёт в Ansible.

</details>

### Drift: код и реальность разошлись

Drift (дрейф) это расхождение между кодом и реальной инфраструктурой. Причины: коллега поправил группу безопасности в консоли «на минуту», автоскейлер поменял параметр, провайдер облака добавил метку, кто-то вручную удалил ресурс.

Terraform в каждом `plan` делает refresh: спрашивает облако о реальном состоянии, сравнивает со state и с кодом. Поэтому обычный `terraform plan` уже ловит drift. Для автоматики важен флаг `-detailed-exitcode`:

| Код выхода | Значение |
|---|---|
| 0 | изменений нет, код и реальность совпадают |
| 1 | ошибка (нет доступа, битый код) |
| 2 | есть изменения: код и реальность различаются |

Ночная проверка запускает `plan -detailed-exitcode`, и на коде 2 job падает, а команда получает уведомление. Важно: проверка ничего не применяет. Решение о том, что верно (код или ручная правка), принимает человек.

Ansible drift ловит своим способом: `ansible-playbook site.yml --check --diff` показывает, что поменялось бы. Для чистой идемпотентной роли на здоровой ВМ итог `changed=0`.

> **Проверь понимание:** ночной plan вернул код 2. Автоматически делать `apply`?

<details>
<summary>Ответ</summary>

Нет. Изменение могло быть аварийной правкой на проде, которую нужно перенести в код, а не откатить. Автоматический `apply` сотрёт её и может устроить инцидент. Порядок: посмотреть diff, выяснить автора, затем либо откатить ручное изменение `apply`, либо обновить код под реальность (или `terraform import`, если создан целый ресурс).

</details>

### Immutable или mutable

Mutable (изменяемая) инфраструктура: ВМ живёт годами, её правят на месте Ansible-плейбуками. Просто, но накапливается дрейф внутри ОС: «на этой ВМ ещё ставили пакет руками».

Immutable (неизменяемая) инфраструктура: ВМ не правят, а заменяют. Собрали новый образ, создали новую ВМ, переключили трафик, старую удалили. Drift внутри ОС невозможен по построению, но нужны сборка образов (Packer), балансировщик и внешние данные (БД и диски вне ВМ).

В «Заметках» мы используем гибрид: ВМ создаёт Terraform, ПО на ней раскатывает Ansible, приложение внутри в контейнерах с закреплённым тегом (это ближе к immutable на уровне приложения). Полностью immutable подход в этом курсе представляет Kubernetes из темы 5.

### Проверки кода до применения

В CI для Terraform запускают четыре проверки, от дешёвой к дорогой:

- `terraform fmt -check -recursive`: единый стиль, код выхода 3 при расхождении;
- `terraform validate`: синтаксис и типы, без обращения к облаку (нужен `init -backend=false`);
- `trivy config`: статический анализ на небезопасные настройки (например, SSH открыт на `0.0.0.0/0`), с Trivy ты работал в уроках 3.4 и 4.8;
- `terraform plan`: реальное сравнение с облаком, нужны учётные данные.

Первые три идут на каждый pull request и не требуют секретов. `plan` с доступом к облаку запускают по расписанию и на изменениях в `main`. Долгоживущие ключи в secrets опасны, поэтому предпочтительны короткоживущие токены (принцип из урока 3.4).

### Соответствие AWS

| Что в этом уроке | Ближайшее в AWS |
|---|---|
| `terraform apply` + `ansible-playbook` | Terraform + SSM Run Command или `cloud-init` |
| ночной `plan -detailed-exitcode` | AWS Config, CloudFormation drift detection |
| `trivy config` | cfn-lint, tfsec, Checkov |
| immutable: образ + пересоздание ВМ | AMI (Packer) + Auto Scaling Group instance refresh |
| Makefile как вход | CodePipeline, GitHub Actions |
| `terraform import` | `cdk import`, `terraform import` |

## Практика

Нужны: рабочие `infra/terraform/envs/dev` (уроки 7.1-7.3) и `infra/ansible` (7.4-7.6), учётные данные Yandex Cloud, vault-пароль. Облачная ВМ стоит денег: в конце обязательно `make infra-down`. Без облака: используй Multipass-ВМ из урока 7.4, задание 1 выполнится без `terraform`, а задания 2-3 читай как разбор.

### Задание 1. Одна команда: от пустого облака до «Заметок»

**Цель:** собрать конвейер `apply` -> ожидание SSH -> `ansible-playbook` в одной цели Makefile.

**Предскажи:**

1. Что покажет второй запуск `make infra-up` подряд: `Apply complete! Resources: 0 added` и `changed=0`, или что-то пересоздастся?
2. Почему `wait_for_connection` стоит между Terraform и Ansible?

<details>
<summary>Ответ</summary>

1. Нулевые изменения и в Terraform, и в Ansible: обе стороны декларативные и идемпотентные. Если что-то меняется на втором запуске, это баг кода.
2. Terraform считает ВМ созданной, когда API облака вернул `RUNNING`, но загрузка ОС и запуск `sshd` идут ещё десятки секунд. Без ожидания первый запуск упадёт с `UNREACHABLE`.

</details>

**Шаги:**

1. Создай в корне `~/notes` файл `Makefile` (если он уже есть с целями из уроков 1.6 и 4.9, допиши цели в конец). Отступы в командах это символ табуляции, не пробелы:

   ```make
   # Каталоги: окружение Terraform и Ansible
   TF  := infra/terraform/envs/dev
   ANS := infra/ansible

   .PHONY: infra-up infra-plan infra-down

   # Только план. Код выхода 2 означает "есть расхождения" (drift)
   infra-plan:
   	terraform -chdir=$(TF) plan -detailed-exitcode

   # Создать ВМ, записать inventory, дождаться SSH, настроить
   infra-up:
   	terraform -chdir=$(TF) apply
   	@printf 'all:\n  children:\n    notes:\n      hosts:\n        notes-vm:\n          ansible_host: %s\n          ansible_user: ubuntu\n' \
   		"$$(terraform -chdir=$(TF) output -raw public_ip)" > $(ANS)/inventory.yml
   	cd $(ANS) && ansible notes -m wait_for_connection -a timeout=180
   	cd $(ANS) && ansible-playbook site.yml

   # Снести всё, что создал Terraform
   infra-down:
   	terraform -chdir=$(TF) destroy
   ```

2. Посмотри, что выполнится, ничего не запуская:

   ```bash
   make -n infra-up
   ```

3. Запусти с нуля и подтверди `apply` словом `yes`:

   ```bash
   make infra-up
   ```

4. Запусти второй раз:

   ```bash
   make infra-up
   ```

**Что должно получиться:**

```text
Apply complete! Resources: 0 added, 0 changed, 0 destroyed.

Outputs:

public_ip = "203.0.113.10"

PLAY RECAP *********************************************************************
notes-vm                   : ok=14   changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

Числа `ok` и адрес у тебя будут свои, `changed=0` обязателен. **Объясни себе:**

- Почему inventory генерируется, а не редактируется руками?
- Что произойдёт, если `terraform output` вернёт пустую строку?
- Почему `infra-plan` отдельная цель, а не часть `infra-up`?

**Типичные ошибки:**

- `Makefile:9: *** missing separator.  Stop.`: в командах пробелы вместо табуляции: замени отступ на Tab.
- `UNREACHABLE! => {"msg": "Failed to connect to the host via ssh: ssh: connect to host 203.0.113.10 port 22: Connection timed out"}`: SSH ещё не поднялся или закрыт группой безопасности: увеличь `timeout`, проверь правило 22 из урока 7.2.
- `Error: No value for required variable`: не заданы переменные Terraform: `terraform.tfvars` или `TF_VAR_...` из урока 7.2.

### Задание 2. Ловим drift руками

**Цель:** изменить ВМ мимо кода и увидеть, что `plan` это замечает.

**Предскажи:**

1. Какой код выхода вернёт `make infra-plan` после ручной правки метки ВМ?
2. Что покажет plan: `+`, `-`, `~` или `-/+`?

<details>
<summary>Ответ</summary>

1. Код 2, `make` напишет `Error 2` (для Makefile это «ненулевой код», для нас «нашли drift»).
2. `~` (изменение на месте): метки меняются без пересоздания ВМ. `-/+` было бы, если бы менялся параметр, требующий пересоздания.

</details>

**Шаги:**

1. Убедись, что расхождений нет:

   ```bash
   make infra-plan; echo "код выхода: $?"
   ```

2. Поправь метку ВМ «в консоли» (через `yc`, как это сделал бы коллега):

   ```bash
   yc compute instance update notes-vm --labels env=manual
   ```

3. Снова проверь план:

   ```bash
   make infra-plan; echo "код выхода: $?"
   ```

4. Приведи реальность к коду (решение «код прав»):

   ```bash
   terraform -chdir=infra/terraform/envs/dev apply
   ```

**Что должно получиться:**

```text
No changes. Your infrastructure matches the configuration.
код выхода: 0
```

После ручной правки:

```text
  # yandex_compute_instance.notes will be updated in-place
  ~ resource "yandex_compute_instance" "notes" {
      ~ labels = {
          ~ "env" = "manual" -> "dev"
        }
    }

Plan: 0 to add, 1 to change, 0 to destroy.
make: *** [Makefile:6: infra-plan] Error 2
код выхода: 2
```

Имя ресурса и метки могут отличаться, если в 7.2 ты назвал их иначе: ищи `~` и `Plan: 0 to add, 1 to change`.

**Объясни себе:**

- Откуда Terraform узнал о правке, если код и state не менялись?
- Когда верным решением будет не `apply`, а правка кода?
- Что было бы, если бы кто-то в консоли удалил ВМ?

**Типичные ошибки:**

- `ERROR: rpc error: code = NotFound desc = Instance with name notes-vm not found`: имя ВМ в облаке другое: `yc compute instance list`.
- `Error: Failed to query available provider packages`: реестр недоступен из сети: зеркало из урока 7.3.
- `Error: Error acquiring the state lock`: предыдущий запуск не завершился: см. задание 3.

### Задание 3. Прерванный apply и замок state

**Цель:** понять, что происходит с state и блокировкой, если `apply` оборвали.

**Предскажи:**

1. Если прервать `apply` через Ctrl+C, останется ли замок state?
2. Удалятся ли уже созданные ресурсы?

<details>
<summary>Ответ</summary>

1. При одном Ctrl+C Terraform штатно завершает текущую операцию и снимает замок. При жёстком обрыве (второй Ctrl+C, `kill -9`, отключение сети) замок остаётся.
2. Нет. Созданные ресурсы остаются, state записывает то, что успело создаться. Terraform не откатывает, он доводит состояние следующим `apply`.

</details>

**Шаги:**

1. Измени в коде `envs/dev` что-то долгое (например, размер диска данных, если он у тебя есть) и запусти:

   ```bash
   terraform -chdir=infra/terraform/envs/dev apply
   ```

2. Ответь `yes` и сразу нажми Ctrl+C один раз. Дождись завершения.
3. Проверь, что осталось:

   ```bash
   terraform -chdir=infra/terraform/envs/dev plan
   ```

4. Заверши работу:

   ```bash
   terraform -chdir=infra/terraform/envs/dev apply
   ```

**Что должно получиться:**

```text
Interrupt received.
Please wait for Terraform to exit or data loss may occur.
Gracefully shutting down...
```

Следующий `plan` показывает остаток работы, а не ошибку, `apply` доводит его до `Apply complete!`.

**Объясни себе:**

- Почему Terraform не откатывает частично применённые изменения?
- Чем опасно `terraform force-unlock` и когда он оправдан?
- Как связаны замок и remote state из урока 7.3?

**Типичные ошибки:**

- `Error: Error acquiring the state lock`: замок держит другой процесс или остался после обрыва: сначала убедись, что никто не применяет, затем `terraform force-unlock <ID>` с ID из сообщения.

### Задание 4. Проверки до плана: fmt, validate, trivy

**Цель:** прогнать локально то же, что будет выполнять CI, и поймать ошибку на стадии, где нужны нулевые секреты.

**Предскажи:** какая из трёх проверок ничего не знает о твоём облаке и запустится на чужой машине без ключей?

<details>
<summary>Ответ</summary>

Все три: `fmt`, `validate` (с `init -backend=false`) и `trivy config` работают только с файлами. Секреты нужны лишь для `plan`.

</details>

**Шаги:**

1. Форматирование:

   ```bash
   terraform fmt -check -recursive infra/terraform; echo "код: $?"
   ```

2. Валидация без доступа к бакету:

   ```bash
   terraform -chdir=infra/terraform/envs/dev init -backend=false
   terraform -chdir=infra/terraform/envs/dev validate
   ```

3. Статический анализ (Trivy установлен по уроку 3.4):

   ```bash
   trivy config --severity HIGH,CRITICAL --exit-code 1 infra/terraform
   ```

4. Специально испорти `vm.tf` (лишний пробел в отступе) и повтори шаг 1, затем исправь командой `terraform fmt -recursive infra/terraform`.

**Что должно получиться:**

```text
Success! The configuration is valid.
```

Для `trivy config` при чистом коде отчёт пустой и код выхода 0. Если есть SSH на `0.0.0.0/0`, Trivy покажет HIGH с номером правила и строкой: это надо исправить (ограничить `v4_cidr_blocks` своим адресом) или явно принять и задокументировать.

**Объясни себе:**

- Почему `validate` не заменяет `plan`?
- Почему `trivy` может ругаться на то, что «работает»?

**Типичные ошибки:**

- `Error: Backend initialization required, please run "terraform init"`: не было `init`: выполни шаг 2.
- `Terraform exited with code 3.`: `fmt -check` нашёл неформатированные файлы: `terraform fmt -recursive`.
- `FATAL	Fatal error	config scan error: scan error: scan failed`: неверный путь к каталогу: проверь, что запускаешь из `~/notes`.

### Задание 5. Шаг проекта: workflow с ночной проверкой drift

**Цель:** перенести проверки в CI, добавить ночной plan на drift, закоммитить `Makefile` и workflow.

**Предскажи:** job ночного plan увидит код 2. Какой статус будет у прогона в GitHub и что произойдёт дальше?

<details>
<summary>Ответ</summary>

Шаг с plan вернёт ненулевой код, job станет красным, GitHub пришлёт уведомление о падении запланированного workflow владельцу. Ничего не применяется и не откатывается: мы получили сигнал, разбираться будет человек.

</details>

**Шаги:**

1. Создай `.github/workflows/terraform.yml`:

{% raw %}
   ```yaml
   name: terraform

   on:
     pull_request:
       paths: ["infra/terraform/**"]
     schedule:
       - cron: "0 2 * * *"   # каждую ночь, 02:00 UTC
     workflow_dispatch:

   permissions:
     contents: read

   jobs:
     static:
       # Проверки без секретов: fmt, validate, trivy
       runs-on: ubuntu-24.04
       steps:
         - uses: actions/checkout@v4
         - uses: hashicorp/setup-terraform@v3
           with:
             terraform_version: 1.16.4
         - name: fmt
           run: terraform fmt -check -recursive infra/terraform
         - name: validate
           run: |
             terraform -chdir=infra/terraform/envs/dev init -backend=false
             terraform -chdir=infra/terraform/envs/dev validate
         - name: trivy config
           uses: aquasecurity/trivy-action@0.33.1
           with:
             scan-type: config
             scan-ref: infra/terraform
             severity: HIGH,CRITICAL
             exit-code: "1"

     drift:
       # Ночной plan: код выхода 2 значит "есть drift", job красный
       if: github.event_name != 'pull_request'
       needs: static
       runs-on: ubuntu-24.04
       env:
         YC_TOKEN: ${{ secrets.YC_TOKEN }}
         AWS_ACCESS_KEY_ID: ${{ secrets.STATE_ACCESS_KEY }}
         AWS_SECRET_ACCESS_KEY: ${{ secrets.STATE_SECRET_KEY }}
       steps:
         - uses: actions/checkout@v4
         - uses: hashicorp/setup-terraform@v3
           with:
             terraform_version: 1.16.4
         - name: init
           run: terraform -chdir=infra/terraform/envs/dev init -input=false
         - name: plan на drift
           run: terraform -chdir=infra/terraform/envs/dev plan -input=false -lock=false -detailed-exitcode
   ```
{% endraw %}

   Версию `trivy-action` и способ получения `YC_TOKEN` проверь актуальную на страницах проектов. Для учебного стенда токен кладут в `Settings -> Secrets`, в реальной работе его заменяют на короткоживущий токен через OIDC (урок 3.4). Ключи S3 нужны только для чтения state.

2. Проверь синтаксис YAML и коммит:

   ```bash
   python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/terraform.yml')); print('yaml ok')"
   git add Makefile .github/workflows/terraform.yml
   git commit -m "infra: make infra-* и workflow terraform (drift)"
   ```

3. В интерфейсе GitHub открой Actions, workflow `terraform`, нажми `Run workflow` (`workflow_dispatch`) и дождись результата.

**Что должно получиться:**

```text
yaml ok
[main 3f2a9c1] infra: make infra-* и workflow terraform (drift)
 2 files changed, 78 insertions(+)
```

Эталон: [project/notes/](https://github.com/distinguished-sre/devops/tree/devops/project/notes/) в репозитории курса. В Actions job `static` зелёный, `drift` зелёный при отсутствии расхождений и красный после ручной правки из задания 2.

**Объясни себе:**

- Почему `-lock=false` допустим для ночного plan, а для `apply` нет?
- Чем плох токен со сроком жизни в год в secrets?

**Типичные ошибки:**

- `Error: Invalid workflow file: ... You have an error in your yaml syntax`: смещён отступ: проверь `python3 -c` из шага 2.
- `Error: No valid credential sources found`: не заданы secrets для бэкенда: `Settings -> Secrets and variables -> Actions`.
- `Error: Failed to get existing workspaces: ... AccessDenied`: у ключа нет прав чтения на бакет state: роль `storage.viewer` на бакет.

## Сломай и почини

Поломку делаешь сам, по описанию. Меняешь ты только реальность (облако, процесс), код в git остаётся прежним.

### Симптом

Выбери один из трёх сценариев.

1. После пересоздания ВМ (`terraform apply -replace=yandex_compute_instance.notes`) `make infra-up` падает: `UNREACHABLE! ... Permission denied (publickey)` или `Connection timed out`.
2. Ты прервал `apply` посередине (`kill -9`), и следующий запуск пишет `Error acquiring the state lock`.
3. Ночная проверка красная, но в коде за неделю никто ничего не менял. В plan видно, что `ingress` группы безопасности отличается от кода.

### Гипотезы

Для каждого сценария запиши минимум две гипотезы до проверок. Например для первого: (а) inventory хранит старый IP, (б) новая ВМ ещё грузится, (в) в `known_hosts` старый отпечаток хоста на этот адрес.

### Проверки

- Сценарий 1: сравни `terraform output -raw public_ip` с `ansible_host` в `inventory.yml`; проверь `ssh ubuntu@<ip>` вручную.
- Сценарий 2: прочитай ID и владельца замка в сообщении об ошибке; проверь, что другой `terraform` не запущен (`ps aux | grep terraform`); посмотри `plan`, что осталось недоделано.
- Сценарий 3: `terraform plan` покажет, что именно поменялось; в журнале аудита облака (Audit Trails) найди, кто и когда менял группу.

### Исправление

<details>
<summary>Разбор всех сценариев</summary>

1. Inventory устарел: IP нового ВМ другой. Причина в том, что inventory писали один раз руками. Исправление: генерировать его в цели `infra-up` из `terraform output` (как в задании 1) и не редактировать вручную. Если ошибка `REMOTE HOST IDENTIFICATION HAS CHANGED`, удали старую запись: `ssh-keygen -R <ip>`.
2. Замок остался после жёсткого обрыва. Убедись, что никто не применяет, затем `terraform force-unlock <ID>`, потом `plan` и доведи `apply`. Профилактика: прерывай один раз Ctrl+C и жди, а в CI задавай `timeout` job и не убивай процесс.
3. Drift: кто-то открыл порт в консоли. Решай осознанно. Если правка нужна навсегда, внеси её в код через pull request. Если нет, `apply` вернёт правило по коду. В обоих случаях запиши причину, а чтобы не повторялось, ограничь права на ручные правки в консоли.

</details>

## Вопросы с собеседований

### 1. [junior] Что такое drift в Terraform и как его обнаружить?

Drift это расхождение между кодом и реальной инфраструктурой, например ручная правка в консоли. `terraform plan` делает refresh и показывает разницу. В CI запускаю `plan -detailed-exitcode` по расписанию: код 2 значит, что есть расхождение.

**Что хотят услышать:** refresh, `-detailed-exitcode` и значения кодов, проверка по расписанию, только план без apply.

**Красный флаг:** «drift это когда версия Terraform устарела».

### 2. [middle] Ночной plan показал изменения, а в git ничего не менялось. Твои действия?

Читаю diff: что изменилось и на каком ресурсе. В журнале аудита облака нахожу автора и время. Дальше решение: если это аварийная правка нужна, переношу в код через PR, если нет, откатываю `apply`. Фиксирую причину и закрываю пути ручных правок правами.

**Что хотят услышать:** сначала выяснить причину, не применять вслепую, аудит, процесс (PR), профилактика правами.

**Красный флаг:** «просто запущу apply, и всё встанет как надо».

### 3. [junior] Как связать Terraform и Ansible?

Terraform создаёт ВМ и отдаёт IP через output. Скрипт или Makefile пишет по нему inventory, ждёт SSH и запускает плейбук. Terraform отвечает за существование ресурсов, Ansible за настройку внутри.

**Что хотят услышать:** граница ответственности, output -> inventory, ожидание SSH, порядок шагов.

**Красный флаг:** «настрою всё через `remote-exec` provisioner».

### 4. [middle] После пересоздания ВМ Ansible не подключается. Что проверишь?

Сначала совпадает ли IP в inventory с текущим output. Затем доступность порта 22 и группа безопасности, ключ на новой ВМ, и не осталась ли в `known_hosts` старая запись. Проверяю ручным `ssh -v`, потом чиню причину, а не повторяю запуск.

**Что хотят услышать:** устаревший inventory, `wait_for_connection`, `ssh -v`, `known_hosts`, генерация inventory.

**Красный флаг:** «пересоздам ВМ ещё раз».

### 5. [middle] `apply` оборвался на середине. Что со state и что делать?

Созданные ресурсы остаются, state содержит то, что успело записаться. Откатов нет. Проверяю замок, смотрю `plan` и довожу `apply`. Если замок завис и никто не работает, `force-unlock` с ID из ошибки.

**Что хотят услышать:** нет отката, `plan` как источник истины, замок и осторожный `force-unlock`, remote state.

**Красный флаг:** «удалю state и начну заново» (это осиротит реальные ресурсы).

### 6. [junior] Immutable или mutable инфраструктура: в чём разница?

При mutable сервер правят на месте, при immutable заменяют новым из образа. Immutable исключает накопление ручных правок и упрощает откат, но требует образов и внешних данных. Mutable проще старт, но появляется drift внутри ОС.

**Что хотят услышать:** замена вместо правки, откат, drift внутри ОС, цена подхода (Packer, балансировщик).

**Красный флаг:** «immutable значит, что данные не меняются».

### 7. [middle] Как построишь CI для Terraform-репозитория?

На pull request без секретов: `fmt -check`, `validate`, `trivy config`. Затем plan и публикация результата в PR. По расписанию ночной plan на drift. `apply` только после ревью и по защищённой ветке, а креды короткоживущие через OIDC.

**Что хотят услышать:** порядок проверок, plan в PR, apply после ревью, секреты и OIDC, drift-job.

**Красный флаг:** «`apply` автоматически на каждый push».

### 8. [middle] Кто-то удалил ВМ в консоли. Что покажет plan и что сделаешь?

Refresh не найдёт ресурс, plan предложит создать ВМ заново (`+`). Перед `apply` проверю, что пересоздание безопасно: адрес, данные на диске, привязки. Потом `make infra-up`, и Ansible настроит новую ВМ. Данные нужно восстанавливать из бэкапа.

**Что хотят услышать:** ресурс появится в плане как create, данные не возвращаются сами, второй шаг Ansible, бэкап.

**Красный флаг:** «Terraform восстановит и данные».

### 9. [middle] Как понять, что настройка ВМ не разошлась с Ansible-кодом?

Запускаю `ansible-playbook site.yml --check --diff`. Для идемпотентной роли итог `changed=0`, а ненулевой `changed` означает drift внутри ОС.

**Что хотят услышать:** `--check --diff`, `changed=0`, ограничения check-режима у `command` и `shell`.

**Красный флаг:** «перезапускаю плейбук раз в день, и всё».

### 10. [junior] Зачем `-detailed-exitcode` и какие у него коды?

Без флага `plan` возвращает 0 и при изменениях, и без них. С флагом: 0 нет изменений, 1 ошибка, 2 есть изменения. Это основа автоматической проверки drift.

**Что хотят услышать:** три кода, применение в CI, различие ошибки и drift.

**Красный флаг:** «код 1 это drift».

## Проверено на версиях

- Terraform: 1.16.4
- OpenTofu: 1.12.6 (совместимая замена, команды `tofu`)
- провайдер `yandex-cloud/yandex`: версия не закреплена, проверь актуальную версию на странице проекта
- Ansible: версия ansible-core не закреплена, проверь актуальную версию на странице проекта
- Trivy: версия не закреплена, проверь актуальную версию на странице проекта
- GitHub Actions `hashicorp/setup-terraform`: v3, `aquasecurity/trivy-action`: проверь актуальную версию на странице проекта
- «Заметки»: образ 0.4.1
- Ubuntu: 26.04 LTS или 24.04

## Итог урока: ты умеешь

- [ ] умею одной командой `make infra-up` создать ВМ, дождаться SSH и настроить её Ansible
- [ ] умею генерировать inventory из `terraform output`
- [ ] умею вызвать и прочитать drift через `plan -detailed-exitcode`
- [ ] умею решить, что верно при drift: код или ручная правка
- [ ] умею действовать после оборванного `apply` и зависшего замка state
- [ ] умею настроить в CI `fmt`, `validate`, `trivy config` и ночной plan
- [ ] умею объяснить разницу между mutable и immutable инфраструктурой
- [ ] умею снести стенд командой `make infra-down`

**Дальше:** [Тема 8: Наблюдаемость](../08-observability/index.md)
