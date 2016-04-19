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

CONFIG_ROOT="${ORIGIN_ROOT}/_oz"
create-config-secret() {
  local config_root=$1

  local master_name="oz-master"
  local namespace="default"
  local master_fqdn="${master_name}.${namespace}.svc.cluster.local"

  mkdir -p "${config_root}"

  # TODO: Determine the public master programatically
  local public_master="https://172.17.0.4:30123"
  local master_url="https://localhost:8443"
  pushd "${config_root}" > /dev/null
    openshift start master --write-config=openshift.local.config/master \
        --master="${master_url}" \
        --public-master="${public_master}" \
        --network-plugin="redhat/openshift-ovs-subnet"
    # Ensure that the nodeport context is used by default
    local config="openshift.local.config/master/admin.kubeconfig"
    KUBECONFIG="${config}" oc config use-context default/172-17-0-4:30123/system:admin
  popd > /dev/null

  local secret_file="${config_root}/config.json"
  openshift cli secrets new oz-config \
    "${config_root}/openshift.local.config/master/" \
    -o json > "${secret_file}"
  oc create -f "${secret_file}"
}

create-rc-file() {
  local origin_root=$1
  local config_root=$2

  local rc_file="oz.rc"
  local config="${config_root}/openshift.local.config/master/admin.kubeconfig"
  echo "export KUBECONFIG=${config}" > "${rc_file}"

  if [ "${KUBECONFIG:-}" != "${config}" ]; then
    echo ""
    echo "Before invoking the openshift cli, make sure to source the
cluster's rc file to configure the bash environment:

  $ . ${rc_file}
  $ oc get nodes
"
  fi
}

launch-cluster() {
  local spec_root=$1

  oc create -f "${spec_root}/oz-master-service.yaml"
  oc create -f "${spec_root}/oz-master.yaml"
  oc create -f "${spec_root}/oz-node.yaml"
}

delete-cluster() {
  local config_root=$1

  oc delete pod oz-node --ignore-not-found=true
  oc delete pod oz-master --ignore-not-found=true
  oc delete service oz-master --ignore-not-found=true
  oc delete secret oz-config --ignore-not-found=true
  rm -rf "${config_root}"
}

build-image() {
  local name=$1

  # TODO make this configurable
  local image_repo="10.14.6.90:4000"
  local repo_name="${image_repo}/${name}"

  docker build -t "${name}" .
  docker tag "${name}" "${repo_name}"
  docker push "${repo_name}"
}

build-images() {
  local origin_root=$1

  # TODO - build in a docker container to minimize dependencies
  # ${origin_root}/hack/build-go.sh

  local oz_images="${origin_root}/images/oz"

  pushd "${oz_images}/base" > /dev/null
    build-image openshift/oz-base
  popd > /dev/null

  local openshift_cmd="${origin_root}/_output/local/bin/linux/amd64/openshift"

  pushd "${oz_images}/master" > /dev/null
    cp "${openshift_cmd}" bin/
    cp "${origin_root}/examples/hello-openshift/hello-pod.json" bin/
    build-image openshift/oz-master
  popd > /dev/null

  local src_path="${origin_root}/Godeps/_workspace/src/github.com"
  local osdn_path="${src_path}/openshift/openshift-sdn/plugins/osdn/ovs/bin"
  pushd "${oz_images}/node" > /dev/null
    cp "${openshift_cmd}" bin/
    cp "${osdn_path}/openshift-sdn-ovs" bin/
    cp "${osdn_path}/openshift-sdn-docker-setup.sh" bin/
    chmod +x bin/*
    build-image openshift/oz-node
  popd > /dev/null
}

case "${1:-""}" in
  create)
    create-config-secret "${CONFIG_ROOT}"
    launch-cluster "${ORIGIN_ROOT}/hack/oz"
    create-rc-file "${ORIGIN_ROOT}" "${CONFIG_ROOT}"
    ;;
  delete)
    delete-cluster "${CONFIG_ROOT}"
    ;;
  build-images)
    build-images "${ORIGIN_ROOT}"
    ;;
  *)
    echo "Usage: $0 {create|delete|build-images}"
    exit 2
esac
