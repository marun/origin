#
# This image is the base image for nodes of an openshift dev cluster.
#
# The standard name for this image is openshift/oz-base
#

FROM fedora:23

## Configure systemd to run in a container
ENV container=docker

RUN systemctl mask systemd-remount-fs.service dev-hugepages.mount \
  sys-fs-fuse-connections.mount systemd-logind.service getty.target \
  console-getty.service dnf-makecache.service lvm2-lvmetad.service \
  lvm2-lvmpolld systemd-udevd.service systemd-udev-hwdb-update.service \
  systemd-udev-trigger.service docker-storage-setup.service \
  dmeventd.service crond.service auditd.service dm-event.service \
  systemd-vconsole-setup.service systemd-firstboot.service

RUN cp /usr/lib/systemd/system/dbus.service /etc/systemd/system/; \
  sed -i 's/OOMScoreAdjust=-900//' /etc/systemd/system/dbus.service

VOLUME ["/run", "/tmp"]

## Install packages
RUN dnf -y update && dnf -y install git golang hg tar make \
  hostname bind-utils iproute iputils which procps-ng openssh-server \
  # Node-specific packages
  openvswitch bridge-utils ethtool \
  && dnf clean all

# Install docker from upstream until fedora 23 has 1.10
COPY docker.repo /etc/yum.repos.d/
RUN dnf -y install docker-engine && dnf clean all

# sshd should be enabled as needed
RUN systemctl disable sshd.service

## Configure dind
ENV DIND_COMMIT 81aa1b507f51901eafcfaad70a656da376cf937d
RUN curl -fL "https://raw.githubusercontent.com/docker/docker/${DIND_COMMIT}/hack/dind" \
  -o /usr/local/bin/dind-wrapper && chmod +x /usr/local/bin/dind-wrapper
# The kubelet naively tries to manage a random process named 'docker'.
# Rename docker to dind via symlink to ensure an external kubelet
# doesn't try to manage the docker-in-docker process.
RUN ln -s /usr/bin/docker /usr/bin/dind
RUN mkdir -p /etc/systemd/system/docker.service.d
COPY oz.conf /etc/systemd/system/docker.service.d/
COPY ensure-mount-propagation.service /etc/systemd/system/

VOLUME /var/lib/docker

# Fix 'WARNING: terminal is not fully functional' when TERM=dumb
ENV TERM=xterm

CMD ["/usr/sbin/init"]
