#
# This image is the image for nodes of an openshift dev cluster.
#
# The standard name for this image is openshift/oz-node
#

FROM openshift/oz-base

RUN mkdir -p /var/lib/origin/openshift.local.config

ENV KUBECONFIG /config/admin.kubeconfig

RUN systemctl enable ensure-mount-propagation.service
RUN systemctl enable docker.service

ADD openshift-generate-config.sh /usr/bin/

## Install OpenShift SDN
ADD bin/openshift-sdn-ovs /usr/bin/
ADD bin/openshift-sdn-docker-setup.sh /usr/bin/

RUN mkdir -p /etc/systemd/system/docker.service.d
ADD docker-sdn-ovs.conf /etc/systemd/system/docker.service.d/

RUN systemctl enable openvswitch

COPY openshift-node.service /etc/systemd/system
RUN systemctl enable openshift-node.service

ADD bin/openshift /usr/bin/openshift
RUN ln -s /usr/bin/openshift /usr/bin/oc && \
    ln -s /usr/bin/openshift /usr/bin/oadm && \
    ln -s /usr/bin/openshift /usr/bin/osc && \
    ln -s /usr/bin/openshift /usr/bin/osadm && \
    ln -s /usr/bin/openshift /usr/bin/kubectl && \
    ln -s /usr/bin/openshift /usr/bin/openshift-deploy && \
    ln -s /usr/bin/openshift /usr/bin/openshift-docker-build && \
    ln -s /usr/bin/openshift /usr/bin/openshift-sti-build && \
    ln -s /usr/bin/openshift /usr/bin/openshift-f5-router
