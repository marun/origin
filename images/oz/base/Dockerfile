#
# This is the base image for nodes of an openshift dev cluster.
#
# The standard name for this image is openshift/oz-base
#

FROM fedora:24

## Configure systemd to run in a container
ENV container=docker

# Fixup systemd
RUN systemctl mask\
 auditd.service\
 console-getty.service\
 dev-hugepages.mount\
 dnf-makecache.service\
 docker-storage-setup.service\
 getty.target\
 lvm2-lvmetad.service\
 sys-fs-fuse-connections.mount\
 systemd-logind.service\
 systemd-remount-fs.service\
 systemd-udev-hwdb-update.service\
 systemd-udev-trigger.service\
 systemd-udevd.service\
 systemd-vconsole-setup.service
RUN cp /usr/lib/systemd/system/dbus.service /etc/systemd/system/;\
 sed -i 's/OOMScoreAdjust=-900//' /etc/systemd/system/dbus.service

VOLUME ["/run", "/tmp"]

## Install packages
RUN dnf -y update && dnf -y install\
 bind-utils\
 findutils\
 git\
 golang\
 hg\
 hostname\
 iproute\
 iputils\
 make\
 openssh-server\
 procps-ng\
 tar\
 which\
 # Node-specific packages
 bridge-utils\
 docker\
 ethtool\
 iptables-services\
 openvswitch\
 # Volume-supporting packages
 ceph-common\
 glusterfs-fuse\
 nfs-utils\
 && dnf clean all

# sshd can be enabled as needed
RUN systemctl disable sshd.service

# Configure docker
VOLUME /var/lib/docker
RUN systemctl enable docker.service
# Default storage to vfs.  overlay will be enabled at runtime if available.
RUN echo "DOCKER_STORAGE_OPTIONS=--storage-driver vfs" >\
 /etc/sysconfig/docker-storage

# TODO - add unit file that sets overlay as the storage driver if possible.
# Will need to 'modprobe overlay' as well (via sidecar?)

COPY ensure-mount-propagation.service /etc/systemd/system/
RUN systemctl enable ensure-mount-propagation.service

COPY openshift-generate-config.sh /usr/local/bin/

RUN mkdir -p /etc/systemd/system/docker.service.d
COPY docker-sdn-ovs.conf /etc/systemd/system/docker.service.d/

RUN systemctl enable openvswitch

COPY openshift-node.service /etc/systemd/system
RUN systemctl enable openshift-node.service

## Install OpenShift SDN
COPY bin/openshift-sdn-ovs /usr/local/bin/
COPY bin/openshift-sdn-docker-setup.sh /usr/local/bin/

## Install openshift
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

## Hardlink init to another name to avoid having oci-systemd-hooks
## detect containers using this image as requiring read-only cgroup
## mounts.  containers running docker need to be run with --privileged
## to ensure cgroups are mounted with read-write permissions.
RUN ln /usr/sbin/init /usr/sbin/nested_init

CMD ["/usr/sbin/nested_init"]
