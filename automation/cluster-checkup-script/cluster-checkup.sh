#!/bin/bash

# Exit on any error
set -o pipefail

VERSION="1.0.0"

echo "==============================================="
echo "Cluster Checkup Script - Version $VERSION"
echo "==============================================="

echo "Running Ansible playbook to gather cluster information..."

RAW_DATA=$(ANSIBLE_STDOUT_CALLBACK=json ansible-playbook -i inventory.yaml cluster-playbook-json-output.yaml 2>/dev/null)

if [ -z "$RAW_DATA" ]; then
    echo "Error: Failed to run Ansible playbook or no output received."
    exit 1
fi

echo -e "\nParsing hardware information..."

echo -e "\n--- Hardware Information ---"
echo "$RAW_DATA" | jq -e -r '
    .plays[].tasks[]
    | select(.task.name == "Display hardware information")
    | .hosts[]
    | if (.msg | type == "array") then .msg[] else .msg end
'

#echo "$RAW_DATA" | jq -e -r '.plays[].tasks[] | select(.task.name == "Display hardware information") | .hosts[].msg'

if [ $? -ne 0 ]; then
    echo "Error: Failed to retrieve hardware information from JSON output."
    exit 1
fi

echo "Parsing k3s cluster information..."

echo -e "\n--- k3s Cluster Information ---"
echo "$RAW_DATA" | jq -e -r '
    .plays[].tasks[]
    | select(.task.name == "Display k3s cluster information")
    | .hosts[]
    | if (.msg | type == "array") then .msg[] else .msg end
'

#echo "$RAW_DATA" | jq -e -r '.plays[].tasks[] | select(.task.name == "Display k3s cluster information") | .hosts[].msg' 

if [ $? -ne 0 ]; then
    echo "Error: Failed to retrieve k3s cluster information from JSON output."
    exit 1
fi