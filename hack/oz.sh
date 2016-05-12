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

# TODO ensure the oc path is always qualified

# TODO Discover the ip to use
PUBLIC_IP="10.14.6.90"

CONFIG_ROOT="${ORIGIN_ROOT}/_oz"
create-config-secret() {
  local config_root=$1
  local public_ip=$2
  local public_port=$3
  local undershift_service_ip=$4
  local network_plugin=$5

  local master_config_dir="${config_root}/openshift.local.config/master"
  mkdir -p "${master_config_dir}"

  # Ensure nodes can reach master via service dns
  # TODO: make the master name and namespace dynamic
  local master_name="oz-master"
  local namespace="default"
  local master_fqdn="${master_name}.${namespace}.svc.cluster.local"

  master_url="https://localhost:8443"
  public_url="https://${public_ip}:${public_port}"

  # Include the ip for the overshift kube service to ensure that nodes
  # will be able to talk to the api.
  #
  # TODO - ensure that the portal net cidr differs between overshift
  # and undershift to avoid confusion.
  local overshift_service_ip="172.30.0.1"

  # TODO is there another way to set the network plugin and etcd dir
  # and is it safe to generate configuration over existing
  # configuration to allow config/etcd store reuse across cluster
  # starts?
  openshift start master --write-config="${master_config_dir}" \
      --master="${master_url}" \
      --etcd-dir="/var/lib/origin/openshift.local.etcd" \
      --public-master="${public_url}" \
      --network-plugin="${network_plugin}" > /dev/null

  openshift admin ca create-master-certs \
      --overwrite=false \
      --cert-dir="${master_config_dir}" \
      --hostnames="localhost,127.0.0.1,${public_ip},${undershift_service_ip},${master_fqdn},${overshift_service_ip}" \
      --master="${master_url}" \
      --public-master="${public_url}" > /dev/null

  # Create config files that default to the appropriate context
  local localhost_conf="${master_config_dir}/admin.kubeconfig"
  local public_conf="${master_config_dir}/public-admin.kubeconfig"
  cp "${localhost_conf}" "${public_conf}"
  local public_ctx="default/$(echo "${public_ip}" | sed 's/\./-/g'):${public_port}/system:admin"
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

  local overshift_root="$(get-overshift-root ${config_root})"

  oc delete dc oz-node --ignore-not-found=true > /dev/null
  oc delete dc oz-master --ignore-not-found=true > /dev/null
  oc delete service oz-master --ignore-not-found=true > /dev/null
  oc delete secret oz-config --ignore-not-found=true > /dev/null
  # etcd permissions require the use of sudo
  sudo rm -rf "${overshift_root}"
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

  local config="$(get-public-kubeconfig "$(get-overshift-root "${config_root}")")"
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
  local src_path="${origin_root}/Godeps/_workspace/src/github.com"
  local osdn_path="${src_path}/openshift/openshift-sdn/plugins/osdn/ovs/bin"
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

  network_plugin="$(os::provision::get-network-plugin "${network_plugin}")"

  local overshift_root="$(get-overshift-root ${config_root})"

  local spec_root="${ORIGIN_ROOT}/hack/oz"

  oc create -f "${spec_root}/oz-master-service.yaml" > /dev/null
  service_ip="$(oc get service oz-master --template "{{ .spec.clusterIP }}")"

  # TODO: discover the port
  create-config-secret "${overshift_root}" "${PUBLIC_IP}" "30123" \
      "${service_ip}" "${network_plugin}"

  # Add default service account to privileged scc to ensure that the
  # ozone container can be launched.
  #
  # TODO add under a new service account like the router to avoid
  # giving too much privilege to the default account.
  oadm policy add-scc-to-group privileged system:serviceaccounts:default

  oc create -f "${spec_root}/ozone.yaml" > /dev/null

  create-rc-file "${ORIGIN_ROOT}" "${overshift_root}"
}

get-overshift-root() {
  local config_root=$1

  echo "${config_root}/overshift"
}

get-undershift-root() {
  local config_root=$1

  echo "${config_root}/undershift"
}

# TODO allow shutdown of undershift
create-undershift() {
  local origin_root=$1
  local config_root=$2

  local undershift_root="$(get-undershift-root ${config_root})"
  mkdir -p "${undershift_root}"

  # TODO discover this path
  local bin_path="${origin_root}/_output/local/bin/linux/amd64"

  local config="$(get-kubeconfig "${undershift_root}")"

  # Override the default portal net cidr so that the ozone cluster can
  # use the default without ambiguity.
  #
  # TODO: Allow this to be configured
  local portal_net="172.40.0.0/16"

  pushd "${undershift_root}" > /dev/null
    sudo bash -c "OPENSHIFT_DNS_DOMAIN=undershift.local \
        ${bin_path}/openshift start --dns='tcp://${PUBLIC_IP}:53' \
        --portal-net=${portal_net} &> out.log & \
        echo \$! > ${undershift_root}/undershift.pid"

    local msg="OpenShift configuration to be written"
    local condition="test -f ${config}"
    os::provision::wait-for-condition "${msg}" "${condition}"

    # Make the configuration readable so it can be used by oc
    sudo chmod -R g+rw openshift.local.config
  popd > /dev/null

  wait-for-cluster "${config}" "${bin_path}/oc" 1

  local rc_file="oz-undershift.rc"

  cat > "${rc_file}" <<EOF
export KUBECONFIG=${config}
export PATH=\$PATH:${bin_path}
EOF

  if [[ "${KUBECONFIG:-}" != "${config}"  ||
          ":${PATH}:" != *":${bin_path}:"* ]]; then
    echo "
Before invoking the openshift cli for the undershift cluster, make sure to
source the cluster's rc file to configure the bash environment:

  $ . ${rc_file}
  $ oc get nodes
"
  fi
}

delete-undershift() {
  local config_root=$1

  local undershift_root="$(get-undershift-root "${config_root}")"
  local pid_filename="${undershift_root}/undershift.pid"
  if [[ -f "${pid_filename}" ]]; then

    # TODO wait for terminating ozone nodes or their pod volumes will
    # be busy until docker is restarted.

    local pid="$(cat "${pid_filename}")"
    # TODO kill gracefully!
    sudo -E kill "${pid}"
    # TODO consider optionally saving cluster state
    sudo -E rm -rf "${undershift_root}"
  else
    >&2 echo "OpenShift underlay not detected"
  fi
}

wait-for-overshift() {
  local config_root=$1

  local undershift_config="$(get-kubeconfig "$(get-undershift-root "${config_root}")")"
  local node_count="$(oc --config="${undershift_config}" get dc oz-node --template='{{ .spec.replicas }}')"
  local overshift_config="$(get-public-kubeconfig "$(get-overshift-root "${config_root}")")"
  wait-for-cluster "${overshift_config}" oc "${node_count}"
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
      wait-for-overshift "${CONFIG_ROOT}"
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
    # undershift
    delete-notready-nodes "${CONFIG_ROOT}"
    # TODO do this automatically on deletion
    cleanup-volumes
    ;;
  build-images)
    build-images "${ORIGIN_ROOT}"
    ;;
  create-undershift)
    create-undershift "${ORIGIN_ROOT}" "${CONFIG_ROOT}"
    ;;
  delete-undershift)
    delete-undershift "${CONFIG_ROOT}"
    ;;
  wait-for-cluster)
    wait-for-overshift "${CONFIG_ROOT}"
    ;;
  *)
    echo "Usage: $0 {create|exec|delete|cleanup|build-images|create-undershift|delete-undershift|wait-for-cluster}"
    exit 2
esac
