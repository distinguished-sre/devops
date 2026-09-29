---
layout: lesson
title: "Ansible: роли и деплой «Заметок» одним запуском"
topic: 7
lesson: "7.6"
time: "2 ч"
---

## Зачем это нужно

Плейбук на 200 строк, в котором смешаны установка Docker, конфиги, пароли и деплой, никто не хочет читать и никто не осмеливается менять. На работе такое разбирают на роли (roles): «docker», «nginx», «app». Их переиспользуют на десятках серверов, а пароли шифруют, чтобы держать в git рядом с кодом.

В этом уроке ты соберёшь две роли и запустишь «Заметки» на чистой ВМ одной командой. Пароль БД будет лежать в зашифрованном файле.

Шаг проекта: в `~/notes/infra/ansible/` появятся роли `docker` и `notes` и зашифрованный `group_vars/all/vault.yml`; `ansible-playbook site.yml` поднимает «Заметки» на ВМ.

## Что нужно знать

- [Урок 7.4: инвентарь, модули, ad-hoc](04-ansible-basics.md) - inventory, `ansible.cfg`, доступ по SSH
- [Урок 7.5: плейбуки, handlers и Jinja2](05-ansible-playbooks.md) - `tasks`, `notify`, шаблоны `.j2`, идемпотентность
- [Урок 7.2: переменные, ВМ и outputs](02-terraform-vm-variables.md) - откуда берётся IP ВМ
- [Урок 4.5: Compose с PostgreSQL](../04-docker/05-compose-postgres.md) - `compose.yml`, `.env`, healthcheck
- [Урок 6.3: деплой на ВМ](../06-cloud/03-deploy-notes-vm.md) - что мы автоматизируем: pull образа и `up -d`
- [Урок 1.3: права и пользователи](../01-linux/03-users-permissions.md) - владелец и режим файла `.env` (640)

## Теория

### Роль: папка с договорённой структурой

Роль (role) это каталог, где каждый тип содержимого лежит на своём месте, а Ansible сам его находит. Ничего не нужно подключать вручную.

```text
roles/notes/
  tasks/main.yml       # задачи, точка входа
  handlers/main.yml    # обработчики (notify)
  templates/           # шаблоны .j2
  files/               # статичные файлы (копируются как есть)
  defaults/main.yml    # значения по умолчанию, самый низкий приоритет
  vars/main.yml        # жёсткие значения роли, высокий приоритет
  meta/main.yml        # зависимости и метаданные
```

Правило: всё, что хочется менять снаружи, кладёшь в `defaults/`. В `vars/` только то, что роль менять не позволяет. Модуль `template` берёт файлы из `templates/` роли без указания пути, `copy` из `files/`.

Плейбук сжимается до списка ролей:

```yaml
- hosts: notes
  become: true
  roles:
    - docker
    - notes
```

Роли выполняются сверху вниз. Если `notes` окажется выше `docker`, Compose ещё не установлен и запуск упадёт. Порядок можно закрепить зависимостью в `meta/main.yml`: тогда `docker` подтянется сам.

> **Проверь понимание:** чем `defaults/main.yml` отличается от `vars/main.yml`, и куда ты положишь порт приложения?

<details markdown="1">
<summary>Ответ</summary>

`defaults` переопределяются чем угодно: `group_vars`, `-e`, inventory. `vars` роли имеют высокий приоритет и снаружи почти не перебиваются. Порт приложения это настройка, которую пользователь роли захочет менять, значит `defaults`.

</details>

### Приоритет переменных: кто победил

Одна переменная может быть объявлена в десятке мест. Запомни короткий порядок от слабого к сильному: `defaults` роли, `group_vars/all`, `group_vars/<группа>`, `host_vars`, `vars` роли, `vars` плейбука, `-e` в командной строке. `-e` побеждает всё, поэтому им удобно разово перебить значение и им же опасно оставлять «временные» правки в CI.

Когда результат неожиданный, не гадай, а смотри: `ansible -m debug -a "var=notes_tag" notes` покажет итоговое значение для хоста.

> **Проверь понимание:** `notes_tag` задан в `defaults` роли как `0.4.1` и в `group_vars/all` как `0.4.0`. Запуск идёт без `-e`. Какой тег задеплоится?

<details markdown="1">
<summary>Ответ</summary>

`0.4.0`. `group_vars` сильнее `defaults`.

</details>

### Ansible Vault: секреты в git в зашифрованном виде

`ansible-vault` (Ansible Vault) шифрует файл симметрично (AES256) паролем. Зашифрованный файл безопасно коммитить: без пароля это набор байт. При запуске Ansible расшифровывает его в памяти.

Принятая схема из двух файлов в `group_vars/all/`: открытый `vars.yml` со ссылками и зашифрованный `vault.yml` с секретами. В `vars.yml` пишется `notes_db_password: "..."`, ссылающийся на `vault_notes_db_password`. Тогда по `grep` видно, где используется переменная, а значение остаётся зашифрованным.

Пароль от vault хранится вне репозитория, у нас в `~/.notes-secrets/ansible-vault-pass` с режимом 600, а путь к нему указан в `ansible.cfg`. Это осознанный долг: пароль лежит на твоём ноутбуке. Централизованное хранение появится в теме 9 (Vault от HashiCorp, не путать с `ansible-vault`, см. урок 9.1).

Что нельзя: печатать значения в лог. Задачам с паролями ставь `no_log: true`, иначе Ansible покажет их при ошибке.

> **Проверь понимание:** ты закоммитил `vault.yml` в зашифрованном виде, а `.vault-pass` тоже случайно добавил в git. Что произошло с защитой?

<details markdown="1">
<summary>Ответ</summary>

Защиты нет: ключ лежит рядом с замком, а история git хранит его вечно. Пароль vault нужно сменить (`ansible-vault rekey`), а пароль БД считать скомпрометированным и сменить тоже.

</details>

### Модуль community.docker и коллекции

Модули не из ядра ставятся коллекциями (collections). Для Compose нужна `community.docker` (модуль `docker_compose_v2`, он вызывает CLI-плагин `docker compose`). Версию закрепляют в `requirements.yml`: `ansible-galaxy collection install -r requirements.yml`.

### Соответствие AWS

| Что в Ansible | Ближайшее в AWS |
|---|---|
| роль `docker` (настройка ОС) | AMI с Packer или EC2 Image Builder |
| `ansible-vault` | AWS Secrets Manager, SSM Parameter Store (для зашифрованных значений) |
| плейбук по SSH | SSM Run Command, State Manager |
| `site.yml` целиком | User Data + CloudFormation `cfn-init` |
| `--limit` на группу | Target по тегу в SSM |

## Практика

Целевая машина: ВМ `notes-vm` из уроков 6.2 и 7.2 (или Multipass-ВМ Ubuntu 24.04). Inventory и `ansible.cfg` готовы с урока 7.4. Работаем в `~/notes/infra/ansible/`.

### Задание 1. Роль docker: apt-репозиторий Docker

**Цель:** установить Docker Engine и Compose-плагин из официального apt-репозитория, чтобы повторный запуск ничего не менял.

**Предскажи:** сколько задач покажут `changed` при втором запуске роли? Почему? 

<details markdown="1">
<summary>Ответ</summary>

Ноль. Модули `apt`, `get_url`, `apt_repository` и `service` проверяют состояние и меняют его только при расхождении.

</details>

**Шаги:**

1. Создай каталоги роли:

   ```bash
   cd ~/notes/infra/ansible
   mkdir -p roles/docker/{tasks,defaults,handlers}
   ```

2. `roles/docker/defaults/main.yml`:

{% raw %}
   ```yaml
   # Релиз Ubuntu для репозитория Docker (можно перебить, если у Docker нет нового)
   docker_apt_release: "{{ ansible_facts['distribution_release'] }}"
   # Пакеты, которые ставим из репозитория Docker
   docker_packages:
     - docker-ce
     - docker-ce-cli
     - containerd.io
     - docker-compose-plugin
   ```
{% endraw %}

3. `roles/docker/tasks/main.yml`:

{% raw %}
   ```yaml
   - name: Зависимости для apt по HTTPS
     ansible.builtin.apt:
       name: [ca-certificates, curl]
       state: present
       update_cache: true
       cache_valid_time: 3600

   - name: Каталог для ключей apt
     ansible.builtin.file:
       path: /etc/apt/keyrings
       state: directory
       mode: "0755"

   - name: Ключ репозитория Docker
     ansible.builtin.get_url:
       url: https://download.docker.com/linux/ubuntu/gpg
       dest: /etc/apt/keyrings/docker.asc
       mode: "0644"

   - name: Репозиторий Docker
     ansible.builtin.apt_repository:
       repo: >-
         deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc]
         https://download.docker.com/linux/ubuntu
         {{ docker_apt_release }} stable
       filename: docker
       state: present

   - name: Docker Engine и Compose-плагин
     ansible.builtin.apt:
       name: "{{ docker_packages }}"
       state: present
       update_cache: true
     notify: Перезапустить docker

   - name: Docker запущен и включён при старте
     ansible.builtin.service:
       name: docker
       state: started
       enabled: true
   ```
{% endraw %}

4. `roles/docker/handlers/main.yml`:

   ```yaml
   - name: Перезапустить docker
     ansible.builtin.service:
       name: docker
       state: restarted
   ```

5. Временный плейбук `site.yml`:

   ```yaml
   - name: Настройка сервера «Заметок»
     hosts: notes
     become: true
     roles:
       - docker
   ```

6. Запусти дважды:

   ```bash
   ansible-playbook site.yml
   ansible-playbook site.yml
   ```

**Что должно получиться:** в конце второго запуска:

```text
PLAY RECAP *********************************************************************
notes-vm                   : ok=7    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

Проверка на ВМ: `ansible notes -a "docker compose version"` печатает `Docker Compose version v5.x`.

**Объясни себе:**

- Зачем `signed-by` и ключ в `/etc/apt/keyrings`, а не `apt-key`?
- Почему `distribution_release` берётся из фактов, а не пишется руками?
- Когда сработает handler и почему не при втором запуске?

**Типичные ошибки:**

- `E: The repository 'https://download.docker.com/linux/ubuntu resolute Release' does not have a Release file.`: у Docker ещё нет каталога для нового релиза Ubuntu. Проверь актуальный список на странице установки Docker и временно укажи предыдущий LTS в переменной `docker_apt_release` вместо факта.
- `fatal: [notes-vm]: FAILED! => {"msg": "Missing sudo password"}`: забыт `become: true` или на ВМ нет `NOPASSWD`. Проверь урок 7.4.
- `changed=1` на каждом запуске у `apt_repository`: repo записан разными строками (лишние пробелы). Оставь одну форму записи `>-`.

### Задание 2. Vault: зашифруй пароль БД

**Цель:** положить пароль БД в зашифрованный файл и убедиться, что в git он не читается.

**Предскажи:** что покажет `cat group_vars/all/vault.yml` после шифрования: пароль, часть пароля или что-то ещё?

<details markdown="1">
<summary>Ответ</summary>

Заголовок `$ANSIBLE_VAULT;1.1;AES256` и строки шестнадцатеричного текста. Пароля нет.

</details>

**Шаги:**

1. Сгенерируй пароль vault и пароль БД, ни один не печатай в терминал:

   ```bash
   mkdir -p ~/.notes-secrets && chmod 700 ~/.notes-secrets
   openssl rand -base64 24 > ~/.notes-secrets/ansible-vault-pass
   chmod 600 ~/.notes-secrets/ansible-vault-pass
   ```

2. В `ansible.cfg` в секцию `[defaults]` добавь строку:

   ```ini
   vault_password_file = ~/.notes-secrets/ansible-vault-pass
   ```

3. Создай открытый файл и шифруемый файл:

{% raw %}
   ```bash
   mkdir -p group_vars/all
   printf '# Секреты из vault.yml через префикс vault_\nnotes_db_password: "%s"\n' '{{ vault_notes_db_password }}' > group_vars/all/vars.yml
   printf 'vault_notes_db_password: "%s"\n' "$(openssl rand -base64 24)" > group_vars/all/vault.yml
   ansible-vault encrypt group_vars/all/vault.yml
   ```
{% endraw %}

4. Проверь, что видно снаружи и что внутри:

   ```bash
   head -n 2 group_vars/all/vault.yml
   ansible-vault view group_vars/all/vault.yml | sed 's/: ".*"/: "***"/'
   ```

**Что должно получиться:**

```text
$ANSIBLE_VAULT;1.1;AES256
36323431386533613538323261353762313331366335363330333462303836666436396264316531
vault_notes_db_password: "***"
```

**Объясни себе:**

- Зачем два файла, а не один зашифрованный `vars.yml`?
- Что будет с историей git, если ты потеряешь пароль vault?
- Почему пароль БД генерируется, а не придумывается?

**Типичные ошибки:**

- `ERROR! Attempting to decrypt but no vault secrets found`: в `ansible.cfg` нет `vault_password_file` и не передан `--ask-vault-pass`. Добавь строку из шага 2.
- `ERROR! Decryption failed (no vault secrets were found that could decrypt)`: пароль в файле не тот, которым шифровали. Восстанови верный пароль или зашифруй файл заново.
- `Vault format unhexlify error: Odd-length string`: файл повреждён при правке вручную. Верни из git прежнюю версию.

### Задание 3. Роль notes: compose и .env из vault

**Цель:** роль кладёт на ВМ `compose.yml` и `.env` (читают только `root` и группа `notes`), затем поднимает стек.

**Предскажи:** какие права будут у `/etc/notes/notes.env` и кто сможет его прочитать на ВМ? Почему это важно в модуле `template`?

<details markdown="1">
<summary>Ответ</summary>

Владелец `root`, группа `notes`, режим `0640`. Читают `root` и участники `notes`. Режим задаётся в самой задаче, иначе пароль окажется на диске с umask по умолчанию (`0644`), доступный всем.

</details>

**Шаги:**

1. Каталоги и зависимость от роли `docker`:

   ```bash
   mkdir -p roles/notes/{tasks,defaults,meta,templates}
   cat > roles/notes/meta/main.yml <<'YML'
   # Роль docker выполняется до notes автоматически
   dependencies:
     - role: docker
   YML
   ```

2. `roles/notes/defaults/main.yml`:

   ```yaml
   notes_tag: "0.4.1"                  # тег образа, latest не используем
   notes_image: "ghcr.io/CHANGE_ME/notes"   # замени на свой github-user
   notes_dir: /opt/notes               # код и compose, владелец root
   notes_env_dir: /etc/notes           # конфиг, режим 640 root:notes
      ```

3. `roles/notes/tasks/main.yml`:

{% raw %}
   ```yaml
   - name: Системная группа notes
     ansible.builtin.group:
       name: notes
       system: true

   - name: Каталоги проекта
     ansible.builtin.file:
       path: "{{ item.path }}"
       state: directory
       owner: root
       group: "{{ item.group }}"
       mode: "{{ item.mode }}"
     loop:
       - { path: "{{ notes_dir }}", group: root, mode: "0755" }
       - { path: "{{ notes_env_dir }}", group: notes, mode: "0750" }

   - name: Файл окружения с паролем БД
     ansible.builtin.template:
       src: notes.env.j2
       dest: "{{ notes_env_dir }}/notes.env"
       owner: root
       group: notes
       mode: "0640"
     no_log: true

   - name: compose.yml
     ansible.builtin.template:
       src: compose.yml.j2
       dest: "{{ notes_dir }}/compose.yml"
       owner: root
       group: root
       mode: "0644"

   - name: Стек запущен
     community.docker.docker_compose_v2:
       project_src: "{{ notes_dir }}"
       env_files:
         - "{{ notes_env_dir }}/notes.env"
       state: present
       pull: missing

   - name: Приложение отвечает на /healthz
     ansible.builtin.uri:
       url: http://127.0.0.1/healthz
       status_code: 200
     register: notes_health
     retries: 10
     delay: 3
     until: notes_health.status == 200
   ```
{% endraw %}

4. `roles/notes/templates/notes.env.j2`:

{% raw %}
   ```text
   POSTGRES_PASSWORD={{ notes_db_password }}
   DATABASE_URL=postgresql://notes:{{ notes_db_password }}@db:5432/notes
   APP_VERSION={{ notes_tag }}
   ```
{% endraw %}

5. `roles/notes/templates/compose.yml.j2`:

{% raw %}
   ```yaml
   services:
     notes:
       image: {{ notes_image }}:{{ notes_tag }}
       ports:
         - "80:8080"      # TLS и nginx перед приложением: урок 6.3
       env_file: {{ notes_env_dir }}/notes.env
       restart: unless-stopped
       depends_on:
         db:
           condition: service_healthy
     db:
       image: postgres:18
       environment:
         POSTGRES_USER: notes
         POSTGRES_DB: notes
         POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
       volumes:
         - pgdata:/var/lib/postgresql
       healthcheck:
         test: ["CMD-SHELL", "pg_isready -U notes -d notes"]
         interval: 5s
         retries: 10
       restart: unless-stopped
   volumes:
     pgdata:
   ```
{% endraw %}

6. Обнови `site.yml`, оставив только роль `notes` (`docker` придёт по зависимости) и запусти:

   ```bash
   cat > site.yml <<'YML'
   - name: Настройка сервера «Заметки»
     hosts: notes
     become: true
     roles:
       - notes
   YML
   ansible-galaxy collection install community.docker:==5.0.0
   ansible-playbook site.yml
   ```

**Что должно получиться:** запуск заканчивается `failed=0`, а на ВМ:

```text
$ ansible notes -a "stat -c '%a %U:%G' /etc/notes/notes.env"
notes-vm | CHANGED | rc=0 >>
640 root:notes
```

Проверка сайта: `curl -s http://<IP ВМ>/healthz` печатает `ok`. Повторный запуск с `--check --diff` даёт `changed=0`.

**Объясни себе:**

- Почему пароль не появился в выводе плейбука?
- Что произойдёт, если поменять только `notes_tag` и запустить снова?

**Типичные ошибки:**

- `fatal: [notes-vm]: FAILED! => {"msg": "The task includes an option with an undefined variable. The error was: 'notes_db_password' is undefined"}`: не подхватился `group_vars/all/vars.yml`. Каталог `group_vars` должен лежать рядом с inventory или плейбуком.
- `ERROR! couldn't resolve module/action 'community.docker.docker_compose_v2'`: не установлена коллекция. Выполни `ansible-galaxy collection install community.docker:==5.0.0`.
- `manifest unknown`: образа с таким тегом нет в реестре. Проверь `notes_image` и `notes_tag`.

### Задание 4. Шаг проекта: «Заметки» одним запуском на чистой ВМ

**Цель:** зафиксировать роли в репозитории и проверить полный цикл на чистой ВМ.

**Шаги:**

1. Добавь `requirements.yml`:

   ```yaml
   collections:
     - name: community.docker
       version: "5.0.0"
   ```

2. Закоммить и запусти на свежей ВМ (пересоздай её или удали контейнеры и `/opt/notes`):

   ```bash
   cd ~/notes
   git add infra/ansible
   git commit -m "feat(infra): роли docker и notes, vault для пароля БД"
   cd infra/ansible
   ansible-galaxy collection install -r requirements.yml
   time ansible-playbook site.yml
   ```

3. Проверь снаружи и повторно:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://<IP ВМ>/healthz
   ansible-playbook site.yml | tail -n 3
   ```

**Что должно получиться:**

```text
200
PLAY RECAP *********************************************************************
notes-vm                   : ok=17   changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

Эталон: [infra/ansible в репозитории курса](https://github.com/distinguished-sre/devops/tree/devops/project/notes/infra/ansible).

**Объясни себе:**

- Что осталось долгом: где хранится пароль vault и что будет при смене ноутбука?

**Типичные ошибки:**

- `UNREACHABLE! => {"msg": "Failed to connect to the host via ssh: ... Permission denied (publickey)."}`: у ВМ пересоздан ключ или сменился IP. Обнови `inventory.yml` (урок 7.4).
- `Could not find or access 'notes.env.j2'`: шаблон лежит не в `roles/notes/templates/`.

## Сломай и почини

Запусти скрипт из клона курса и не читай его: `bash <клон-курса>/project/notes/break/7.6/break.sh random` (или номер 1-3). Он вносит одну из трёх поломок в `~/notes/infra/ansible`.

### Симптом

После запуска `ansible-playbook site.yml` падает. В выводе одна из картин: ошибка про vault («Decryption failed»), «is undefined» в задаче шаблона, или Compose-задача падает потому, что Docker на ВМ ещё не поставлен.

### Гипотезы

- Роли выстроены в неверном порядке, зависимость `docker` потеряна.
- Файл vault зашифрован другим паролем или в `ansible.cfg` указан не тот файл пароля.
- В шаблоне опечатка в имени переменной либо переменная не объявлена.

### Проверки

```bash
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --list-tasks
ansible-vault view group_vars/all/vault.yml >/dev/null && echo vault-ok
ansible -m debug -a "var=notes_db_password" notes
grep -rn "dependencies" roles/notes/meta/main.yml
```

Порядок в `--list-tasks` показывает, идёт ли `docker` до `notes`. Вывод `vault-ok` подтверждает пароль. Отсутствие переменной в `debug` указывает на `group_vars`.

### Исправление

<details markdown="1">
<summary>Разбор всех сценариев</summary>

1. Неверный порядок ролей: в `meta/main.yml` роли `notes` снова допиши `dependencies: [{role: docker}]` либо переставь роли в `site.yml`. Задачи Compose теперь идут после установки Docker.
2. Неверный пароль vault: проверь `vault_password_file` в `ansible.cfg` и файл `~/.notes-secrets/ansible-vault-pass`. Если пароль потерян, файл `vault.yml` пересоздают заново и шифруют новым паролем, а пароль БД на ВМ меняют.
3. Шаблон Jinja2 без переменной: найди имя в ошибке `'xxx' is undefined`, сверь с `defaults/main.yml` и `group_vars`. Обычно опечатка в шаблоне или пропавшая строка в `vars.yml`.

Профилактика: `ansible-lint`, `--syntax-check` и `--check --diff` перед каждым прогоном.

</details>

## Вопросы с собеседований

### 1. [junior] Что такое роль в Ansible и зачем она нужна?

Роль это каталог с фиксированной структурой (`tasks`, `handlers`, `templates`, `defaults`), которую можно подключить одной строкой. Я выношу туда повторяющуюся настройку вроде Docker или nginx и использую на разных серверах и проектах. Переменные роли задаю через `defaults`, чтобы их можно было переопределить.

**Что хотят услышать:** структура каталогов, `defaults` против `vars`, переиспользование, `meta` и зависимости.

**Красный флаг:** «это то же самое, что плейбук, только в папке».

### 2. [junior] Как хранить пароли в Ansible, чтобы они не попали в git открытым текстом?

Через `ansible-vault`: шифрую файл переменных, пароль от vault держу вне репозитория, в CI он приходит из секретов. В открытом `vars.yml` только ссылки на `vault_*`. Задачам с секретами ставлю `no_log`.

**Что хотят услышать:** шифрование файла целиком или значения (`encrypt_string`), пароль вне репозитория, `no_log`.

**Красный флаг:** «пароль в `.env` и добавлен в `.gitignore`, а на ВМ копируем руками».

### 3. [middle] Я закоммитил пароль vault в git. Что делаешь?

Считаю скомпрометированным и сам vault-файл, и всё, что в нём. Меняю реальные секреты (пароль БД, токены), делаю `ansible-vault rekey`, убираю файл пароля из репозитория. История git всё помнит, поэтому переписывание истории вторично: главное, что секреты ротированы.

**Что хотят услышать:** ротация секретов на первом месте, `rekey`, чистка истории вторым шагом, профилактика (pre-commit, сканер секретов).

**Красный флаг:** «сделаю `git rm` и всё».

### 4. [middle] Роль отработала без ошибок, но приложение на ВМ не поднялось. Как ищешь?

Смотрю на ВМ `docker compose ps` и `logs`, а не на вывод Ansible: `changed` не означает «работает». Проверяю, что шаблон отрисовался верно (`--check --diff`), права на `.env` и что переменные пришли из нужного места (`debug var=`). Затем добавляю в роль задачу `uri` с `retries`, чтобы такая ошибка ловилась сразу.

**Что хотят услышать:** проверка результата на цели, `debug`, `--diff`, health-check внутри роли.

**Красный флаг:** «перезапускаю плейбук, пока не заработает».

### 5. [middle] Переменная задана в трёх местах, а применяется не та. Как разбираешься?

Знаю порядок приоритета: `defaults` роли самые слабые, дальше `group_vars`, `host_vars`, `vars` роли, `-e` сильнее всех. Итоговое значение смотрю `ansible -m debug -a var=...` по конкретному хосту. Ищу лишний `-e` в CI и `vars` роли.

**Что хотят услышать:** порядок приоритетов, способ посмотреть итог, где искать перекрытие.

**Красный флаг:** «просто задам во всех местах одинаково».

### 6. [junior] Что значит «идемпотентно» на примере Ansible?

Повторный запуск не меняет систему, если она уже в нужном состоянии. Модуль `apt` с `state: present` ничего не ставит второй раз, а итог `changed=0`. Ломают идемпотентность `command` и `shell` без `creates` или `changed_when`.

**Что хотят услышать:** пример модуля, признак `changed=0`, ловушка с `shell`.

**Красный флаг:** «идемпотентно значит быстро».

### 7. [middle] Нужно обновить приложение на 20 серверах без простоя. Как сделаешь через Ansible?

Использую `serial` в плейбуке: обновляю по 1-2 сервера, после каждого пакета проверяю health-check и только затем иду дальше. Ставлю `max_fail_percentage`, чтобы остановить раскатку при первых ошибках. Серверы выводят из балансировщика на время обновления через `delegate_to`.

**Что хотят услышать:** `serial`, проверка здоровья, остановка при сбое, вывод из балансировки.

**Красный флаг:** «запущу на всех сразу, Ansible идемпотентный».

### 8. [middle] Плейбук на проде падает посередине. Что будет с сервером и что делаешь?

Ansible не откатывает: выполненные задачи остаются. Смотрю, на какой задаче упал, исправляю причину и запускаю снова: идемпотентность доведёт состояние. Если нужен откат, он должен быть заложен в дизайн: `block/rescue` или деплой по тегу образа, который можно вернуть.

**Что хотят услышать:** отсутствие автоотката, безопасность повторного запуска, `block/rescue`, откат по версии.

**Красный флаг:** «Ansible сам откатит изменения».

### 9. [junior] Чем `ansible-vault` отличается от HashiCorp Vault?

`ansible-vault` шифрует файл и работает только в связке с Ansible, пароль один на файл. HashiCorp Vault это сервис: политики доступа, аудит, динамические секреты. Для одного проекта хватает первого, для команды и множества сервисов нужен второй.

**Что хотят услышать:** файл против сервиса, аудит и политики, границы применимости.

**Красный флаг:** «это одно и то же».

### 10. [middle] Как проверять роли, чтобы не ломать прод? 

Прогоняю `ansible-lint` и `--syntax-check` в CI, затем `--check --diff` на стенде. Для ролей, которыми пользуются многие, гоняю Molecule (контейнеры или ВМ) и повторный запуск с проверкой `changed=0`.

**Что хотят услышать:** lint, check-режим, тестовый стенд, проверка идемпотентности.

**Красный флаг:** «проверяю сразу на проде, роль же простая».

## Проверено на версиях

- Ansible: версия ansible-core не закреплена, проверь актуальную версию на странице проекта
- community.docker: 5.0.0 (проверь актуальную версию на странице коллекции)
- Docker Engine и Compose-плагин: из apt-репозитория Docker, версия не закреплена, проверь актуальную версию на странице проекта
- PostgreSQL: 18
- nginx: 1.30
- «Заметки»: образ 0.4.1
- Ubuntu на ВМ: 26.04 LTS или 24.04

## Итог урока: ты умеешь

- [ ] умею выделить настройку в роль (`tasks`, `handlers`, `templates`, `defaults`)
- [ ] умею закрепить порядок ролей через `meta/main.yml`
- [ ] умею шифровать секреты `ansible-vault` и хранить пароль vault вне репозитория
- [ ] умею отрисовать `.env` с правами 640 из vault и не показать пароль в логе
- [ ] умею поднять стек Compose модулем `community.docker.docker_compose_v2`
- [ ] умею смотреть приоритет переменных через `debug`
- [ ] умею проверить плейбук `--check --diff`, `ansible-lint` и повторным запуском

**Дальше:** [Урок 7.7: Terraform + Ansible: конвейер с нуля, drift](07-terraform-ansible-drift.md)
