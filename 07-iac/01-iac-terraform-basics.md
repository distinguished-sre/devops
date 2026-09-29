---
layout: lesson
title: "IaC и Terraform: ресурс, план, состояние"
topic: 7
lesson: "7.1"
time: "2 ч"
---

## Зачем это нужно

В теме 6 ты создавал сеть и ВМ командами `yc` и кликами в консоли. Через месяц никто не вспомнит, какой именно командой создан этот диск, а повторить окружение для теста придётся по памяти. Инфраструктура как код (Infrastructure as Code, IaC) решает это: желаемое состояние описано в файлах, лежит в Git, а инструмент сам сравнивает описание с реальностью и показывает план изменений до того, как что-то тронет.

На работе это ежедневная рутина: ревью изменений сети в pull request, `plan` в CI, откат через `git revert`. На собеседовании про Terraform спросят про state, drift и опасный `-/+` в плане.

Шаг проекта: в репозитории «Заметок» появляется `infra/terraform/` с `versions.tf`, `providers.tf`, `network.tf`: сеть и подсеть `notes` описаны кодом, state пока локальный.

## Что нужно знать

- [Урок 1.3: права](../01-linux/03-users-permissions.md) - права на файлы, чтобы понимать, почему state нельзя оставлять доступным всем
- [Урок 3.1: основы Git](../03-git-ci/01-git-basics.md) - `.gitignore` и коммиты: код инфраструктуры живёт в Git, а state нет
- [Урок 6.1: облако и соответствие AWS](../06-cloud/01-cloud-models-aws-mapping.md) - аккаунт, каталог `notes`, сервисный аккаунт
- [Урок 6.2: ВМ, сеть и диски](../06-cloud/02-vm-network-storage.md) - сеть и подсеть, которые ты делал руками, теперь опишем кодом

## Теория

### Декларативный и императивный подход

Императивный скрипт (bash с `yc vpc network create`) описывает шаги: «создай, потом создай, потом добавь». Запусти его дважды и получишь ошибку «уже существует» или дубликат. Декларативное описание говорит, что должно быть в итоге: «есть сеть `notes` и подсеть 10.0.1.0/24». Инструмент сам вычисляет разницу с реальностью и делает минимум действий. Повторный запуск ничего не меняет: это идемпотентность (idempotency).

Terraform от HashiCorp работает именно так. Лицензия с 2023 года Business Source License (BSL), не открытая. Открытый форк называется OpenTofu (Linux Foundation): команды идентичны, вместо `terraform` пишешь `tofu`. В уроке пишем `terraform`; всё сказанное относится и к OpenTofu, а различия появятся только в теме 7.3 (шифрование state есть лишь в OpenTofu).

> **Проверь понимание:** ты запустил скрипт создания сети дважды. Что будет, если бы то же самое было описано в Terraform?

<details>
<summary>Ответ</summary>

Второй `apply` увидел бы, что реальность совпадает с описанием, и сказал бы `No changes`. Скрипт же упадёт с ошибкой или создаст дубль: он не знает текущего состояния, он просто выполняет шаги.

</details>

### Из чего состоит конфигурация

Terraform читает все файлы `*.tf` в каталоге как одно целое на языке HCL (HashiCorp Configuration Language). Основные блоки:

- `terraform { ... }` - требования: версия самого Terraform и версии провайдеров;
- провайдер (provider) - плагин, который умеет говорить с API конкретной платформы: `yandex-cloud/yandex`, `hashicorp/local`, `hashicorp/random`;
- ресурс (resource) - один управляемый объект: `resource "тип" "имя" { ... }`;
- источник данных (data source) - только чтение существующего;
- ссылка `тип.имя.атрибут` - и она же неявная зависимость: Terraform сам поймёт, что подсеть создаётся после сети.

Файлы принято делить по смыслу (`versions.tf`, `providers.tf`, `network.tf`), но для Terraform имена файлов не важны.

> **Проверь понимание:** в подсети написано `network_id = yandex_vpc_network.notes.id`. Что это даёт кроме значения?

<details>
<summary>Ответ</summary>

Неявную зависимость: сначала создаётся сеть, потом подсеть; при удалении порядок обратный. Порядок в файле роли не играет.

</details>

### Цикл работы: init, plan, apply, destroy

1. `terraform init` скачивает провайдеры в `.terraform/` и пишет `.terraform.lock.hcl` (точные версии и хеши провайдеров; этот файл коммитят).
2. `terraform fmt` приводит код к стандартному виду, `terraform validate` проверяет синтаксис и ссылки без обращения к API.
3. `terraform plan` читает код, state и реальность, показывает разницу. Ничего не меняет.
4. `terraform apply` показывает план ещё раз и после `yes` применяет.
5. `terraform destroy` удаляет всё, что записано в state.

Символы в плане: `+` создать, `-` удалить, `~` изменить на месте (in-place), `-/+` удалить и создать заново (replace). Последний знак опасен: для диска или БД это потеря данных. Читай каждый `-/+` глазами.

### State: память Terraform

Terraform не спрашивает облако «что у меня есть»: он помнит созданное в файле состояния (state), по умолчанию `terraform.tfstate` рядом с кодом. В нём для каждого ресурса записаны идентификатор в облаке и все атрибуты. Отсюда три следствия:

- потерял state - Terraform считает, что ничего не создавал, и попытается создать всё заново (дубли);
- state содержит атрибуты открытым текстом, включая пароли и ключи: он секретный, в Git его не коммитят (`*.tfstate*` уже есть в `.gitignore` проекта с урока 3.1);
- два человека с локальными state расходятся; лечится общим хранилищем с блокировкой, это урок [7.3](03-terraform-state-modules.md).

Дрейф (drift) - расхождение между state и реальностью, например кто-то удалил или поправил ресурс в консоли. `plan` обновляет сведения из API (refresh) и покажет дрейф как изменение.

> **Проверь понимание:** почему state нельзя коммитить, даже если репозиторий приватный?

<details>
<summary>Ответ</summary>

В нём секреты в открытом виде, а история Git хранит их вечно. Кроме того, state меняется при каждом apply, и коммиты будут конфликтовать. Хранить надо в удалённом бэкенде с блокировкой и шифрованием.

</details>

### Соответствие AWS

| Что | Yandex Cloud | AWS | Ресурс Terraform (Yandex / AWS) |
|---|---|---|---|
| Сеть | VPC network | VPC | `yandex_vpc_network` / `aws_vpc` |
| Подсеть | VPC subnet (одна зона) | Subnet | `yandex_vpc_subnet` / `aws_subnet` |
| Правила доступа | Security group | Security group | `yandex_vpc_security_group` / `aws_security_group` |
| ВМ | Compute instance | EC2 | `yandex_compute_instance` / `aws_instance` |
| Бакет | Object Storage | S3 | `yandex_storage_bucket` / `aws_s3_bucket` |
| Идентичность | Сервисный аккаунт | IAM role / user | `yandex_iam_service_account` / `aws_iam_role` |

Подход тот же: `init`, `plan`, `apply`, state. Меняются только провайдер и имена ресурсов.

## Практика

Задания 1-4 идут без облака и без денег: провайдеры `local` и `random` создают файлы на твоём диске, а цикл `plan`/`apply`/state работает так же, как с облаком. Задание 5 применяет то же к сети «Заметок» в Yandex Cloud.

### Задание 1. Установка и первый ресурс

**Цель:** установить Terraform 1.16.4 и создать файл через ресурс.

**Предскажи:** сколько ресурсов покажет первый `plan` для одного `local_file` и что будет, если сразу запустить `plan` второй раз после `apply`?

<details>
<summary>Ответ</summary>

Первый `plan`: `1 to add, 0 to change, 0 to destroy`. После `apply` повторный `plan` скажет `No changes`: реальность совпала с описанием.

</details>

**Шаги:**

1. Установи Terraform из репозитория HashiCorp (без `curl | bash`):

   ```bash
   # Ключ репозитория и сам репозиторий
   sudo apt-get update && sudo apt-get install -y gnupg wget ca-certificates
   wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
   echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo "$VERSION_CODENAME") main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
   sudo apt-get update && sudo apt-get install -y terraform=1.16.4-1
   terraform version
   ```

   Сноска: OpenTofu 1.12.6 ставится по его инструкции, команды `tofu init/plan/apply` те же. Если репозиторий HashiCorp недоступен из твоей сети, поставь OpenTofu.

2. Создай рабочий каталог и конфигурацию:

   ```bash
   mkdir -p ~/tf-lesson && cd ~/tf-lesson
   ```

   ```hcl
   # main.tf
   terraform {
     required_version = ">= 1.5"
     required_providers {
       local = {
         source  = "hashicorp/local"
         version = "~> 2.5"
       }
     }
   }

   # Ресурс: файл на диске. Тип "local_file", локальное имя "hello"
   resource "local_file" "hello" {
     filename = "${path.module}/hello.txt"
     content  = "Привет из Terraform\n"
   }
   ```

3. Пройди цикл:

   ```bash
   terraform init
   terraform fmt
   terraform validate
   terraform plan
   terraform apply
   cat hello.txt
   terraform plan
   ```

**Что должно получиться:**

```text
Plan: 1 to add, 0 to change, 0 to destroy.
...
local_file.hello: Creating...
local_file.hello: Creation complete after 0s [id=...]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

После `cat` видишь строку «Привет из Terraform», а последний `plan` печатает `No changes. Your infrastructure matches the configuration.`

**Объясни себе:**

- Что появилось в каталоге после `init` и что из этого нужно коммитить?
- Почему второй `plan` пустой?

**Типичные ошибки:**

- `Error: Unsupported Terraform Core version`: установленный Terraform не подходит под `required_version`: обнови или поправь ограничение.
- `Error: Inconsistent dependency lock file`: изменил версию провайдера, не запустив `init`: выполни `terraform init -upgrade`.
- `Error: Failed to query available provider packages ... connection timed out`: реестр недоступен из сети: используй зеркало (тема 7.3) или OpenTofu.

### Задание 2. Изменение: in-place или replace

**Цель:** научиться отличать безопасное изменение от пересоздания.

**Предскажи:** если поменять `content` у `local_file`, будет `~` или `-/+`? А если поменять `filename`?

<details>
<summary>Ответ</summary>

Оба раза `-/+` (`must be replaced`): у `local_file` эти атрибуты не изменяются на месте, провайдер удаляет файл и создаёт новый. `~` (update in-place) увидишь у ресурсов вроде описания подсети или тегов. Знак в плане зависит от ресурса и провайдера, поэтому план читают всегда.

</details>

**Шаги:**

1. Поменяй `content` на `"Привет, версия 2\n"` и запусти `terraform plan`. Найди `-/+` и `# forces replacement`.
2. Примени и убедись: `cat hello.txt`.

**Что должно получиться:**

```text
  # local_file.hello must be replaced
-/+ resource "local_file" "hello" {
      ~ content  = "Привет из Terraform\n" -> "Привет, версия 2\n" # forces replacement
...
Plan: 1 to add, 0 to change, 1 to destroy.
```

**Объясни себе:**

- Почему для базы данных `-/+` это авария, а для файла нет?
- Что означает `forces replacement` и как узнать, какой атрибут его вызвал?

**Типичные ошибки:**

- `Error: Provider produced inconsistent result after apply`: ошибка провайдера или несовместимая версия: зафиксируй версию и обнови в `versions.tf`.
- `Error: Reference to undeclared resource`: опечатка в имени ссылки: имя берётся из `resource "тип" "имя"`.

### Задание 3. Drift: удалили руками

**Цель:** увидеть, как Terraform обнаруживает расхождение и чинит его.

**Предскажи:** ты удалил `hello.txt` командой `rm`. Что покажет `plan` и что сделает `apply`?

<details>
<summary>Ответ</summary>

`plan` увидит, что ресурса нет: `Objects have changed outside of Terraform` и `1 to add`. `apply` создаст файл заново с содержимым из кода.

</details>

**Шаги:**

1. `rm hello.txt`
2. `terraform plan`
3. `terraform apply`, затем `cat hello.txt`.

**Что должно получиться:**

```text
Note: Objects have changed outside of Terraform

  # local_file.hello has been deleted
...
Plan: 1 to add, 0 to change, 0 to destroy.
```

**Объясни себе:**

- Кто «прав» при расхождении: код или реальность? Что делать, если ручная правка была нужной?
- Почему drift опасен в облаке, где правят в консоли на пожаре?

**Типичные ошибки:**

- `Error: Invalid function argument`: в `file()` указан путь, которого нет: проверь `path.module`.
- `Error: Provider configuration not present`: ресурс остался в state, а его провайдер убран из кода: верни провайдер или удали ресурс через `terraform state rm`.

### Задание 4. Что внутри state

**Цель:** прочитать state и понять, почему он секретный.

**Предскажи:** попадёт ли в `terraform.tfstate` значение, которое ты пометил как секретное?

<details>
<summary>Ответ</summary>

Да. `sensitive` скрывает значение только в выводе `plan` и `output`, а в state оно лежит открытым текстом. Поэтому state защищают правами и шифрованием хранилища.

</details>

**Шаги:**

1. Добавь в `required_providers` строку `random = { source = "hashicorp/random", version = "~> 3.6" }`, выполни `terraform init -upgrade` и добавь ресурс со «секретом»:

   ```hcl
   resource "random_password" "db" {
     length  = 16
     special = false
   }

   output "db_password" {
     value     = random_password.db.result
     sensitive = true
   }
   ```

2. `terraform apply`, затем:

   ```bash
   terraform state list
   terraform show | head -20
   terraform output db_password
   grep -c '"result"' terraform.tfstate
   ls -l terraform.tfstate
   ```

3. Проверь `.gitignore`: рядом с кодом создай файл:

   ```bash
   printf '.terraform/\n*.tfstate\n*.tfstate.*\n*.tfvars\ncrash.log\n' > .gitignore
   ```

**Что должно получиться:**

```text
local_file.hello
random_password.db
...
1
-rw-r--r-- 1 user user ... terraform.tfstate
```

Строка `"result"` присутствует в state, значит пароль там читается глазами. Права `644`: любой пользователь машины прочтёт.

**Объясни себе:**

- Что лежит в state, кроме паролей, и зачем это Terraform?
- Что и почему коммитится (`.terraform.lock.hcl`), а что нет?

**Типичные ошибки:**

- `Error: Output refers to sensitive values`: вывод содержит секрет, но не помечен: добавь `sensitive = true`.
- `fatal: ... tfstate` в `git status` как «новый файл»: `.gitignore` создан после добавления: `git rm --cached terraform.tfstate`.

### Задание 5. Шаг проекта: сеть «Заметок» кодом

**Цель:** описать сеть и подсеть `notes` в `~/notes/infra/terraform/`, применить и снести.

**Предскажи:** сколько ресурсов создаст `apply` и в каком порядке, если подсеть ссылается на сеть?

<details>
<summary>Ответ</summary>

Два ресурса: сначала `yandex_vpc_network.notes`, затем `yandex_vpc_subnet.notes`. Порядок следует из ссылки `network_id`.

</details>

**Шаги:**

1. Подготовь доступ. Нужен сервисный аккаунт из урока 6.1 и его ключ. Токен передаётся окружением, в код не пишется:

   ```bash
   mkdir -p ~/notes/infra/terraform && cd ~/notes/infra/terraform
   # Временный IAM-токен (живёт до 12 часов), в файлы не записываем
   export YC_TOKEN=$(yc iam create-token)
   export YC_CLOUD_ID=$(yc config get cloud-id)
   export YC_FOLDER_ID=$(yc config get folder-id)
   ```

2. `versions.tf`:

   ```hcl
   terraform {
     required_version = ">= 1.5"

     required_providers {
       yandex = {
         source  = "yandex-cloud/yandex"
         # Версию провайдера проверь на странице проекта и зафиксируй по факту
         version = "~> 0.130"
       }
     }
   }
   ```

3. `providers.tf`:

   ```hcl
   # Токен, облако и каталог приходят из переменных окружения YC_*
   provider "yandex" {
     zone = "ru-central1-a"
   }
   ```

4. `network.tf`:

   ```hcl
   # Сеть «Заметок»
   resource "yandex_vpc_network" "notes" {
     name = "notes"
   }

   # Подсеть в одной зоне; ссылка на сеть задаёт порядок создания
   resource "yandex_vpc_subnet" "notes" {
     name           = "notes"
     zone           = "ru-central1-a"
     network_id     = yandex_vpc_network.notes.id
     v4_cidr_blocks = ["10.0.1.0/24"]
   }
   ```

5. Применяй и проверяй:

   ```bash
   terraform init
   terraform fmt -check
   terraform validate
   terraform plan
   terraform apply
   yc vpc subnet list
   ```

6. Убедись, что state не попадёт в Git, и закоммить код:

   ```bash
   cd ~/notes
   git status --short infra/
   git add infra/terraform/*.tf infra/terraform/.terraform.lock.hcl
   git commit -m "infra: сеть и подсеть notes в Terraform"
   ```

7. Сеть и подсеть бесплатны, оставь их для урока 7.2.

**Что должно получиться:**

```text
Plan: 2 to add, 0 to change, 0 to destroy.
...
yandex_vpc_network.notes: Creation complete after 2s [id=enp...]
yandex_vpc_subnet.notes: Creation complete after 1s [id=e9b...]

Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
```

`yc vpc subnet list` показывает подсеть `notes` с `10.0.1.0/24`, `git status` не упоминает `terraform.tfstate` и `.terraform/`.

**Объясни себе:**

- Откуда провайдер берёт учётные данные и почему их нельзя писать в `providers.tf`?
- Что произойдёт, если сеть `notes` уже создана руками в уроке 6.2 и ты запустишь `apply`?

**Типичные ошибки:**

- `Error: Failed to query available provider packages ... could not connect to registry.terraform.io`: реестр недоступен из сети: зеркало провайдеров разберём в 7.3.
- `Error: cannot get IAM token / unauthenticated`: токен не задан или истёк: повтори `export YC_TOKEN=$(yc iam create-token)`.
- `Error: Cannot create network: Quota limit vpc.networks.count exceeded`: в облаке уже много сетей (в том числе созданных руками в 6.2): удали лишние через `yc vpc network delete`.
- `Error: ... network with name notes already exists`: сеть создана руками: удали её или импортируй в state (тема 7.3).

## Сломай и почини

Запусти сценарий и не читай его код: `break/7.1/break.sh` поломает окружение, а ты диагностируешь. Запуск: `bash ~/notes/break/7.1/break.sh <n>` (n от 1 до 3), разбор ниже.

### Симптом

Три ситуации:

1. `terraform apply` отвечает `Error: Error acquiring the state lock`.
2. Кто-то поправил ресурс в консоли, а следующий `apply` вернул старое значение.
3. Тебе поменяли параметр диска в коде, и `plan` показывает `-/+` для диска с данными.

### Гипотезы

1. Другой процесс держит блокировку: коллега, CI или зависший предыдущий `apply`.
2. Правка в консоли не в коде, а Terraform приводит реальность к коду.
3. Атрибут не меняется на месте, провайдер пересоздаёт ресурс.

### Проверки

```bash
terraform plan                          # кто держит блокировку (Who, Created)
terraform plan -refresh-only            # что изменилось вне кода
terraform plan | grep -B3 'forces replacement'
```

### Исправление

<details>
<summary>Разбор трёх сценариев</summary>

**1. State lock.** Сообщение содержит `Lock Info` с `ID`, `Who`, `Operation` и временем. Если процесс жив, подожди или `-lock-timeout=60s`. Если процесс умер (закрыли терминал, упал CI), проверь, что никто не применяет, и снимай блокировку: `terraform force-unlock <ID>`. Не снимай блокировку, пока не убедился, что другой apply не идёт: два записывающих процесса испортят state.

**2. Drift.** `terraform plan -refresh-only` покажет расхождения, не меняя инфраструктуру. Решение: если правка нужна, перенеси её в код и сделай `apply`; если нет, `apply` вернёт по коду. Правила: в консоли не правят, а если правили, то догоняют кодом в тот же день.

**3. Replace затирает диск.** Читай план: `-/+` и `forces replacement` рядом с атрибутом. Перед apply возвращай значение или защищай ресурс блоком `lifecycle { prevent_destroy = true }` (подробно в 7.2). Данные сначала снапшотом (урок 6.5), потом изменение.

</details>

## Вопросы с собеседований

### 1. [junior] Что такое state в Terraform и где его хранить?

State это файл с соответствием «ресурс в коде, объект в облаке» и всеми атрибутами. Без него Terraform не знает, что создал. Локально его держат только на учёбе, на работе в удалённом бэкенде (S3-бакет, GitLab) с блокировкой и шифрованием.

**Что хотят услышать:** секретность, remote backend, lock, версионирование бакета.

**Красный флаг:** «state коммитим в Git, чтобы всем был доступен».

### 2. [junior] Чем отличается `plan` от `apply` и зачем нужен первый?

`plan` вычисляет разницу между кодом, state и реальностью и ничего не меняет. `apply` выполняет изменения. Так изменения проверяют глазами и в pull request до применения.

**Что хотят услышать:** ревью плана, сохранённый план в CI, `-auto-approve` только осознанно.

**Красный флаг:** «apply сам покажет, что делает, план не нужен».

### 3. [middle] В плане на прод есть `-/+` для диска с данными. Твои действия?

Останавливаюсь и не применяю. Ищу `forces replacement`, какой атрибут вызвал пересоздание. Возвращаю его в коде или делаю изменение вне Terraform. Перед любыми правками снапшот диска, добавляю `prevent_destroy`.

**Что хотят услышать:** чтение плана, снапшот, lifecycle, `-target` как крайняя мера.

**Красный флаг:** «подтвержу, Terraform всё пересоздаст».

### 4. [middle] `apply` падает: `Error acquiring the state lock`. Что делаешь?

Читаю Lock Info: кто и когда. Проверяю, что не идёт чужой apply или CI-задача. Если жив, жду. Если процесс мёртв, `terraform force-unlock <ID>` и потом `plan`.

**Что хотят услышать:** не снимать блокировку вслепую, причина (упавший CI, закрытый терминал).

**Красный флаг:** «удалю tfstate и запущу заново».

### 5. [middle] Коллега поправил группу безопасности в консоли. Что произойдёт при следующем apply?

Terraform сравнит реальность с кодом и вернёт значение из кода: это drift. Правку в консоли можно потерять, поэтому сначала `plan -refresh-only`, решаем, переносить ли её в код.

**Что хотят услышать:** drift, refresh-only, процесс: изменения только через код и PR.

**Красный флаг:** «Terraform подхватит изменения из консоли сам».

### 6. [middle] Потеряли state, а ресурсы в облаке живы. Что делать?

Восстановить из версии бакета или бэкапа. Если нет, `terraform import` для каждого ресурса и сверка через `plan` до состояния `No changes`. Создавать заново нельзя: получим дубли и конфликты имён.

**Что хотят услышать:** версионирование бакета, `import`, `plan` как проверка.

**Красный флаг:** «apply создаст всё заново».

### 7. [junior] Что делает `.terraform.lock.hcl` и коммитят ли его?

Фиксирует точные версии провайдеров и их хеши. Коммитят: у всей команды и CI одинаковые провайдеры. Обновляют осознанно через `terraform init -upgrade`.

**Что хотят услышать:** воспроизводимость, supply chain.

**Красный флаг:** «файл генерируется, в `.gitignore` его».

### 8. [junior] Terraform или OpenTofu: в чём разница?

Форк после смены лицензии HashiCorp на BSL в 2023 году. Синтаксис и провайдеры совместимы, команда `tofu`. У OpenTofu встроенное шифрование state. Выбор зависит от политики компании.

**Что хотят услышать:** лицензия BSL против MPL, совместимость, что миграция обычно простая.

**Красный флаг:** «это два совершенно разных языка».

### 9. [middle] `terraform apply` прервался на середине (упала сеть). Что со state и что делать?

Terraform записывает в state то, что успело создаться. Запускаю `plan`: он покажет недостающее. Если ресурс создан, но не записан, помогает `import`. Повторный `apply` доведёт до цели: это следствие идемпотентности.

**Что хотят услышать:** state отражает частичный результат, повторный apply безопасен.

**Красный флаг:** «сделаю destroy и начну заново» без анализа.

### 10. [middle] Как в CI проверять Terraform-код в pull request?

`fmt -check`, `validate`, `plan` с публикацией результата в PR, сканер конфигураций (trivy config, tfsec), apply только после merge и ревью. Токены через секреты CI, не в коде.

**Что хотят услышать:** plan в PR, отдельные права на apply, статический анализ.

**Красный флаг:** «apply прямо из ветки на ноутбуке».

## Проверено на версиях

- Terraform: 1.16.4
- OpenTofu: 1.12.6 (совместимая замена, команды `tofu`)
- провайдер `hashicorp/local`: версия не закреплена, проверь актуальную версию на странице проекта
- провайдер `hashicorp/random`: версия не закреплена, проверь актуальную версию на странице проекта
- провайдер `yandex-cloud/yandex`: версия не закреплена, проверь актуальную версию на странице проекта
- Ubuntu: 26.04 LTS и 24.04

## Итог урока: ты умеешь

- [ ] умею объяснить декларативный подход и идемпотентность на примере
- [ ] умею пройти цикл `init`, `fmt`, `validate`, `plan`, `apply`, `destroy`
- [ ] умею читать план и отличать `~` от `-/+` и находить `forces replacement`
- [ ] умею находить drift и решать, чинить его кодом или переносить правку в код
- [ ] умею объяснить, что лежит в state, почему он секретный и почему не в Git
- [ ] умею снять зависшую блокировку, убедившись, что apply не идёт
- [ ] умею описать сеть и подсеть «Заметок» в `infra/terraform/`

**Дальше:** [Урок 7.2: Terraform: переменные, ВМ и outputs](02-terraform-vm-variables.md)
