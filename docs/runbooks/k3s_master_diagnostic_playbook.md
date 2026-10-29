# Master K3s Diagnostic & Triage Playbook

**Scope:** 4-node Raspberry Pi K3s cluster (`172.69.115.201` – `172.69.115.204`)  
**Execution Context:** Run directly on `admin@pi5-8gb-node` via SSH or console.

---

## Troubleshooting Funnel

```
[ Rapid Triage (60s) ]
         │
         ├──► Layer 1: Node & Host OS (Memory, Disk, /run tmpfs, Dmesg)
         ├──► Layer 2: Persistent Storage (/dev/nvme0n1p1, Mount flags)
         ├──► Layer 3: Cilium CNI & eBPF (Agent health, BPF maps, iptables NAT)
         ├──► Layer 4: Split-DNS Routing (Pi-hole port 53, CoreDNS, Upstreams)
         ├──► Layer 5: Ingress & Auth (Traefik .211, Cloudflared, Authelia)
         └──► Layer 6: Pod & Workload Deep Dive (Exit codes, Events, PVC bindings)
```

---

## 1. 60-Second Rapid Health Audit

Run this script block on `pi5-8gb-node` to locate the failing tier immediately:

```bash
echo "=== 1. CLUSTER NODES ==="
kubectl get nodes -o wide

echo "=== 2. FAILING PODS ==="
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

echo "=== 3. /RUN TMPFS USAGE ACROSS NODES ==="
for ip in 201 202 203 204; do
  echo -n "172.69.115.\$ip /run: "
  ssh -o ConnectTimeout=2 "admin@172.69.115.\$ip" "df -h /run | awk 'NR==2 {print \$5}'" 2>/dev/null || echo "UNREACHABLE"
done

echo "=== 4. STORAGE MOUNT STATE ==="
findmnt /var/lib/rancher/k3s/storage -o TARGET,SOURCE,FSTYPE,OPTIONS

echo "=== 5. DNS STATUS ==="
nslookup -timeout=2 cloudflare.com 172.69.115.201 >/dev/null && echo "Pi-hole DNS: OK" || echo "Pi-hole DNS: FAILED"
```

---

## 2. Layer 1: Node & Host OS Triage

If nodes report `NotReady`, SSH times out, or pods fail to spawn:

1. **System Resource Saturation:**
   ```bash
   free -h
   df -h / /run
   uptime
   ```
2. **RAM-Backed `/run` Exhaustion:**
   If `/run` is at 100%, `runc` cannot create container sockets:
   ```bash
   sudo du -sh /run/* | sort -hr | head -n 5
   # If /run/cilium/state consumed space, check /etc/fstab for the bind mount:
   # /var/lib/cilium-state /run/cilium/state none bind,defaults 0 0
   ```
3. **Core Dump Suppression:**
   Ensure `/etc/sysctl.d/50-coredump.conf` is active:
   ```bash
   cat /proc/sys/kernel/core_pattern
   # Expected: |/bin/false
   ```

---

## 3. Layer 2: Persistent Storage Layer

If stateful services (`postgres`, `pihole`, `uptime-kuma`, `grafana`) crash:

1. **Check Mount Options:**
   ```bash
   findmnt /var/lib/rancher/k3s/storage
   ```
   *Watch for `ro` (read-only) or missing mount entries.*
2. **Check dmesg for Block I/O Errors:**
   ```bash
   dmesg -T | grep -iE "nvme|ext4|error|i/o" | tail -n 20
   ```
3. **Inspect PVC Status in Kubernetes:**
   ```bash
   kubectl get pvc -A
   kubectl get pv
   ```

---

## 4. Layer 3: Cilium CNI & eBPF Networking

If pods cannot communicate across nodes or outbound LAN egress hangs:

1. **Check Cilium Agent Pod Status:**
   ```bash
   kubectl get pods -n kube-system -l k8s-app=cilium -o wide
   ```
2. **Inspect Cilium Node-Level Health:**
   ```bash
   kubectl exec -n kube-system ds/cilium -c cilium-agent -- cilium-dbg status --brief
   ```
3. **Check for Masquerade / iptables Reconciliation Deadlocks:**
   If pod egress stops being NAT'd to the physical LAN:
   ```bash
   sudo iptables -t nat -S OLD_CILIUM_POST_nat
   # Flush if stale: sudo iptables -t nat -F OLD_CILIUM_POST_nat
   ```

---

## 5. Layer 4: Split-DNS Routing

If internal service discovery or LAN client resolution fails:

1. **Verify HostPort 53 Binding on Pi 5:**
   ```bash
   sudo ss -tulpn | grep :53
   # Ensure Pi-hole container is listening on 0.0.0.0:53
   ```
2. **Test Resolution Paths:**
   ```bash
   # LAN to Pi-hole:
   nslookup homepage.littlehomelab.com 172.69.115.201

   # In-cluster via CoreDNS:
   kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -- nslookup auth.littlehomelab.com 10.43.0.10
   ```
3. **Check Pi-hole Concurrent Query Saturation:**
   ```bash
   kubectl logs -n pihole deployment/pihole -c pihole --tail=50 | grep -i "concurrent"
   # If "Maximum number of concurrent DNS queries reached (max: 150)" appears,
   # Pi-hole has lost upstream network egress.
   ```

---

## 6. Layer 5: Ingress & Authentication

If external or LAN web requests return `404`, `502`, or SSL certificate warnings:

1. **Check Traefik Service & Static IP:**
   ```bash
   kubectl get svc -n kube-system traefik
   # Verify EXTERNAL-IP is bound to 172.69.115.211
   ```
2. **Inspect Cloudflare Tunnel (`cloudflared`):**
   ```bash
   kubectl get pods -n default -l app=cloudflared -o wide
   kubectl logs -n default -l app=cloudflared --tail=30
   ```
3. **Verify Authelia Middleware & ForwardAuth:**
   ```bash
   kubectl get middleware -A
   kubectl logs -n default deployment/authelia --tail=30
   ```

---

## 7. Layer 6: Pod & Workload Deep Dive

When an individual pod is stuck in `CrashLoopBackOff`, `Pending`, or `Error`:

1. **Check Pod Exit Code & Termination Reason:**
   ```bash
   kubectl get pod <pod-name> -n <namespace> -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\tExitCode: "}{.lastState.terminated.exitCode}{"\tReason: "}{.lastState.terminated.reason}{"\n"}{end}'
   ```
   * *Exit Code 137:* Out Of Memory (`OOMKilled`).
   * *Exit Code 1/2:* Application startup failure or corrupted config/database.
   * *Exit Code 255:* Container runtime error (typically `/run` tmpfs full on the host).
2. **Inspect Container Logs:**
   ```bash
   # Previous crashed instance:
   kubectl logs -n <namespace> <pod-name> --previous --tail=50
   ```
3. **Inspect Kubernetes Lifecycle Events:**
   ```bash
   kubectl describe pod <pod-name> -n <namespace> | grep -A 10 Events:
   ```
