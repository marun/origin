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
  local public_ip=$2
  local public_port=$3
  local service_ip=$4

  local master_config_dir="${config_root}/openshift.local.config/master"
  mkdir -p "${master_config_dir}"

  master_url="https://localhost:8443"
  public_url="https://${public_ip}:${public_port}"

  openshift admin ca create-master-certs \
      --overwrite=false \
      --cert-dir="${master_config_dir}" \
      --hostnames="localhost,127.0.0.1,${public_ip},${service_ip}" \
      --master="${master_url}" \
      --public-master="${public_url}"

  openshift start master --write-config="${master_config_dir}" \
      --master="${master_url}" \
      --public-master="${public_url}" \
      --network-plugin="redhat/openshift-ovs-subnet"

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

create-rc-file() {
  local origin_root=$1
  local config_root=$2

  local rc_file="oz.rc"
  local config="${config_root}/openshift.local.config/master/public-admin.kubeconfig"
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

create() {
  local origin_root=$1
  local config_root=$2

  local spec_root="${ORIGIN_ROOT}/hack/oz"

  oc create -f "${spec_root}/oz-master-service.yaml"
  service_ip="$(oc get service oz-master --template "{{ .spec.clusterIP }}")"

  # TODO: discover public ip and port
  create-config-secret "${CONFIG_ROOT}" "172.17.0.4" "30123" "${service_ip}"
  launch-cluster "${spec_root}"
  create-rc-file "${ORIGIN_ROOT}" "${CONFIG_ROOT}"
}


case "${1:-""}" in
  create)
    create "${ORIGIN_ROOT}" "${CONFIG_ROOT}"
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
