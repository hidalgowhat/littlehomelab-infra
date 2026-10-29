# Pi 5 NVMe Hardware Audit & Recovery Runbook

**Target Node:** `pi5-8gb-node` (`172.69.115.201`)  
**Mountpoint:** `/var/lib/rancher/k3s/storage` (`/dev/nvme0n1p1`)  
**Execution Context:** Direct SSH or physical console as `admin` / `root`.

---

## 1. Overview & Failure Modes

When an NVMe drive on the Raspberry Pi 5 encounters an `error -5 EIO` or `NVME_IOCTL_ADMIN_CMD: Input/output error`, the Linux kernel trips the `ext4` filesystem into an emergency `shutdown` or read-only (`ro`) state to prevent data corruption. On the Pi 5, this is rarely flash wear; it is typically caused by:
1. **APST Deep Sleep Lockups:** The controller enters low-power sleep states (`PS3`/`PS4`) and fails to wake within the Broadcom PCIe bridge's timeout window.
2. **PCIe Bus Signal Drops:** Thermal expansion or unshielded FFC ribbon interference causing AER link errors.
3. **Transient Power Droops:** Voltage sag on the 3.3V rail during concurrent heavy writes (e.g., Restic backups + Postgres WAL flushes).

---

## 2. Phase 1: Hardware & Power Health Audit (Non-Destructive)

Run these checks while the node and cluster are running:

```bash
# 1. Check for past under-voltage or thermal throttling events
# Expected: throttled=0x0. If 0x50000 or 0x50005 appears, power drooped under load.
vcgencmd get_throttled

# 2. Inspect NVMe controller health, error logs, and media degradation
sudo nvme smart-log /dev/nvme0

# 3. Check for PCIe bus link drops or Advanced Error Reporting (AER) anomalies
sudo lspci -vvv -d ::0108 | grep -iE "LnkSta:|UESta:|CESta:"

# 4. Check active Autonomous Power State Transition (APST) settings
sudo nvme get-feature /dev/nvme0 -f 0x0c -H
```

### Preventative Hardening
1. **Disable APST Deep Sleep:** In `/boot/firmware/cmdline.txt`, append the following parameter to the existing single line:
   ```text
   nvme_core.default_ps_max_latency_us=0
   ```
2. **Lock PCIe Gen 2:** Ensure `/boot/firmware/config.txt` contains:
   ```ini
   dtparam=pciex1
   ```
   *(Do NOT enable PCIe Gen 3 `dtparam=pciex1_gen=3` over flexible ribbon cables).*

---

## 3. Phase 2: Live Incident Triage

If stateful pods (`postgres`, `pihole`, `uptime-kuma`, `grafana`) simultaneously enter `CrashLoopBackOff`:

```bash
# 1. Check if the ext4 filesystem tripped into emergency 'shutdown' or read-only
findmnt /var/lib/rancher/k3s/storage

# 2. Inspect kernel dmesg for I/O timeouts and dropped PCIe links
dmesg -T | grep -iE "ext4|nvme|pcie|i/o|error" | tail -n 25

# 3. Probe the NVMe Admin Queue
sudo nvme id-ctrl /dev/nvme0 | grep -E "mn|sn|fr"
```

* **If `nvme id-ctrl` succeeds:** Controller is responsive; the issue is filesystem corruption. Proceed to Phase 3.
* **If `nvme id-ctrl` returns `Input/output error`:** The NVMe controller is locked on the PCIe bus. Perform a cold hardware power cycle:
  ```bash
  sudo systemctl stop k3s
  sudo poweroff
  ```
  *Wait for the red LED, unplug USB-C power for 20 seconds, and reconnect.*

---

## 4. Phase 3: Offline Filesystem Repair (`fsck.ext4`)

Never run `fsck` while container namespaces hold active mount references.

```bash
# 1. Stop K3s and tear down all isolated containerd mount namespaces
sudo systemctl stop k3s
sudo /usr/local/bin/k3s-killall.sh

# 2. Verify the block device is completely released
findmnt /dev/nvme0n1p1
sudo fuser -v /dev/nvme0n1p1

# 3. Repair the filesystem structure (resolves corrupted htree directory indexes)
sudo fsck.ext4 -f -y /dev/nvme0n1p1

# 4. Remount storage cleanly and restart K3s
sudo mount -a
findmnt /var/lib/rancher/k3s/storage
sudo systemctl start k3s
```

---

## 5. Phase 4: Post-Boot Cascade Verification

```bash
# 1. Verify Cilium's masquerade table didn't deadlock on stale chains
sudo iptables -t nat -S OLD_CILIUM_POST_nat 2>/dev/null
# If deadlocked, flush: sudo iptables -t nat -F OLD_CILIUM_POST_nat

# 2. Test DNS resolution through Pi-hole
nslookup cloudflare.com 172.69.115.201

# 3. Confirm all pods recovered cleanly
kubectl get pods -A | grep -vE "Running|Completed"
```
