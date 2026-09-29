---
layout: lesson
title: "Terraform: remote state, модули, окружения"
topic: 7
lesson: "7.3"
time: "2 ч"
---

## Зачем это нужно

Пока state (файл состояния) лежит у тебя на ноутбуке, инфраструктура принадлежит одному человеку: коллега не увидит, что уже создано, а два одновременных `apply` могут испортить состояние. Потеря ноутбука означает потерю карты ресурсов, которые продолжают стоить денег. Копипаста кода для dev и stage быстро расходится, и окружения перестают быть похожими.
Общий state в бакете с блокировкой и модуль (module), из которого собираются окружения, это базовый уровень командной работы с Terraform. Про это спрашивают на собеседованиях.

Шаг проекта: state «Заметок» переезжает в бакет Object Storage, сеть и ВМ выносятся в модуль `infra/terraform/modules/notes-vm`, а окружение `dev` вызывает этот модуль.

## Что нужно знать

- [Урок 7.1: IaC и Terraform](01-iac-terraform-basics.md) - план, apply, что такое state и почему он хранит секреты.
- [Урок 7.2: переменные, ВМ и outputs](02-terraform-vm-variables.md) - файлы `variables.tf`, `vm.tf`, `outputs.tf`, которые мы переносим в модуль.
- [Урок 6.1: облачные модели и соответствие AWS](../06-cloud/01-cloud-models-aws-mapping.md) - сервисные аккаунты и ключи доступа.
- [Урок 6.2: ВМ, сеть, хранилище](../06-cloud/02-vm-network-storage.md) - как выглядят сеть, ВМ и группа безопасности руками.
- [Урок 3.1: основы Git](../03-git-ci/01-git-basics.md) - `.gitignore`, почему `*.tfstate` не коммитят.

## Теория

### Remote state и блокировка

По умолчанию state (`terraform.tfstate`) лежит рядом с кодом. Для одного человека это работает, для команды ломается по трём причинам: файла нет у коллег, он содержит секреты (пароли, ключи) открытым текстом и в git его класть нельзя, а параллельные запуски перетирают друг друга.

Remote backend (удалённое хранилище состояния) решает всё сразу: state лежит в общем месте, доступ выдаётся правами, в бакете включено версионирование, а перед изменениями Terraform берёт блокировку (state lock). Пока один `apply` держит блокировку, второй получит `Error acquiring the state lock` и не тронет состояние.

Для S3-совместимых хранилищ (Yandex Object Storage, AWS S3, MinIO) используется backend `s3`. Блокировка бывает двух видов:

- Старый способ: отдельная таблица DynamoDB (в Yandex это YDB в режиме, совместимом с DynamoDB). Нужен лишний ресурс.
- Новый способ: параметр `use_lockfile = true`. Блокировка живёт файлом `<ключ>.tflock` рядом со state в том же бакете (появился в Terraform 1.10). Работает, если хранилище поддерживает условную запись объектов. Для Yandex Object Storage не считай это очевидным, а проверь на своём бакете (задание 2).

Backend не может использовать переменные: имя бакета и ключ пишутся в коде буквально или передаются через `-backend-config`.

> **Проверь понимание:** почему нельзя положить `terraform.tfstate` в git, даже если репозиторий приватный?

<details>
<summary>Ответ</summary>

Во-первых, в state значения ресурсов лежат открытым текстом, включая пароли и ключи, а круг людей с доступом к репозиторию шире, чем к секретам. Во-вторых, у git нет блокировки: два человека закоммитят разные версии, а слить state-файл merge'ем нельзя. В-третьих, история git навсегда сохранит секрет, даже если файл потом удалить.

</details>

### Соответствие AWS

| Что делаем | Yandex Cloud | AWS |
|---|---|---|
| Бакет для state | Object Storage | S3 |
| Блокировка (старый способ) | YDB (Document API) | DynamoDB |
| Ключи для backend | статический ключ сервисного аккаунта | IAM access key |
| Права на state | роль на бакет | IAM policy на бакет |
| Шифрование | ключ Yandex KMS | SSE-KMS |
| Провайдер | `yandex-cloud/yandex` | `hashicorp/aws` |
| Backend в коде | `backend "s3"` с `endpoints` | `backend "s3"` |

Backend `s3` один и тот же. Отличается адрес endpoint и несколько флагов, отключающих проверки, специфичные для AWS.

### Модули

Модуль (module) это каталог с `.tf` файлами, который вызывают из другого места блоком `module`. У него есть входные переменные (`variable`), ресурсы и выходные значения (`output`). Корневой модуль (root module) это каталог, из которого ты запускаешь `terraform`; у нас это `envs/dev`.

```hcl
module "notes_vm" {
  source = "../../modules/notes-vm"   # путь до каталога модуля

  env     = "dev"
  cores   = 2
  ssh_key = var.ssh_key
}
```

Правила, которые спасают на практике:

- Модуль знает только то, что ему передали. Он не читает чужой state и не берёт переменные снаружи.
- Наружу выдаёт только `output`. Можно `module.notes_vm.public_ip`, нельзя `module.notes_vm.yandex_compute_instance.notes_vm`.
- Выносить в модуль стоит то, что повторяется хотя бы дважды (dev и stage) и меняется вместе. Модуль на один ресурс без логики это лишний слой.
- Версию модуля фиксируют. У локального `source` версии нет, поэтому правка модуля сразу видна всем окружениям. Для модуля из git пишут `?ref=v1.2.0`, для реестра `version = "~> 1.2"`.

> **Проверь понимание:** ты переименовал ресурс внутри модуля. Что покажет `plan`?

<details>
<summary>Ответ</summary>

Адрес ресурса изменился, поэтому Terraform предложит удалить старый и создать новый (для ВМ это потеря машины). Чтобы этого избежать, добавляют блок `moved { from = ..., to = ... }`: он сообщает, что ресурс тот же и просто сменил адрес.

</details>

### Окружения: каталоги или workspaces

Есть два подхода разделить dev и stage.

- Каталоги: `envs/dev/`, `envs/stage/`. У каждого свой `backend.tf` и свой state, общий код лежит в модулях. Многословно, зато на экране видно, где ты, и права на state можно разделить (dev открыт всем, prod только CI).
- Workspaces: один код, много state в одном backend (`terraform workspace new stage`). Компактно, но текущий workspace не виден в коде, легко применить изменения не туда, а права на бакет общие.

Команды чаще выбирают каталоги, а workspaces оставляют для одинаковых временных копий (например, окружение на время ревью). В курсе идём через каталоги.

### Импорт и потеря state

Если state потерян или ресурс создан руками, Terraform о нём не знает: `apply` попытается создать дубликат и упадёт на конфликте имён. Два пути.

1. Восстановить state из версии бакета (версионирование включают заранее). Самый быстрый способ.
2. Заново привязать существующие ресурсы: `terraform import <адрес> <id>`. В Terraform 1.5 и новее то же можно записать блоком `import` в коде. Импорт не пишет код: описание ресурса создаёшь сам и добиваешься `No changes`.

> **Проверь понимание:** после `terraform import` команда `plan` показывает изменения. Что это значит?

<details>
<summary>Ответ</summary>

Код не совпадает с реальным ресурсом: импорт положил в state настоящие значения, а в коде другие. Правь код, пока `plan` не покажет `No changes`, либо осознанно применяй, если ресурс нужно привести к коду.

</details>

### Зеркало провайдеров в РФ

Провайдеры скачиваются с `registry.terraform.io`, а доступность оттуда из России нестабильна. Решение: зеркало провайдеров (provider mirror). В файле `~/.terraformrc` указывают, откуда качать `yandex-cloud/yandex`. Адрес зеркала меняется, поэтому в примере он помечен: проверь актуальный адрес в документации Yandex Cloud по Terraform.

## Практика

Работаем в `~/notes/infra/terraform`. Файлы `versions.tf`, `providers.tf`, `network.tf`, `variables.tf`, `vm.tf`, `outputs.tf` уже есть из уроков 7.1 и 7.2. Нужны Terraform, `yc` с настроенным профилем и SSH-ключ из [урока 6.2](../06-cloud/02-vm-network-storage.md).

Трек без облака: вместо Object Storage поднимается MinIO в контейнере (версия не закреплена, проверь актуальный образ). Backend настраивается так же, меняется только `endpoints.s3`.

### Задание 1. Бакет и ключ для state

**Цель:** создать бакет с версионированием и отдельный ключ, которым Terraform будет ходить в него.

**Предскажи:** можно ли создать бакет для state тем же Terraform? Ответ: нет, state бакета должен лежать в бакете, которого ещё нет (курица и яйцо), поэтому его создают вручную.

**Шаги:**

1. Создай бакет. Имя уникально на весь облачный провайдер, добавь свой суффикс:

```bash
export TF_BUCKET="notes-tfstate-CHANGE_ME"
yc storage bucket create --name "$TF_BUCKET"
```

2. Включи версионирование, чтобы иметь путь назад при порче state:

```bash
yc storage bucket update --name "$TF_BUCKET" --versioning versioning-enabled
```

3. Создай сервисный аккаунт для state (права на бакет выдай по документации `yc storage bucket update --help`, только на этот бакет, не на весь каталог):

```bash
yc iam service-account create --name notes-tf-state
```

4. Выпусти статический ключ и передай его окружению. Значения не печатай и не коммить:

```bash
yc iam access-key create --service-account-name notes-tf-state --format json > ~/.notes-tf-key.json
chmod 600 ~/.notes-tf-key.json
export AWS_ACCESS_KEY_ID="$(jq -r .access_key.key_id ~/.notes-tf-key.json)"
export AWS_SECRET_ACCESS_KEY="$(jq -r .secret ~/.notes-tf-key.json)"
```

**Что должно получиться:**

```bash
yc storage bucket get --name "$TF_BUCKET" --format json | jq '{name, versioning}'
```

```text
{
  "name": "notes-tfstate-CHANGE_ME",
  "versioning": "VERSIONING_ENABLED"
}
```

**Объясни себе:**

1. Почему права выдаются на бакет, а не на весь каталог?
2. Чем утечка этого ключа опаснее утечки одного `terraform.tfstate` без ключей?

**Типичные ошибки:**

- `ERROR: rpc error: code = AlreadyExists desc = Bucket already exists`: имя занято кем-то другим. Добавь уникальный суффикс.
- `jq: command not found`: не установлен `jq`. Поставь `sudo apt install jq`.
- Ключ попал в git: считай его скомпрометированным, отзови (`yc iam access-key delete`) и выпусти новый.

### Задание 2. Миграция state в бакет и проверка блокировки

**Цель:** перенести локальный state в бакет и убедиться, что второй параллельный запуск не пройдёт.

**Предскажи:** если в бакете по этому ключу уже лежит чужой state, что сделает `terraform init -migrate-state`?

<details>
<summary>Ответ</summary>

Terraform спросит, перезаписать ли существующий state локальным. Он ничего не склеивает. Ответ `yes` затрёт чужое состояние, поэтому читай вопрос и при сомнении отвечай `no`.

</details>

**Шаги:**

1. В `infra/terraform` создай `backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket = "notes-tfstate-CHANGE_ME"   # то же имя, что в TF_BUCKET
    key    = "notes/dev/terraform.tfstate"
    region = "ru-central1"

    endpoints = {
      s3 = "https://storage.yandexcloud.net"
    }

    # блокировка файлом в бакете; полагайся на неё только после проверки ниже
    use_lockfile = true

    # проверки, специфичные для AWS, в Yandex не нужны
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
```

2. Перенеси state и ответь `yes` на вопрос о копировании:

```bash
terraform init -migrate-state
```

3. Проверь, что state теперь в бакете:

```bash
yc storage s3api list-objects --bucket "$TF_BUCKET" --format json | jq -r '.contents[].key'
terraform state list
```

4. Проверь блокировку. В первом терминале запусти `apply` и не отвечай на вопрос `Enter a value`:

```bash
terraform apply
```

Во втором терминале (с теми же `AWS_*` переменными):

```bash
terraform plan
```

5. В первом терминале ответь `no`. Повтори `plan` во втором: теперь он проходит.

**Что должно получиться:** во втором терминале, пока первый ждёт ответа:

```text
Error: Error acquiring the state lock

Lock Info:
  ID:        3d2c6a1e-7f0b-4b5e-9d3a-0c6f7c1e2a44
  Path:      notes-tfstate-CHANGE_ME/notes/dev/terraform.tfstate
  Operation: OperationTypeApply
  Who:       user@laptop
```

Точный текст первой строки зависит от версии. Если второй `plan` прошёл без ошибки, хранилище не поддержало условную запись и `use_lockfile` тебя не защищает: запускай Terraform только из CI с очередью и не полагайся на флаг.

**Объясни себе:**

1. Где физически лежит блокировка и что будет с ней, если процесс `terraform` убить?
2. Почему `skip_*` флаги нужны для Yandex, но их не нужно копировать в конфиг для настоящего AWS?

**Типичные ошибки:**

- `Error: Failed to get existing workspaces: ... InvalidAccessKeyId`: в этом терминале не выставлены `AWS_ACCESS_KEY_ID` и `AWS_SECRET_ACCESS_KEY`. Экспортируй их заново.
- `Error: Unsupported argument ... "endpoint"`: старый синтаксис. В Terraform 1.10 и новее пиши `endpoints = { s3 = "..." }`.
- `Error: Backend initialization required, please run "terraform init"`: после правки `backend.tf` не выполнен `init`.

### Задание 3. Модуль notes-vm и окружение dev

**Цель:** вынести сеть и ВМ в модуль и вызвать его из `envs/dev`, не пересоздавая ресурсы.

**Предскажи:** если просто перенести файлы в модуль и вызвать его на том же state, что покажет `plan`: `No changes` или пересоздание? Что произошло с адресами ресурсов?

<details>
<summary>Ответ</summary>

Адреса стали вида `module.notes_vm.yandex_vpc_network.notes`. Для Terraform это новые ресурсы, а старые исчезли, поэтому `plan` предложит удалить всё и создать заново. Чтобы этого не случилось, нужны блоки `moved` (или `terraform state mv`).

</details>

**Шаги:**

1. Создай структуру и перенеси файлы. Резервная копия state уже есть в бакете (версионирование), локально сделай ещё одну:

```bash
cd ~/notes/infra/terraform
terraform state pull > /tmp/notes-state-before-module.json   # страховка перед переездом
mkdir -p modules/notes-vm envs/dev
git mv network.tf variables.tf vm.tf outputs.tf modules/notes-vm/
git mv versions.tf providers.tf backend.tf envs/dev/
```

После переезда удали страховочный файл, он содержит секреты: `rm /tmp/notes-state-before-module.json`.

2. В `modules/notes-vm/variables.tf` оставь переменные, зависящие от окружения (`env`, `cores`, `ssh_key`, каждая с `type` и `description`), а в `modules/notes-vm/outputs.tf` объяви `output "public_ip"` со значением `yandex_compute_instance.notes_vm.network_interface[0].nat_ip_address`.

3. Вызов модуля из окружения4. Вызов модуля из окружения, файл `envs/dev/main.tf`:

```hcl
module "notes_vm" {
  source = "../../modules/notes-vm"

  env     = "dev"
  cores   = 2
  ssh_key = var.ssh_key
}

output "public_ip" {
  value = module.notes_vm.public_ip
}
```

4. Блоки `moved` лежат в корневом модуле, где менялись адреса. Файл `envs/dev/moved.tf` (повтори блок для каждого своего ресурса):

```hcl
moved {
  from = yandex_vpc_network.notes
  to   = module.notes_vm.yandex_vpc_network.notes
}

moved {
  from = yandex_compute_instance.notes_vm
  to   = module.notes_vm.yandex_compute_instance.notes_vm
}
```

5. Добавь `variable "ssh_key" { type = string }` в `envs/dev/variables.tf`, значение передай через окружение, затем проверь план:

```bash
export TF_VAR_ssh_key="$(cat ~/.ssh/id_ed25519.pub)"
cd envs/dev
terraform init
terraform plan
```

6. Второе окружение делается по образцу: скопируй `envs/dev` в `envs/stage`, поменяй `key` в backend на `notes/stage/terraform.tfstate` и `env = "stage"`, удали `moved.tf`. Модуль один, состояний два.

**Что должно получиться:** `plan` показывает перемещения, а не пересоздание:

```text
Terraform will perform the following actions:

  # yandex_vpc_network.notes has moved to module.notes_vm.yandex_vpc_network.notes
    resource "yandex_vpc_network" "notes" {
        id   = "enp7example0000000000"
        name = "notes"
    }

Plan: 0 to add, 0 to change, 0 to destroy.
```

**Объясни себе:**

1. Почему `moved` пишут в корневом модуле, а не внутри вызываемого?
2. Что будет с `envs/stage`, если ты поменяешь код модуля? Как защититься от этого в команде?

**Типичные ошибки:**

- `Error: Module not installed`: после добавления блока `module` не выполнен `terraform init`.
- `Error: Unsupported argument ... An argument named "cores" is not expected here`: в модуле нет `variable "cores"`.
- `Error: Reference to undeclared module`: имя в ссылке (`module.notes_vm`) не совпадает с именем блока `module`.

### Задание 4. Зеркало провайдеров и lock-файл

**Цель:** настроить установку провайдера через зеркало и зафиксировать версии.

**Предскажи:** какой файл появится после `init` и почему его коммитят, а каталог `.terraform/` нет?

<details>
<summary>Ответ</summary>

Появится `.terraform.lock.hcl` с версиями и хешами провайдеров. Его коммитят, чтобы у всех и в CI стояли одни и те же версии. Каталог `.terraform/` это скачанные бинарники и кэш, он собирается заново и в git не нужен.

</details>

**Шаги:**

1. Создай `~/.terraformrc`. Адрес зеркала в примере условный, проверь актуальный адрес в документации Yandex Cloud:

```hcl
provider_installation {
  network_mirror {
    url     = "https://terraform-mirror.yandexcloud.net/"   # проверь актуальный адрес
    include = ["registry.terraform.io/yandex-cloud/*"]
  }
  direct {
    exclude = ["registry.terraform.io/yandex-cloud/*"]
  }
}
```

2. Пересобери провайдеры и проверь код без применения:

```bash
cd ~/notes/infra/terraform/envs/dev
rm -rf .terraform
terraform init -upgrade
terraform fmt -recursive ../..
terraform validate
```

**Что должно получиться:**

```text
Success! The configuration is valid.
```

В `git status` `.terraform.lock.hcl` виден как новый файл: его нужно добавить в коммит.

**Объясни себе:**

1. Зачем в `direct` исключён провайдер Yandex, а остальные качаются напрямую?
2. Что произойдёт, если удалить `.terraform.lock.hcl` и запустить `init` через месяц?

**Типичные ошибки:**

- `Error: Failed to query available provider packages ... no available releases match the given constraints`: нужной версии провайдера нет на зеркале. Ослабь ограничение в `versions.tf` или смени зеркало.
- `Error: Failed to install provider ... context deadline exceeded`: registry недоступен, а зеркало не подхватилось. Проверь опечатки в `~/.terraformrc`.

### Задание 5. Шаг проекта: инфраструктура «Заметок» в git

**Цель:** зафиксировать в `~/notes` модуль, окружение `dev` и backend.

**Предскажи:** какие файлы из `infra/terraform` должны попасть в коммит, а какие нет?

<details>
<summary>Ответ</summary>

В коммит: `modules/notes-vm/*.tf`, `envs/dev/*.tf` (включая `backend.tf` и `moved.tf`) и `.terraform.lock.hcl`. Не в коммит: `.terraform/`, `*.tfstate*`, `*.tfvars` с секретами. Файл ключа `~/.notes-tf-key.json` лежит вне репозитория.

</details>

**Шаги:**

1. Проверь структуру:

```bash
cd ~/notes
find infra/terraform -type f -not -path '*/.terraform/*' | sort
```

2. Убедись, что `dev` не хочет ничего менять:

```bash
cd infra/terraform/envs/dev
terraform plan -detailed-exitcode
echo "код выхода: $?"
```

3. Закоммить:

```bash
cd ~/notes
git add infra/terraform
git commit -m "infra: модуль notes-vm, окружение dev, state в Object Storage"
git push
```

**Что должно получиться:** `terraform plan` без изменений (набор файлов может отличаться от твоего, если в 7.2 были дополнительные):

```text
No changes. Your infrastructure matches the configuration.
код выхода: 0
```

 Эталон: [infra/terraform в репозитории курса](https://github.com/distinguished-sre/devops/tree/devops/project/notes/infra/terraform).

**Объясни себе:**

1. Что означает код выхода 2 у `plan -detailed-exitcode`?
2. Почему `backend.tf` лежит в `envs/dev`, а не в модуле?

**Типичные ошибки:**

- `fatal: pathspec 'infra/terraform' did not match any files`: ты не в репозитории `~/notes`.
- В `git status` виден `terraform.tfstate`: в `.gitignore` нет `*.tfstate*` (правило из [урока 3.1](../03-git-ci/01-git-basics.md)). Добавь шаблон и убери файл из индекса: `git rm --cached`.

## Сломай и почини

Сценарии ручные: ломаешь командами, разбор в `<details>`. Работай в `envs/dev`.

### Симптом

Выбери сценарий и воспроизведи:

1. Конфликт state. В одном терминале запусти `terraform apply` и не отвечай, во втором сделай то же самое. Убей первый процесс через `kill -9` и повтори `terraform plan`.
2. `Error: Backend configuration changed`. Поменяй в `backend.tf` `key` на `notes/dev2/terraform.tfstate` и запусти `terraform plan`.
3. Потеря state. Удали объект state из бакета: `yc storage s3api delete-object --bucket "$TF_BUCKET" --key notes/dev/terraform.tfstate`, затем `terraform plan`.

### Гипотезы

- Сценарий 1: блокировка осталась от убитого процесса, либо кто-то ещё реально работает.
- Сценарий 2: state лежит в другом месте, а Terraform помнит старый backend в `.terraform/`.
- Сценарий 3: Terraform видит пустой state и хочет создать всё заново.

### Проверки

```bash
# объекты в бакете (файл блокировки, версии state)
yc storage s3api list-objects --bucket "$TF_BUCKET" --format json | jq -r '.contents[].key'
# что Terraform помнит о backend
jq '.backend.config' .terraform/terraform.tfstate
```

### Исправление

<details>
<summary>Разбор сценариев</summary>

**1. Блокировка от убитого процесса.** Убедись, что никто больше не работает (спроси в чате, посмотри `Who` в сообщении). Затем сними блокировку по ID из ошибки:

```bash
terraform force-unlock 3d2c6a1e-7f0b-4b5e-9d3a-0c6f7c1e2a44
```

Дальше запусти `plan`: state мог остаться в промежуточном состоянии. `force-unlock` опасен, потому что разрешает параллельный `apply`. Хороший процесс: запуски идут только из CI с очередью.

**2. Backend configuration changed.** Terraform заметил, что описание backend не совпадает с запомненным, и не гадает, что ты хотел. Два честных варианта:

```bash
# перенести state в новое место
terraform init -migrate-state
# переключиться на другое место без копирования
terraform init -reconfigure
```

Ошибка защищает от ситуации, когда `plan` пойдёт по пустому state и предложит создать всё заново.

**3. Потеря state.** Сначала попробуй восстановить предыдущую версию объекта из бакета (см. `list-object-versions`, скачай нужную версию и загрузи её как текущую). Если версий нет, ресурсы живы в облаке, а Terraform о них не знает. Тогда код у тебя уже есть, остаётся импортировать:

```bash
terraform import module.notes_vm.yandex_vpc_network.notes <id сети из yc vpc network list>
terraform import module.notes_vm.yandex_compute_instance.notes_vm <id ВМ из yc compute instance list>
terraform plan
```

Повторяй импорт для каждого ресурса, пока `plan` не покажет `No changes`. Вывод: версионирование бакета включают до аварии, а не после.

</details>

## Вопросы с собеседований

### 1. [junior] Зачем хранить state Terraform удалённо и что такое блокировка?

Локальный файл нельзя разделить с командой, и в нём лежат секреты. Удалённый state живёт в общем бакете с версионированием и доступом по правам. Блокировка не даёт двум `apply` работать одновременно: второй ждёт или падает с `Error acquiring the state lock`.

**Что хотят услышать:** секреты в state, общий источник правды, версионирование как страховка, lock, S3 плюс DynamoDB или `use_lockfile`.

**Красный флаг:** «храним state в git, репозиторий же приватный».

### 2. [middle] Второй `apply` упал с `Error acquiring the state lock`. Что делаешь?

Читаю сообщение: `Who`, `Operation`, время. Выясняю, работает ли владелец блокировки. Если запуск живой, жду. Если процесс убит или связь оборвалась, снимаю блокировку `terraform force-unlock <ID>` и сразу делаю `plan`, потому что state мог остаться в промежуточном состоянии.

**Что хотят услышать:** сначала выяснить, кто держит, потом `force-unlock`, после него `plan`, запуски через CI.

**Красный флаг:** «сразу `-lock=false` и применяю».

### 3. [middle] Кто-то удалил файл state из бакета. Что делаешь?

Проверяю версионирование бакета и восстанавливаю предыдущую версию объекта. Если версий нет, ресурсы в облаке живы, а state пуст: сверяю код и делаю `terraform import` по каждому ресурсу, пока `plan` не покажет `No changes`. `apply` на пустом state не запускаю, иначе получу дубликаты или конфликт имён.

**Что хотят услышать:** версионирование, import, не запускать `apply` на пустом state, ограничение прав на запись в бакет.

**Красный флаг:** «создам всё заново, старые ресурсы удалю руками».

### 4. [middle] После переноса кода в модуль `plan` хочет удалить и создать ВМ. Почему и как исправить?

Поменялись адреса ресурсов (появился префикс `module.<имя>`), а Terraform сопоставляет ресурсы по адресу. Исправляю блоками `moved` в корневом модуле или командой `terraform state mv`. После этого `plan` показывает только перемещение.

**Что хотят услышать:** адрес ресурса, `moved`, `state mv`, чтение плана до `apply`.

**Красный флаг:** «применил, ВМ пересоздалась, ничего страшного».

### 5. [middle] После правки `backend.tf` `plan` пишет `Backend configuration changed`. Чем `-migrate-state` отличается от `-reconfigure`?

Terraform сравнил конфиг backend с запомненным в `.terraform/` и требует явного решения. `-migrate-state` копирует state из старого места в новое. `-reconfigure` просто переключает на новый backend без копирования, это годится, когда state уже перенесли руками или он не нужен.

**Что хотят услышать:** защита от `plan` по пустому state, различие флагов, осторожность с вопросом «перезаписать?».

**Красный флаг:** «удалю `.terraform/` и всё заработает» без понимания последствий.

### 6. [middle] Когда выносить код в модуль и как версионировать модули?

Когда код повторяется и меняется вместе (dev и stage), а не на всякий случай. У модуля есть переменные и outputs, внутренности наружу не торчат. Версию фиксирую: для git `?ref=v1.2.0`, для реестра `version = "~> 1.2"`. Локальный `source` годится, пока модуль живёт в одном репозитории, но тогда правки видят все окружения, и выкатываю их через dev.

**Что хотят услышать:** интерфейс модуля, версионирование, риск «поправил модуль и сломал все окружения».

**Красный флаг:** модуль на один ресурс и ссылка на ветку `main` вместо тега.

### 7. [middle] Ресурс создан руками в консоли, его просят «взять под Terraform». Как?

Пишу описание ресурса в коде, делаю `terraform import <адрес> <id>` или блок `import` (Terraform 1.5 и новее), потом `plan` и правлю код, пока не получу `No changes`. Применяю только после этого, чтобы не изменить ресурс неожиданно.

**Что хотят услышать:** import не пишет код, цель `No changes`, осторожность с `apply`.

**Красный флаг:** «удалю и создам заново», если это база с данными.

### 8. [middle] В CI нужен `plan` на каждый pull request. Какие подводные камни?

Нужен доступ CI к state (для PR только чтение), ключи не хранятся в репозитории (OIDC или секреты CI), для последующего `apply` план сохраняют через `plan -out`. Блокировка берётся и на `plan`, поэтому параллельные PR могут мешать друг другу. Секреты в выводе плана надо маскировать.

**Что хотят услышать:** `-out`, права read-only, lock на plan, секреты в state и логах.

**Красный флаг:** «дадим CI админский ключ и отключим lock».

### 9. [middle] `terraform init` из РФ зависает на скачивании провайдера. Что делаешь?

Проверяю сеть до registry, затем настраиваю зеркало в `~/.terraformrc`: `network_mirror` для `yandex-cloud/*`, остальное напрямую. Хеши в lock-файле не дадут зеркалу подложить другую сборку. В CI использую тот же файл или кэширую каталог плагинов.

**Что хотят услышать:** `.terraformrc`, зеркало, кэш плагинов в CI, хеши в lock-файле.

**Красный флаг:** «качаю бинарник провайдера откуда попало и кладу руками».

### 10. [junior] Как разделить окружения dev и prod: workspaces или каталоги?

Каталоги с общими модулями: у каждого окружения свой backend, ключ и права, и видно, где я работаю. Workspaces компактнее, но легко перепутать текущий и применить изменения не туда, а права на бакет общие.

**Что хотят услышать:** плюсы и минусы обоих подходов, безопасность prod, права на state.

**Красный флаг:** «workspaces, потому что меньше файлов», без упоминания рисков.

### 11. [junior] Что коммитят из Terraform-каталога, а что нет?

Коммитят `.tf` файлы и `.terraform.lock.hcl` (версии и хеши провайдеров, чтобы у всех и в CI были одни версии). Не коммитят `.terraform/`, `*.tfstate*` и `*.tfvars` с секретами.

**Что хотят услышать:** воспроизводимость версий, секреты в tfvars и state.

**Красный флаг:** «lock-файл в `.gitignore`, он мешает».

## Проверено на версиях

- Terraform: версия не закреплена, проверь актуальную версию на странице проекта (для `use_lockfile` нужна 1.10 или новее)
- Провайдер `yandex-cloud/yandex`: версия не закреплена, проверь актуальную версию на странице проекта
- Yandex Cloud CLI (`yc`): версия не закреплена, проверь актуальную версию на странице проекта
- Ubuntu: 26.04 LTS и 24.04 LTS

## Итог урока: ты умеешь

- [ ] умею создать бакет с версионированием и отдельным ключом сервисного аккаунта для state
- [ ] умею перенести локальный state в S3-совместимый backend через `terraform init -migrate-state`
- [ ] умею проверить, что блокировка работает, и снять зависшую через `force-unlock`
- [ ] умею вынести сеть и ВМ в модуль и вызвать его из окружения без пересоздания ресурсов (`moved`)
- [ ] умею развести dev и stage по каталогам с отдельными state
- [ ] умею восстановить потерянный state из версии бакета или через `terraform import`
- [ ] умею настроить зеркало провайдеров в `~/.terraformrc`
- [ ] умею объяснить на собеседовании разницу между workspaces и каталогами окружений

**Дальше:** [Урок 7.4: Ansible: инвентарь, модули, ad-hoc](04-ansible-basics.md)
