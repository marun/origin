#
# This image is for nodes of an openshift dev cluster.
#
# The standard name for this image is openshift/oz-node
#

FROM openshift/oz-base

RUN mkdir -p /var/lib/origin/openshift.local.config/node

COPY decommission-node.sh /usr/local/bin/

ENV KUBECONFIG /config/public-admin.kubeconfig
