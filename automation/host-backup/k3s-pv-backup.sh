#!/bin/bash
set -e

# Load Restic environment variables
source /etc/restic/r2-pvs.env

echo "=== Starting K3s PV Backup: $(date) ==="

# 1. Back up the local path storage directory on NVME drive
restic backup /var/lib/rancher/k3s/storage --tag k3s-pvs

# 2. Prune old snapshots (Keeps 7 daily, 4 weekly, 6 monthly)
restic forget --tag k3s-pvs --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

echo "=== Backup completed successfully: $(date) ==="
