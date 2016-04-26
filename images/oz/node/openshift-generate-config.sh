#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

CONFIG_DIR="/var/lib/origin/openshift.local.config/node"
CONFIG_FILE="${NODE_CONFIG_DIR}/node-config.yaml"

if [ ! -f "${CONFIG_FILE}" ]; then
  # Copy the certs to local storage.  Attempting to generate node
  # config against the secret path will cause the openshift command to
  # panic.
  mkdir -p "${CONFIG_DIR}"
  cp /config/* "${CONFIG_DIR}"

  NAME=$(hostname)
  # TODO - make this dynamic
  MASTER="https://oz-master.default.svc.cluster.local:8443"
  IP_ADDR=$(ip addr | grep inet | grep eth0 | \
      awk '{print $2}' | sed -e 's+/.*++')

  /usr/bin/openshift admin create-node-config \
    --node-dir="${CONFIG_DIR}" \
    --node="${NAME}" \
    --master="${MASTER}" \
    --hostnames="${IP_ADDR}" \
    --network-plugin="redhat/openshift-ovs-subnet" \
    --node-client-certificate-authority="${CONFIG_DIR}/ca.crt" \
    --certificate-authority="${CONFIG_DIR}/ca.crt" \
    --signer-cert="${CONFIG_DIR}/ca.crt" \
    --signer-key="${CONFIG_DIR}/ca.key" \
    --signer-serial="${CONFIG_DIR}/ca.serial.txt"
fi
