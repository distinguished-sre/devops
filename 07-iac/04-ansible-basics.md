---
layout: lesson
title: "Ansible: инвентарь, модули, ad-hoc"
topic: 7
lesson: "7.4"
time: "1.5 ч"
---

## Зачем это нужно

Terraform создал ВМ, но она пустая: нет Docker, нет пользователя `notes`, нет каталогов. Зайти по SSH и набрать команды руками можно один раз. На третьем сервере ты забудешь шаг, на десятом получишь машины, которые "почти одинаковые". Ansible заходит на серверы по SSH сам, приводит их к описанному состоянию и не требует ставить на них агента.

На работе Ansible встречается везде, где есть виртуальные машины: обновить пакет на 40 серверах, раскатить конфиг, проверить, что везде одна версия. Вопросы про идемпотентность, инвентарь и `become` есть почти на каждом собеседовании по DevOps.

Шаг проекта: в `~/notes/infra/ansible/` появляются `ansible.cfg` и `inventory.yml` с адресом ВМ из `terraform output`. Плейбуки будут в [уроке 7.5](05-ansible-playbooks.md).

## Что нужно знать

- [Урок 1.3: права](../01-linux/03-users-permissions.md) - кто такой root, что делает sudo: `become` это тот же sudo.
- [Урок 1.6: bash](../01-linux/06-bash-basics.md) - подстановка `$(...)` и переменные окружения нужны при сборке инвентаря.
- [Урок 2.2: порты, TCP и SSH](../02-network/02-ports-tcp-ssh.md) - ключи SSH и порт 22: Ansible целиком построен на них.
- [Урок 6.2: ВМ, сеть и диски](../06-cloud/02-vm-network-storage.md) - облачная ВМ, на которой мы будем тренироваться.
- [Урок 7.2: переменные, ВМ и outputs](02-terraform-vm-variables.md) - `terraform output public_ip` даёт адрес для инвентаря.

## Теория

### Как работает Ansible: без агента

Ansible работает без агента (agentless): на управляемой машине нет ничего, кроме SSH-сервера и Python. Ты запускаешь `ansible` на своём компьютере (управляющий узел, control node). Он читает список серверов (инвентарь, inventory), подключается к каждому по SSH, копирует туда маленькую Python-программу (модуль, module), запускает её, забирает JSON с результатом и удаляет программу.

Это модель push ("толкать"): изменение начинается с твоей стороны. Противоположность это pull ("тянуть"): агент на сервере сам ходит за конфигурацией (так работают Puppet и Chef). Плюсы push: на серверах нечего ставить и обновлять, порядок под твоим контролем. Минусы: без запуска сервер сам себя не исправит, а на тысячах машин SSH становится узким местом.

Terraform и Ansible делят работу так: Terraform создаёт ВМ, сети и диски через API облака, Ansible настраивает то, что внутри ВМ: пакеты, файлы, пользователей, сервисы.

> **Проверь понимание:** зачем Ansible на сервере Python, если он "без агента"?

<details markdown="1">
<summary>Ответ</summary>

Модули Ansible это Python-скрипты. Ansible копирует модуль на сервер, там его запускает интерпретатор Python, результат возвращается как JSON. Постоянно работающего процесса нет, но Python на цели должен быть. Для голой машины без Python есть модуль `raw`: он просто гонит команду через SSH.

</details>

### Инвентарь: список серверов и групп

Инвентарь (inventory) говорит Ansible, куда ходить. Формат INI короче, YAML нагляднее для переменных, мы используем YAML.

```yaml
# inventory.yml: одна группа notes с одним сервером
all:
  children:
    notes:
      hosts:
        notes-vm:
          ansible_host: 203.0.113.10
          ansible_user: ubuntu
```

`all` это корневая группа, в ней дочерняя группа `notes`, в ней хост с именем `notes-vm`. Имя хоста это метка для тебя, а реальный адрес задаёт `ansible_host`. Переменные `ansible_*` управляют подключением: `ansible_user`, `ansible_port`, `ansible_ssh_private_key_file`.

Переменные можно задавать на группу: рядом с инвентарём лежат каталоги `group_vars/<группа>.yml` и `host_vars/<хост>.yml`. Переменная хоста сильнее переменной группы, переменная группы сильнее `all`. Полный порядок приоритетов разбирается в [уроке 7.5](05-ansible-playbooks.md). Проверить, как Ansible понял инвентарь: `ansible-inventory --graph`.

> **Проверь понимание:** в инвентаре хост `notes-vm` без `ansible_host`. Куда попытается подключиться Ansible?

<details markdown="1">
<summary>Ответ</summary>

Он возьмёт само имя `notes-vm` как DNS-имя. Если его нет в DNS и в `/etc/hosts`, получишь `UNREACHABLE` с `Could not resolve hostname`.

</details>

### Ad-hoc и модули

Ad-hoc это разовая команда без плейбука: `ansible <группа> -m <модуль> -a "<аргументы>"`. Удобна для быстрой проверки ("какое ядро на всех серверах").

Модуль это единица работы. Главное свойство хороших модулей: ты описываешь желаемое состояние, а не действие. `apt` с `name=htop state=present` значит "htop должен стоять". Если он уже есть, модуль ничего не делает и отвечает `changed: false`. Это идемпотентность (idempotency): повторный запуск не меняет результат.

| Модуль | Что делает |
|---|---|
| `ansible.builtin.ping` | проверяет SSH и Python (это не ICMP-ping) |
| `ansible.builtin.setup` | собирает факты (facts): ОС, IP, память |
| `ansible.builtin.apt` | ставит и удаляет пакеты |
| `ansible.builtin.copy` | кладёт файл или текст на сервер |
| `ansible.builtin.file` | создаёт каталоги, задаёт владельца и права |
| `ansible.builtin.user` | создаёт пользователей |
| `ansible.builtin.lineinfile` | гарантирует наличие строки в файле |
| `ansible.builtin.systemd_service` | запускает и включает сервисы |
| `ansible.builtin.command` | выполняет команду без оболочки |
| `ansible.builtin.shell` | выполняет команду через `/bin/sh` (пайпы, `>`) |
| `ansible.builtin.raw` | голая команда по SSH, Python не нужен |

`command` сам по себе не идемпотентен: Ansible не знает, что изменила твоя команда, и всегда пишет `changed`. Где есть готовый модуль, берём модуль; `shell` нужен только для пайпов и перенаправлений. Запись `ansible.builtin.apt` это FQCN (fully qualified collection name): коллекция плюс имя модуля. Короткое `apt` тоже работает, но в плейбуках принято полное имя.

> **Проверь понимание:** чем `ansible all -m command -a "useradd bob"` хуже модуля `user` с `name=bob`?

<details markdown="1">
<summary>Ответ</summary>

Второй запуск `command` упадёт с ошибкой "user already exists", а модуль `user` увидит, что `bob` есть, и ответит `ok`. Модуль проверяет состояние перед действием, `command` просто выполняет.

</details>

### become, факты и ansible.cfg

`become` включает повышение привилегий: Ansible входит под обычным пользователем (`ubuntu`) и выполняет модуль через `sudo`. В ad-hoc это флаг `--become` (или `-b`). Без него `apt` упадёт: ставить пакеты может только root ([урок 1.3](../01-linux/03-users-permissions.md)).

Факты собирает модуль `setup`: `ansible_distribution`, `ansible_default_ipv4`, `ansible_memtotal_mb` и другие. Плейбуки используют их в условиях ("если Ubuntu, то ...").

Файл `ansible.cfg` задаёт умолчания, чтобы не повторять флаги. Ansible ищет его по порядку: переменная `ANSIBLE_CONFIG`, файл в текущем каталоге, `~/.ansible.cfg`, `/etc/ansible/ansible.cfg`. Берётся первый найденный, поэтому важно, из какого каталога ты запускаешь команды.

Режим `--check --diff` это сухой прогон: `--check` показывает, что изменилось бы, `--diff` показывает разницу файлов построчно. Ничего не меняется. Это аналог `terraform plan`. Ограничение: `command` и `shell` в этом режиме пропускаются, результат неполный.

> **Проверь понимание:** `--check` показал всё зелёным. Гарантирует ли это, что боевой запуск ничего не сломает?

<details markdown="1">
<summary>Ответ</summary>

Нет. Задачи `command`/`shell` были пропущены, а шаги, зависящие от их результата, могли считаться по устаревшим данным. `--check` это оценка, а не гарантия.

</details>

### Соответствие AWS

| Что | Yandex Cloud / у нас | AWS |
|---|---|---|
| Настройка ВМ по SSH без агента | Ansible | Ansible; Systems Manager Run Command (через агент SSM) |
| Первичная настройка при создании ВМ | cloud-init (`user_data`) | EC2 User Data |
| Список ВМ для инвентаря | динамический инвентарь (плагин облака) | плагин `amazon.aws.aws_ec2` |
| Вход по SSH | ключ в metadata ВМ, пользователь `ubuntu` | Key Pair, пользователь `ubuntu` или `ec2-user` |

## Практика

Нужна ВМ с Ubuntu 24.04 или 26.04 и входом по SSH-ключу. Вариант A: облачная ВМ из [урока 7.2](02-terraform-vm-variables.md). Вариант B без облака: ВМ Multipass.

```bash
# Вариант B: локальная ВМ, если нет облачной
multipass launch 24.04 --name notes-vm --cpus 1 --memory 1G --disk 8G
# кладём свой публичный ключ в ВМ, иначе Ansible не войдёт
multipass exec notes-vm -- bash -c "echo '$(cat ~/.ssh/id_ed25519.pub)' >> ~/.ssh/authorized_keys"
```

### Задание 1. Установка ansible-core в venv

**Цель:** поставить ansible-core 2.21.4 в изолированное окружение, не трогая системный Python.

**Предскажи:** сработает ли `sudo pip install ansible` на Ubuntu? Где окажется команда `ansible` после установки в venv?

<details markdown="1">
<summary>Ответ</summary>

Нет: Ubuntu защищает системный Python, pip ответит `externally-managed-environment`. В venv команда лежит в `bin/` окружения и появляется в PATH только после активации (`pipx` сам кладёт ссылку в `~/.local/bin`).

</details>

**Шаги:**

1. Создай каталог проекта и venv:

```bash
mkdir -p ~/notes/infra/ansible && cd ~/notes/infra/ansible
sudo apt install -y python3-venv
python3 -m venv ~/.venvs/ansible
```

2. Поставь закреплённую версию и проверь (вариант с pipx: `pipx install ansible-core==2.21.4`):

```bash
~/.venvs/ansible/bin/pip install "ansible-core==2.21.4"
source ~/.venvs/ansible/bin/activate
ansible --version | head -n 3
```

**Что должно получиться:**

```text
ansible [core 2.21.4]
  config file = None
  configured module search path = ['/home/user/.ansible/plugins/modules', '/usr/share/ansible/plugins/modules']
```

**Объясни себе:** зачем закреплять версию `==2.21.4`? Что даёт venv по сравнению с установкой в систему?

**Типичные ошибки:**

- `error: externally-managed-environment`: pip запущен на системном Python. Используй venv или pipx.
- `ansible: command not found`: venv не активирован в этом терминале. Выполни `source ~/.venvs/ansible/bin/activate`.

### Задание 2. Инвентарь и ansible.cfg

**Цель:** описать ВМ в инвентаре и убедиться, что Ansible до неё доходит.

**Предскажи:** что покажет `ansible-inventory --graph` для одной группы `notes` с одним хостом?

<details markdown="1">
<summary>Ответ</summary>

Дерево: `@all` содержит `@ungrouped:` (пусто) и `@notes:` с `notes-vm`. Группы `all` и `ungrouped` есть всегда.

</details>

**Шаги:**

1. Узнай адрес. Облако: `terraform -chdir=../terraform output -raw public_ip`. Multipass: `multipass info notes-vm | grep IPv4`.
2. Создай `ansible.cfg`:

```ini
# ansible.cfg: умолчания проекта, чтобы не писать флаги каждый раз
[defaults]
inventory = inventory.yml
remote_user = ubuntu
private_key_file = ~/.ssh/id_ed25519
# не спрашивать отпечаток при первом входе (только для учебной ВМ!)
host_key_checking = False
interpreter_python = auto_silent
```

3. Создай `inventory.yml` (подставь свой адрес вместо `203.0.113.10`):

```yaml
# inventory.yml: адрес берём из terraform output public_ip
all:
  children:
    notes:
      hosts:
        notes-vm:
          ansible_host: 203.0.113.10
```

4. Проверь:

```bash
ansible-inventory --graph
ansible notes -m ansible.builtin.ping
```

**Что должно получиться:**

```text
@all:
  |--@ungrouped:
  |--@notes:
  |  |--notes-vm
notes-vm | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

**Объясни себе:** откуда Ansible узнал пользователя и ключ, если в команде их нет? Почему `host_key_checking = False` допустим для учебной ВМ и опасен на проде?

**Типичные ошибки:**

- `Failed to connect to the host via ssh: ubuntu@203.0.113.10: Permission denied (publickey).`: ключ не тот или не лежит в `authorized_keys` на ВМ, либо не тот пользователь. Проверь вручную `ssh -i ~/.ssh/id_ed25519 ubuntu@<адрес>`.
- `[WARNING]: provided hosts list is empty, only localhost is available`: команда запущена не из каталога с `ansible.cfg`. Перейди в `~/notes/infra/ansible`.

### Задание 3. Ad-hoc: факты, пакеты, идемпотентность

**Цель:** увидеть на практике разницу между `changed` и `ok`.

**Предскажи:** ты дважды запускаешь `apt` с `name=htop state=present`. Что будет в `changed` в первый раз и во второй?

<details markdown="1">
<summary>Ответ</summary>

Первый: `CHANGED`, `"changed": true` (пакет установлен). Второй: `SUCCESS`, `"changed": false` (уже стоит).

</details>

**Шаги:**

```bash
# факты: только про дистрибутив (фильтр, чтобы не читать 500 строк)
ansible notes -m ansible.builtin.setup -a "filter=ansible_distribution*"

# первый запуск: установка
ansible notes -m ansible.builtin.apt -a "name=htop state=present update_cache=true" --become

# второй запуск: та же команда
ansible notes -m ansible.builtin.apt -a "name=htop state=present" --become

# для сравнения: command всегда пишет changed
ansible notes -m ansible.builtin.command -a "uptime"
```

**Что должно получиться:** (вывод сокращён)

```text
notes-vm | SUCCESS => {
    "ansible_facts": {
        "ansible_distribution": "Ubuntu",
        "ansible_distribution_release": "noble",
        "ansible_distribution_version": "24.04"
    },
    "changed": false
}
notes-vm | CHANGED => {
    "changed": true,
    ...
}
notes-vm | SUCCESS => {
    "changed": false
}
notes-vm | CHANGED | rc=0 >>
 10:41:07 up 12 min,  1 user,  load average: 0.00, 0.01, 0.00
```

`uptime` только читает, но `command` всё равно пишет `CHANGED`: Ansible не знает, что делает произвольная команда.

**Объясни себе:** почему второй `apt` дал `changed: false`? Как сделать `command` честным (подсказка: параметры `creates` и `removes`)? Почему `setup` всегда `changed: false`?

**Типичные ошибки:**

- `Failed to lock apt for exclusive operation`: на ВМ работает `unattended-upgrades`. Подожди пару минут и повтори.
- `Missing sudo password`: у пользователя нет NOPASSWD, см. "Сломай и почини", сценарий 2.

### Задание 4. Файлы, `--check --diff` и ansible-doc

**Цель:** изменить файл на ВМ и увидеть разницу до применения.

**Предскажи:** появится ли файл на сервере после запуска с `--check --diff`? Покажет ли Ansible изменения?

<details markdown="1">
<summary>Ответ</summary>

Изменения покажет: `CHANGED` и diff со строками добавления. Файла на сервере не появится: `--check` ничего не пишет.

</details>

**Шаги:**

```bash
# сухой прогон: что изменилось бы
ansible notes -m ansible.builtin.copy \
  -a "content='notes managed by ansible' dest=/etc/motd-notes mode=0644" \
  --become --check --diff

# убедимся, что файла нет
ansible notes -m ansible.builtin.command -a "ls /etc/motd-notes" || true

# применим по-настоящему и повторим
ansible notes -m ansible.builtin.copy \
  -a "content='notes managed by ansible' dest=/etc/motd-notes mode=0644" --become
ansible notes -m ansible.builtin.copy \
  -a "content='notes managed by ansible' dest=/etc/motd-notes mode=0644" --become

# справка по модулю прямо в терминале
ansible-doc ansible.builtin.copy | head -n 20
```

**Что должно получиться:** (первая команда)

```text
notes-vm | CHANGED => {
    "changed": true,
    "diff": [
        {
            "after": "notes managed by ansible",
            "before": "",
            "after_header": "dynamically generated"
        }
    ]
}
```

После настоящего применения: первый запуск `CHANGED`, второй `SUCCESS` с `"changed": false`.

**Объясни себе:** как Ansible понял, что файл уже нужного содержания? Когда `--check` не поможет? Где читать параметры модуля без интернета?

**Типичные ошибки:**

- `ERROR! couldn't resolve module/action 'ansible.builtin.copyy'`: опечатка в имени модуля. Найди правильное: `ansible-doc -l | grep copy`.
- `Destination directory /opt/notes does not exist`: `copy` не создаёт каталоги. Сначала модуль `file` с `state=directory`.

### Задание 5. Шаг проекта: инвентарь «Заметок» из terraform output

**Цель:** зафиксировать конфиг Ansible в репозитории и брать адрес ВМ автоматически.

**Предскажи:** ВМ пересоздали, IP сменился. Что произойдёт с инвентарём, где адрес прописан руками?

<details markdown="1">
<summary>Ответ</summary>

Ansible пойдёт на старый адрес: получишь `UNREACHABLE` по таймауту или, хуже, зайдёшь на чужую машину, получившую этот IP. Поэтому адрес берут из `terraform output` при каждом запуске (подробнее в [уроке 7.7](07-terraform-ansible-drift.md)).

</details>

**Шаги:**

1. Замени `inventory.yml`: адрес читается из переменной окружения `NOTES_VM_IP`, общие параметры вынесены в `vars` группы. Двойные фигурные скобки в файле это Jinja2, шаблонизатор Ansible.

{% raw %}
```yaml
# infra/ansible/inventory.yml
# Адрес ВМ: export NOTES_VM_IP=$(terraform -chdir=../terraform output -raw public_ip)
all:
  children:
    notes:
      hosts:
        notes-vm:
          ansible_host: "{{ lookup('env', 'NOTES_VM_IP') }}"
      vars:
        ansible_user: ubuntu
```
{% endraw %}

2. Запусти и закоммить:

```bash
cd ~/notes/infra/ansible
export NOTES_VM_IP=$(terraform -chdir=../terraform output -raw public_ip)   # или адрес Multipass
ansible notes -m ansible.builtin.ping
git add ansible.cfg inventory.yml
git commit -m "ansible: inventory и ansible.cfg"
```

**Что должно получиться:**

```text
notes-vm | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
[main 4c1f9a2] ansible: inventory и ansible.cfg
 2 files changed, 22 insertions(+)
```

Эталон: [infra/ansible в репозитории курса](https://github.com/distinguished-sre/devops/tree/devops/project/notes/infra/ansible).

**Объясни себе:** зачем адрес вынесен из файла в переменную окружения? Почему приватного ключа в репозитории быть не должно, а `ansible.cfg` с путём к нему можно?

**Типичные ошибки:**

- `Failed to connect to the host via ssh: ssh: Could not resolve hostname : Name or service not known`: `NOTES_VM_IP` пуста. Проверь `echo "$NOTES_VM_IP"` и повтори `export`.
- `ERROR! Unable to parse .../inventory.yml as an inventory source`: сбит отступ в YAML. Проверь `ansible-inventory --graph`.

## Сломай и почини

Запусти скрипт (читать его не нужно, разбираем как настоящий инцидент):

```bash
cd ~/notes && bash project/notes/break/7.4/break.sh random
```

### Симптом

Одна из трёх картин при `ansible notes -m ansible.builtin.ping` или `apt ... --become`:

- `UNREACHABLE! ... Permission denied (publickey)`;
- `FAILED! ... Missing sudo password` (или `sudo: a password is required`);
- `MODULE FAILURE ... /usr/bin/python3: not found`.

### Гипотезы

- Ansible не может войти: другой пользователь, другой ключ, ключа нет в `authorized_keys`.
- Вход есть, но `sudo` требует пароль, а Ansible его не передал.
- Вход и sudo есть, но на цели нет Python или интерпретатор указан неверно.

### Проверки

```bash
# 1. подробный вывод: какой ключ и пользователь реально используются
ansible notes -m ansible.builtin.ping -vvv 2>&1 | grep -i 'ssh\|identity\|user' | head
# 2. то же вручную, без Ansible
ssh -i ~/.ssh/id_ed25519 ubuntu@"$NOTES_VM_IP" 'sudo -n true && echo sudo-ok'
# 3. есть ли Python на цели (raw не требует Python)
ansible notes -m ansible.builtin.raw -a "command -v python3 || echo no-python"
```

### Исправление

<details markdown="1">
<summary>Разбор трёх сценариев</summary>

**1. Permission denied (publickey).** Текст: `UNREACHABLE! => {"msg": "Failed to connect to the host via ssh: ubuntu@203.0.113.10: Permission denied (publickey)."}`. Ручной `ssh` падает так же, значит проблема в SSH, а не в Ansible. Причины: неверный `remote_user`, неверный `private_key_file`, публичного ключа нет в `~/.ssh/authorized_keys`, права `~/.ssh` шире 700. Исправление: положить нужный ключ и указать верного пользователя в `ansible.cfg` или `ansible_user`.

**2. sudo: a password is required.** Текст: `FAILED! => {"msg": "Missing sudo password"}` (в старых версиях `sudo: a password is required`). Вход работает, а `sudo -n true` просит пароль. Причина: нет NOPASSWD. Исправление: на цели создать `/etc/sudoers.d/ubuntu` со строкой `ubuntu ALL=(ALL) NOPASSWD:ALL` через `visudo -f` ([урок 1.3](../01-linux/03-users-permissions.md)) или запускать с `--ask-become-pass` (`-K`). Для автоматизации нужен NOPASSWD.

**3. python3 not found.** Текст: `"msg": "The module failed to execute correctly, you probably need to set the interpreter."` и `"module_stdout": "/bin/sh: 1: /usr/bin/python3: not found"`. `raw` покажет `no-python`. Исправление: поставить Python модулем `raw`: `ansible notes -m ansible.builtin.raw -a "apt-get install -y python3" --become`, либо указать верный путь в `ansible_python_interpreter`.

</details>

## Вопросы с собеседований

### 1. [junior] Чем Ansible отличается от Terraform и когда что берёшь?

Terraform создаёт и удаляет ресурсы облака через API и хранит state. Ansible настраивает содержимое машин по SSH: пакеты, файлы, сервисы. Порядок: Terraform создаёт ВМ, Ansible её настраивает. Для одноразовой первичной настройки иногда хватает cloud-init.

**Что хотят услышать:** создание против настройки, state против его отсутствия, API против SSH, стык через `terraform output` в инвентарь.

**Красный флаг:** "это одно и то же, просто другой синтаксис".

### 2. [junior] Что такое идемпотентность и как её видно в выводе Ansible?

Повторный запуск даёт то же состояние и ничего не меняет. Первый запуск пишет `changed`, второй `ok`. Так работают `apt`, `file`, `copy`: они сначала проверяют состояние.

**Что хотят услышать:** пример `changed` -> `ok`, отличие модулей от `command`, параметры `creates`/`removes`.

**Красный флаг:** "скрипт можно запускать много раз" без объяснения, как этого добиться.

### 3. [junior] Что такое инвентарь и что кладут в `group_vars`?

Инвентарь это список хостов и групп. В `group_vars/<группа>.yml` лежат переменные всей группы: порт, пользователь, версия пакета. `host_vars` сильнее групповых.

**Что хотят услышать:** группы и вложенность, `ansible_host`, статический против динамического инвентаря.

**Красный флаг:** пароли открытым текстом в `group_vars`.

### 4. [middle] Ansible пишет `UNREACHABLE! Permission denied (publickey)`. Что проверишь?

Повторю то же руками: `ssh -i ключ user@host`. Если и так не входит, дело в SSH: не тот пользователь или ключ, ключа нет в `authorized_keys`, права на `~/.ssh`. Затем `ansible -vvv`: какой ключ и пользователь реально использованы.

**Что хотят услышать:** отделить SSH от Ansible, `-vvv`, `remote_user`, `private_key_file`, права 700/600.

**Красный флаг:** "отключу проверку ключей" или сразу вход по паролю.

### 5. [middle] Задача падает на `Missing sudo password`. Что делаешь?

Вход работает, а `become` не получает root: нет NOPASSWD. Для интерактива запускаю с `-K`. Для автоматизации добавляю в `/etc/sudoers.d/` NOPASSWD только для нужного пользователя и проверяю `visudo -c`. Пароль в репозитории не храню.

**Что хотят услышать:** `become`, `--ask-become-pass`, `sudoers.d`, наименьшие привилегии.

**Красный флаг:** вход по SSH сразу под root или пароль в плейбуке.

### 6. [middle] `command`, `shell` и `raw`: в чём разница?

`command` запускает программу без оболочки (нет пайпов и переменных). `shell` идёт через `/bin/sh`, пайпы работают, но выше риск инъекций. `raw` просто гонит команду по SSH и не требует Python на цели: им ставят Python. Ни один не идемпотентен без `creates`/`removes`.

**Что хотят услышать:** когда нужен `raw`, риск `shell`, предпочтение готовым модулям.

**Красный флаг:** везде `shell`, "потому что привычнее".

### 7. [middle] Прогон на 200 серверов идёт час. Как ускорить?

Поднять `forks` (по умолчанию 5), включить `pipelining`, отключить сбор фактов там, где они не нужны (`gather_facts: false`) или кешировать их, включить ControlPersist. Раскатывать по частям через `--limit` и `serial`.

**Что хотят услышать:** `forks`, `pipelining`, `gather_facts`, `strategy: free`, `serial` для безопасной раскатки.

**Красный флаг:** "взять сервер помощнее" без поиска узкого места.

### 8. [middle] Чем полезен `--check` и где он вводит в заблуждение?

Показывает, что изменилось бы, ничего не трогая, а `--diff` показывает правки файлов. Врёт там, где есть `command`/`shell` (пропускаются) и где следующий шаг зависит от результата предыдущего. Это оценка, а не гарантия.

**Что хотят услышать:** аналогия с `terraform plan`, ограничения, `check_mode` у отдельных задач.

**Красный флаг:** "check зелёный, катим на прод без оглядки".

### 9. [junior] На свежей ВМ Ansible ругается, что нет `/usr/bin/python3`. Что делаешь?

Модули требуют Python на цели. Ставлю его через `raw` (`apt-get install -y python3`): `raw` Python не нужен. Затем проверяю `ansible_python_interpreter`. Чтобы не повторять, ставлю Python в образ или через cloud-init.

**Что хотят услышать:** `raw`, причина (минимальный образ), cloud-init.

**Красный флаг:** "надо ставить агент Ansible на сервер".

### 10. [middle] Плюсы и минусы agentless-подхода по сравнению с агентом на сервере?

Плюсы: на серверах ничего не установлено и не обновляется, порядок под контролем. Минусы: сервер сам не исправит дрейф, нужен SSH-доступ ко всем машинам, на тысячах узлов медленно. Агентная модель (Puppet, `ansible-pull`) сама забирает конфигурацию, но агент нужно ставить и обновлять.

**Что хотят услышать:** бастион и доступ по SSH, масштаб, `ansible-pull`, ночной прогон в CI против дрейфа.

**Красный флаг:** "agentless всегда лучше" без минусов.

## Проверено на версиях

- ansible-core: 2.21.4 (venv или pipx)
- Ubuntu на управляющем узле и на цели: 24.04 LTS, 26.04 LTS
- Python на цели: системный python3 из Ubuntu
- Multipass: версия не закреплена, проверь актуальную версию на странице проекта

## Итог урока: ты умеешь

- [ ] умею поставить ansible-core в venv или pipx с закреплённой версией
- [ ] умею описать серверы в `inventory.yml` с группами и `ansible_host`
- [ ] умею настроить `ansible.cfg` и проверить связь через `ansible notes -m ping`
- [ ] умею запускать ad-hoc с `--become` и отличать `changed` от `ok`
- [ ] умею смотреть изменения через `--check --diff` и знаю их ограничения
- [ ] умею искать модули и параметры через `ansible-doc`
- [ ] умею диагностировать `UNREACHABLE`, ошибку sudo и отсутствие Python
- [ ] умею брать адрес ВМ из `terraform output` для инвентаря

**Дальше:** [Урок 7.5: Ansible: плейбуки, handlers и Jinja2](05-ansible-playbooks.md)
