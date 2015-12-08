#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

NODE_CONFIG="/var/lib/origin/openshift.local.config/node"
NODE_CONFIG_FILE="${NODE_CONFIG}/node-config.yaml"

if [ ! -f "${NODE_CONFIG_FILE}" ]; then
  CONFIG_PATH=/tmp/config

  # Attempting to generate node config against the secret path will
  # cause the openshift command to panic.
  mkdir -p "${CONFIG_PATH}"
  cp /config/* "${CONFIG_PATH}"

  NAME=$(hostname)
  MASTER=$(grep server "${CONFIG_PATH}/admin.kubeconfig" | awk '{print $2}')
  IP_ADDR=$(ip addr | grep inet | grep eth0 | \
      awk '{print $2}' | sed -e 's+/.*++')

  /usr/bin/openshift admin create-node-config \
    --node-dir="/var/lib/origin/openshift.local.config/node" \
    --node="${NAME}" \
    --master="${MASTER}" \
    --hostnames="${IP_ADDR}" \
    --network-plugin="redhat/openshift-ovs-subnet" \
    --node-client-certificate-authority="${CONFIG_PATH}/ca.crt" \
    --certificate-authority="${CONFIG_PATH}/ca.crt" \
    --signer-cert="${CONFIG_PATH}/ca.crt" \
    --signer-key="${CONFIG_PATH}/ca.key" \
    --signer-serial="${CONFIG_PATH}/ca.serial.txt"
fi
