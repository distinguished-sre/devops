# Стенд для проверки уроков: Ubuntu с systemd внутри контейнера.
# Не для учеников (они работают на ВМ), а для тех, кто правит курс.
#   docker build -t devops-lab:24.04 --build-arg UBUNTU=24.04 tools/lab
#   docker run -d --privileged --cgroupns=host --name lab devops-lab:24.04
#   docker exec -it -u student -w /home/student lab bash
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
    && (id ubuntu >/dev/null 2>&1 && userdel -r ubuntu || true) \
    && useradd -m -s /bin/bash -G sudo student \
    && echo 'student ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/student \
    && systemctl mask systemd-logind.service getty.target console-getty.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
