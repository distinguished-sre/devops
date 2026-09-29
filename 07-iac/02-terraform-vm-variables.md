---
layout: lesson
title: "Terraform: переменные, ВМ и outputs"
topic: 7
lesson: "7.2"
time: "2 ч"
---

## Зачем это нужно

В уроке 7.1 ты описал сеть и подсеть, но значения были вписаны прямо в код. Для одной ВМ это терпимо, для трёх окружений превращается в копипасту: правишь один файл, забываешь другой. Плюс IP-адрес созданной машины нужен дальше всем (SSH, DNS, деплой), и доставать его руками из консоли облака значит снова кликать.

На работе так выглядит каждый Terraform-репозиторий: `variables.tf` со входами, `outputs.tf` с выходами, а между ними ресурсы. Здесь же первая настоящая ловушка: секрет, попавший в state.

Шаг проекта: в `infra/terraform/` появляются `variables.tf`, `vm.tf`, `cloud-init.yaml.tftpl` и `outputs.tf`: ВМ `notes-vm`, диск данных, группа безопасности, IP выдаётся через `terraform output`.

## Что нужно знать

- [Урок 7.1: IaC и Terraform](01-iac-terraform-basics.md) - `init`, `plan`, `apply`, state, ссылки между ресурсами, сеть и подсеть `notes`, которые мы используем здесь.
- [Урок 6.2: ВМ, сеть и диски в облаке](../06-cloud/02-vm-network-storage.md) - то же самое ты уже делал руками через `yc`: ВМ, диск данных, группа безопасности. Теперь это код.
- [Урок 1.3: права и sudo](../01-linux/03-users-permissions.md) - права `640 root:notes` на конфиг, которые мы зададим через cloud-init.
- [Урок 3.4: качество и безопасность в CI](../03-git-ci/04-quality-security-ci.md) - почему секреты не живут в git.

## Теория

### Переменные, locals и outputs: вход, промежуточное, выход

Каталог с `.tf` файлами устроен как функция: `variable` это аргументы, `locals` это промежуточные вычисления, `output` это возвращаемое значение.

Пример: `variable "vm_cores" { type = number, default = 2 }`. У переменной есть тип (type), значение по умолчанию (default), проверка (validation) и признак `sensitive`. Без `default` переменная обязательна: Terraform спросит её в терминале, а в CI упадёт. Значения берутся в таком порядке (последний побеждает): `default`, переменные окружения `TF_VAR_<имя>`, `terraform.tfvars`, `*.auto.tfvars`, затем `-var` и `-var-file` в порядке их записи в командной строке. Запомни главное: флаг `-var` сильнее всего, `default` слабее всего.

`locals` нужны, чтобы не повторять выражение: `local.name`. Это не вход, снаружи их не задать.

`output` печатается после `apply` и доступен командой `terraform output`. Через output инфраструктура передаёт данные дальше: IP для SSH, адрес для DNS.

> **Проверь понимание:** в `terraform.tfvars` стоит `vm_cores = 4`, а ты запустил `terraform plan -var vm_cores=8`. Сколько ядер получит ВМ?

<details>
<summary>Ответ</summary>

Восемь. Флаг `-var` приоритетнее файла `terraform.tfvars`. Файл, в свою очередь, приоритетнее переменной окружения `TF_VAR_vm_cores` и `default`.

</details>

### validation и sensitive: защита от глупостей и от утечек в вывод

Блок `validation` останавливает работу до обращения к облаку (пример ниже, в задании 1). Функция `can()` возвращает `false`, если выражение внутри падает с ошибкой: так проверяют формат.

`sensitive = true` прячет значение в выводе `plan`, `apply` и `output` (там будет `(sensitive value)`). Это защита от случайного показа в логах CI, не шифрование. В state значение всё равно записывается открытым текстом.

> **Проверь понимание:** переменная помечена `sensitive = true`. Можно ли теперь коммитить `terraform.tfstate` в git?

<details>
<summary>Ответ</summary>

Нельзя. `sensitive` скрывает значение только в выводе команд. В state оно лежит как есть, и любой, кто прочитает файл, увидит секрет. Поэтому `*.tfstate*` в `.gitignore` (добавлено в 3.1), а в командной работе state живёт в закрытом бакете (урок 7.3).

</details>

### data source и зависимости

`resource` создаёт или меняет объект, `data` только читает существующий. Так мы найдём актуальный образ Ubuntu, не вписывая его id вручную:

Зависимости Terraform строит сам по ссылкам: если ВМ использует `yandex_vpc_subnet.notes.id`, подсеть создастся раньше. Явный `depends_on` нужен редко: когда связь есть, а ссылки в коде нет (например, ресурс должен появиться после выдачи роли, id которой он не использует).

Нюанс: образ по `family` со временем меняется, а id образа у ВМ записан в state. При следующем `plan` Terraform увидит новый id и захочет пересоздать ВМ. Решение ниже, в `lifecycle`.

### count и for_each

Оба создают несколько экземпляров ресурса. `count = 3` нумерует их 0, 1, 2, а `for_each` называет их ключами карты или множества.

Разница видна при удалении. Из списка `["a", "b", "c"]` убрали `"a"`: при `count` элементы сдвигаются, `b` становится индексом 0, и Terraform пересоздаёт лишнее. При `for_each` ключи `b` и `c` остаются на месте, удаляется только `a`. Поэтому для наборов разнородных вещей (правила SG, пользователи) берут `for_each`, а `count` оставляют для «создать 0 или 1»: `count = var.enabled ? 1 : 0`.

Ограничение `for_each`: ключи должны быть известны на этапе `plan`. Если ключом служит id ещё не созданного ресурса, будет `Invalid for_each argument` (разберём в «Сломай и почини»).

> **Проверь понимание:** три правила SG созданы через `count` по списку портов `[22, 80, 443]`. Ты убрал порт 80 из середины. Что покажет `plan`?

<details>
<summary>Ответ</summary>

Индекс 1 теперь занимает порт 443, а индекс 2 исчезает. Terraform покажет изменение правила 1 (с 80 на 443) и удаление правила 2 вместо простого удаления порта 80. Для правил на живой инфраструктуре это лишние изменения и риск короткого разрыва. С `for_each` по карте `{ssh, http, https}` удалилось бы только `http`.

</details>

### lifecycle: страховка от разрушения

Блок `lifecycle` внутри ресурса меняет поведение Terraform:

- `prevent_destroy = true`: любой план, который удалит ресурс (включая `destroy`), завершится ошибкой. Ставим на диск с данными.
- `create_before_destroy = true`: новый объект создаётся до удаления старого. Нужен, когда замену нельзя делать с простоем.
- `ignore_changes = [...]`: Terraform не считает расхождением изменения этих атрибутов. Ставим на то, что меняется само или что нельзя менять пересозданием.

`prevent_destroy` защищает только от Terraform. Из консоли облака диск удалить по-прежнему можно, а из кода блок можно просто убрать. Это ремень безопасности, не сейф.

> **Проверь понимание:** зачем на диск данных ставить и `prevent_destroy`, и `auto_delete = false` при подключении к ВМ?

<details>
<summary>Ответ</summary>

Это две разные защиты. `prevent_destroy` не даёт Terraform удалить диск. `auto_delete = false` не даёт облаку удалить диск вместе с ВМ, когда ВМ пересоздаётся. Для secondary_disk это значение и так по умолчанию, но явная запись читается как намерение.

</details>

### cloud-init, templatefile и секрет в state

При создании ВМ ей передают cloud-init (user-data): описание, которое выполняется при первом запуске. Мы положим туда конфиг `/etc/notes/notes.env`. Функция `templatefile()` подставляет переменные в шаблон, а `${имя}` в шаблоне это синтаксис Terraform, не shell.

Цена решения: user-data лежит в state открытым текстом, вместе с паролем. Полностью проблему не убрать, её снижают: state в закрытом бакете (7.3), секрет берётся из хранилища во время работы сервиса (9.2), пароль из этого урока учебный и меняется после первого входа. Это долг проекта: «state Terraform с секретами», закрывается в 7.3.

### Соответствие AWS

| Что делаем | Terraform (Yandex Cloud) | AWS |
|---|---|---|
| ВМ | `yandex_compute_instance` | `aws_instance` (EC2) |
| Диск | `yandex_compute_disk` | `aws_ebs_volume` |
| Группа безопасности | `yandex_vpc_security_group` и `yandex_vpc_security_group_rule` | `aws_security_group` и `aws_vpc_security_group_ingress_rule` |
| Поиск образа | `data "yandex_compute_image"` (family) | `data "aws_ami"` (filter, most_recent) |
| Cloud-init | `metadata = { user-data = ... }` | `user_data` |
| Публичный IP | `network_interface { nat = true }` | `associate_public_ip_address` или Elastic IP |

## Практика

Все команды запускаются в `~/notes/infra/terraform/`. Нужны файлы из 7.1: `versions.tf`, `providers.tf`, `network.tf`. В `network.tf` сеть и подсеть называются `yandex_vpc_network.notes` и `yandex_vpc_subnet.notes`, авторизация провайдера идёт через переменные окружения, как в 7.1. На треке без облака читай задания как разбор кода и проверяй их через `terraform validate`; `apply` там пропусти, локальная замена ВМ описана в уроке 6.2. OpenTofu (`tofu`) принимает те же файлы и те же команды.

### Задание 1. Переменные и tfvars без секретов в git

**Цель:** вынести настраиваемые значения в `variables.tf`, а конкретные значения хранить там, где git их не увидит.

**Предскажи:**

1. Что произойдёт, если запустить `terraform plan` без значения для `my_ip_cidr`?
2. Что произойдёт при `my_ip_cidr = "0.0.0.0/0"`?

<details>
<summary>Ответ</summary>

1. У переменной нет `default`: Terraform в интерактивном режиме спросит значение, а с флагом `-input=false` (как в CI) упадёт с `No value for required variable`.
2. Сработает `validation`: план остановится с текстом `error_message` до обращения к облаку.

</details>

**Шаги:**

1. Создай `variables.tf`:

```hcl
variable "my_ip_cidr" {
  description = "Твой адрес в формате CIDR, откуда разрешён SSH"
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0)) && var.my_ip_cidr != "0.0.0.0/0"
    error_message = "Нужен CIDR вроде 203.0.113.7/32, и не весь интернет."
  }
}

variable "ssh_public_key_path" {
  description = "Путь к публичному SSH-ключу"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "image_family" {
  description = "Семейство образа ОС (для Ubuntu 26.04 найди имя командой yc compute image list --folder-id standard-images)"
  type        = string
  default     = "ubuntu-2404-lts"
}

variable "vm_cores" {
  description = "Число vCPU"
  type        = number
  default     = 2
}

variable "data_disk_gb" {
  description = "Размер диска данных, ГБ"
  type        = number
  default     = 10
}

variable "notes_db_password" {
  description = "Пароль БД «Заметок» (только через TF_VAR или tfvars вне git)"
  type        = string
  sensitive   = true
}
```

2. Узнай свой внешний адрес (`curl -s https://ifconfig.me`) и создай `terraform.tfvars` (значения подставь свои):

```bash
cat > terraform.tfvars <<'TFV'
my_ip_cidr = "203.0.113.7/32"
TFV

# Пароль не пишем в файл: передаём через окружение, только в этой сессии
export TF_VAR_notes_db_password="$(openssl rand -base64 24)"
```

3. Добавь рабочий файл значений в `.gitignore` (правило `*.tfstate*` есть с урока 3.1) и проверь оба пути. В репозиторий вместо рабочего файла кладём пример без реальных значений:

```bash
cd ~/notes
printf '%s\n' 'infra/terraform/terraform.tfvars' >> .gitignore
git check-ignore -v infra/terraform/terraform.tfvars infra/terraform/terraform.tfstate

cd ~/notes/infra/terraform
cat > terraform.tfvars.example <<'TFV'
# Скопируй в terraform.tfvars и подставь свои значения
my_ip_cidr = "203.0.113.7/32"
TFV
terraform fmt
```

**Что должно получиться:**

```text
.gitignore:14:infra/terraform/terraform.tfvars	infra/terraform/terraform.tfvars
.gitignore:6:*.tfstate*	infra/terraform/terraform.tfstate
```

Номера строк у тебя будут другие. Главное: обе проверки нашли правило.

**Объясни себе:**

- Почему пароль передан через `TF_VAR_`, а не записан в `terraform.tfvars`?
- Зачем в git лежит `.tfvars.example`, если рабочий файл игнорируется?

**Типичные ошибки:**

- `Error: No value for required variable`: не задана переменная без `default`: добавь её в `terraform.tfvars` или экспортируй `TF_VAR_...`.
- `git check-ignore` молчит и завершается с кодом 1: правило не совпало с путём: проверь путь относительно корня репозитория.

### Задание 2. ВМ, диск, группа безопасности и cloud-init как код

**Цель:** описать то, что в 6.2 ты создавал командами `yc`, и прочитать план.

**Предскажи:**

1. Сколько ресурсов покажет `plan` в строке `Plan: N to add`, если сеть и подсеть из 7.1 уже созданы?
2. Появится ли пароль в выводе `plan`?

<details>
<summary>Ответ</summary>

1. Семь: диск (1), группа безопасности (1), три правила ingress и одно egress (4), ВМ (1).
2. Нет. Пароль входит в `user-data`, а он собран из `sensitive` переменной, поэтому Terraform помечает весь атрибут как `(sensitive value)`.

</details>

**Шаги:**

1. Создай `vm.tf`:

```hcl
# Образ Ubuntu ищем по семейству: свежий id без правки кода
data "yandex_compute_image" "ubuntu" {
  family = var.image_family
}

locals {
  name = "notes-vm"

  # Правила входящего трафика: ключ это имя правила, индексы не сдвигаются
  ingress_rules = {
    ssh   = { port = 22, cidrs = [var.my_ip_cidr] }
    http  = { port = 80, cidrs = ["0.0.0.0/0"] }
    https = { port = 443, cidrs = ["0.0.0.0/0"] }
  }
}

# Диск данных живёт отдельно от ВМ и защищён от случайного destroy
resource "yandex_compute_disk" "data" {
  name = "notes-data"
  type = "network-ssd"
  zone = yandex_vpc_subnet.notes.zone
  size = var.data_disk_gb

  lifecycle {
    prevent_destroy = true
  }
}

resource "yandex_vpc_security_group" "notes" {
  name       = "notes-sg"
  network_id = yandex_vpc_network.notes.id
}

resource "yandex_vpc_security_group_rule" "ingress" {
  for_each = local.ingress_rules

  security_group_binding = yandex_vpc_security_group.notes.id
  direction              = "ingress"
  description            = "notes ${each.key}"
  protocol               = "TCP"
  port                   = each.value.port
  v4_cidr_blocks         = each.value.cidrs
}

# Наружу разрешено всё: серверу нужны пакеты и образы
resource "yandex_vpc_security_group_rule" "egress" {
  security_group_binding = yandex_vpc_security_group.notes.id
  direction              = "egress"
  description            = "notes egress"
  protocol               = "ANY"
  from_port              = 0
  to_port                = 65535
  v4_cidr_blocks         = ["0.0.0.0/0"]
}

resource "yandex_compute_instance" "notes" {
  name        = local.name
  zone        = yandex_vpc_subnet.notes.zone
  platform_id = "standard-v3"

  resources {
    cores         = var.vm_cores
    memory        = 2
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = 20
    }
  }

  secondary_disk {
    disk_id     = yandex_compute_disk.data.id
    auto_delete = false
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.notes.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.notes.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${file(pathexpand(var.ssh_public_key_path))}"
    user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      db_password = urlencode(var.notes_db_password)
    })
  }

  # Новый образ в семействе не должен пересоздавать живую ВМ
  lifecycle {
    ignore_changes = [boot_disk[0].initialize_params[0].image_id]
  }
}
```

2. Создай шаблон `cloud-init.yaml.tftpl` (доступы как в уроке 1.3: конфиг `640 root:notes`, данные `750 notes:notes`):

```yaml
#cloud-config
# Выполняется один раз, при первом запуске ВМ
write_files:
  - path: /etc/notes/notes.env
    permissions: "0600"
    owner: root:root
    content: |
      PORT=8080
      STORE=postgres
      DATABASE_URL=postgresql://notes:${db_password}@127.0.0.1:5432/notes
runcmd:
  # Системный пользователь и каталог данных
  - groupadd --system notes
  - useradd --system --gid notes --home-dir /var/lib/notes --shell /usr/sbin/nologin notes
  - install -d -m 0750 -o notes -g notes /var/lib/notes
  # Конфиг читают root и группа notes
  - chgrp notes /etc/notes/notes.env
  - chmod 0640 /etc/notes/notes.env
```

3. Проверь код и сохрани план:

```bash
terraform fmt
terraform validate
terraform plan -out=tfplan
```

**Что должно получиться:**

```text
Success! The configuration is valid.
...
Plan: 7 to add, 0 to change, 0 to destroy.
```

**Объясни себе:**

- Почему правила SG вынесены в отдельный ресурс с `for_each`, а не записаны блоками внутри SG?
- Зачем диску `prevent_destroy`, а ВМ `ignore_changes` на `image_id`?
- В каких трёх местах окажется пароль после `apply`?

**Типичные ошибки:**

- `Error: Reference to undeclared resource` про `yandex_vpc_subnet.notes`: в `network.tf` из 7.1 ресурсы названы иначе: приведи ссылки к своим именам.
- `Error: Invalid function argument ... no file exists at`: не найден публичный ключ: проверь `ls ~/.ssh/*.pub` и путь в `ssh_public_key_path`. Без `pathexpand()` символ `~` Terraform не раскроет.
- `Error: ... platform "standard-v3" ... core_fraction`: сочетание платформы, ядер и доли не допускается: оставь 2 ядра и 20%.

### Задание 3. Output, apply и вход по SSH

**Цель:** применить план, получить IP из output и зайти на ВМ, не открывая консоль облака.

**Предскажи:** сразу после `apply` запустить `terraform plan`. Что он покажет?

<details>
<summary>Ответ</summary>

`No changes. Your infrastructure matches the configuration.` Код и state совпали (идемпотентность). Если план показывает изменения без правок кода, ищи атрибут, который облако меняет само: повод для `ignore_changes`.

</details>

**Шаги:**

1. Создай `outputs.tf`:

```hcl
output "public_ip" {
  description = "Публичный IP ВМ notes-vm"
  value       = yandex_compute_instance.notes.network_interface[0].nat_ip_address
}

output "data_disk_id" {
  description = "Id диска данных"
  value       = yandex_compute_disk.data.id
}
```

2. Добавь output в план заново (файл изменился), примени и зайди по SSH:

```bash
terraform plan -out=tfplan
terraform apply tfplan
terraform output public_ip
# -raw печатает значение без кавычек: удобно для скриптов
ssh -o StrictHostKeyChecking=accept-new ubuntu@"$(terraform output -raw public_ip)" \
  'cloud-init status --wait; sudo ls -l /etc/notes/notes.env'
terraform plan
```

3. Проверь выражения в `terraform console` (выход: Ctrl+D), это чтение без изменений:

```bash
terraform console
```

```hcl
data.yandex_compute_image.ubuntu.name
urlencode("a/b+c=")
local.ingress_rules.ssh.port
```

**Что должно получиться:**

```text
Apply complete! Resources: 7 added, 0 changed, 0 destroyed.

Outputs:

data_disk_id = "fhm1abcd2efg3hijk4lm"
public_ip = "203.0.113.55"

status: done
-rw-r----- 1 root notes 96 Sep 29 10:12 /etc/notes/notes.env

No changes. Your infrastructure matches the configuration.
```

Id диска, адрес и имя образа у тебя будут другие. В консоли ожидай строку с датой образа, `"a%2Fb%2Bc%3D"` и `22`.

**Объясни себе:**

- Чем `terraform output -raw` удобнее обычного `terraform output` в скрипте?
- Что покажет `terraform plan`, если вручную удалить правило SG в консоли?

**Типичные ошибки:**

- `ssh: connect to host 203.0.113.55 port 22: Operation timed out`: SSH закрыт группой безопасности: `my_ip_cidr` это уже не твой адрес: поменяй значение и сделай `apply`.
- `ubuntu@203.0.113.55: Permission denied (publickey).`: в ВМ попал другой ключ: проверь `ssh_public_key_path` или укажи ключ явно `ssh -i ~/.ssh/id_ed25519 ...`.

### Задание 4. Шаг проекта: код инфраструктуры в репозитории и уборка

**Цель:** зафиксировать код в git без секретов и проверить, что защита диска работает.

**Предскажи:** сработает ли `terraform destroy` на такой конфигурации?

<details>
<summary>Ответ</summary>

Нет. Terraform построит план удаления, дойдёт до `yandex_compute_disk.data` и остановится с ошибкой `Instance cannot be destroyed` (`prevent_destroy`). Это защита, а не поломка.

</details>

**Шаги:**

1. Зафиксируй код и убедись, что секретов в коммите нет:

```bash
cd ~/notes
git add infra/terraform/variables.tf infra/terraform/vm.tf \
  infra/terraform/cloud-init.yaml.tftpl infra/terraform/outputs.tf \
  infra/terraform/terraform.tfvars.example infra/terraform/.terraform.lock.hcl .gitignore
git commit -m "infra: ВМ notes-vm, диск, группа безопасности и outputs в Terraform"
git ls-files infra/terraform | grep -E 'tfstate|terraform.tfvars$' || echo "чисто"
git status --short
```

2. Увидь срабатывание защиты:

```bash
cd infra/terraform
terraform destroy
```

3. Чтобы не платить за учебные ресурсы, закомментируй `prevent_destroy` в `vm.tf` (осознанно, на время) и повтори `terraform destroy`, затем проверь `yc compute instance list` и `yc compute disk list`. Верни `prevent_destroy = true` до коммита.

**Что должно получиться:**

```text
чисто
...
Error: Instance cannot be destroyed
...
Destroy complete! Resources: 9 destroyed.
```

Девять это семь ресурсов урока плюс сеть и подсеть из 7.1. В списках `yc` не должно остаться `notes-vm` и `notes-data`.

**Объясни себе:**

- Почему `.terraform.lock.hcl` коммитится, а `.terraform/` и `terraform.tfstate` нет?
- Чем `destroy` без `prevent_destroy` опасен для диска с данными?

**Типичные ошибки:**

- `Error: Instance cannot be destroyed`: сработал `prevent_destroy`: это ожидаемо; снимай блок осознанно.
- В `git status` виден `terraform.tfvars`: правило `.gitignore` не подхватило файл: проверь путь и выполни `git rm --cached infra/terraform/terraform.tfvars`.

## Сломай и почини

Сценарии выполняются вручную, командами и правками из текста. Исходное состояние: применённый код из задания 3 (если ты уже сделал `destroy`, подними его заново).

### Симптом

1. Ты хочешь создать правило SG для каждого диска, и получаешь `Error: Invalid for_each argument` на этапе `plan`.
2. `plan` показывает `-/+ destroy and then create replacement` для `notes-vm`, хотя код не менялся.
3. Ревьюер открыл Pull Request и говорит, что в репозитории лежит рабочий пароль БД.

Сценарий 1 воспроизведи временным ресурсом `yandex_vpc_security_group_rule.broken` с `for_each = toset([yandex_compute_disk.data.id])`.

Для сценария 2 закомментируй `lifecycle { ignore_changes ... }` у ВМ и сравни id образа: `terraform console` и `data.yandex_compute_image.ubuntu.id` против `terraform state show yandex_compute_instance.notes`. Для сценария 3:

```bash
grep -c 'DATABASE_URL' terraform.tfstate
```

### Гипотезы

- Сценарий 1: значение неизвестно до `apply`; опечатка в имени ресурса; неверный тип аргумента.
- Сценарий 2: изменился атрибут, который нельзя поменять на месте; кто-то правил ВМ в консоли; в семействе вышел новый образ.
- Сценарий 3: секрет попал в `tfvars`, в user-data, в state; поможет ли `sensitive`?

### Проверки

- Сценарий 1: прочитай ошибку целиком, там сказано «cannot be determined until apply».
- Сценарий 2: найди в плане атрибут с пометкой `# forces replacement`.
- Сценарий 3: `git ls-files | grep -E 'tfvars|tfstate'`, `git log -p -S'DATABASE_URL' --oneline`, и `grep` по state из симптома.

### Исправление

<details>
<summary>Разбор сценариев</summary>

**1. Invalid for_each argument.** Ошибка выглядит так:

```text
Error: Invalid for_each argument

  on vm.tf line 118, in resource "yandex_vpc_security_group_rule" "broken":
 118:   for_each = toset([yandex_compute_disk.data.id])

The "for_each" set includes values derived from resource attributes that
cannot be determined until apply, and so Terraform cannot determine the
full set of keys that will identify the instances of this resource.
```

Ключи `for_each` должны быть известны при `plan`, а id ещё не созданного диска неизвестен. Исправление: строить ключи из статичных данных (карта в `locals`, как `local.ingress_rules`), а неизвестные значения оставлять в значениях (`each.value`). Блок `broken` удали.

**2. Пересоздание ВМ.** Смена `image_id` даёт `forces replacement`: загрузочный диск ВМ на месте не подменить. Образ в семействе обновился, data source вернул новый id. Исправление: `ignore_changes = [boot_disk[0].initialize_params[0].image_id]` (есть в коде из задания 2). Если ВМ нужно обновить осознанно, делай это командой `terraform apply -replace=yandex_compute_instance.notes` и читай план до конца. Запомни и про user-data: cloud-init выполняется только при первом запуске, правка шаблона живую ВМ сама не перенастроит (в плане смотри пометку `~` или `-/+`). Такие изменения проводят конфигурацией (Ansible, [урок 7.4](04-ansible-basics.md)) или осознанной заменой ВМ.

**3. Секрет в state и в git.** `grep -c` вернёт число больше нуля: пароль лежит в state открытым текстом, потому что входит в user-data. Если `terraform.tfvars` с паролем попал в коммит, `git rm` не хватит: значение осталось в истории. Порядок: считать пароль скомпрометированным и сменить, затем очистить историю (`git filter-repo`) и включить сканер секретов в CI, как в [уроке 3.4](../03-git-ci/04-quality-security-ci.md). Профилактика: `TF_VAR_notes_db_password` из окружения, `*.tfstate*` и `terraform.tfvars` в `.gitignore`, state в закрытом бакете (7.3), а сам секрет доставлять в ВМ через хранилище (9.2). `sensitive = true` только скрывает значение в выводе.

</details>

## Вопросы с собеседований

### 1. [middle] Ты убрал один элемент из середины списка, созданного через `count`, и `plan` хочет пересоздать несколько ресурсов. Почему и что делать?

Terraform адресует экземпляры по индексу: `web[0]`, `web[1]`. Убрал элемент из середины, индексы сдвинулись, и с точки зрения state ресурсы поменялись местами. Перевожу на `for_each` по карте, чтобы ключи были стабильными, а для существующей инфраструктуры переношу адреса блоком `moved` или `terraform state mv`, чтобы ничего не пересоздавать.

**Что хотят услышать:** `count` против `for_each`, стабильные ключи, `moved`, чтение плана до `apply`.

**Красный флаг:** «просто применю и посмотрю».

### 2. [middle] Ты нашёл в репозитории закоммиченный `terraform.tfstate`, а пароль в переменной был `sensitive`. Насколько всё плохо?

Плохо: `sensitive` скрывает значение только в выводе команд, а в state оно лежит открытым текстом. Считаю пароль скомпрометированным, меняю его, убираю state из истории, добавляю `*.tfstate*` в `.gitignore`. Дальше state переезжает в закрытый бакет с шифрованием и ограниченным доступом, а секреты по возможности не проходят через Terraform вообще.

**Что хотят услышать:** state хранит секреты открытым текстом, ротация, чистка истории, remote state, внешнее хранилище секретов.

**Красный флаг:** «sensitive шифрует значение».

### 3. [middle] Прод: после `plan` видишь `-/+ destroy and then create replacement` у боевой ВМ. Твои действия?

Останавливаюсь и не применяю. Нахожу в плане строку `# forces replacement`: какой атрибут вызвал замену. Если это дрейф, например новый образ в семействе, ставлю `ignore_changes` или фиксирую образ. Если замена нужна, планирую её: данные на отдельном диске с `prevent_destroy`, при необходимости `create_before_destroy`, работа в окно.

**Что хотят услышать:** чтение плана, `forces replacement`, `ignore_changes`, отдельный диск данных, окно работ.

**Красный флаг:** «apply, потом разберёмся».

### 4. [junior] Чем `resource` отличается от `data`?

`resource` создаёт объект и ведёт его жизненный цикл, `data` только читает существующий: например, находит id актуального образа или сети, созданной другой командой. Data source ничего не создаёт и не удаляет.

**Что хотят услышать:** чтение существующего, пример (образ, сеть), выполняется во время `plan`.

**Красный флаг:** «это одно и то же, просто другой синтаксис».

### 5. [middle] `plan` падает с `Invalid for_each argument ... cannot be determined until apply`. Что это и как чинить?

Ключи `for_each` должны быть известны на этапе `plan`, а я построил их из атрибута ещё не созданного ресурса. Переделываю: ключи из статичных данных (карта в `locals` или входная переменная), неизвестные значения только в значениях. Крайняя мера: применить сначала часть через `-target`, но это разовое решение, не привычка.

**Что хотят услышать:** ключи против значений, «known after apply», `locals`, `-target` как исключение.

**Красный флаг:** «добавлю `depends_on`».

### 6. [junior] Как передать в Terraform значение переменной и что победит при конфликте?

Через `default`, `terraform.tfvars`, `*.auto.tfvars`, `-var-file`, `-var` и переменные окружения `TF_VAR_*`. Самый сильный флаг `-var`, самый слабый `default`. В CI обычно использую `TF_VAR_*`, чтобы не писать секреты в файлы.

**Что хотят услышать:** порядок приоритетов, `TF_VAR_`, секреты не в git.

**Красный флаг:** «только через файл tfvars в репозитории».

### 7. [middle] Как сделать так, чтобы случайный `terraform destroy` не снёс диск с данными?

Ставлю `lifecycle { prevent_destroy = true }` на диск, подключаю его к ВМ с `auto_delete = false`, диск живёт отдельно от ВМ. Понимаю границы: защита работает только внутри Terraform, из консоли диск удалить можно, поэтому добавляю права IAM и снапшоты по расписанию.

**Что хотят услышать:** `prevent_destroy`, отдельный диск, ограничение блока, IAM и бэкапы.

**Красный флаг:** «prevent_destroy защищает от любого удаления».

### 8. [middle] Ты изменил user-data у ВМ в Terraform, `apply` прошёл, а на машине ничего не поменялось. Почему?

Cloud-init выполняется при первом запуске. Terraform обновил метаданные (или пересоздал ВМ, смотря что показал план), но на уже работающей машине скрипт заново не запустился. Либо пересоздаю ВМ осознанно через `-replace`, либо изменения такого рода веду через Ansible, а cloud-init оставляю для начальной подготовки.

**Что хотят услышать:** cloud-init один раз, разделение «создать» и «настроить», `-replace`, Ansible.

**Красный флаг:** «значит Terraform сломан».

### 9. [middle] Коллега руками поменял правило SG в консоли. Что покажет `plan` и как поступишь?

План покажет изменение, возвращающее правило к коду: это drift. Сначала выясняю, зачем правили. Если правка нужна, переношу её в код обычным PR, если нет, `apply` вернёт состояние. Чтобы не повторялось, ограничиваю права на ручные изменения и включаю регулярный `plan`.

**Что хотят услышать:** drift, код как источник правды, PR, ограничение прав, регулярный plan.

**Красный флаг:** «просто перезапишу, не разбираясь».

### 10. [junior] Как передать IP созданной ВМ в скрипт деплоя?

Объявляю `output`, в скрипте читаю `terraform output -raw public_ip`, а для нескольких значений `terraform output -json` и `jq`. Так адрес не копируется руками из консоли.

**Что хотят услышать:** `output`, `-raw`, `-json`, `jq`, использование в inventory или деплое.

**Красный флаг:** «смотрю в консоли облака и копирую».

## Проверено на версиях

- Terraform: 1.16.4 (лицензия BSL)
- OpenTofu: 1.12.6 (совместимая замена, команды `tofu` те же)
- Провайдер `yandex-cloud/yandex`: версия не закреплена, проверь актуальную версию на странице проекта
- Ubuntu на ВМ: 24.04 LTS (для 26.04 поменяй `image_family`)
- yc CLI: версия не закреплена, проверь актуальную версию на странице проекта

## Итог урока: ты умеешь

- [ ] умею вынести значения в `variable` с `type`, `default` и `validation`
- [ ] умею передать значение через `tfvars` и `TF_VAR_` и не закоммитить секрет
- [ ] умею найти образ ОС через `data` и проверить выражение в `terraform console`
- [ ] умею описать ВМ, диск и группу безопасности с `for_each`
- [ ] умею находить в плане `forces replacement` и гасить лишнее через `ignore_changes`
- [ ] умею защитить диск данных через `prevent_destroy`
- [ ] умею получить IP через `output` и зайти на ВМ по SSH
- [ ] умею объяснить, почему `sensitive` не защищает state

**Дальше:** [Урок 7.3: Terraform: remote state, модули, окружения](03-terraform-state-modules.md)
