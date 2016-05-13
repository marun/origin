#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

ORIGIN_ROOT=$(
  unset CDPATH
  origin_root=$(dirname "${BASH_SOURCE}")/..
  cd "${origin_root}"
  pwd
)
source ${ORIGIN_ROOT}/contrib/vagrant/provision-util.sh

CONFIG_ROOT="${ORIGIN_ROOT}/_aio"

PID_FILENAME="${CONFIG_ROOT}/aio.pid"

# TODO discover this path
BIN_PATH="${ORIGIN_ROOT}/_output/local/bin/linux/amd64"

# TODO Allow these parameters to be configured
PUBLIC_IP="10.14.6.90"
PORTAL_NET="172.40.0.0/16"

get-kubeconfig() {
  local config_root=$1

  echo "${config_root}/openshift.local.config/master/admin.kubeconfig"
}

create() {
  local config_root=$1

  mkdir -p "${config_root}"

  local config="$(get-kubeconfig "${config_root}")"

  pushd "${config_root}" > /dev/null
    sudo bash -c "OPENSHIFT_DNS_DOMAIN=aio.local \
        ${bin_path}/openshift start --dns='tcp://${PUBLIC_IP}:53' \
        --portal-net=${PORTAL_NET} &> out.log & \
        echo \$! > ${config_root}/aio.pid"

    local msg="OpenShift All-In-One configuration to be written"
    local condition="test -f ${config}"
    os::provision::wait-for-condition "${msg}" "${condition}"

    # Make the configuration readable so it can be used by oc
    sudo chmod -R g+rw openshift.local.config
  popd > /dev/null

  local rc_file="aio.rc"

  cat > "${rc_file}" <<EOF
export KUBECONFIG=${config}
export PATH=\$PATH:${BIN_PATH}
EOF

  if [[ "${KUBECONFIG:-}" != "${config}"  ||
          ":${PATH}:" != *":${BIN_PATH}:"* ]]; then
    echo "
Before invoking the OpenShift cli for the All-In-One cluster, make sure to
source the cluster's rc file to configure the bash environment:

  $ . ${rc_file}
  $ oc get nodes
"
  fi
}

delete() {
  local config_root=$1

  check-for-cluster "${config_root}"

  local pid_filename=
  if [[ -f "${pid_filename}" ]]; then
    local pid="$(cat "${pid_filename}")"
    sudo -E kill "${pid}"
    # TODO consider optionally saving cluster state (i.e. allow restarting)
    sudo -E rm -rf "${config_root}"
  else
    >&2 echo "OpenShift All-In-One cluster not detected."
  fi
}

wait-for-ready() {
  local config_root=$1

  local config="$(get-kubeconfig "${config_root}")"
  wait-for-cluster "${config}" "${BIN_PATH}/oc" 1
}

case "${1:-""}" in
  create)
    WAIT_FOR_READY=
    OPTIND=2
    while getopts ":w" opt; do
      case $opt in
        w)
          WAIT_FOR_READY=1
          ;;
        n)
          NETWORK_PLUGIN="${OPTARG}"
          ;;
        \?)
          echo "Invalid option: -${OPTARG}" >&2
          exit 1
          ;;
      esac
    done
    create "${ORIGIN_ROOT}" "${CONFIG_ROOT}"
    if [[ -n "${WAIT_FOR_READY}" ]]; then
      wait-for-ready "${CONFIG_ROOT}"
    fi
    ;;
  delete)
    delete-cluster "${CONFIG_ROOT}"
    ;;
  wait)
    wait-for-ready "${CONFIG_ROOT}"
    ;;
  *)
    echo "Usage: $0 {create|delete|wait}"
    exit 2
esac
