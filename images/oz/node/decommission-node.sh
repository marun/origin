#!/bin/bash

HOSTNAME="$(hostname)"
oadm manage-node "${HOSTNAME}" --evacuate --force
# TODO wait for pods to drain before deleting node
oc delete node "${HOSTNAME}"
