#!/bin/bash

# This script runs the networking e2e tests. See CONTRIBUTING.adoc for
# documentation.

set -o errexit
set -o nounset
set -o pipefail

if [[ -n "${OPENSHIFT_VERBOSE_OUTPUT:-}" ]]; then
  set -o xtrace
  export PS4='+ \D{%b %d %H:%M:%S} $(basename ${BASH_SOURCE}):${LINENO} ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
fi

# Ensure that subshells inherit bash settings (specifically xtrace)
export SHELLOPTS

OS_ROOT=$(dirname "${BASH_SOURCE}")/../..
source "${OS_ROOT}/hack/util.sh"
source "${OS_ROOT}/hack/common.sh"
source "${OS_ROOT}/hack/lib/log.sh"
source "${OS_ROOT}/hack/lib/util/environment.sh"
os::log::install_errexit

NETWORKING_DEBUG=${NETWORKING_DEBUG:-false}

# These strings filter the available tests.
#
# The EmptyDir test is a canary; it will fail if mount propagation is
# not properly configured on the host.
NETWORKING_E2E_FOCUS="${NETWORKING_E2E_FOCUS:-etworking|Services|EmptyDir volumes should support \(root,0644,tmpfs\)}"
NETWORKING_E2E_SKIP="${NETWORKING_E2E_SKIP:-}"

DEFAULT_SKIP_LIST=(
  # DNS inside container fails in CI but works locally
  "should provide Internet connection for containers"
  # Skip the router tests until they no longer require connectivity
  # between test host and pod network.
  "openshift router"
)

# Skip tests that require secrets if running with docker < 1.10.
SECRETS_SKIP_LIST=(
  "Networking should function for intra-pod"
)

CLUSTER_CMD="${OS_ROOT}/hack/oz.sh"

# Control variable to limit unnecessary cleanup
CLEANUP_REQUIRED=0

function get-undershift-kubeconfig() {
  echo "${OS_ROOT}/_oz/undershift/openshift.local.config/master/admin.kubeconfig"
}

function get-node-names() {
  local config=$1

  read -d '' template <<'EOF'
{{range $item := .items}}
  {{ printf "%s " $item.metadata.name }}
{{end}}
EOF
  # Remove formatting before use
  template="$(echo "${template}" | tr -d '\n' | sed -e 's/} \+/}/g')"
  # TODO - ensure oc is operating in the correct namespace
  oc --config="${config}" get pods --template="${template}"
}

function copy-node-files() {
  local source_path=$1
  local base_dest_dir=$2

  local config="$(get-undershift-kubeconfig)"

  local node_names=("$(get-node-names "${config}")")
  node_names=(${node_names//\ / })

  for node_name in "${node_names[@]}"; do
    local dest_dir="${base_dest_dir}/${node_name}"
    if [[ ! -d "${dest_dir}" ]]; then
      mkdir -p "${dest_dir}"
    fi
    oc --config="${config}" rsync "${node_name}:${source_path}" "${dest_dir}" \
        > /dev/null
  done
}

function save-node-logs() {
  local base_dest_dir=$1
  local output_to_stdout=${2:-}

  os::log::info "Saving node logs"

  local node_log_file="/tmp/pod-systemd.log.gz"

  local config="$(get-undershift-kubeconfig)"

  local node_names=("$(get-node-names "${config}")")
  node_names=(${node_names//\ / })

  for node_name in "${node_names[@]}"; do
    local dest_dir="${base_dest_dir}/${node_name}"
    if [[ ! -d "${dest_dir}" ]]; then
      mkdir -p "${dest_dir}"
    fi
    # TODO set explicity oc binary location
    # TODO ensure oc is targeting the underlay
    oc --config="${config}" exec -t "${node_name}" -- \
        bash -c "journalctl | gzip > ${node_log_file}"
    oc --config="${config}" rsync "${node_name}:${node_log_file}" \
       "${dest_dir}" > /dev/null
    # Output logs to stdout to ensure that jenkins has detail to
    # classify the failure cause.
    if [[ -n "${output_to_stdout}" ]]; then
      local msg="System logs for node ${node_name}"
      os::log::info "< ${msg} >"
      os::log::info "***************************************************"
      gunzip --stdout "${dest_dir}/$(basename "${node_log_file}")"
      os::log::info "***************************************************"
      os::log::info "</ ${msg} >"
    fi
  done
}

function save-artifacts() {
  local name=$1
  local config_root=$2

  os::log::info "Saving cluster configuration"

  local dest_dir="${ARTIFACT_DIR}/${name}"

  local config_source="${config_root}/openshift.local.config"
  local config_dest="${dest_dir}/openshift.local.config"
  mkdir -p "${config_dest}"
  cp -r ${config_source}/* ${config_dest}/

  copy-node-files "/etc/hosts" "${dest_dir}"
  copy-node-files "/etc/resolv.conf" "${dest_dir}"
}

function deploy-cluster() {
  local name=$1
  local plugin=$2
  local log_dir=$3

  os::log::info "Launching a cluster for the ${name} plugin"

  # TODO - support tmpdir location of oz config root?
  export OPENSHIFT_CONFIG_ROOT="${OS_ROOT}/_oz/overshift"

  CLEANUP_REQUIRED=1

  if ${CLUSTER_CMD} delete && ${CLUSTER_CMD} create -w -n "${plugin}"; then
    local exit_status=0
  else
    local exit_status=1
  fi

  save-artifacts "${name}" "${OPENSHIFT_CONFIG_ROOT}"

  return "${exit_status}"
}

function get-public-kubeconfig-from-root() {
  local config_root=$1

  echo "${config_root}/openshift.local.config/master/public-admin.kubeconfig"
}

function get-kubeconfig-from-root() {
  local config_root=$1

  echo "${config_root}/openshift.local.config/master/admin.kubeconfig"
}

# Any non-zero exit code from any test run invoked by this script
# should increment TEST_FAILURE so the total count of failed test runs
# can be returned as the exit code.
TEST_FAILURES=0
function test-osdn-plugin() {
  local name=$1
  local plugin=$2
  local isolation=$3

  os::log::info "Targeting ${name} plugin: ${plugin}"

  local log_dir="${LOG_DIR}/${name}"
  mkdir -p "${log_dir}"

  local deployment_failed=
  local tests_failed=

  if deploy-cluster "${name}" "${plugin}" "${log_dir}"; then
    os::log::info "Running networking e2e tests against the ${name} plugin"
    export TEST_REPORT_FILE_NAME="${name}-junit"

    export OPENSHIFT_NETWORK_ISOLATION="${isolation}"
    local kubeconfig="$(get-public-kubeconfig-from-root "${OPENSHIFT_CONFIG_ROOT}")"
    if ! TEST_REPORT_FILE_NAME=networking_${name}_${isolation} \
         run-extended-tests "${kubeconfig}" "${log_dir}/test.log"; then
      tests_failed=1
      os::log::error "e2e tests failed for plugin: ${plugin}"
    fi
  else
    deployment_failed=1
    os::log::error "Failed to deploy cluster for plugin: {$name}"
  fi

  # Record the failure before further errors can occur.
  if [[ -n "${deployment_failed}" || -n "${tests_failed}" ]]; then
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi

  # Output node logs to stdout if deployment fails
  save-node-logs "${log_dir}" "${deployment_failed}"

  os::log::info "Shutting down cluster for the ${name} plugin"
  ${CLUSTER_CMD} delete
  CLEANUP_REQUIRED=0
}

function join { local IFS="$1"; shift; echo "$*"; }

function run-extended-tests() {
  local kubeconfig=$1
  local log_path=${2:-}

  local focus_regex="${NETWORKING_E2E_FOCUS}"
  local skip_regex="${NETWORKING_E2E_SKIP}"

  if [[ -z "${skip_regex}" ]]; then
      skip_regex=$(join '|' "${DEFAULT_SKIP_LIST[@]}")

      # Skip secret-requiring tests if running with docker without
      # mount propagation support (< 1.10).
      #
      # TODO: Remove this check once 1.10 becomes the default in F23/rhel7/centos7
      if [[ "$(docker version -f '{{.Server.Version}}' | cut -c 1-3)" != "1.1" ]]; then
        skip_regex="${skip_regex}|$(join '|' "${SECRETS_SKIP_LIST[@]}")"
      fi
  fi

  local test_args="--test.v '--ginkgo.skip=${skip_regex}' \
'--ginkgo.focus=${focus_regex}' ${TEST_EXTRA_ARGS}"

  if [[ "${NETWORKING_DEBUG}" = 'true' ]]; then
    local test_cmd="dlv exec ${TEST_BINARY} -- ${test_args}"
  else
    local test_cmd="${TEST_BINARY} ${test_args}"
  fi

  if [[ -n "${log_path}" ]]; then
    test_cmd="${test_cmd} | tee ${log_path}"
  fi

  local saved_kubeconfig="${KUBECONFIG}"
  export KUBECONFIG="${kubeconfig}"
  export EXTENDED_TEST_PATH="${OS_ROOT}/test/extended"

  pushd "${EXTENDED_TEST_PATH}/networking" > /dev/null
    eval "${test_cmd}; "'exit_status=${PIPESTATUS[0]}'
  popd > /dev/null

  # Reset to old value to ensure undershift is used by default
  # TODO provide better clarity between under/overshift
  export KUBECONFIG="${saved_kubeconfig}"

  return ${exit_status}
}

CONFIG_ROOT="${OPENSHIFT_CONFIG_ROOT:-}"
case "${CONFIG_ROOT}" in
  dev)
    CONFIG_ROOT="${OS_ROOT}"
    ;;
  oz)
    CONFIG_ROOT="${OS_ROOT}/_oz/overshift"
    if [[ ! -d "${CONFIG_ROOT}" ]]; then
      os::log::error "OPENSHIFT_CONFIG_ROOT=oz but ozone cluster not found"
      # TODO - how to document the requirement for undershift?
      os::log::info  "To launch a cluster: hack/oz.sh create-undershift && hack/oz.sh create -w"
      exit 1
    fi
    ;;
  *)
    if [[ -n "${CONFIG_ROOT}" ]]; then
      CONFIG_FILE="${CONFIG_ROOT}/openshift.local.config/master/admin.kubeconfig"
      if [[ ! -f "${CONFIG_FILE}" ]]; then
        os::log::error "${CONFIG_FILE} not found"
        exit 1
      fi
    fi
    ;;
esac

TEST_EXTRA_ARGS="$@"

if [[ "${OPENSHIFT_SKIP_BUILD:-false}" = "true" ]] &&
     [[ -n $(os::build::find-binary extended.test) ]]; then
  os::log::warn "Skipping rebuild of test binary due to OPENSHIFT_SKIP_BUILD=true"
else
  hack/build-go.sh test/extended/extended.test
fi
TEST_BINARY="${OS_ROOT}/$(os::build::find-binary extended.test)"

os::log::info "Starting 'networking' extended tests"
if [[ -n "${CONFIG_ROOT}" ]]; then
  KUBECONFIG="$(get-kubeconfig-from-root "${CONFIG_ROOT}")"
  os::log::info "KUBECONFIG=${KUBECONFIG}"
  run-extended-tests "${KUBECONFIG}"
elif [[ -n "${OPENSHIFT_TEST_KUBECONFIG:-}" ]]; then
  os::log::info "KUBECONFIG=${OPENSHIFT_TEST_KUBECONFIG}"
  # Run tests against an existing cluster
  run-extended-tests "${OPENSHIFT_TEST_KUBECONFIG}"
else
  # For each plugin, run tests against a test-managed cluster

  os::util::environment::setup_tmpdir_vars "test-extended/networking"
  reset_tmp_dir

  os::log::start_system_logger

  if [[ -n "${OPENSHIFT_SKIP_BUILD:-}" ]]; then
    os::log::warn "Skipping image build due to OPENSHIFT_SKIP_BUILD=true"
  else
    os::log::info "Building ozone images"
    ${CLUSTER_CMD} build-images
  fi

  # Ensure cleanup on error
  ENABLE_SELINUX=0
  function cleanup {
    local exit_code=$?
    if [[ "${CLEANUP_REQUIRED}" = "1" ]]; then
      os::log::info "Shutting down cluster"
      ${CLUSTER_CMD} delete
    fi
    enable-selinux || true
    if [[ "${TEST_FAILURES}" = "0" ]]; then
      os::log::info "No test failures were detected"
    else
      os::log::error "${TEST_FAILURES} plugin(s) failed one or more tests"
    fi
    # Return non-zero for either command or test failures
    if [[ "${exit_code}" = "0" ]]; then
      exit_code="${TEST_FAILURES}"
    else
      os::log::error "Exiting with code ${exit_code}"
    fi
    exit $exit_code
  }
  trap "exit" INT TERM
  trap "cleanup" EXIT

  # Docker-in-docker is not compatible with selinux
  disable-selinux

  # Ignore deployment errors for a given plugin to allow other plugins
  # to be tested.
  test-osdn-plugin "subnet" "redhat/openshift-ovs-subnet" "false" || true

  # Avoid unnecessary go builds for subsequent deployments
  export OPENSHIFT_SKIP_BUILD=true

  test-osdn-plugin "multitenant" "redhat/openshift-ovs-multitenant" "true" || true
fi
