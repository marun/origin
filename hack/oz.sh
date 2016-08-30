#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

source "$(dirname "${BASH_SOURCE}")/lib/init.sh"

ORIGIN_ROOT=$(
  unset CDPATH
  origin_root=$(dirname "${BASH_SOURCE}")/..
  cd "${origin_root}"
  pwd
)
source ${ORIGIN_ROOT}/contrib/vagrant/provision-util.sh

# TODO
# - ensure the oc path is always qualified
# - check for selinux being permissive?
# - modprobe overlayfs
# - modprobe network modules (ovs, etc)
# - allow configuration of where data is (etcd and config) is stored

# TODO
CONFIG_ROOT="${ORIGIN_ROOT}/_oz"
create-config-secret() {
  local config_root=$1
  local public_ip=$2
  local service_ip=$3
  local node_port=$4
  local namespace=$5
  local network_plugin=$6

  local master_config_dir="${config_root}/openshift.local.config/master"
  mkdir -p "${master_config_dir}"

  # Ensure nodes can reach master via service dns
  # TODO: make the master name and namespace dynamic
  local master_name="oz-master"
  local master_fqdn="${master_name}.${namespace}.svc.cluster.local"

  master_url="https://localhost:8443"
  public_url="https://${public_ip}:${node_port}"

  # Override the default portal net cidr so that the ozone cluster can
  # use the default without ambiguity.
  #
  # TODO - ensure that the portal net cidr differs between nested
  # and hosting cluster to avoid confusion.
  #
  # TODO: Allow this to be configured
  local portal_net="172.40.0.0/16"

  # Include the ip for the nested kube service to ensure that nodes
  # will be able to talk to the api.
  local nested_service_ip="172.40.0.1"

  # TODO is there another way to set the network plugin and etcd dir
  # and is it safe to generate configuration over existing
  # configuration to allow config/etcd store reuse across cluster
  # starts?
  openshift start master --write-config="${master_config_dir}" \
      --master="${master_url}" \
      --etcd-dir="/var/lib/origin/openshift.local.etcd" \
      --public-master="${public_url}" \
      --portal-net="${portal_net}" \
      --network-plugin="${network_plugin}" > /dev/null

  openshift admin ca create-master-certs \
      --overwrite=false \
      --cert-dir="${master_config_dir}" \
      --hostnames="localhost,127.0.0.1,${public_ip},${service_ip},${master_fqdn},${nested_service_ip}" \
      --master="${master_url}" \
      --public-master="${public_url}" > /dev/null

  # Create config files that default to the appropriate context
  local localhost_conf="${master_config_dir}/admin.kubeconfig"
  local public_conf="${master_config_dir}/public-admin.kubeconfig"
  cp "${localhost_conf}" "${public_conf}"
  local public_ctx="default/$(echo "${public_ip}" | sed 's/\./-/g'):${node_port}/system:admin"
  oc --config="${public_conf}" config use-context "${public_ctx}" > /dev/null

  local secret_file="${config_root}/config.json"
  openshift cli secrets new oz-config \
    "${config_root}/openshift.local.config/master/" \
    -o json > "${secret_file}"
  oc create -f "${secret_file}" > /dev/null
}

get-kubeconfig() {
  local config_root=$1

  echo "${config_root}/openshift.local.config/master/admin.kubeconfig"
}

get-public-kubeconfig() {
  local config_root=$1

  echo "${config_root}/openshift.local.config/master/public-admin.kubeconfig"
}

create-rc-file() {
  local origin_root=$1
  local config_root=$2

  # TODO vary the rc filename to support more than one ozone instance
  local rc_file="oz.rc"
  local config="$(get-public-kubeconfig ${config_root})"
  cat > "${rc_file}" <<EOF
export OZ_KUBECONFIG=${config}
alias oz='KUBECONFIG=${config}'
EOF

  if [[ "${OZ_KUBECONFIG:-}" != "${config}" ]]; then
    echo ""
    echo "Before invoking the openshift cli for the ozone cluster, make sure to source the
cluster's rc file to configure the bash environment:

  $ . ${rc_file}
  $ oz oc get nodes
"
  fi
}

delete-cluster() {
  local config_root=$1

  local nested_root="$(get-nested-root ${config_root})"

  oc delete dc oz-node --ignore-not-found=true > /dev/null
  oc delete dc oz-master --ignore-not-found=true > /dev/null
  oc delete service oz-master --ignore-not-found=true > /dev/null
  oc delete secret oz-config --ignore-not-found=true > /dev/null
  # etcd permissions require the use of sudo
  sudo rm -rf "${nested_root}"
}

cleanup-volumes() {
  # Cleanup orphaned volumes
  #
  # See: https://github.com/jpetazzo/dind#important-warning-about-disk-usage
  #
  echo "Cleaning up volumes used by docker-in-docker daemons"
  local volume_ids=$(docker volume ls -qf dangling=true)
  if [[ "${volume_ids}" ]]; then
    docker volume rm ${volume_ids}
  fi
}

delete-notready-nodes() {
  local config_root=$1

  local config="$(get-public-kubeconfig "$(get-nested-root "${config_root}")")"
  local node_names="$(oc --config="${config}" get nodes | grep node | grep NotReady | awk '{print $1}')"
  if [[ -n "${node_names}" ]]; then
    oc --config="${config}" delete node ${node_names}
  fi
}

build-image() {
  local name=$1

  # TODO - optionally support pushing to a repo to support deploying
  # on more than an aio cluster.
  docker build -t "${name}" .
}

build-images() {
  local origin_root=$1

  # TODO - build in a docker container to minimize dependencies
  # TODO - Need to build oc as well?
  # ${origin_root}/hack/build-go.sh

  local oz_images="${origin_root}/images/oz"

  local openshift_cmd="${origin_root}/_output/local/bin/linux/amd64/openshift"
  local osdn_path="${origin_root}/pkg/sdn/plugin/bin"
  pushd "${oz_images}/base" > /dev/null
    cp "${openshift_cmd}" bin/
    cp "${osdn_path}/openshift-sdn-ovs" bin/
    cp "${osdn_path}/openshift-sdn-docker-setup.sh" bin/
    chmod +x bin/*
    build-image openshift/oz-base
  popd > /dev/null

  pushd "${oz_images}/master" > /dev/null
    build-image openshift/oz-master
  popd > /dev/null

  pushd "${oz_images}/node" > /dev/null
    build-image openshift/oz-node
  popd > /dev/null
}

create() {
  local origin_root=$1
  local config_root=$2
  local network_plugin=$3

  # TODO allow this to be configurable
  local namespace=myproject

  # TODO - remove dependency on provision
  network_plugin="$(os::provision::get-network-plugin "${network_plugin}")"

  local nested_root="$(get-nested-root ${config_root})"

  local spec_root="${ORIGIN_ROOT}/hack/oz"

  # Add default service account to privileged scc to ensure that the
  # ozone container can be launched.
  #
  # TODO add under a new service account (like the router does) to avoid
  # giving too much privilege to the default account.
  oadm policy add-scc-to-group privileged system:serviceaccounts:"${namespace}"

  # TODO supporting more than aio may require targeting something other than the master
  local cluster_address="$(get-server-address)"
  local cluster_ip="$(echo ${cluster_address} | sed -e 's+:.*++')"

  oc create -f "${spec_root}/oz-master-service.yaml" > /dev/null
  local service_ip="$(oc get service oz-master --template "{{ .spec.clusterIP }}")"
  local node_port="$(oc get service oz-master --template '{{ $port := index .spec.ports 0 }}{{ $port.nodePort }}')"

  create-config-secret "${nested_root}" "${cluster_ip}" "${service_ip}" \
      "${node_port}" "${namespace}" "${network_plugin}"

  oc create -f "${spec_root}/ozone.yaml" > /dev/null

  create-rc-file "${ORIGIN_ROOT}" "${nested_root}"
}

# Retrieve the server url for the hosting cluster
get-server-address() {
  local current_context="$(oc config view -o jsonpath='{.current-context}')"
  local cluster="$(oc config view -o jsonpath="{.contexts[?(@.name == \"${current_context}\")].context.cluster}")"
  local server="$(oc config view -o jsonpath="{.clusters[?(@.name == \"${cluster}\")].cluster.server}")"
  echo "${server}" | sed -e 's+https://++'
}

get-nested-root() {
  local config_root=$1

  echo "${config_root}/nested"
}

wait-for-nested() {
  local config_root=$1

  local node_count="$(oc get dc oz-node --template='{{ .spec.replicas }}')"
  local nested_config="$(get-public-kubeconfig "$(get-nested-root "${config_root}")")"
  wait-for-cluster "${nested_config}" oc "${node_count}"
}

# Make it easy to get a shell on any of the ozone nodes. Use docker
# exec to work around 'oc exec' 80 char term limitation.
node-exec() {
  local node_name=$1

  echo "Connecting to node ${node_name}..."

  # The node pods have only one container.
  template='{{ with $cs := index .status.containerStatuses 0 }}{{ $cs.containerID }}{{ end }}'
  container_id="$(oc get pod "${node_name}" --template="${template}" | sed -e 's+docker://++')"
  if [[ -n "${container_id}" ]]; then
    docker exec -ti "${container_id}" /bin/bash
  fi
}

case "${1:-""}" in
  create)
    WAIT_FOR_CLUSTER=
    NETWORK_PLUGIN=
    OPTIND=2
    while getopts ":wn:" opt; do
      case $opt in
        w)
          WAIT_FOR_CLUSTER=1
          ;;
        n)
          NETWORK_PLUGIN="${OPTARG}"
          ;;
        \?)
          echo "Invalid option: -${OPTARG}" >&2
          exit 1
          ;;
        :)
          echo "Option -${OPTARG} requires an argument." >&2
          exit 1
          ;;
      esac
    done
    create "${ORIGIN_ROOT}" "${CONFIG_ROOT}" "${NETWORK_PLUGIN}"
    if [[ -n "${WAIT_FOR_CLUSTER}" ]]; then
      wait-for-nested "${CONFIG_ROOT}"
    fi
    ;;
  exec)
    if [[ -z "${2:-}" ]]; then
      >&2 echo "Usage: $0 $1 [name of node pod]"
      exit 2
    fi
    node-exec "${2}"
    ;;
  delete)
    delete-cluster "${CONFIG_ROOT}"
    ;;
  cleanup)
    # TODO remove nodes that don't have corresponding pods in the
    # hosting cluster
    delete-notready-nodes "${CONFIG_ROOT}"
    # TODO do this automatically on deletion
    cleanup-volumes
    ;;
  build-images)
    build-images "${ORIGIN_ROOT}"
    ;;
  wait-for-cluster)
    wait-for-nested "${CONFIG_ROOT}"
    ;;
  *)
    echo "Usage: $0 {create|exec|delete|cleanup|build-images|wait-for-cluster}"
    exit 2
esac
