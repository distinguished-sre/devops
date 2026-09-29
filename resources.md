---
title: "Дополнительные материалы и ссылки"
redirect_from:
  - /Старые-уроки-и-задания.html
---

# Дополнительные материалы и ссылки

> Раньше этот файл был архивом уроков и вопросов к собеседованию. **Вопросы разнесены по темам** — теперь они лежат рядом с соответствующей теорией и, в отличие от прежней версии, снабжены ответами. Ищи их в разделе `Вопросы с собеседований` в конце теоретической части каждой темы:
>
> [Linux](01-linux/index.md) · [Сеть](02-network/index.md) · [Git и CI/CD](03-git-ci/index.md) · [Docker](04-docker/index.md) · [Kubernetes и Helm](05-kubernetes/index.md) · [Ansible и Terraform](07-iac/index.md) · [Мониторинг](08-observability/index.md) · [Vault и GitOps](09-secrets-gitops/index.md)
>
> Здесь осталось то, что не помещается в темы: внешние курсы, книги и порядок изучения технологий

### Первый совет

Начни учить английские слова. Для начала достаточно уметь прочесть и понять текст: документация, сообщения об ошибках и ответы на форумах почти всегда на английском

### Порядок изучения технологий

Общепринятая дорожная карта: https://roadmap.sh/devops. Комментарии к ней применительно к этому курсу:

1. Основы bash — [тема 1](01-linux/index.md). Дополнительно стоит освоить Python или Go: без языка программирования потолок роста ниже
2. Из операционных систем ставь Ubuntu: https://ubuntu.com/desktop, а если у тебя Windows — Ubuntu из магазина Microsoft: https://apps.microsoft.com/detail/9nz3klhxdjp5
3. Из редакторов научись открывать и править файлы в `nano`, а затем в `vim`
4. Терминал, права, процессы, systemd — [тема 1](01-linux/index.md)
5. Сети — [тема 2](02-network/index.md)
6. Git и CI/CD — [тема 3](03-git-ci/index.md). Проще начинать с GitHub Actions, потом переходить на GitLab CI
7. Контейнеризация — [тема 4](04-docker/index.md), затем Kubernetes в [теме 5](05-kubernetes/index.md)
8. Облачные провайдеры — [тема 6](06-cloud/index.md). В России это Yandex Cloud, Cloud.ru или VK Cloud
9. Terraform и Ansible как инфраструктура как код — [тема 7](07-iac/index.md)
10. Мониторинг, логи и трейсинг — [тема 8](08-observability/index.md)
11. Управление секретами через Vault и GitOps — [тема 9](09-secrets-gitops/index.md)
12. Хранилища собранных образов и чартов: Harbor, Nexus, Artifactory
13. Управление сетевым трафиком в Kubernetes: Istio или Linkerd — разбирается в [теме 8](08-observability/index.md)

### Полезные YouTube-каналы

- [ADV-IT](https://www.youtube.com/@ADV-IT/playlists) — плейлисты, по которым училось много DevOps-инженеров
- [Merion Academy](https://www.youtube.com/watch?v=NtGN7Nz6I0c) — про технологии из дорожной карты простыми словами
- [Pavlenko AT](https://www.youtube.com/@pavlenkoat/playlists) — хороший канал по DevOps, смотреть на скорости 1.25

### Дополнительные материалы по темам

<details>
  <summary>Linux, сети и bash-скрипты</summary>

| Что изучить | Как понять, что цель достигнута |
|-------------|--------------------------------|
| Linux — ядро операционной системы. Курс https://youtu.be/wdaHKwvNRuU и статья https://habr.com/ru/articles/788970/, задания https://github.com/distinguished-sre/devops-linux | Умеешь устанавливать программы, знаешь основные команды, понимаешь, что такое ядро и какие каталоги есть в `/`. Вопросы: https://github.com/bregman-arie/devops-exercises/tree/master/topics/linux |
| Bash-скрипты — автоматизация рутины. Задание: написать скрипты ко всем заданиям https://github.com/distinguished-sre/devops-linux и к задачам 2, 5, 9 из https://github.com/bregman-arie/devops-exercises/tree/master/topics/shell | Умеешь работать с переменными, условиями, циклами и `case`. Вопросы: https://github.com/bregman-arie/devops-exercises/tree/master/topics/shell |
| Сети. Статьи https://habr.com/ru/post/326574/, https://ru.wikipedia.org/wiki/Маска_подсети, https://habr.com/ru/post/711578/, про websocket https://youtu.be/19d4AXt3dSI | Понимаешь SSH, пакеты, уровни TCP/IP, DNS, HTTP и REST API, IP и маску подсети, умеешь смотреть интерфейсы и перехватывать трафик, знаешь конфиг nginx и балансировку. Вопросы: https://github.com/bregman-arie/devops-exercises#network |

</details>

<details>
  <summary>Git и GitLab CI/CD</summary>

| Что изучить | Как понять, что цель достигнута |
|-------------|--------------------------------|
| Git. Обзор https://youtu.be/EeARyFrZsnU, курс https://www.youtube.com/watch?list=PLg5SS_4L6LYstwxTEOU05E0URTHnbtA0l до 15 урока. Создать свой репозиторий с несколькими ветками и тегами | Умеешь делать коммиты, ветки и теги и объясняешь разницу, разрешаешь конфликты, откатываешься на старую версию, различаешь `fetch` и `pull`. Вопросы: https://github.com/bregman-arie/devops-exercises/tree/master/topics/git |
| CI/CD. Уроки 15 и 16 того же курса, https://youtu.be/tE3u1LquFcg?t=212, сборка образов через Kaniko: https://docs.gitlab.com/ee/ci/docker/using_kaniko.html | Настроил автоматическую сборку образа и отправку его в реестр, знаешь из каких шагов состоит хороший пайплайн. Вопросы: https://github.com/bregman-arie/devops-exercises/tree/master/topics/cicd |

</details>

<details>
  <summary>Docker и Kubernetes</summary>

| Что изучить | Как понять, что цель достигнута |
|-------------|--------------------------------|
| Docker. https://youtu.be/aZTL2zRmOnA и https://habr.com/ru/companies/flant/articles/787494/ | Понимаешь, зачем нужен Docker, умеешь собрать свой образ и отправить его в реестр, запускаешь несколько контейнеров вместе через Compose |
| Kubernetes. Курс https://learn.microsoft.com/ru-ru/training/modules/intro-to-kubernetes/, материалы https://github.com/distinguished-sre/devops-kubernetes и https://habr.com/ru/articles/777728/, локальная установка Istio | Понимаешь, зачем нужен Kubernetes, ставишь приложения через Helm. Вопросы: https://github.com/bregman-arie/devops-exercises/tree/master/topics/kubernetes |

Дорожные карты: [Docker](https://roadmap.sh/docker) · [Kubernetes](https://roadmap.sh/kubernetes)

Лучшие практики по Kubernetes, в том числе про распределение подов по нодам и зонам: https://github.com/distinguished-sre/devops-kubernetes/blob/main/ЛУЧШИЕ_ПРАКТИКИ.md

</details>

<details>
  <summary>Мониторинг и логирование</summary>

| Что изучить | Как понять, что цель достигнута |
|-------------|--------------------------------|
| Мониторинг. https://youtu.be/wDan20_WyNg, пример стека https://github.com/ruanbekker/docker-monitoring-stack-gpnc, ELK https://youtu.be/ZcC3BTChCY0?t=110 и https://github.com/docker/awesome-compose/tree/master/elasticsearch-logstash-kibana, трейсинг https://youtu.be/7Dyf4AiUAcQ | Умеешь создавать алерты, настраивать мониторинг Docker и хоста, устанавливать в кластер https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack. Вопросы: https://github.com/bregman-arie/devops-exercises#prometheus |

- Логирование в Kubernetes: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Золотые сигналы: https://habr.com/ru/companies/southbridge/articles/688082/
- Готовые правила алертов на все случаи: https://github.com/samber/awesome-prometheus-alerts
- Автоматический сбор золотых метрик через Linkerd: https://linkerd.io/2.13/features/telemetry/

</details>

<details>
  <summary>Ansible и Terraform</summary>

| Что изучить | Как понять, что цель достигнута |
|-------------|--------------------------------|
| Ansible — управление конфигурацией по SSH. https://youtu.be/23Zec3ORJOY, курс https://www.youtube.com/watch?list=PLg5SS_4L6LYufspdPupdynbMQTBnZd31N (уроки 1, 6, 10, 12, 14, 15, 19) | Понимаешь, зачем нужен Ansible, что такое идемпотентность и playbook, умеешь писать свои роли. Вопросы: https://github.com/bregman-arie/devops-exercises/tree/master/topics/ansible |
| Terraform. https://youtu.be/ph4iNA0Uuko, курс https://www.youtube.com/watch?list=PLg5SS_4L6LYujWDTYb-Zbofdl44Jxb2l8 (уроки 1, 3, 6, 7, 12, 14, 16, 18) | Понимаешь, зачем нужен Terraform, умеешь создавать ресурсы и знаешь, где хранится состояние |

</details>

### Где ещё искать вопросы к собеседованию

- Подборка вопросов с разбором: https://habr.com/ru/articles/775560/
- Большой открытый сборник упражнений и вопросов: https://github.com/bregman-arie/devops-exercises
