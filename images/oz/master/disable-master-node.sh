#!/bin/bash

OS_WAIT_FOREVER=-1
os::provision::wait-for-condition() {
  local msg=$1
  # condition should be a string that can be eval'd.  When eval'd, it
  # should not output anything to stderr or stdout.
  local condition=$2
  local timeout=${3:-60}

  local start_msg="Waiting for ${msg}"
  local error_msg="[ERROR] Timeout waiting for ${msg}"

  local counter=0
  while ! $(${condition}); do
    if [[ "${counter}" = "0" ]]; then
      echo "${start_msg}"
    fi

    if [[ "${counter}" -lt "${timeout}" ||
            "${timeout}" = "${OS_WAIT_FOREVER}" ]]; then
      counter=$((counter + 1))
      if [[ "${timeout}" != "${OS_WAIT_FOREVER}" ]]; then
        echo -n '.'
      fi
      sleep 1
    else
      echo -e "\n${error_msg}"
      return 1
    fi
  done

  if [[ "${counter}" != "0" && "${timeout}" != "${OS_WAIT_FOREVER}" ]]; then
    echo -e '\nDone'
  fi

}

os::provision::is-node-registered() {
  local config=$1
  local node_name=$2

  oc --config="${config}" get nodes "${node_name}" &> /dev/null

}

os::provision::disable-node() {
  local config=$1
  local node_name=$2

  local msg="${node_name} to register with the master"
  local condition="os::provision::is-node-registered ${config} ${node_name}"
  os::provision::wait-for-condition "${msg}" "${condition}"

  echo "Disabling scheduling for node ${node_name}"
  osadm --config="${config}" manage-node "${node_name}" --schedulable=false > \
      /dev/null
}

os::provision::disable-node \
    /var/lib/origin/openshift.local.config/master/admin.kubeconfig \
    "$(hostname)"
