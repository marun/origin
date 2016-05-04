#
# This image is for the master of an openshift-on-openshift dev cluster.
#
# The standard name for this image is openshift/oz-master
#

FROM openshift/oz-base

RUN mkdir -p /var/lib/origin/openshift.local.config/master

ENV KUBECONFIG /var/lib/origin/openshift.local.config/master/admin.kubeconfig

COPY openshift-master.service /etc/systemd/system
RUN systemctl enable openshift-master.service

COPY disable-master-node.sh /usr/local/bin/
COPY disable-master-node.service /etc/systemd/system
RUN systemctl enable disable-master-node.service

COPY sync-etc-hosts.sh /usr/local/bin/
COPY sync-etc-hosts.service /etc/systemd/system/
COPY sync-etc-hosts.timer /etc/systemd/system/
RUN systemctl enable sync-etc-hosts.service
RUN systemctl enable sync-etc-hosts.timer

# Override name for node that will ensure master to pod connectivity
RUN sed -i -e 's+^\(ExecStartPre=.*\)+\1 oz-master-node+'\
 /etc/systemd/system/openshift-node.service

# Ensure that the node depends on the master
RUN sed -i -e 's+^\(Requires=.*\)+\1 openshift-master.service+'\
 /etc/systemd/system/openshift-node.service
RUN sed -i -e 's+^\(After=.*\)+\1 openshift-master.service+'\
 /etc/systemd/system/openshift-node.service
