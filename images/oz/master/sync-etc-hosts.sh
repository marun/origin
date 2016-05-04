#!/bin/bash

# Update /etc/hosts with entries for each node in the cluster to
# ensure that node names are resolveable on the master.  This is
# required for the master to be able to query the kubelet, since query
# urls are currently composed with the node name as host rather than
# any of a node's addresses.
#
# This script is intended to be managed by a systemd timer so no
# locking is performed.
#
# Revisit when upstream kube addresses the issue:
#
#     https://github.com/kubernetes/kubernetes/issues/22063
#

set -o errexit
set -o nounset
set -o pipefail

# Retrieve address|host pairs for all nodes in the cluster
get-node-entries() {
  local node_prefix=$1
  local config=$2

  local template=
  # Nodes are assumed to only have a single address
  # Use | as a placeholder for \t to work around how bash parses arrays
  read -d '' template <<'EOF'
{{ range $item := .items }}
  {{ with $addressMap := index .status.addresses 0 }}
    {{ printf "%s|%s\\n" $addressMap.address $item.metadata.name }}
  {{ end }}
{{ end }}
EOF
  # Remove formatting before use
  template="$(echo "${template}" | tr -d '\n' | sed -e 's/} \+/}/g')"

  echo "$(oc --config="${config}" get nodes --template="${template}" \
      | grep ${node_prefix})"
}

get-ts-entry() {
  local entry=$1

  echo "${entry}" | sed -e 's+|+\t+'
}

# Retrieve the contents of /etc/hosts minus entries for unknown nodes
get-filtered-entries() {
  local node_prefix=$1
  local node_entries=$2

  while read line; do
    local skip=
    if [[ "${line}" == *"${node_prefix}"* ]]; then
      local include=
      for entry in ${node_entries[@]}; do
        if [[ "${line}" == "$(get-ts-entry "${entry}")" ]]; then
          include=1
        fi
      done
      if [[ -z "${include}" ]]; then
        skip=1
      fi
    fi

    if [[ -z "${skip}" ]]; then
      if [[ -n "${ENTRIES}" ]]; then
        ENTRIES+="\n"
      fi
      ENTRIES+="${line}"
    else
      CHANGED=1
    fi
  done < /etc/hosts
}

add-new-addresses() {
  local node_entries=$1

  for entry in ${node_entries[@]}; do
    local ts_entry="$(get-ts-entry "${entry}")"
    if [[ "${ENTRIES}" != *"${ts_entry}"* ]]; then
      ENTRIES+="\n${ts_entry}"
      CHANGED=1
    fi
  done
}

main() {
  local config=$1

  local node_prefix="oz-node"
  local node_entries=( "$(get-node-entries "${node_prefix}" "${config}")" )

  get-filtered-entries "${node_prefix}" "${node_entries}"
  add-new-addresses "${node_entries}"

  if [[ -n "${CHANGED}" ]]; then
    echo -e "${ENTRIES}" > /etc/hosts
  fi
}

# Global variables vs passing by reference in bash? No thanks, I'd
# rather be coding in python.
ENTRIES=
CHANGED=

main /var/lib/origin/openshift.local.config/master/admin.kubeconfig
