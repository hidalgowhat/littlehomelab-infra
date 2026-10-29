# Repository Guide (`littlehomelab-infra`)

## 1. Architecture & Node Topology
- **Hardware Layout (4-Node Raspberry Pi ARM64 Cluster)**:
  - **Control Plane (`pi5-8gb-node` / `172.69.115.201`)**:
    - Runs K3s server (v1.36.2).
    - Storage layout: Boots `/boot/firmware` from `mmcblk0p1` (microSD); dedicated 120GB NVMe SSD (`nvme0n1p1`) mounted at `/var/lib/rancher/k3s/storage`.
    - High-IOPS stateful workloads (PostgreSQL, Pi-hole, Uptime Kuma, Authelia, Homelable backend) are intentionally pinned to `pi5-8gb-node` via `nodeSelector: kubernetes.io/hostname: pi5-8gb-node` to leverage NVMe performance and data locality.
    - Workloads scheduled on `pi5-8gb-node` must include control-plane tolerations (`node-role.kubernetes.io/control-plane` and `node-role.kubernetes.io/master`).
  - **Worker Nodes (`pi4-8gb-node` `.202`, `pi4-4gb-node` `.203`, `pi4-2gb-node` `.204`)**:
    - Run K3s agent (v1.36.2), booting OS and root filesystems from USB 3 flash drives.
    - `pi4-2gb-node` is **fully untainted and active**, actively scheduling lightweight utilities, stateless services, and HA multi-replica pods.
- **Storage Subsystem**:
  - `local-path` StorageClass (`ReadWriteOnce`).
  - Workloads bound to local-path PVCs must remain pinned to their node. Never rely on dynamic rescheduling for single-node local storage volumes.
- **Host-Level Hardening & Node Prerequisites**:
  - **ARM64 Core Dump Suppression**: All four Raspberry Pi nodes require `/etc/sysctl.d/50-coredump.conf` set to `kernel.core_pattern = |/bin/false`. This prevents recurring ARM64 TCMalloc crashes during periodic `cilium-envoy --version` health invocations from dumping multi-gigabyte cores into memory.
  - **Cilium State Mount (`/run/cilium/state`)**: Worker nodes (especially `pi4-8gb-node`) must mount `/var/lib/cilium-state` to `/run/cilium/state` in `/etc/fstab` via `bind,defaults 0 0` to prevent temporary endpoint compilation files from consuming 100% of the `/run` tmpfs partition.
  - **Pi 5 PCIe Stability**: `/boot/firmware/config.txt` on `pi5-8gb-node` must stay locked to `dtparam=pciex1` (PCIe Gen 2, 5 Gbps) to avoid signal-degradation I/O crashes (error -5 EIO) and ext4 emergency shutdowns over FFC ribbon cables.

---

## 2. Network & Ingress Architecture
- **Cilium eBPF CNI (v1.16.0)**:
  - Deployed in pure eBPF replacement mode (`kubeProxyReplacement: true`).
  - Dynamic eBPF map sizing ratio tuned to `bpf.mapDynamicSizeRatio: 0.001` with `ctGlobalTcpMax: 262144` and `ctGlobalAnyMax: 131072` to preserve memory on ARM64 nodes.
  - **ARM64 Gotcha**: Standalone Envoy is disabled (`envoy.enabled: false`) to avoid ARM64 TCMalloc segmentation crashes.
  - **LB-IPAM & L2 Announcements**:
    - Managed via `homelab-ip-pool` allocating `172.69.115.210` - `172.69.115.250` (`infrastructure/cilium-configs/ippool.yaml`).
    - L2 announcements enabled across Ethernet and Wi-Fi interfaces (`eth[0-9]+`, `end[0-9]+`, `wlan[0-9]+`).
- **Traefik LoadBalancer Ingress Controller (`172.69.115.211`)**:
  - Configured via K3s `HelmChartConfig/traefik` (`infrastructure/traefik-config/traefik-config.yaml` and `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml`).
  - **Real Client IP Preservation**: Both `web` (8000) and `websecure` (8443) entrypoints declare trusted proxy ranges:
    `--entryPoints.web.forwardedHeaders.trustedIPs=10.42.0.0/16,172.69.115.0/24`
    `--entryPoints.websecure.forwardedHeaders.trustedIPs=10.42.0.0/16,172.69.115.0/24`
    This ensures Traefik forwards real client IPs (`CF-Connecting-IP`, `X-Forwarded-For`) to Authelia and application backends, preventing brute-force regulation from inadvertently banning internal `cloudflared` pods.
  - **Global HTTP-to-HTTPS Redirection**:
    - Traefik entrypoint `web` enforces `--entryPoints.web.http.redirections.entryPoint.to=websecure`, `--entryPoints.web.http.redirections.entryPoint.scheme=https`, and `permanent=true` (HTTP 308).
    - Ingress manifests must specify `traefik.ingress.kubernetes.io/router.entrypoints: websecure` and `traefik.ingress.kubernetes.io/router.tls: "true"`.
- **Cloudflare Tunnel (`cloudflared`)**:
  - Deployed in namespace `cloudflare` with 2 replicas for high availability on external domain `*.littlehomelab.com`.
  - **HA Anti-Affinity Rule**: Workload enforces `podAntiAffinity` on `kubernetes.io/hostname` to guarantee replicas schedule across separate physical nodes (`pi4-8gb-node`, `pi4-4gb-node`, `pi4-2gb-node`).
- **Internal Split-DNS Routing**:
  - Pods resolve `*.littlehomelab.com` through CoreDNS custom config (`infrastructure/coredns/coredns-custom.yaml` in `kube-system`).
  - Fast-paths `auth.littlehomelab.com` and `argocd.littlehomelab.com` directly to Traefik (`172.69.115.211`), with dynamic fallthrough to Pi-hole (`172.69.115.201:53`).
  - Without this split-DNS fast-path, internal pod-to-pod OIDC/API calls fail with `no such host` or hairpin timeout deadlocks.

---

## 3. Security & Container Hardening
- **Service Account Token Auto-Mounting**:
  - `automountServiceAccountToken: false` is enforced by default across all deployments and stateful workloads to eliminate ambient credential exposure.
  - **Documented Exception**: `apps/homepage` explicitly mounts its service account token (`serviceAccountName: homepage`) to query the Kubernetes API via its dedicated ClusterRole for cluster metrics (node status, pod counts) on the operations dashboard.
- **Mandatory Resource Sizing**:
  - Every container deployment must declare explicit `resources.requests` and `resources.limits` for both CPU and memory.
  - Omission causes Kubernetes to treat memory demands as `0`, defaults pod QoS to `BestEffort`, and over-allocates workloads to `pi5-8gb-node`.
  - Memory-intensive workloads (e.g. Authelia with Argon2id hashing, Homelable with parallel `nmap` subnet sweeps) require limits sized appropriately (Authelia `256Mi`, Homelable backend `1Gi`) to avoid Linux kernel `OOMKilled` (Exit Code 137).
- **NetworkPolicy Micro-Segmentation**:
  - **Untrusted Ingress Workloads (BentoPDF - `apps/bentopdf/network-policy.yaml`)**:
    - Ingress restricted strictly to Traefik pods (`app.kubernetes.io/name: traefik` in `kube-system`) on port 8080.
    - Egress restricted solely to CoreDNS on port 53.
    - All lateral east-west cluster traffic and private LAN access are blocked.
  - **Stateful Database Workloads (PostgreSQL - `apps/wiki.js/postgres-network-policy.yaml`)**:
    - Ingress on port 5432 restricted strictly to Wiki.js application pods (`app.kubernetes.io/name: wiki.js`) in the same namespace.
    - All cross-namespace and outside network traffic is dropped.
- **Authentication, SSO & RBAC (Authelia)**:
  - Authelia operates in `default` namespace with SQLite database stored on persistent NVMe PVC (`authelia-data-pvc`).
  - **RBAC Policy Model**:
    - **Admins (`group:admins`)**: Unrestricted access to all services and cluster administration tools (Argo CD, Pi-hole admin, Hubble UI, Homelable network map, etc.).
    - **Friends (`group:friends`)**: Strictly scoped to shared testing applications (`homepage.littlehomelab.com`, `wiki.littlehomelab.com`, `pdf.littlehomelab.com`). All cluster administration, monitoring, and network scanning tools are blocked.
  - **ForwardAuth Attachment**: Secure any Ingress behind SSO by adding:
    `traefik.ingress.kubernetes.io/router.middlewares: default-authelia-forwardauth@kubernetescrd`

---

## 4. GitOps Workflow & Argo CD
- **App-of-Apps Pattern**:
  - `bootstrap/root-app.yaml` watches `argocd-apps/` on branch `main` (`HEAD`).
  - Manages 18 child applications spanning infrastructure (`cilium`, `traefik`, `cert-manager`, `coredns-custom`, `cloudflared`, `reflector`, `backups`, `monitoring`) and user-facing applications (`argocd-config`, `authelia`, `homepage`, `wikijs`, `pihole`, `bentopdf`, `homelable`, `uptime-kuma`, `utility-ping`).
- **Sync Behavior**:
  - Auto-sync with prune and self-heal enabled across applications. Pushing commits directly to `main` deploys changes to the cluster.
- **Adding an Application**:
  1. Create an Argo CD Application manifest in `argocd-apps/<app-name>.yaml` pointing `source.path` to `apps/<app-name>` (or `infrastructure/<component>`).
  2. Create Kubernetes manifests in `apps/<app-name>/`.
  3. Reference modern starter manifests in `templates/stateless`, `templates/stateful-app`, or `templates/cronjob`.

---

## 5. Secrets Management (SOPS + Age)
- **Key Location**: `SOPS_AGE_KEY_FILE=/home/admin/.config/sops/age/keys.txt` (configured in environment).
- **CRITICAL File Naming Rule**: Secret files **must** end with `.sops.yaml` (e.g. `secret.sops.yaml`, `configmap.sops.yaml`).
  - `.sops.yaml` regex targets `.*\.sops\.yaml$` with `encrypted_regex: '^(data|stringData)$'`.
  - If named without `.sops.yaml`, SOPS encrypts entire YAML documents, destroying Kubernetes metadata and breaking manifests.
- **Argo CD CMP Decryption (`cmp-sops-plugin`)**:
  - Auto-discovers directories containing YAML files with `ENC[`.
  - If `kustomization.yaml` exists: decrypts matching files in-place and runs `kustomize build .`.
  - If NO `kustomization.yaml`: renders files via `find . -maxdepth 1` and `sops -d`. (Manifests in subdirectories will be ignored unless managed by Kustomize or Helm).
- **Secret Operations**:
  - Decrypt / view: `sops -d apps/<app>/secret.sops.yaml`
  - Edit secret: `sops apps/<app>/secret.sops.yaml`
  - Encrypt new file in-place: `sops -e -i apps/<app>/secret.sops.yaml`

---

## 6. Manifest Gotchas & Operational Rules
- **No Standalone `Certificate` CRDs alongside Ingress TLS**:
  - TLS certificates are provisioned by cert-manager `ClusterIssuer/letsencrypt-cloudflare` via DNS-01 challenges.
  - Always use Ingress annotations (`cert-manager.io/cluster-issuer: letsencrypt-cloudflare`).
  - **Never create standalone `Certificate` CRs** for the same hostname/secret as an Ingress; having both creates duplicate cert-manager objects that conflict over the same secret (`IncorrectCertificate` error).
- **Deployment Strategy for Single-Replica Workloads**:
  - Workloads bound to local-path PVCs or utilizing `hostPort` (e.g. Pi-hole port 53, Postgres, Authelia, Homelable backend) must set:
    `strategy: { type: Recreate }`
  - The default `RollingUpdate` strategy causes deadlocks because the replacement pod cannot bind the host port or attach the local volume while the terminating pod still holds it.

---

## 7. Verification & Routine Commands
- **Dry-run & Manifest Validation**:
  - Kustomize build: `kubectl kustomize apps/<app>`
  - Manifest dry-run: `kubectl apply --dry-run=client -f <file>`
- **Cluster & Workload Inspection**:
  - Node health: `kubectl get nodes -o wide`
  - Argo CD apps: `kubectl get applications -n argocd`
  - Pod status: `kubectl get pods -n <namespace> -o wide`
  - Workload logs: `kubectl logs -n <namespace> deployment/<app>`
- **Cluster Automation Scripts**:
  - Hardware health & resources (temps, throttling, disk, k3s): `./automation/cluster-checkup-script/cluster-checkup.sh`
  - System packages update & serial reboots: `./automation/cluster-update-script/cluster-update.sh`
- **Troubleshooting & Incident Runbook**:
  - **Stale Cilium iptables NAT Deadlock**: If pod egress stops being masqueraded to the LAN (e.g., Pi-hole cannot reach public upstreams 1.1.1.1/9.9.9.9), check for deadlocked rules in `OLD_CILIUM_POST_nat` (such as strings matching ASCII `cili` / `99.105.108.105`). The fix is flushing the chain via `sudo iptables -t nat -F OLD_CILIUM_POST_nat`, allowing Cilium to immediately reinstall the active `10.42.0.0/24` masquerading rule.
  - **Pi-hole Concurrent Query Saturation**: If Pi-hole loses outbound egress connectivity, pending queries queue up until hitting dnsmasq's ceiling (`Maximum number of concurrent DNS queries reached (max: 150)`). Once saturated, Pi-hole drops all incoming LAN requests, mimicking a total port 53 service outage while the container remains `Running`.

---

## 8. Git Conventions
- Commits are pushed directly to `main`.
- Style: concise, imperative lowercase messages (e.g. `change status style to dot`, `fix homelable oom during network scan`).
