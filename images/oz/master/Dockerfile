#
# This image is the image for the master an openshift dev cluster.
#
# The standard name for this image is openshift/oz-master
#

FROM openshift/oz-base

RUN mkdir -p /var/lib/origin/openshift.local.config/master

ENV KUBECONFIG /var/lib/origin/openshift.local.config/master/admin.kubeconfig

COPY openshift-master.service /etc/systemd/system
RUN systemctl enable openshift-master.service

RUN systemctl enable ensure-mount-propagation.service
RUN systemctl enable docker.service

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

ADD bin/hello-pod.json /tmp/hello-pod.json
