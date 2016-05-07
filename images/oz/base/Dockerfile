#
# This is the base image for nodes of an openshift dev cluster.
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
RUN dnf -y update && dnf -y install git golang hg tar make nfs-utils \
  hostname bind-utils iproute iputils which procps-ng openssh-server \
  # Node-specific packages
  openvswitch bridge-utils ethtool \
  # Volume-supporting packages
  nfs-utils glusterfs-client \
  && dnf clean all

# Install docker 1.10 from upstream until it lands in Fedora.  Avoid
# 1.11 for now.
COPY docker.repo /etc/yum.repos.d/
RUN dnf -y install\
 docker-engine-1.10.3\
 docker-engine-selinux-1.10.3\
 && dnf clean all

# sshd should be enabled as needed
RUN systemctl disable sshd.service

## Configure dind
ENV DIND_COMMIT 81aa1b507f51901eafcfaad70a656da376cf937d
RUN curl -fL "https://raw.githubusercontent.com/docker/docker/${DIND_COMMIT}/hack/dind" \
  -o /usr/local/bin/dind-wrapper && chmod +x /usr/local/bin/dind-wrapper
# The kubelet naively tries to manage a random process named 'docker'.
# Rename docker to dind via hardlink to ensure an external kubelet
# doesn't try to manage the docker-in-docker process.
RUN ln /usr/bin/docker /usr/local/bin/dind
RUN mkdir -p /etc/systemd/system/docker.service.d
COPY oz.conf /etc/systemd/system/docker.service.d/
COPY ensure-mount-propagation.service /etc/systemd/system/

VOLUME /var/lib/docker

RUN systemctl enable ensure-mount-propagation.service
RUN systemctl enable docker.service

COPY openshift-generate-config.sh /usr/local/bin/

RUN mkdir -p /etc/systemd/system/docker.service.d
COPY docker-sdn-ovs.conf /etc/systemd/system/docker.service.d/

RUN systemctl enable openvswitch

COPY openshift-node.service /etc/systemd/system
RUN systemctl enable openshift-node.service

## Install OpenShift SDN
COPY bin/openshift-sdn-ovs /usr/local/bin/
COPY bin/openshift-sdn-docker-setup.sh /usr/local/bin/

COPY bin/openshift /usr/local/bin/openshift
RUN ln -s /usr/local/bin/openshift /usr/local/bin/oc && \
    ln -s /usr/local/bin/openshift /usr/local/bin/oadm && \
    ln -s /usr/local/bin/openshift /usr/local/bin/osc && \
    ln -s /usr/local/bin/openshift /usr/local/bin/osadm && \
    ln -s /usr/local/bin/openshift /usr/local/bin/kubectl && \
    ln -s /usr/local/bin/openshift /usr/local/bin/openshift-deploy && \
    ln -s /usr/local/bin/openshift /usr/local/bin/openshift-docker-build && \
    ln -s /usr/local/bin/openshift /usr/local/bin/openshift-sti-build && \
    ln -s /usr/local/bin/openshift /usr/local/bin/openshift-f5-router

# Fix 'WARNING: terminal is not fully functional' when TERM=dumb
ENV TERM=xterm

CMD ["/usr/sbin/init"]
