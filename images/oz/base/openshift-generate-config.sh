#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

NODE_CONFIG_DIR="/var/lib/origin/openshift.local.config/node"
NODE_CONFIG_FILE="${NODE_CONFIG_DIR}/node-config.yaml"

if [ ! -f "${NODE_CONFIG_FILE}" ]; then
  # Copy the certs to local storage.  Attempting to generate node
  # config against the secret path will cause the openshift command to
  # panic.
  MASTER_CONFIG_DIR="/tmp/config"
  mkdir -p "${MASTER_CONFIG_DIR}"
  cp /config/* "${MASTER_CONFIG_DIR}"

  NAME=$(hostname)
  # TODO - discover master ip via env vars or use dns (not enabled by default in aio)
  MASTER=$(grep server "${MASTER_CONFIG_DIR}/admin.kubeconfig" | grep -v localhost | awk '{print $2}')
  IP_ADDR=$(ip addr | grep inet | grep eth0 | \
      awk '{print $2}' | sed -e 's+/.*++')

  /usr/local/bin/openshift admin create-node-config \
    --node-dir="${NODE_CONFIG_DIR}" \
    --node="${NAME}" \
    --master="${MASTER}" \
    --hostnames="${IP_ADDR}" \
    --network-plugin="redhat/openshift-ovs-subnet" \
    --node-client-certificate-authority="${MASTER_CONFIG_DIR}/ca.crt" \
    --certificate-authority="${MASTER_CONFIG_DIR}/ca.crt" \
    --signer-cert="${MASTER_CONFIG_DIR}/ca.crt" \
    --signer-key="${MASTER_CONFIG_DIR}/ca.key" \
    --signer-serial="${MASTER_CONFIG_DIR}/ca.serial.txt"
fi
