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

CONFIG_ROOT="${ORIGIN_ROOT}/_oz"
create-config-secret() {
  local config_root=$1
  local public_ip=$2
  local public_port=$3
  local service_ip=$4

  local master_config_dir="${config_root}/openshift.local.config/master"
  mkdir -p "${master_config_dir}"

  # Ensure nodes can reach master via service dns
  # TODO: make the master name and namespace dynamic
  local master_name="oz-master"
  local namespace="default"
  local master_fqdn="${master_name}.${namespace}.svc.cluster.local"

  master_url="https://localhost:8443"
  public_url="https://${public_ip}:${public_port}"

  # TODO is there another way to set the network plugin and etcd dir
  # and is it safe to generate configuration over existing
  # configuration to allow config/etcd store reuse across cluster
  # starts?
  openshift start master --write-config="${master_config_dir}" \
      --master="${master_url}" \
      --etcd-dir="/var/lib/origin/openshift.local.etcd" \
      --public-master="${public_url}" \
      --network-plugin="redhat/openshift-ovs-subnet"

  openshift admin ca create-master-certs \
      --overwrite=false \
      --cert-dir="${master_config_dir}" \
      --hostnames="localhost,127.0.0.1,${public_ip},${service_ip},${master_fqdn}" \
      --master="${master_url}" \
      --public-master="${public_url}"

  # Create config files that default to the appropriate context
  local localhost_conf="${master_config_dir}/admin.kubeconfig"
  local public_conf="${master_config_dir}/public-admin.kubeconfig"
  cp "${localhost_conf}" "${public_conf}"
  local public_ctx="default/$(echo "${public_ip}" | sed 's/\./-/g'):${public_port}/system:admin"
  oc --config="${public_conf}" config use-context "${public_ctx}"

  local secret_file="${config_root}/config.json"
  openshift cli secrets new oz-config \
    "${config_root}/openshift.local.config/master/" \
    -o json > "${secret_file}"
  oc create -f "${secret_file}"
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

  oc delete dc oz-node --ignore-not-found=true
  oc delete dc oz-master --ignore-not-found=true
  oc delete service oz-master --ignore-not-found=true
  oc delete secret oz-config --ignore-not-found=true
  rm -rf "${overshift_root}"
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

  local overshift_root="$(get-overshift-root ${config_root})"

  local spec_root="${ORIGIN_ROOT}/hack/oz"

  oc create -f "${spec_root}/oz-master-service.yaml"
  service_ip="$(oc get service oz-master --template "{{ .spec.clusterIP }}")"

  # TODO: discover public ip and port
  create-config-secret "${overshift_root}" "10.14.6.90" "30123" "${service_ip}"

  # Add default service account to privileged scc to ensure that the
  # ozone container can be launched.
  #
  # TODO add under a new service account like the router to avoid
  # giving too much privilege to the default account.
  oadm policy add-scc-to-group privileged system:serviceaccounts:default

  oc create -f "${spec_root}/ozone.yaml"

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

  pushd "${undershift_root}" > /dev/null
    sudo bash -c "${bin_path}/openshift start &> out.log & echo \$! > ${undershift_root}/undershift.pid"

    local msg="OpenShift configuration to be written"
    local condition="test -f ${config}"
    os::provision::wait-for-condition "${msg}" "${condition}"

    # Make the configuration readable so it can be used by oc
    sudo chmod -R g+r openshift.local.config
  popd > /dev/null

  wait-for-cluster "${config}" oc 1

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
    local pid="$(cat "${pid_filename}")"
    sudo -E kill -9 "${pid}"
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

case "${1:-""}" in
  create)
    create "${ORIGIN_ROOT}" "${CONFIG_ROOT}"
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
    echo "Usage: $0 {create|delete|cleanup|build-images|create-undershift|delete-undershift|wait-for-cluster}"
    exit 2
esac
