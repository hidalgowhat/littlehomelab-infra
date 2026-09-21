#!/bin/bash

# Exit on any error
set -o pipefail

VERSION="1.0.0"

echo "==============================================="
echo "Cluster Update Script - Version $VERSION"
echo "==============================================="

echo "Running ansible playbook to update the cluster packages..."

ansible-playbook -i inventory.yaml update-playbook.yaml

if [ $? -ne 0 ]; then
    echo "Error: Failed to run Ansible playbook for cluster update."
    exit 1
fi

echo -e "\nCluster update completed successfully."