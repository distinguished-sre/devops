---
layout: lesson
title: "Ansible: плейбуки, handlers и Jinja2"
topic: 7
lesson: "7.5"
time: "2 ч"
---

## Зачем это нужно

Ad-hoc команды из прошлого урока хороши для разовой проверки, но настройка сервера это десятки шагов, и их нужно повторять на новой ВМ без ручной памяти. Плейбук (playbook) записывает эти шаги в YAML: его читает человек, хранит git, запускает CI. На работе плейбук пишут для установки Docker, раскладки конфигов, создания пользователей, а на собеседовании спрашивают «почему у тебя `changed=1` при каждом запуске» и «почему handler не перезапустил сервис».
Шаг проекта: в `~/notes/infra/ansible/` появляются `site.yml`, каталог `playbooks/` (base, docker, config) и шаблон `templates/notes.env.j2`.

## Что нужно знать

- [Урок 7.4: инвентарь, модули, ad-hoc](04-ansible-basics.md) - inventory, `ansible.cfg`, `become`, идемпотентность модулей
- [Урок 1.3: пользователи и права](../01-linux/03-users-permissions.md) - владелец и режим файла (`640 root:notes`)
- [Урок 1.8: systemd](../01-linux/08-systemd-editors.md) - что значит перезапустить сервис
- [Урок 4.5: Compose и PostgreSQL](../04-docker/05-compose-postgres.md) - зачем на сервере Docker и `.env`
- [Урок 6.3: «Заметки» на ВМ](../06-cloud/03-deploy-notes-vm.md) - что мы раньше ставили руками на этой ВМ

## Теория

{% raw %}

### Плейбук: play, tasks, модули

Плейбук (playbook) это YAML-список игр (play). Игра связывает группу хостов (`hosts`) со списком задач (`tasks`). Задача вызывает один модуль с параметрами и описывает желаемое состояние: `state: present` значит «пакет должен быть», а не «поставь пакет». Поэтому второй запуск ничего не меняет: модуль сравнивает факт с описанием и молчит, если они совпали.

```yaml
- name: Пример
  hosts: all          # к кому применять
  become: true        # выполнять от root (sudo)
  tasks:
    - name: Пакет htop установлен
      ansible.builtin.apt:
        name: htop
        state: present
```

В конце запуска Ansible печатает `PLAY RECAP`: для каждого хоста счётчики `ok`, `changed`, `failed`, `skipped`. Главный признак здорового плейбука: второй запуск даёт `changed=0`.

> **Проверь понимание:** чем `state: present` в модуле `apt` отличается от команды `apt install`?

<details markdown="1"><summary>Ответ</summary>

`apt install` это действие: оно каждый раз что-то делает. `state: present` это описание итога: модуль проверяет, стоит ли пакет, и ставит только при необходимости. Поэтому повторный запуск безопасен и показывает `ok`, а не `changed`.

</details>

### Переменные и Jinja2

Значения выносят в переменные (`vars`) и подставляют шаблонизатором Jinja2 (Jinja2 templating): `{{ имя }}`. В YAML значение, начинающееся с `{{`, обязательно в кавычках, иначе YAML решит, что это словарь. Шаблонный файл `.j2` рендерится модулем `ansible.builtin.template` на управляющей машине, а на сервер попадает готовый текст. Переменные бывают свои (`vars`), из инвентаря (`group_vars`) и факты (facts), собранные автоматически: `ansible_facts['distribution_release']` даёт имя релиза Ubuntu (`noble` или `resolute`).

Приоритет переменных (упрощённо, от слабого к сильному): значения по умолчанию, `group_vars`, `host_vars`, `vars` в play, параметр `-e` в командной строке. `-e` побеждает всё, поэтому им удобно переопределять значение на один запуск.

Неопределённая переменная это ошибка, а не пустая строка: Ansible остановится с `is undefined`. Это защита: лучше упасть, чем записать в конфиг пустой пароль.

> **Проверь понимание:** ты задал `notes_port: 8080` в `vars` плейбука и запустил с `-e notes_port=9090`. Какой порт попадёт в шаблон?

<details markdown="1"><summary>Ответ</summary>

9090. Переменная из `-e` имеет наивысший приоритет.

</details>

### Handlers: реакция на изменение

Handler это задача, которая выполняется только если её вызвала (`notify`) задача со статусом `changed`. Так сервис перезапускается ровно тогда, когда конфиг реально изменился, а не при каждом запуске. Три правила, на которых ломаются:

1. Handler запускается один раз в конце play, сколько бы задач его ни вызвали.
2. Если задача вернула `ok` (файл не менялся), handler не запускается.
3. Если play упал раньше, накопленные handlers не выполняются (флаг `--force-handlers` или `meta: flush_handlers` меняют это).

```yaml
tasks:
  - name: Конфиг
    ansible.builtin.template:
      src: notes.env.j2
      dest: /etc/notes/notes.env
    notify: Перечитать конфиг
handlers:
  - name: Перечитать конфиг
    ansible.builtin.debug:
      msg: "конфиг изменился"
```

Имя в `notify` должно совпадать с `name` handler символ в символ.

> **Проверь понимание:** три задачи изменили файлы и все вызвали один handler. Сколько раз он выполнится?

<details markdown="1"><summary>Ответ</summary>

Один раз, в конце play. Это защита от трёх перезапусков подряд.

</details>

### Условия, циклы, register, теги

- `when: ansible_facts['os_family'] == 'Debian'` пропускает задачу (`skipped`), если условие ложно. Внутри `when` скобки `{{ }}` не нужны.
- `loop: [a, b]` повторяет задачу для каждого элемента, значение доступно как `item`.
- `register: результат` сохраняет ответ модуля в переменную; ей пользуются в `when` и `debug`.
- `tags: [config]` даёт метку; `--tags config` запускает только помеченные задачи, `--limit хост` ограничивает хосты.
- `command` и `shell` всегда возвращают `changed`, потому что Ansible не знает, что сделала команда. Лечится `creates:` (пропустить, если файл есть), `changed_when:` или заменой на специализированный модуль.

> **Проверь понимание:** как заставить `command: touch /tmp/flag` показывать `ok` при втором запуске?

<details markdown="1"><summary>Ответ</summary>

Добавить `args: {creates: /tmp/flag}`, или заменить на модуль `ansible.builtin.file` с `state: touch` и `modification_time: preserve`, или задать `changed_when: false`, если команда только читает.

</details>

### Соответствие AWS

| Что делаем в Ansible | Аналог в AWS | Замечание |
|---|---|---|
| Плейбук по SSH | AWS Systems Manager Run Command, State Manager | SSM ходит через агента, без открытого порта 22 |
| Группа хостов в inventory | Теги EC2 и Resource Groups | динамический inventory строится по тегам |
| Шаблон `.j2` с параметрами | User data (cloud-init) с переменными | user data срабатывает при первом старте, Ansible можно запускать повторно |
| Handler и перезапуск | Перезапуск через SSM или замена инстанса в Auto Scaling | при immutable-подходе сервер меняют, а не правят |

### Проверка и безопасный запуск

Перед запуском на реальной ВМ всегда два шага: `ansible-playbook --syntax-check` (ловит опечатки в YAML) и `--check --diff` (сухой прогон: показывает, что изменилось бы, и построчную разницу файлов). Ограничение сухого прогона: `command` и `shell` в нём пропускаются, поэтому по нему нельзя судить о задачах-командах. Линтер `ansible-lint` находит плохие практики: короткие имена модулей без `ansible.builtin.`, `command` вместо модуля, задачи без имени.

> **Проверь понимание:** сухой прогон показал `changed=0`, а на деле после запуска что-то изменилось. Как это возможно?

<details markdown="1"><summary>Ответ</summary>

Изменение делала задача `command` или `shell`: в `--check` они пропускаются, и Ansible не может предсказать их эффект. Кроме того, задача может зависеть от результата предыдущей, которая в сухом прогоне ничего не сделала.

</details>

## Практика

Везде дальше рабочий каталог `~/notes/infra/ansible/`, а `inventory.yml` и `ansible.cfg` из урока 7.4 уже настроены. Ansible ставился в venv или pipx: версия ansible-core 2.21.4. Целевая машина это ВМ `notes-vm` (облако или Multipass, Ubuntu 24.04 или 26.04). Плейбуки написаны для `hosts: all`, чтобы не зависеть от имени группы в твоём инвентаре.

```bash
cd ~/notes/infra/ansible
ansible --version | head -1
ansible all -m ping
mkdir -p playbooks templates
```

```text
ansible [core 2.21.4]
notes-vm | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

### Задание 1. Первый плейбук: база сервера и идемпотентность

**Цель:** описать плейбуком пакеты, системного пользователя `notes` и каталоги «Заметок» и убедиться, что повторный запуск ничего не меняет.

**Предскажи:** что покажет `PLAY RECAP` при первом запуске и при втором? Сколько задач будут `changed` во второй раз?

<details markdown="1"><summary>Ответ</summary>

Первый запуск: `changed` равен числу задач, которые что-то создали (пакеты, пользователь, каталоги). Второй: `changed=0`, все задачи `ok`. Если во втором запуске `changed` не ноль, в плейбуке есть неидемпотентная задача.

</details>

**Шаги:**

1. Создай `playbooks/base.yml`:

```yaml
- name: Базовая настройка сервера для Заметок
  hosts: all
  become: true          # без этого apt и useradd упадут: нужен root
  tasks:
    - name: Индекс пакетов свежий
      ansible.builtin.apt:
        update_cache: true
        cache_valid_time: 3600   # не чаще раза в час

    - name: Базовые пакеты установлены
      ansible.builtin.apt:
        name:
          - ca-certificates
          - curl
          - jq
        state: present

    - name: Системный пользователь notes существует
      ansible.builtin.user:
        name: notes
        system: true
        shell: /usr/sbin/nologin
        create_home: false

    - name: Каталоги Заметок созданы
      ansible.builtin.file:
        path: "{{ item.path }}"
        state: directory
        owner: "{{ item.owner }}"
        group: "{{ item.group }}"
        mode: "{{ item.mode }}"
      loop:
        - { path: /opt/notes, owner: root, group: root, mode: "0755" }
        - { path: /var/lib/notes, owner: notes, group: notes, mode: "0750" }
        - { path: /etc/notes, owner: root, group: notes, mode: "0750" }
```

2. Проверь синтаксис и запусти дважды:

```bash
ansible-playbook playbooks/base.yml --syntax-check
ansible-playbook playbooks/base.yml
ansible-playbook playbooks/base.yml
```

**Что должно получиться:** в конце второго запуска:

```text
PLAY RECAP *********************************************************************
notes-vm                   : ok=5    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

**Объясни себе:**

- Почему у `apt` стоит `cache_valid_time`, и что было бы без него на втором запуске?
- Что делает `loop` и откуда берётся `item`?
- Почему пользователь `notes` создан без домашнего каталога и с `nologin`?

**Типичные ошибки:**

- `fatal: [notes-vm]: FAILED! => {"msg": "Missing sudo password"}`: у пользователя ВМ нет `NOPASSWD` в sudo, а `become` включён: настрой sudo без пароля или запусти с `--ask-become-pass`.
- `E: Could not get lock /var/lib/dpkg/lock-frontend`: на свежей ВМ фоном идёт `unattended-upgrades`: подожди пару минут и повтори.
- `ERROR! We were unable to read either as JSON nor YAML`: отступы пробелами, табы в YAML запрещены.

### Задание 2. Docker из официального apt-репозитория

**Цель:** поставить Docker Engine на ВМ так, как это делают в проде: ключ, репозиторий с `signed-by`, пакеты, автозапуск.

**Предскажи:** какие факты нужны, чтобы собрать строку репозитория для Ubuntu 24.04 (`noble`) и 26.04 одним плейбуком?

<details markdown="1"><summary>Ответ</summary>

Архитектура процессора (`amd64` или `arm64`) и кодовое имя релиза. Оба даёт сбор фактов: `ansible_facts['architecture']` (значения `x86_64` и `aarch64`, поэтому нужна таблица соответствия) и `ansible_facts['distribution_release']`. Здесь архитектуру берём готовой командой `dpkg --print-architecture`.

</details>

**Шаги:**

1. Создай `playbooks/docker.yml`:

```yaml
- name: Docker Engine на сервере
  hosts: all
  become: true
  tasks:
    - name: Каталог для ключей apt
      ansible.builtin.file:
        path: /etc/apt/keyrings
        state: directory
        mode: "0755"

    - name: Ключ репозитория Docker скачан
      ansible.builtin.get_url:
        url: https://download.docker.com/linux/ubuntu/gpg
        dest: /etc/apt/keyrings/docker.asc
        mode: "0644"

    - name: Архитектура dpkg
      ansible.builtin.command: dpkg --print-architecture
      register: dpkg_arch
      changed_when: false      # команда только читает, изменений нет

    - name: Репозиторий Docker подключён
      ansible.builtin.apt_repository:
        repo: >-
          deb [arch={{ dpkg_arch.stdout }} signed-by=/etc/apt/keyrings/docker.asc]
          https://download.docker.com/linux/ubuntu
          {{ ansible_facts['distribution_release'] }} stable
        filename: docker
        state: present

    - name: Пакеты Docker установлены
      ansible.builtin.apt:
        name:
          - docker-ce
          - docker-ce-cli
          - containerd.io
          - docker-compose-plugin
        state: present
        update_cache: true
      notify: Перезапустить Docker

    - name: Docker включён и запущен
      ansible.builtin.systemd_service:
        name: docker
        state: started
        enabled: true

  handlers:
    - name: Перезапустить Docker
      ansible.builtin.systemd_service:
        name: docker
        state: restarted
```

2. Запусти два раза и проверь на ВМ:

```bash
ansible-playbook playbooks/docker.yml
ansible-playbook playbooks/docker.yml
ansible all -m command -a "docker compose version" --become
```

**Что должно получиться:** второй запуск с `changed=0`; версия плагина Compose в выводе (число зависит от даты установки, версия Docker не закреплена, проверь актуальную версию на странице проекта):

```text
notes-vm | CHANGED | rc=0 >>
Docker Compose version v5.x.x
```

**Объясни себе:**

- Зачем `changed_when: false` у задачи с `dpkg`, и что покажет второй запуск без него?
- В каком порядке выполнятся задача установки и handler, и когда именно?
- Почему ключ лежит в `/etc/apt/keyrings/`, а в строке репозитория стоит `signed-by`?

**Типичные ошибки:**

- `fatal: [notes-vm]: FAILED! => {"msg": "Failed to update apt cache: E: The repository ... does not have a Release file"}`: у Docker может не быть репозитория для только что вышедшего релиза Ubuntu: проверь `curl -I https://download.docker.com/linux/ubuntu/dists/<релиз>/Release`, при 404 подставь предыдущий LTS в `repo` (проверь актуальную поддержку на странице Docker).
- `The task includes an option with an undefined variable. The error was: 'dpkg_arch' is undefined`: задача с `register` не выполнилась раньше или переименована: имена в `register` и в шаблоне должны совпадать.
- `Could not resolve host: download.docker.com`: у ВМ нет выхода в интернет или DNS: проверь `dig download.docker.com` (урок 2.3).

### Задание 3. Шаблон Jinja2 и handler на конфиг

**Цель:** сгенерировать `/etc/notes/notes.env` из шаблона, выдать права `640 root:notes` и вызвать handler только при реальном изменении.

**Предскажи:** ты меняешь в плейбуке только `notes_log_level` с `INFO` на `DEBUG` и запускаешь. Что покажет задача с шаблоном и выполнится ли handler? А если запустить ещё раз?

<details markdown="1"><summary>Ответ</summary>

Первый запуск: задача `changed`, handler выполнится. Второй: задача `ok`, handler пропущен, потому что нечего перечитывать.

</details>

**Шаги:**

1. Создай `templates/notes.env.j2`:

```text
# Файл создан Ansible, не правь руками: изменения перезапишутся
STORE={{ notes_store }}
HOST=127.0.0.1
PORT=8080
LOG_LEVEL={{ notes_log_level }}
DATABASE_URL=postgresql://notes:{{ notes_db_password }}@db:5432/notes
```

2. Создай `playbooks/config.yml`. Пароль здесь заглушка `CHANGE_ME`; шифрование паролей это тема следующего урока:

```yaml
- name: Конфиг Заметок
  hosts: all
  become: true
  vars:
    notes_store: postgres
    notes_log_level: INFO
    notes_db_password: CHANGE_ME
  tasks:
    - name: Файл окружения из шаблона
      ansible.builtin.template:
        src: ../templates/notes.env.j2
        dest: /etc/notes/notes.env
        owner: root
        group: notes
        mode: "0640"
      notify: Сообщить о смене конфига
      tags: [config]

  handlers:
    - name: Сообщить о смене конфига
      ansible.builtin.debug:
        msg: "Конфиг изменился, приложению нужен перезапуск"
```

3. Запусти, потом покажи разницу и права:

```bash
ansible-playbook playbooks/config.yml
ansible-playbook playbooks/config.yml -e notes_log_level=DEBUG --check --diff
ansible all -m command -a "stat -c '%a %U:%G %n' /etc/notes/notes.env" --become
```

**Что должно получиться:** `--diff` показывает одну изменённую строку, права правильные:

```text
-LOG_LEVEL=INFO
+LOG_LEVEL=DEBUG
notes-vm | CHANGED | rc=0 >>
640 root:notes /etc/notes/notes.env
```

**Объясни себе:**

- Где рендерится шаблон: на ВМ или на твоей машине?
- Почему `-e notes_log_level=DEBUG` победил значение из `vars`?
- Почему файл с паролем нельзя оставить `644`? (урок 1.3)

**Типичные ошибки:**

- `fatal: [notes-vm]: FAILED! => {"msg": "AnsibleUndefinedVariable: 'notes_store' is undefined"}`: переменная не определена ни в `vars`, ни в `group_vars`: определи её или задай `default('postgres')`.
- `Could not find or access '../templates/notes.env.j2'`: путь `src` считается от каталога плейбука: проверь, что запускаешь из `infra/ansible/` и шаблон лежит в `templates/`.
- `did not find expected key while parsing a block mapping`: значение с `{{` в начале не взято в кавычки.

### Задание 4. Шаг проекта: `site.yml` собирает всё

**Цель:** оформить `infra/ansible/site.yml` точкой входа, которая подключает три плейбука по порядку, и получить `changed=0` при втором запуске на настроенной ВМ.

**Предскажи:** что будет, если `site.yml` подключит `config.yml` раньше `base.yml`?

<details markdown="1"><summary>Ответ</summary>

Задача шаблона упадёт: каталога `/etc/notes` и группы `notes` ещё нет, `template` вернёт ошибку про несуществующую группу или каталог. Порядок import_playbook задаёт порядок выполнения.

</details>

**Шаги:**

1. Создай `site.yml`:

```yaml
# Точка входа: порядок важен, каждый шаг опирается на предыдущий
- import_playbook: playbooks/base.yml
- import_playbook: playbooks/docker.yml
- import_playbook: playbooks/config.yml
```

2. Проверь, сделай сухой прогон и запусти дважды. Затем ограничь запуск одним тегом:

```bash
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
ansible-playbook site.yml
ansible-playbook site.yml --tags config
```

3. Зафиксируй в git:

```bash
cd ~/notes
git add infra/ansible
git commit -m "ansible: site.yml, playbooks base/docker/config, шаблон notes.env"
```

**Что должно получиться:** во втором полном запуске везде `changed=0`; с `--tags config` выполняется только одна задача:

```text
PLAY RECAP *********************************************************************
notes-vm                   : ok=15   changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

Число `ok` зависит от количества задач и фактов, важен `changed=0`. Эталон: [infra/ansible в репозитории курса](https://github.com/distinguished-sre/devops/tree/devops/project/notes/infra/ansible).

**Объясни себе:**

- Чем `import_playbook` отличается от трёх запусков вручную?
- Что даёт `--tags`, и почему теги нужно ставить заранее?

**Типичные ошибки:**

- `ERROR! 'import_playbook' is not a valid attribute for a Play`: `import_playbook` записан внутри списка `tasks:`, а должен стоять на верхнем уровне файла.
- `ERROR! Unable to retrieve file contents. Could not find or access '.../playbooks/base.yml'`: неверный путь: пути в `import_playbook` считаются от каталога `site.yml`.
- `fatal: [notes-vm]: UNREACHABLE!`: изменился IP ВМ после пересоздания: обнови `inventory.yml` (урок 7.4).

## Сломай и почини

Запусти сценарий и не читай скрипт: он сломает один из плейбуков.

```bash
bash ~/notes/break/7.5/break.sh random
```

### Симптом

Одно из четырёх: (1) второй запуск показывает `changed=1` на одной и той же задаче; (2) запуск падает с `'foo' is undefined`; (3) задача падает с `Permission denied` или `This command has to be run under the root user`; (4) файл конфига изменился, а handler не отработал.

### Гипотезы

Для каждого симптома выпиши по 2 причины до просмотра разбора. Подумай: что в задаче не идемпотентно; где определяется переменная; на каком уровне стоит `become`; как называется handler и вызывался ли он.

### Проверки

Запускай `ansible-playbook site.yml --check --diff` и `-v`: они показывают, что меняется и что вернул модуль.

### Исправление

<details markdown="1"><summary>Разбор сценариев</summary>

1. `changed=1` каждый раз: в плейбуке `command` или `shell` без `creates`, `removes` или `changed_when`. Замени на модуль (`file`, `copy`, `get_url`) или добавь `creates: /путь/результата`. Проверка: второй запуск даёт `changed=0`.
2. `'foo' is undefined`: переменная не задана или опечатка в имени. Ищи `grep -rn foo playbooks templates`, определи в `vars` или `group_vars`, либо задай `{{ foo | default('значение') }}`, если пустое допустимо.
3. Забыт `become: true`: модуль `apt`, `user` или запись в `/etc` выполняется от обычного пользователя. Добавь `become: true` в play или в задачу. Проверка: `ansible-playbook -v` показывает пользователя-владельца изменений.
4. Handler не сработал: имя в `notify` не совпадает с `name` handler (Ansible молчит или пишет предупреждение), либо задача вернула `ok` (файл уже совпадал), либо play упал до конца. Выровняй имена, при необходимости добавь `meta: flush_handlers` сразу после нужной задачи.

</details>

## Вопросы с собеседований

### 1. [junior] Ты запускаешь плейбук второй раз, и он показывает `changed=3`. Твои действия?

Смотрю, какие именно задачи `changed`. Обычно это `command` или `shell` без `creates`, `removes` или `changed_when`, либо шаблон с меняющимся содержимым (метка времени внутри). Заменяю на модуль или добавляю условия, проверяю `--check --diff`.

**Что хотят услышать:** идемпотентность как критерий качества, поиск по `PLAY RECAP`, `--diff`, `changed_when`.

**Красный флаг:** «так и должно быть» или «просто игнорирую».

### 2. [junior] В плейбуке ты поменял конфиг nginx, но сервис не перезапустился. Почему?

Проверю три вещи: есть ли `notify` у задачи, совпадает ли имя с `name` handler, и вернула ли задача `changed`. Если файл уже был таким, handler не вызывается. Ещё смотрю, не упал ли play до конца.

**Что хотят услышать:** handler запускается в конце play, только при `changed`, `flush_handlers`, `--force-handlers`.

**Красный флаг:** считает, что handler запускается при каждом запуске.

### 3. [junior] Что делает `become: true` и на каком уровне его лучше ставить?

Повышает привилегии до root через sudo. Ставлю на play, если почти все задачи требуют root, и на задачу, если нужен один шаг; так остальное идёт с минимумом прав.

**Что хотят услышать:** sudo, `become_user`, минимальные права, NOPASSWD только для автоматизации.

**Красный флаг:** запускает всё `ansible_user: root`.

### 4. [junior] Плейбук падает с `'db_host' is undefined`. Как ищешь?

`grep -rn db_host` по плейбукам, шаблонам и `group_vars`. Проверяю имя (опечатка), область видимости (`vars` play или inventory) и приоритет. Отладка: `ansible -m debug -a "var=db_host" хост`.

**Что хотят услышать:** источники переменных, приоритет, `debug`, `default()` там, где пусто допустимо.

**Красный флаг:** «добавлю `ignore_errors: true`».

### 5. [middle] Плейбук на проде страшно запускать. Как снижаешь риск?

`--syntax-check`, `ansible-lint`, затем `--check --diff` на одном хосте (`--limit`), потом по одному-двум хостам, потом на всех. Помню, что `command` в check пропускается, и проверяю такие места вручную.

**Что хотят услышать:** `--check --diff`, `--limit`, постепенный раскат, ограничения check, git-ревью.

**Красный флаг:** «запускаю сразу на всех, откатим».

### 6. [middle] После смены конфига нужно перезапустить сервис, но только если конфиг проходит проверку. Как сделать?

В модуле `template` есть параметр `validate` (например, `nginx -t -c %s`): невалидный файл не заменит рабочий. Перезапуск делаю через `notify`, чтобы он был только при изменении.

**Что хотят услышать:** `validate`, `notify`, `reload` против `restart`, откат при ошибке.

**Красный флаг:** пишет конфиг, потом отдельной `command` проверяет и не останавливает play при ошибке.

### 7. [middle] Как передать секрет в плейбук и не засветить его в логах и git?

Не хранить в открытом виде: `ansible-vault` для файла с переменными (следующий урок), либо внешний менеджер секретов. На задачах с секретом ставлю `no_log: true`, чтобы значение не попало в вывод.

**Что хотят услышать:** vault, `no_log`, секрет не в `-e` из истории shell, не в git.

**Красный флаг:** пароль в `vars` плейбука в репозитории.

### 8. [middle] Одна и та же переменная задана в `group_vars`, `vars` play и `-e`. Что победит и как отлаживать?

`-e` сильнее всех, затем `vars` play, потом `group_vars`. Смотрю итоговое значение через `debug: var=` или `ansible-inventory --host`.

**Что хотят услышать:** порядок приоритета, `-e` для разового переопределения, `ansible-inventory`, минимум мест определения.

**Красный флаг:** «Ansible сам решит, не знаю».

### 9. [middle] Нужно пересоздать конфиг только на одной ВМ из десяти, а не гонять весь плейбук. Как?

`--limit host` для хоста и `--tags config` для задач. Заранее размечаю задачи тегами, иначе ограничить нечем.

**Что хотят услышать:** `--limit`, `--tags`, `--start-at-task`, `--list-tasks`.

**Красный флаг:** правит плейбук, комментируя задачи.

### 10. [middle] Ты подставляешь в шаблон список серверов, а в файле пустые строки. Что не так?

Скорее всего, лишние переводы строк от блоков `{% for %}`. Помогают `trim_blocks` и `lstrip_blocks` (в модуле `template` включены по умолчанию для Ansible) или знак `-` в тегах Jinja2. Проверяю результат `--diff`.

**Что хотят услышать:** циклы Jinja2, управление пробелами, `--diff` для проверки, отладка шаблона.

**Красный флаг:** правит файл на сервере руками после запуска.

## Проверено на версиях

- ansible-core: 2.21.4
- Ubuntu на управляемой ВМ: 26.04 LTS и 24.04 LTS
- Docker Engine и плагин Compose: версия не закреплена, проверь актуальную версию на странице проекта
- Python на управляющей машине: 3.13

## Итог урока: ты умеешь

- [ ] умею писать плейбук с play, tasks и `become` и запускать его через `ansible-playbook`
- [ ] умею доказать идемпотентность вторым запуском с `changed=0`
- [ ] умею генерировать конфиг из шаблона Jinja2 и выдавать права `640 root:notes`
- [ ] умею вызывать handler через `notify` и объяснить, когда он срабатывает
- [ ] умею читать `--check --diff` и знаю его пределы для `command`
- [ ] умею ограничивать запуск через `--tags`, `--limit` и `--start-at-task`
- [ ] умею собрать `site.yml` из нескольких плейбуков через `import_playbook`
- [ ] умею найти причину `is undefined` и неидемпотентной задачи

{% endraw %}

**Дальше:** [Урок 7.6: роли и деплой «Заметок» одним запуском](06-ansible-roles.md)
