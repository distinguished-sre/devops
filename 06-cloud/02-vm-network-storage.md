---
layout: lesson
title: "ВМ, сеть и диски в облаке"
topic: 6
lesson: "6.2"
time: "2 ч"
---

## Зачем это нужно

Облачная ВМ это не «сервер в интернете», а набор отдельных ресурсов: сеть, подсеть, правила доступа, загрузочный диск, диск данных, публичный адрес. Каждый ресурс создаётся, тарифицируется и ломается отдельно. Типичные инциденты новичка: `Connection timed out` из-за забытого правила, пропавший после перезагрузки диск, счёт за забытый публичный IP.
Ты соберёшь всё руками и проверишь по SSH, чтобы в теме 7 понимать, что именно описывает Terraform.

Шаг проекта: в репозитории «Заметок» появляется `infra/manual/create-vm.sh`, который создаёт сеть, подсеть, группу безопасности, ВМ `notes-vm`, отдельный диск данных и бакет. Приложение не меняется (0.4.1).

## Что нужно знать

- [Урок 6.1: облако, аккаунт, деньги](01-cloud-models-aws-mapping.md) - каталог `notes`, CLI `yc`, бюджет-алерт
- [Урок 2.1: адреса и маршруты](../02-network/01-addresses-routes.md) - CIDR, подсеть, NAT
- [Урок 2.2: порты, TCP, SSH](../02-network/02-ports-tcp-ssh.md) - refused против timeout, SSH-ключи
- [Урок 2.7: файрвол](../02-network/07-firewall.md) - правила allow и deny, «по умолчанию всё закрыто»
- [Урок 1.5: диск, память, CPU](../01-linux/05-disk-memory-cpu.md) - `df`, `lsblk`, файловые системы
- [Урок 1.3: пользователи и права](../01-linux/03-users-permissions.md) - владелец каталога данных

Трек без облака: на Ubuntu с Multipass все шаги делаются локально, отличия помечены в заданиях как «Трек без облака».

## Теория

### Из чего состоит ВМ в облаке

ВМ (virtual machine, instance) в облаке это связка ресурсов:

- **Облачная сеть** (VPC, virtual private cloud): изолированное пространство адресов. Сама по себе ничего не маршрутизирует.
- **Подсеть** (subnet): кусок сети с CIDR (например `10.10.0.0/24`), привязанный к одной зоне доступности (availability zone, AZ, например `ru-central1-a`). Подсеть живёт в зоне, сеть охватывает регион.
- **Сетевой интерфейс ВМ** берёт внутренний адрес из подсети. Публичный адрес это отдельная сущность: NAT «один к одному» (one-to-one NAT) между публичным и внутренним адресом.
- **Группа безопасности** (security group, SG): файрвол с отслеживанием соединений (stateful) на уровне интерфейса ВМ. Разрешил входящий 22, ответы идут сами. Входящее закрыто, пока не разрешено правилом.
- **Загрузочный диск** создаётся из образа (image), например семейства `ubuntu-2404-lts`.
- **Диск данных** отдельный сетевой диск: живёт независимо от ВМ, его можно отсоединить и присоединить к другой ВМ.

> **Проверь понимание:** ты удалил ВМ командой `yc compute instance delete`. Какие ресурсы могли остаться и продолжать стоить денег?

<details>
<summary>Ответ</summary>

Диск данных (он отдельный ресурс), зарезервированный статический публичный IP, снапшоты, бакет. Загрузочный диск обычно удаляется вместе с ВМ, но флаг `auto-delete` проверь. Поэтому после уборки смотрят `yc compute disk list` и `yc vpc address list`.

</details>

### Группа безопасности и два вида отказа

Из [урока 2.2](../02-network/02-ports-tcp-ssh.md) ты помнишь: `Connection refused` значит, что до хоста дошли, но порт никто не слушает. `Connection timed out` значит, что пакеты молча выброшены. В облаке timeout на порт 22 почти всегда одно из трёх: нет публичного IP, SG не пускает твой адрес, ты ходишь не на тот адрес.

Правило SG состоит из направления, протокола, порта и источника (CIDR или другая группа). Принцип наименьших привилегий (least privilege): 22 только с твоего адреса (`<твой-IP>/32`), 80 и 443 со всего интернета (`0.0.0.0/0`), всё остальное закрыто. Порт 8080 приложения снаружи не открывается: наружу смотрит nginx (урок 6.3).

> **Проверь понимание:** зачем правило для 22 ограничивать `/32`, если на ВМ и так вход только по ключу?

<details>
<summary>Ответ</summary>

Ключ защищает от входа, но не от перебора и шума: на открытый 22 сыплются тысячи попыток в час, они грузят sshd и засоряют логи. Любая будущая уязвимость sshd получает меньше целей. Ограничение по адресу это второй слой защиты (defense in depth).

</details>

### Диски: блочное устройство, файловая система, fstab

Сетевой диск приходит в ВМ как сырое блочное устройство (block device), например `/dev/vdb`. Нужны три шага: создать файловую систему (`mkfs.ext4`), смонтировать (`mount`) и записать в `/etc/fstab`, иначе после перезагрузки диск не смонтируется. В `fstab` диск указывают по UUID, а не по имени `/dev/vdb`: имена устройств могут поменяться при следующей загрузке. Опция `nofail` не даёт ВМ зависнуть на загрузке, если диска нет.

Для «Заметок» диск данных монтируется в `/var/lib/notes` (владелец `notes:notes`, режим 750, константы курса, права см. [урок 1.3](../01-linux/03-users-permissions.md)). Там будет лежать PostgreSQL из compose в уроке 6.3, поэтому данные переживут пересоздание ВМ.

> **Проверь понимание:** что произойдёт с данными в `/var/lib/notes`, если смонтировать диск поверх непустого каталога?

<details>
<summary>Ответ</summary>

Старое содержимое не удаляется, но становится невидимым, пока диск смонтирован (mount shadowing). После `umount` оно снова появится. Поэтому монтируют в пустой каталог или сначала переносят данные.

</details>

### Объектное хранилище

Бакет (bucket) это плоское хранилище объектов с доступом по HTTP API, совместимому с S3. Это не диск: его не смонтируешь как `/dev/vdb` и не положишь на него PostgreSQL. Он нужен для бэкапов, статики, артефактов и (в теме 7) state Terraform. Имя бакета уникально глобально. Доступ по статическому ключу (access key + secret key) сервисного аккаунта, права выдаются ролью. Публичным бакет делать не нужно.

> **Проверь понимание:** чем диск данных отличается от бакета и что куда кладут в «Заметках»?

<details>
<summary>Ответ</summary>

Диск это блочное устройство с файловой системой, быстрое, привязано к зоне, подключается к одной ВМ: сюда идут файлы PostgreSQL. Бакет это объекты по HTTP, доступны отовсюду, дёшево и надёжно хранят: сюда идут бэкапы (урок 6.5).

</details>

### Соответствие AWS

| Yandex Cloud | AWS | Заметка |
|---|---|---|
| Compute Cloud, `yc compute instance` | EC2 | ВМ; `core-fraction` похож на burstable-типы t3 |
| Облачная сеть (network) | VPC | сеть на регион |
| Подсеть (subnet) | Subnet | привязана к зоне |
| Группа безопасности | Security Group | stateful, привязана к интерфейсу |
| Публичный адрес ВМ (NAT) | Elastic IP (или auto-assign) | статический адрес это отдельный платный ресурс |
| Сетевой диск | EBS | зональный, отделим от ВМ |
| Снапшот диска | EBS Snapshot | инкрементальный |
| Object Storage | S3 | тот же S3 API, endpoint `storage.yandexcloud.net` |
| Пользователь `yc-user` | `ec2-user` или `ubuntu` | имя задаёт образ или cloud-init |
| Сервисный аккаунт и роли | IAM role и user | статический ключ для S3 |

## Практика

Перед началом: `yc` настроен по уроку 6.1 (`yc config list` показывает каталог `notes`), бюджет-алерт создан, установлен `jq`. Все ресурсы имеют префикс `notes-`, чтобы их было легко найти и удалить.

### Задание 1. Сеть, подсеть и группа безопасности

**Цель:** создать сетевую основу и убедиться, что SG пускает только то, что ты разрешил.

**Предскажи:** сколько правил в группе после создания командой ниже? Какой трафик входит без правил?

<details>
<summary>Ответ</summary>

Четыре правила: три входящих (22, 80, 443) и одно исходящее. Без явного входящего правила входящий трафик закрыт.

</details>

**Шаги:**

1. Узнай свой внешний адрес, чтобы пустить только его на SSH:

```bash
MY_IP=$(curl -s https://ifconfig.me)
echo "$MY_IP"
```

2. Создай сеть и подсеть:

```bash
yc vpc network create --name notes-net
yc vpc subnet create --name notes-subnet-a \
  --network-name notes-net \
  --zone ru-central1-a \
  --range 10.10.0.0/24
```

3. Создай группу безопасности: SSH только с твоего адреса, HTTP и HTTPS отовсюду, исходящее всё:

```bash
yc vpc security-group create --name notes-sg \
  --network-name notes-net \
  --rule "direction=ingress,port=22,protocol=tcp,v4-cidrs=[${MY_IP}/32]" \
  --rule "direction=ingress,port=80,protocol=tcp,v4-cidrs=[0.0.0.0/0]" \
  --rule "direction=ingress,port=443,protocol=tcp,v4-cidrs=[0.0.0.0/0]" \
  --rule "direction=egress,protocol=any,v4-cidrs=[0.0.0.0/0]"
```

4. Проверь:

```bash
yc vpc network list
yc vpc subnet list
yc vpc security-group get notes-sg --format json | jq -c '.rules[] | {direction, ports, protocol_name}'
```

**Что должно получиться:**

```text
{"direction":"INGRESS","ports":{"from_port":"22","to_port":"22"},"protocol_name":"TCP"}
{"direction":"INGRESS","ports":{"from_port":"80","to_port":"80"},"protocol_name":"TCP"}
{"direction":"INGRESS","ports":{"from_port":"443","to_port":"443"},"protocol_name":"TCP"}
{"direction":"EGRESS","ports":{"from_port":"0","to_port":"65535"},"protocol_name":"ANY"}
```

**Объясни себе:**

- Почему подсеть привязана к зоне, а сеть нет?
- Зачем исходящее правило, если ответы на разрешённые входящие идут автоматически?
- Что сломается, если твой домашний IP сменится?

**Типичные ошибки:**

- `ERROR: rpc error: code = AlreadyExists desc = Network with name notes-net already exists`: ресурс уже создан, это повторный запуск; проверь `yc vpc network list`, второй не создавай.
- `ERROR: rpc error: code = PermissionDenied desc = Permission denied`: у профиля нет роли `vpc.admin` или `editor` на каталог; проверь `yc config list` и роли (урок 6.1).
- `invalid rule: v4-cidrs=[/32]`: переменная `MY_IP` пустая, `curl` не вернул адрес; повтори шаг 1 и проверь `echo "$MY_IP"`.

Трек без облака: сетей и SG нет, роль SG играет `ufw` из [урока 2.7](../02-network/07-firewall.md) на самой ВМ. Переходи к заданию 2.

### Задание 2. ВМ и вход по SSH

**Цель:** создать ВМ `notes-vm` с публичным IP и зайти на неё.

**Предскажи:** что увидит `ip -br a` внутри ВМ: публичный или внутренний адрес?

<details>
<summary>Ответ</summary>

Только внутренний `10.10.0.x`. Публичный адрес это NAT снаружи, гостевая ОС его не знает.

</details>

**Шаги:**

1. Сгенерируй отдельный ключ для курса:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/notes_ed25519 -C "notes-course" -N ""
```

2. Создай ВМ: 2 vCPU с гарантированной долей 20%, 2 ГБ RAM, загрузочный диск 20 ГБ:

```bash
SG_ID=$(yc vpc security-group get notes-sg --format json | jq -r .id)
yc compute instance create \
  --name notes-vm \
  --zone ru-central1-a \
  --platform standard-v3 \
  --cores 2 --core-fraction 20 --memory 2 \
  --network-interface "subnet-name=notes-subnet-a,nat-ip-version=ipv4,security-group-ids=${SG_ID}" \
  --create-boot-disk image-family=ubuntu-2404-lts,image-folder-id=standard-images,size=20 \
  --ssh-key ~/.ssh/notes_ed25519.pub
```

3. Возьми публичный адрес и зайди:

```bash
VM_IP=$(yc compute instance get notes-vm --format json | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')
echo "$VM_IP"
ssh -i ~/.ssh/notes_ed25519 yc-user@"$VM_IP"
```

4. Внутри ВМ:

```bash
hostnamectl | grep 'Operating System'
ip -br a
lsblk
```

**Что должно получиться:**

```text
  Operating System: Ubuntu 24.04.x LTS
lo               UNKNOWN        127.0.0.1/8
eth0             UP             10.10.0.NN/24
NAME    MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS
vda     252:0    0  20G  0 disk
```

**Объясни себе:**

- Почему `ip -br a` не показывает публичный IP?
- Откуда взялся пользователь `yc-user` и твой ключ в нём? Что даёт `core-fraction 20`?

**Типичные ошибки:**

- `ssh: connect to host 203.0.113.10 port 22: Connection timed out`: SG не пускает твой адрес (IP сменился) или нет публичного адреса; проверь правило 22 и поле `one_to_one_nat`.
- `yc-user@203.0.113.10: Permission denied (publickey).`: ключ не тот или нет `-i`; при создании должен быть передан `.pub`, при входе приватный ключ.
- `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`: ты пересоздал ВМ, а адрес переиспользован; удали старую запись `ssh-keygen -R <IP>`.

Трек без облака: `multipass launch 24.04 --name notes-vm --cpus 2 --memory 2G --disk 20G`, вход `multipass shell notes-vm`, адрес `multipass info notes-vm | grep IPv4`.

### Задание 3. Диск данных, файловая система и fstab

**Цель:** подключить отдельный диск, смонтировать его в `/var/lib/notes` и пережить перезагрузку.

**Предскажи:** смонтировал руками, всё работает. Что будет после `sudo reboot` без записи в `/etc/fstab`?

<details>
<summary>Ответ</summary>

`/var/lib/notes` станет обычным пустым каталогом на загрузочном диске, диск данных останется неподключённым. Сервис молча пишет данные на загрузочный диск.

</details>

**Шаги:**

1. С компьютера, где стоит `yc`, создай диск на 10 ГБ и присоедини к ВМ (та же зона):

```bash
yc compute disk create --name notes-data --zone ru-central1-a --size 10 --type network-ssd
yc compute instance attach-disk notes-vm --disk-name notes-data --device-name notes-data --mode rw
```

2. На ВМ найди диск по имени устройства, которое ты задал:

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
ls -l /dev/disk/by-id/ | grep notes-data
```

3. Создай файловую систему и смонтируй (диск пустой; на диске с данными `mkfs` их уничтожит):

```bash
sudo mkfs.ext4 -L notes-data /dev/disk/by-id/virtio-notes-data
sudo mkdir -p /var/lib/notes
sudo mount /dev/disk/by-id/virtio-notes-data /var/lib/notes
```

4. Запиши в `fstab` по UUID с `nofail` и проверь без перезагрузки:

```bash
UUID=$(sudo blkid -s UUID -o value /dev/disk/by-id/virtio-notes-data)
echo "UUID=${UUID} /var/lib/notes ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo umount /var/lib/notes
sudo mount -a
findmnt /var/lib/notes
```

5. Владелец и режим по контракту курса:

```bash
sudo useradd --system --home /var/lib/notes --shell /usr/sbin/nologin notes
sudo chown notes:notes /var/lib/notes
sudo chmod 750 /var/lib/notes
ls -ld /var/lib/notes
```

6. Перезагрузи и проверь:

```bash
sudo reboot
# подожди минуту и зайди снова
findmnt /var/lib/notes
df -h /var/lib/notes
```

**Что должно получиться:**

```text
TARGET         SOURCE    FSTYPE OPTIONS
/var/lib/notes /dev/vdb  ext4   rw,relatime
drwxr-x--- 2 notes notes 4096 Sep 29 12:00 /var/lib/notes
Filesystem      Size  Used Avail Use% Mounted on
/dev/vdb        9.8G   24K  9.3G   1% /var/lib/notes
```

**Объясни себе:**

- Почему в `fstab` пишут UUID, а не `/dev/vdb`?
- Что делает `nofail` и чем опасен для сервиса, которому нужен диск?
- Зачем `mount -a` до перезагрузки?

**Типичные ошибки:**

- `mount: /var/lib/notes: can't find in /etc/fstab.`: записи нет; повтори шаг 4.
- `mount: /var/lib/notes: wrong fs type, bad option, bad superblock on /dev/vdb`: на диске нет файловой системы (пропущен `mkfs`).
- `mkfs.ext4: /dev/vdb is mounted; will not make a filesystem here!`: диск смонтирован; сначала `umount`.
- `/var/lib/notes` пуст после ребута: запись в fstab с опечаткой в UUID; `sudo mount -a` покажет ошибку.

Трек без облака: диска нет, используй файл-образ через loop:

```bash
sudo truncate -s 2G /opt/notes-data.img
sudo mkfs.ext4 -F -L notes-data /opt/notes-data.img
echo "/opt/notes-data.img /var/lib/notes ext4 loop,nofail 0 2" | sudo tee -a /etc/fstab
sudo mkdir -p /var/lib/notes
sudo mount -a
```

### Задание 4. Бакет и загрузка файла по S3 API

**Цель:** создать бакет, выдать доступ сервисному аккаунту, положить и забрать файл.

**Предскажи:** хватит ли твоих прав администратора в `yc`, чтобы выполнить `aws s3 cp`?

<details>
<summary>Ответ</summary>

Нет. `yc` ходит в API облака, а `aws s3` в S3 API, которому нужна пара access key и secret key. Ключ создаётся для сервисного аккаунта.

</details>

**Шаги:**

1. Бакет и сервисный аккаунт с ролью на запись:

```bash
BUCKET="notes-backups-$(openssl rand -hex 4)"
echo "$BUCKET"
yc storage bucket create --name "$BUCKET"
yc iam service-account create --name notes-s3
SA_ID=$(yc iam service-account get notes-s3 --format json | jq -r .id)
FOLDER_ID=$(yc config get folder-id)
yc resource-manager folder add-access-binding "$FOLDER_ID" \
  --role storage.editor --subject serviceAccount:"$SA_ID"
```

2. Статический ключ и AWS CLI в отдельном профиле (`pip` только в venv или pipx):

```bash
yc iam access-key create --service-account-name notes-s3 --format json > ~/notes-s3-key.json
pipx install awscli
aws configure set aws_access_key_id "$(jq -r .access_key.key_id ~/notes-s3-key.json)" --profile yandex
aws configure set aws_secret_access_key "$(jq -r .secret ~/notes-s3-key.json)" --profile yandex
aws configure set region ru-central1 --profile yandex
shred -u ~/notes-s3-key.json
```

3. Загрузи и прочитай файл:

```bash
echo "проверка $(date +%F)" > hello.txt
aws --profile yandex --endpoint-url https://storage.yandexcloud.net s3 cp hello.txt "s3://${BUCKET}/hello.txt"
aws --profile yandex --endpoint-url https://storage.yandexcloud.net s3 ls "s3://${BUCKET}/"
aws --profile yandex --endpoint-url https://storage.yandexcloud.net s3 cp "s3://${BUCKET}/hello.txt" -
```

**Что должно получиться:**

```text
upload: ./hello.txt to s3://notes-backups-1a2b3c4d/hello.txt
2026-09-29 12:00:00         28 hello.txt
проверка 2026-09-29
```

**Объясни себе:**

- Почему ключ у сервисного аккаунта, а не у тебя лично?
- Почему бакет не делают публичным?
- Где лежит секретный ключ после `aws configure` и как его защитить?

**Типичные ошибки:**

- `An error occurred (AccessDenied) when calling the PutObject operation: Access Denied`: у сервисного аккаунта нет роли `storage.editor` на каталог; проверь access-binding.
- `Could not connect to the endpoint URL: "https://s3.amazonaws.com/..."`: забыт `--endpoint-url`, CLI пошёл в AWS.
- `An error occurred (BucketAlreadyExists) when calling the CreateBucket operation`: имя занято другим пользователем; смени суффикс.
- `An error occurred (InvalidAccessKeyId) when calling the PutObject operation`: ключ скопирован с ошибкой или удалён; создай новый.

Трек без облака: MinIO в Docker. Тег образа возьми на релизной странице проекта (`latest` не используем):

```bash
docker run -d --name minio -p 9000:9000 \
  -e MINIO_ROOT_USER=notes -e MINIO_ROOT_PASSWORD=CHANGE_ME_long_password \
  -v minio-data:/data quay.io/minio/minio:<тег-с-релизной-страницы> server /data
aws --endpoint-url http://localhost:9000 s3 mb s3://notes-backups
```

### Задание 5. Проект «Заметки»: `infra/manual/create-vm.sh`

**Цель:** собрать шаги в один скрипт, безопасный к повторному запуску.

**Предскажи:** что будет при втором запуске скрипта, если сеть уже создана?

<details>
<summary>Ответ</summary>

Без проверки `yc vpc network create` упадёт с `AlreadyExists`, `set -e` прервёт скрипт. Решение: сначала `get`, создавать только если ресурса нет. Это ручная идемпотентность, полноценно её даёт Terraform (тема 7).

</details>

**Шаги:**

1. Создай `~/notes/infra/manual/create-vm.sh`:

```bash
#!/usr/bin/env bash
# Ручное создание стенда «Заметки» в Yandex Cloud (урок 6.2).
# Запуск: SSH_PUB=~/.ssh/notes_ed25519.pub ./create-vm.sh
set -euo pipefail

ZONE="${ZONE:-ru-central1-a}"
SSH_PUB="${SSH_PUB:?укажи путь к публичному ключу в SSH_PUB}"
MY_IP="${MY_IP:-$(curl -s https://ifconfig.me)}"
BUCKET="${BUCKET:-notes-backups-$(openssl rand -hex 4)}"

# Создаём ресурс, только если его ещё нет (безопасный повторный запуск)
ensure() { # ensure "<группа команд yc>" <имя> <команда создания...>
  local kind="$1" name="$2"
  shift 2
  # shellcheck disable=SC2086  # kind намеренно раскрывается в два слова
  if yc $kind get "$name" >/dev/null 2>&1; then
    echo "есть: $kind $name"
  else
    echo "создаю: $kind $name"
    "$@"
  fi
}

ensure "vpc network" notes-net \
  yc vpc network create --name notes-net

ensure "vpc subnet" notes-subnet-a \
  yc vpc subnet create --name notes-subnet-a --network-name notes-net \
    --zone "$ZONE" --range 10.10.0.0/24

ensure "vpc security-group" notes-sg \
  yc vpc security-group create --name notes-sg --network-name notes-net \
    --rule "direction=ingress,port=22,protocol=tcp,v4-cidrs=[${MY_IP}/32]" \
    --rule "direction=ingress,port=80,protocol=tcp,v4-cidrs=[0.0.0.0/0]" \
    --rule "direction=ingress,port=443,protocol=tcp,v4-cidrs=[0.0.0.0/0]" \
    --rule "direction=egress,protocol=any,v4-cidrs=[0.0.0.0/0]"

SG_ID="$(yc vpc security-group get notes-sg --format json | jq -r .id)"

ensure "compute disk" notes-data \
  yc compute disk create --name notes-data --zone "$ZONE" --size 10 --type network-ssd

ensure "compute instance" notes-vm \
  yc compute instance create --name notes-vm --zone "$ZONE" \
    --platform standard-v3 --cores 2 --core-fraction 20 --memory 2 \
    --network-interface "subnet-name=notes-subnet-a,nat-ip-version=ipv4,security-group-ids=${SG_ID}" \
    --create-boot-disk image-family=ubuntu-2404-lts,image-folder-id=standard-images,size=20 \
    --attach-disk disk-name=notes-data,device-name=notes-data \
    --ssh-key "$SSH_PUB"

# Бакет: имя глобально уникально, при повторе с новым суффиксом создастся ещё один
yc storage bucket create --name "$BUCKET" || echo "бакет не создан (имя занято или ошибка)"

VM_IP="$(yc compute instance get notes-vm --format json \
  | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')"
echo "Готово. IP ВМ: ${VM_IP}, бакет: ${BUCKET}"
echo "Дальше на ВМ: смонтировать диск в /var/lib/notes (задание 3)."
```

2. Права и проверка скрипта:

```bash
chmod +x ~/notes/infra/manual/create-vm.sh
shellcheck ~/notes/infra/manual/create-vm.sh
```

3. Удали стенд из заданий 1-3 (порядок обратный созданию), запусти скрипт, потом запусти его второй раз:

```bash
yc compute instance delete notes-vm
yc compute disk delete notes-data
yc vpc security-group delete notes-sg
yc vpc subnet delete notes-subnet-a
yc vpc network delete notes-net
SSH_PUB=~/.ssh/notes_ed25519.pub ~/notes/infra/manual/create-vm.sh
SSH_PUB=~/.ssh/notes_ed25519.pub BUCKET="<имя-бакета-из-первого-запуска>" ~/notes/infra/manual/create-vm.sh
```

4. Зафиксируй в git:

```bash
cd ~/notes
git add infra/manual/create-vm.sh
git commit -m "infra: ручное создание стенда в Yandex Cloud (6.2)"
```

**Что должно получиться:**

```text
создаю: vpc network notes-net
создаю: vpc subnet notes-subnet-a
создаю: vpc security-group notes-sg
создаю: compute disk notes-data
создаю: compute instance notes-vm
Готово. IP ВМ: 203.0.113.10, бакет: notes-backups-1a2b3c4d
```

Второй запуск печатает `есть: ...` для сети, подсети, SG, диска и ВМ. Состояние проекта: скрипт в репозитории, `notes-vm` с диском и бакет в облаке, приложение 0.4.1 ещё не задеплоено (урок 6.3). Долг: создание ручное, повторяемость даёт Terraform (тема 7). Эталон: [infra/manual](https://github.com/distinguished-sre/devops/tree/devops/project/notes/infra/manual).

**Объясни себе:**

- Почему путь к ключу берётся из переменной, а не хранится в скрипте?
- Что в этом скрипте Terraform сделает за тебя, а что нет?
- Что случится с бакетами, если запустить скрипт дважды без `BUCKET`?

**Типичные ошибки:**

- `./create-vm.sh: line 7: SSH_PUB: укажи путь к публичному ключу в SSH_PUB`: не задана переменная; передай её перед запуском.
- `jq: command not found`: не установлен `jq`; `sudo apt install -y jq`.

## Сломай и почини

Поломки создаёшь руками, ты знаешь симптом, но не читаешь разбор до проверок.

### Симптом

Сценарий 1. `ssh -i ~/.ssh/notes_ed25519 yc-user@<IP>` зависает и завершается `Connection timed out`. Сломай: удали из `notes-sg` правило 22 (`yc vpc security-group get notes-sg` покажет id правила, затем `yc vpc security-group update-rules notes-sg --delete-rule-id <id>`).

Сценарий 2. После `sudo reboot` `df -h /var/lib/notes` показывает загрузочный диск, данных нет. Сломай: закомментируй строку диска в `/etc/fstab` и перезагрузись.

Сценарий 3. Через неделю в счёте строка за адрес, хотя ВМ удалена. Сломай: `yc vpc address create --external-ipv4 zone=ru-central1-a --name notes-ip`, потом удали ВМ и забудь.

### Гипотезы

Для каждого сценария запиши минимум две гипотезы до проверок. Для 1: SG не пускает; нет публичного IP; идёшь на старый адрес; sshd не запущен. Разницу timeout и refused вспомни по [уроку 2.2](../02-network/02-ports-tcp-ssh.md).

### Проверки

- Сценарий 1: `yc vpc security-group get notes-sg`, `yc compute instance get notes-vm | grep -A3 one_to_one_nat`, `nc -vz -w 5 <IP> 22`.
- Сценарий 2: `findmnt /var/lib/notes`, `lsblk`, `cat /etc/fstab`, `sudo mount -a`.
- Сценарий 3: `yc vpc address list`, `yc compute disk list`, `yc compute instance list`.

### Исправление

<details>
<summary>Разбор всех сценариев</summary>

**1. timed out из-за SG.** SG выбрасывает пакеты на 22 до ВМ, поэтому нет ни refused, ни строк в логах sshd. В правилах нет входящего 22 с твоего адреса. Исправление: `yc vpc security-group update-rules notes-sg --add-rule "direction=ingress,port=22,protocol=tcp,v4-cidrs=[<твой-IP>/32]"`. Профилактика: домашний IP меняется, обновляй правило скриптом или ходи через VPN с фиксированным адресом.

**2. диск не смонтировался после ребута.** Нет записи в `fstab` или UUID неверный. Диск виден в `lsblk`, но без точки монтирования, а `/var/lib/notes` стал обычным каталогом на загрузочном диске. Исправление: остановить сервис, вернуть строку `UUID=... /var/lib/notes ext4 defaults,nofail 0 2`, перенести накопившееся (`rsync`) на диск, затем `sudo mount -a`. Профилактика: `mount -a` до перезагрузки, алерт на отсутствие точки монтирования.

**3. забытый публичный IP.** Зарезервированный адрес это отдельный ресурс: после удаления ВМ он остаётся и тарифицируется. Найти: `yc vpc address list` (поле `used: false`), удалить: `yc vpc address delete notes-ip`. Профилактика: инвентаризация после каждой работы (урок 6.5), метки на ресурсах.

</details>

## Вопросы с собеседований

### 1. [junior] Ты создал ВМ в облаке, SSH даёт timeout. Твои действия?

Иду по слоям. Есть ли у ВМ публичный адрес и тот ли я использую. Пускает ли SG мой адрес на 22. Всё это смотрю через `yc` или консоль, не заходя на ВМ. Если SG и адрес верны, смотрю serial-консоль и лог загрузки: ВМ могла не подняться. Проверка снаружи: `nc -vz -w 5 <IP> 22`.

**Что хотят услышать:** timeout против refused, SG первой причиной, публичный IP, `/32`, последовательность.

**Красный флаг:** «пересоздал ВМ» или «открыл 22 на 0.0.0.0/0, и заработало».

### 2. [middle] После перезагрузки сервис стартовал, но данных нет, диска данных не видно в `df`. Что делаешь?

Смотрю `lsblk` и `findmnt`: диск на месте, но не смонтирован? Читаю `/etc/fstab`, запускаю `mount -a` и смотрю ошибку, сверяю UUID через `blkid`. Сначала останавливаю сервис: без диска он пишет на загрузочный диск и создаёт «вторую» базу. После монтирования переношу то, что успело записаться.

**Что хотят услышать:** UUID и `nofail`, mount shadowing, остановка сервиса до починки.

**Красный флаг:** «перезапущу сервис» или `mkfs` на диске с данными.

### 3. [middle] Диск заполнен на 100%, а `du` показывает мало. Почему?

Кандидаты: удалённый, но открытый процессом файл (`lsof +L1`), исчерпаны inodes (`df -i`), данные лежат под точкой монтирования (писали, пока диск не был смонтирован), снапшоты и резерв ФС. Иду `df -h`, `df -i`, `lsof +L1`, `findmnt`. Для открытого удалённого файла перезапускаю процесс.

**Что хотят услышать:** deleted-but-open, inodes, mount shadowing, порядок проверок.

**Красный флаг:** «удалю логи» без диагностики.

### 4. [junior] Диск данных и бакет: что куда кладёшь, бэкап БД и файлы PostgreSQL?

Файлы PostgreSQL на диск данных: нужны блочная семантика и малая задержка. Бэкапы в бакет: дёшево, доступно отовсюду, переживает потерю ВМ и зоны. Бакет как диск под БД не подходит.

**Что хотят услышать:** блочное против объектного, зона, S3 API, стоимость.

**Красный флаг:** «в бакет, он безлимитный, и БД тоже».

### 5. [middle] Удалил ВМ, а в счёте всё ещё есть строки. Что искать?

Диски, отдельные от ВМ, зарезервированные публичные адреса, снапшоты, бакеты с объектами, образы. Иду по `yc compute disk list`, `yc vpc address list`, `yc compute snapshot list`, `yc storage bucket list`. Профилактика: метки и регулярная инвентаризация.

**Что хотят услышать:** список ресурсов с отдельной тарификацией, метки, бюджет-алерт.

**Красный флаг:** «облако само всё удаляет».

### 6. [middle] Как дать приложению на ВМ запись в бакет без ключей в коде?

Лучше всего привязать сервисный аккаунт к ВМ и брать временный токен из метаданных (аналог instance profile в AWS). Запасной вариант: статический ключ сервисного аккаунта в `/etc/notes/notes.env` с правами 640 и минимальной ролью, с ротацией. Никогда: ключ в git или ключ администратора.

**Что хотят услышать:** сервисный аккаунт, наименьшие права, метаданные, ротация.

**Красный флаг:** «положу в приватный репозиторий».

### 7. [middle] Требование: «ВМ должна пережить пересоздание без потери данных». Как проектируешь?

Данные на отдельном диске, а не на загрузочном. Диск отсоединяется от старой ВМ и присоединяется к новой в той же зоне, монтируется по UUID через `fstab`. Настройка ВМ автоматизирована (cloud-init, позже Ansible), чтобы новая ВМ поднималась без ручных шагов. Плюс снапшоты по расписанию.

**Что хотят услышать:** отделение данных от ВМ, зона, UUID, снапшоты, автоматизация.

**Красный флаг:** «сделаю образ ВМ и всё».

### 8. [middle] Разработчик открыл в SG порт 8080 на весь интернет «чтобы проверить». Что скажешь?

Приложение отдаёт HTTP без TLS и не рассчитано на прямую публикацию, вы обходите nginx с лимитами, заголовками и TLS. Правильно: наружу 80 и 443, приложение слушает внутри, для проверки SSH-туннель `ssh -L 8080:127.0.0.1:8080`. Правило закрываю сразу.

**Что хотят услышать:** наименьшие привилегии, reverse proxy, туннель.

**Красный флаг:** «на время можно, потом закроем».

### 9. [middle] Скрипт создания стенда падает на повторном запуске с `AlreadyExists`. Как чинишь?

Проверяю существование перед созданием (`get`), либо перехожу на декларативный инструмент. Проверка даёт ручную идемпотентность, но не умеет обновлять и удалять то, что изменилось. Для этого нужен Terraform со state (тема 7).

**Что хотят услышать:** идемпотентность, императивное против декларативного, state.

**Красный флаг:** «удалю всё и создам заново», в том числе на проде.

### 10. [middle] Почему диск нельзя присоединить к ВМ из другой зоны и что делать, если нужно?

Сетевой диск живёт в одной зоне доступности и подключается по сети внутри неё. Для переезда делаю снапшот, создаю из него диск в нужной зоне и присоединяю к ВМ там.

**Что хотят услышать:** зона против региона, снапшот как способ переноса, влияние на отказоустойчивость.

**Красный флаг:** «зона это то же, что регион».

## Проверено на версиях

- Ubuntu: 24.04 LTS (образ `ubuntu-2404-lts`), допускается 26.04 LTS
- yc CLI: версия не закреплена, проверь актуальную версию на странице проекта
- AWS CLI v2: версия не закреплена, проверь актуальную версию на странице проекта
- Multipass: версия не закреплена, проверь актуальную версию на странице проекта
- MinIO: версия не закреплена, проверь актуальную версию на странице проекта
- ext4 и util-linux (`lsblk`, `blkid`, `findmnt`): из Ubuntu 24.04

## Итог урока: ты умеешь

- [ ] умею создать сеть, подсеть и группу безопасности и объяснить роль каждой
- [ ] умею создать ВМ с публичным адресом и зайти по SSH
- [ ] умею отличить `timed out` от `refused` и найти причину в SG
- [ ] умею подключить диск данных, смонтировать по UUID и пережить перезагрузку
- [ ] умею создать бакет и работать с ним по S3 API с ключом сервисного аккаунта
- [ ] умею найти забытые платные ресурсы: диски, адреса, снапшоты
- [ ] умею собрать ручные шаги в скрипт `create-vm.sh`, безопасный к повтору

**Дальше:** [Урок 6.3: деплой «Заметок» на ВМ](03-deploy-notes-vm.md)
