# Стенд для проверки уроков: Ubuntu с systemd внутри контейнера.
# Не для учеников (они работают на ВМ), а для тех, кто правит курс.
#   docker build -t devops-lab:24.04 --build-arg UBUNTU=24.04 tools/lab
#   docker run -d --privileged --cgroupns=host --hostname devops --name lab devops-lab:24.04
#   docker exec -it -u ubuntu -w /home/ubuntu lab bash
# Пользователь ubuntu и имя машины devops как в ВМ Multipass из урока 1.1,
# чтобы приглашение и пути в выводе совпадали с тем, что видит ученик.
ARG UBUNTU=24.04
FROM ubuntu:${UBUNTU}
ENV DEBIAN_FRONTEND=noninteractive
# systemd нужен, чтобы уроки с systemctl и journalctl работали как на ВМ.
# Остальное: то, что есть в стандартном образе Ubuntu Server и что уроки считают установленным.
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus sudo ca-certificates \
      iproute2 iputils-ping curl wget nano vim less man-db file \
      python3 procps psmisc lsof git openssh-client openssh-server iptables \
    && rm -rf /var/lib/apt/lists/* \
    && (id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu) \
    && usermod -aG sudo,adm ubuntu \
    && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-ubuntu \
    && systemctl mask systemd-logind.service getty.target console-getty.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
