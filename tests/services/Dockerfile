ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    systemd systemd-sysv systemd-resolved dbus ufw openssh-server iproute2 \
    dnsutils sudo curl ca-certificates python3 jq yq && apt-get clean
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
