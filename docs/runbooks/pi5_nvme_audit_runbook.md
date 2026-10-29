# Pi 5 NVMe Hardware Audit & Recovery Runbook

**Target Node:** `pi5-8gb-node` (`172.69.115.201`)  
**Mountpoint:** `/var/lib/rancher/k3s/storage` (`/dev/nvme0n1p1`)  
**Workloads Impacted:** Postgres (`wiki`), Pi-hole (`pihole`), Uptime Kuma (`monitoring`), Authelia (`default`)  
**Execution Context:** Direct SSH or physical console as `admin` / `root`.

---

## 1. Overview & Hardware Failure Modes

When an NVMe drive on the Raspberry Pi 5 encounters an `error -5 EIO` or `NVME_IOCTL_ADMIN_CMD: Input/output error`, the Linux kernel trips the `ext4` filesystem into an emergency `shutdown` or read-only (`ro`) state to protect persistent volumes. On the Pi 5, this is rarely flash wear; it is typically caused by:

1. **APST Deep Sleep Lockups:** The controller enters autonomous low-power sleep states (`PS3`/`PS4`) and fails to wake within the Broadcom BCM2712 PCIe bridge's timeout window during sudden database writes.
2. **PCIe Bus Signal Drops:** High-frequency packet drops or thermal expansion on the FFC ribbon cable triggering PCIe Advanced Error Reporting (AER) fatal errors.
3. **Transient Power Droops:** Voltage sag on the 3.3V rail during concurrent heavy writes (e.g., Restic backups scanning files while Postgres, Grafana, and Pi-hole flush SQLite/WAL data).

---

## 2. Phase 1: Hardware & Power Health Audit (Non-Destructive)

Run these checks while the node and cluster are operating normally:

```bash
# 1. Check for under-voltage or thermal throttling events since boot
# Expected: throttled=0x0. If 0x50000 or 0x50005 appears, power sagged under load.
vcgencmd get_throttled

# 2. Inspect NVMe controller health, error log entries, and media wear
sudo nvme smart-log /dev/nvme0

# 3. Check for PCIe bus link drops or Advanced Error Reporting (AER) anomalies
sudo lspci -vvv -d ::0108 | grep -iE "LnkSta:|UESta:|CESta:"

# 4. Check active Autonomous Power State Transition (APST) settings
sudo nvme get-feature /dev/nvme0 -f 0x0c -H
```

### Permanent Hardware Hardening
1. **Disable NVMe APST Deep Sleep:** In `/boot/firmware/cmdline.txt`, append the following parameter to the single line of boot arguments:
   ```text
   nvme_core.default_ps_max_latency_us=0
   ```
2. **Lock PCIe Gen 2 Speed:** Ensure `/boot/firmware/config.txt` explicitly sets:
   ```ini
   dtparam=pciex1
   ```
   *(Never set `dtparam=pciex1_gen=3` over unshielded ribbon cables).*

---

## 3. Phase 2: Live Incident Triage

If stateful pods (`postgres`, `pihole`, `uptime-kuma`, `grafana`) simultaneously enter `CrashLoopBackOff`:

```bash
# 1. Check if ext4 tripped into emergency 'shutdown' or 'ro' (read-only)
findmnt /var/lib/rancher/k3s/storage

# 2. Inspect kernel ring buffer for I/O timeouts and dropped PCIe links
dmesg -T | grep -iE "ext4|nvme|pcie|i/o|error" | tail -n 25

# 3. Probe the NVMe Admin Queue
sudo nvme id-ctrl /dev/nvme0 | grep -E "mn|sn|fr"
```

* **If `nvme id-ctrl` succeeds:** The controller is alive; the issue is soft filesystem corruption. Proceed to Phase 3.
* **If `nvme id-ctrl` returns `Input/output error`:** The NVMe controller is locked on the PCIe bus. A soft reboot will not reset the 3.3V rail. Perform a cold hardware power cycle:
  ```bash
  sudo systemctl stop k3s
  sudo poweroff
  ```
  *Wait for the red LED, disconnect the USB-C power cable for 20 seconds, and reconnect.*

---

## 4. Phase 3: Offline Filesystem Repair (`fsck.ext4`)

Never run `fsck` while container runtimes hold active mount namespaces.

```bash
# 1. Stop K3s and tear down all containerd mount namespaces
sudo systemctl stop k3s
sudo /usr/local/bin/k3s-killall.sh

# 2. Verify the block device is completely released
findmnt /dev/nvme0n1p1
sudo fuser -v /dev/nvme0n1p1

# 3. Repair the filesystem structure (resolves corrupted htree directory blocks)
sudo fsck.ext4 -f -y /dev/nvme0n1p1

# 4. Remount storage cleanly and restart K3s
sudo mount -a
findmnt /var/lib/rancher/k3s/storage
sudo systemctl start k3s
```

---

## 5. Phase 4: Post-Boot Verification & Application Recovery

### A. SQLite & Database Integrity Audit
Inspect databases on the NVMe volume to ensure uncommitted WAL frames recovered cleanly:

```bash
# Locate Pi-hole volume
PIHOLE_DIR=\$(ls -d /var/lib/rancher/k3s/storage/pvc-*_pihole_pihole-etc-pvc)

# Check integrity of FTL query database and gravity list
sudo sqlite3 "\$PIHOLE_DIR/pihole-FTL.db" "PRAGMA quick_check;"
sudo sqlite3 "\$PIHOLE_DIR/gravity.db" "PRAGMA quick_check;"

# If pihole-FTL.db returns errors or locks FTL on start, move it aside:
# sudo mv "$PIHOLE_DIR/pihole-FTL.db" "$PIHOLE_DIR/pihole-FTL.db.bak"
# kubectl rollout restart deployment/pihole -n pihole
```

### B. Unlock Stale Restic Backup Locks
If the crash occurred during a scheduled backup, Restic left an exclusive lock in Cloudflare R2:

```bash
# Run restic unlock inside a temporary utility container or via the backup pod:
kubectl create job --from=cronjob/k3s-pv-backup restic-unlock -n backups
# Exec into the pod or override the command to run: restic unlock
```

### C. Network & Masquerade Recovery
```bash
# 1. Verify Cilium masquerade didn't deadlock on OLD_CILIUM_POST_nat
sudo iptables -t nat -S OLD_CILIUM_POST_nat 2>/dev/null
# If populated and pod egress fails: sudo iptables -t nat -F OLD_CILIUM_POST_nat

# 2. Test LAN DNS resolution through Pi-hole
nslookup cloudflare.com 172.69.115.201

# 3. Confirm all pods recovered cleanly
kubectl get pods -A | grep -vE "Running|Completed"
```
