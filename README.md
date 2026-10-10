# Little Homelab Infrastructure (`littlehomelab-infra`)

A production-grade, GitOps-managed Kubernetes cluster running on a 4-node Raspberry Pi ARM64 (`aarch64`) cluster. This repository serves as the single source of truth for all infrastructure, applications, network policies, and configuration using Argo CD, Cilium CNI, Traefik, cert-manager, Authelia SSO, and SOPS with Age encryption.

---

## Architecture & Hardware Overview

The cluster runs lightweight Kubernetes ([k3s](https://k3s.io)) across four physical Raspberry Pi boards connected to a local subnet (`172.69.115.0/24`).

```
                              Internet
                                 │
                         [ Cloudflare DNS ]
                                 │
                         [ Cloudflare Tunnel ] (cloudflared HA)
                                 │
      LAN Devices ───────────────┼────────────────────────┐
           │                     │                        │
     (DNS: Pi-hole)              ▼                        ▼
           │           [ Traefik Ingress ] ──── [ Authelia SSO ]
           ▼            (172.69.115.211)          (auth.littlehomelab.com)
  [ Pi-hole 172.69.115.201 ]     │                        │
                                 ▼ (ForwardAuth / OIDC)   │
                     ┌────────────────────────────────────┼───────────────────┐
                     ▼                                    ▼                   ▼
            [ Homepage Dashboard ]                 [ Argo CD Web ]       [ Workloads ]
           (homepage.littlehomelab.com)          (argocd.littlehomelab.com) (Wiki, PDF, etc.)
```

### Cluster Nodes

| Node Name | IP Address | Hardware | Role | Memory | Primary Workloads |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`pi5-8gb-node`** | `172.69.115.201` | Raspberry Pi 5 | Control Plane | 8 GB | K3s server, NVMe storage, Postgres, Pi-hole, Uptime Kuma, Authelia |
| **`pi4-8gb-node`** | `172.69.115.202` | Raspberry Pi 4 Model B | Worker | 8 GB | Homepage, Wiki.js, BentoPDF, Cloudflared replica |
| **`pi4-4gb-node`** | `172.69.115.203` | Raspberry Pi 4 Model B | Worker | 4 GB | Cilium operator, monitoring agents |
| **`pi4-2gb-node`** | `172.69.115.204` | Raspberry Pi 4 Model B | Worker | 2 GB | Cloudflared replica, lightweight network agents |

> **Storage Architecture Note**: The control plane (`pi5-8gb-node`) is equipped with a dedicated high-speed NVMe SSD. High-IOPS stateful applications (Postgres, Pi-hole, Uptime Kuma, Authelia) are explicitly bound to this node via `local-path` Persistent Volumes.

---

## Core Technology Stack

* **Orchestration**: [k3s](https://k3s.io) (v1.36.2) on Debian GNU/Linux 13 (Trixie) ARM64.
* **CNI & eBPF Networking**: [Cilium](https://cilium.io) (v1.16.0) with `kubeProxyReplacement: true`, L2 Announcements, Hubble Relay & UI, and a dedicated virtual LoadBalancer IP pool (`172.69.115.210-250`).
* **Ingress Controller**: [Traefik](https://traefik.io) deployed as a LoadBalancer service on `172.69.115.211`.
* **External Ingress**: [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) (`cloudflared`) running redundant replicas distributed across separate physical worker nodes via `podAntiAffinity`.
* **Certificate Management**: [cert-manager](https://cert-manager.io) issuing Let's Encrypt wildcard and service certificates via Cloudflare DNS-01 challenges.
* **Continuous Delivery (GitOps)**: [Argo CD](https://argo-cd.readthedocs.io) utilizing the **App-of-Apps** pattern with automated sync, self-healing, and resource pruning.
* **Secrets Encryption**: [SOPS](https://github.com/getsops/sops) combined with [Age](https://github.com/FiloSottile/age) public-key cryptography. Decrypted on-the-fly inside the Argo CD repo-server via a custom Config Management Plugin (`cmp-sops-plugin`).
* **Single Sign-On (SSO)**: [Authelia](https://www.authelia.com) providing OpenID Connect (OIDC) identity federation and Traefik ForwardAuth proxy gating.
* **Internal DNS**: [CoreDNS](https://coredns.io) with custom split-DNS extensions paired with [Pi-hole](https://pi-hole.net) for LAN ad-blocking and wildcard internal resolution.

---

## Deployed Applications & Services

All services are accessible under the `*.littlehomelab.com` domain.

| Service | Namespace | Ingress Hostname | Port | Auth Model | Description |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Argo CD** | `argocd` | `argocd.littlehomelab.com` | `443` | **Authelia OIDC** | GitOps management and cluster deployment dashboard |
| **Authelia** | `default` | `auth.littlehomelab.com` | `9091` | **Public / Root** | Central authentication provider (OIDC & ForwardAuth) |
| **Homepage** | `homepage` | `homepage.littlehomelab.com` | `3000` | **ForwardAuth** | Homelab operations dashboard and service portal |
| **Wiki.js** | `wiki` | `wiki.littlehomelab.com` | `3000` | **Internal Auth** | Team documentation platform backed by PostgreSQL |
| **BentoPDF** | `bentopdf` | `pdf.littlehomelab.com` | `8080` | **Public** | Lightweight privacy-focused PDF editing suite |
| **Grafana** | `monitoring` | `grafana.littlehomelab.com` | `80` | **Internal Auth** | Metrics dashboards (Prometheus, system metrics) |
| **Hubble UI** | `kube-system` | `hubble.littlehomelab.com` | `80` | **Public** | Cilium eBPF network observability and service map |
| **Uptime Kuma** | `monitoring` | `status.littlehomelab.com` | `3001` | **Internal Auth** | Service health checks and uptime status monitoring |
| **Pi-hole** | `pihole` | `pihole.littlehomelab.com` | `80, 53` | **Internal Auth** | Network-wide ad blocker and local DNS resolver |
| **Utility Ping** | `default` | `ping.littlehomelab.com` | `80` | **Public** | Cluster health and network latency probe |
| **K3s Backups** | `default` | *N/A (CronJob)* | *N/A* | *Internal* | Daily SQLite snapshot uploaded to Cloudflare R2 |

---

## Repository Structure

```text
littlehomelab-infra/
├── argocd-apps/                     # Argo CD Application manifests (App-of-Apps source)
│   ├── argocd-config-app.yaml       # Argo CD RBAC, SSO, and repo-server customizations
│   ├── authelia-app.yaml            # Authelia SSO application
│   ├── bentopdf-app.yaml            # BentoPDF application
│   ├── cert-manager-app.yaml        # cert-manager Helm chart
│   ├── cert-manager-configs-app.yaml# ClusterIssuer (Let's Encrypt DNS-01)
│   ├── cilium-helm-app.yaml         # Cilium Helm chart and eBPF tuning
│   ├── cilium-infra-app.yaml        # Cilium L2 IP pools and announcement policies
│   ├── cloudflared-app.yaml         # Cloudflare Tunnel deployment
│   ├── coredns-app.yaml             # CoreDNS split-DNS custom configurations
│   ├── homepage.yaml                # Homepage dashboard application
│   ├── monitoring.yaml              # kube-prometheus-stack Helm release
│   ├── pihole-app.yaml              # Pi-hole DNS and ad-blocking deployment
│   ├── ping-app.yaml                # Utility Ping probe
│   ├── reflector-app.yaml           # Reflector secret replicator Helm release
│   ├── uptime-kuma.yaml             # Uptime Kuma monitoring application
│   └── wikijs-app.yaml              # Wiki.js and Postgres deployment
├── apps/                            # Kubernetes manifests for individual applications
│   ├── argocd/                      # Argo CD configuration, patches, CMP plugin definition
│   ├── authelia/                    # Authelia deployment, PVC, ingress, secrets
│   ├── backups/                     # Cloudflare R2 backup CronJob and scripts
│   ├── bentopdf/                    # BentoPDF deployment, service, ingress
│   ├── cert-manager-configs/        # ClusterIssuer definitions
│   ├── homepage/                    # Homepage configmaps, service, ingress, secrets
│   ├── monitoring/                  # Helm values for Prometheus/Grafana, ingresses
│   ├── pihole/                      # Pi-hole deployment, service, PVC, custom dnsmasq
│   ├── ping/                        # Utility ping probe manifests
│   └── wiki.js/                     # Wiki.js and Postgres deployments, PVC, ingress
├── infrastructure/                  # Core cluster infrastructure components
│   ├── cilium-configs/              # Cilium LoadBalancer IP pools and L2 policies
│   ├── cloudflared/                 # Cloudflare Tunnel manifests (HA deployment)
│   └── coredns/                     # CoreDNS custom ConfigMap for internal split-DNS
├── bootstrap/                       # Initial cluster bootstrap manifests
│   └── root-app.yaml                # Argo CD Root Application (App-of-Apps root)
├── automation/                      # Cluster automation and maintenance scripts
│   ├── cluster-checkup-script/      # Ansible playbook for hardware and k3s health checks
│   └── cluster-update-script/       # Ansible playbook for serial apt upgrades and reboots
├── templates/                       # Reusable starter templates for new services
│   ├── stateless/                   # Namespace, Secret, Deployment, Service, Ingress
│   ├── stateful-app/                # Deployment with local-path PVC and Service
│   └── cronjob/                     # Scheduled backup job template
├── .sops.yaml                       # SOPS encryption creation rules (Age public key)
└── opencode.json                    # OpenCode CLI permissions and configuration
```

---

## Operator Workflows

### 1. GitOps Deployment Workflow (Argo CD)

Deployments are fully automated. Pushing commits directly to the `main` branch deploys changes to the cluster.

To add a new application:
1. Create a directory under `apps/<app-name>/` using templates from `templates/stateless` or `templates/stateful-app`.
2. Add an Argo CD Application manifest in `argocd-apps/<app-name>.yaml` pointing `source.path` to `apps/<app-name>`.
3. Test locally using dry-run validation:
   ```bash
   kubectl apply --dry-run=client -f apps/<app-name>/
   # If using kustomization:
   kubectl kustomize apps/<app-name>/
   ```
4. Commit and push to `main`. The `root-app` will discover the new application and deploy it automatically.
5. Verify application sync and health status across the cluster:
   ```bash
   kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
   ```
   
---

### 2. Secrets Management (SOPS + Age)

Secrets are encrypted in-place using [SOPS](https://github.com/getsops/sops) and [Age](https://github.com/FiloSottile/age).

* **Private Key Location**: Environment variable `SOPS_AGE_KEY_FILE=/home/admin/.config/sops/age/keys.txt`.
* **CRITICAL Naming Rule**: Secret files **must** end with `.sops.yaml` (e.g. `secret.sops.yaml`, `configmap.sops.yaml`).
  * The `.sops.yaml` configuration targets `.*\.sops\.yaml$` with `encrypted_regex: '^(data|stringData)$'`.
  * This ensures Kubernetes metadata (`apiVersion`, `kind`, `metadata.name`) remains in plaintext for Kustomize and Argo CD, while payload data is encrypted.

#### Common Secret Commands

```bash
# Decrypt and view a secret:
sops -d apps/homepage/secret.sops.yaml

# Edit an encrypted secret in your default editor:
sops apps/homepage/secret.sops.yaml

# Encrypt a newly created plaintext secret in-place:
sops -e -i apps/<app>/secret.sops.yaml
```

#### How Argo CD Decrypts Secrets
Argo CD uses a sidecar Config Management Plugin (`cmp-sops-plugin`) in `argocd-repo-server`:
- Auto-discovers any directory containing `.yaml` files with the `ENC[` token.
- If `kustomization.yaml` is present: decrypts matching `.sops.yaml` files in-place and runs `kustomize build .`.
- If no `kustomization.yaml`: decrypts root manifests via `sops -d` and renders them sequentially.

---

### 3. Ingress, TLS, and Split-DNS Routing

Traffic to `*.littlehomelab.com` is routed using a hybrid split-DNS architecture:

1. **External Traffic**: Cloudflare Tunnel (`cloudflared`) connects outbound to Cloudflare edge servers. Traffic reaches `cloudflared` pods inside the cluster and routes directly to Traefik on port `443`.
2. **Internal LAN Traffic**: LAN devices query Pi-hole (`172.69.115.201:53`), which maps `*.littlehomelab.com` directly to Traefik's LoadBalancer IP (`172.69.115.211`).
3. **Internal Pod-to-Pod Traffic**: Pods query CoreDNS (`10.43.0.10:53`), which utilizes `infrastructure/coredns/coredns-custom.yaml`:
   - Fast-paths `auth.littlehomelab.com` and `argocd.littlehomelab.com` to `172.69.115.211`.
   - Forwards all other `littlehomelab.com` queries dynamically to Pi-hole (`172.69.115.201:53`).

#### TLS Certificates (Cert-Manager)
Certificates are issued automatically by cert-manager via Let's Encrypt DNS-01 challenges.
* Add annotations directly to your `Ingress`:
  ```yaml
  metadata:
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-cloudflare
  spec:
    tls:
      - hosts:
          - myapp.littlehomelab.com
        secretName: myapp-tls-cert
  ```
* **Do not create standalone `Certificate` manifests alongside Ingress TLS**. Doing so causes duplicate objects that conflict over the same secret (`IncorrectCertificate` error).

---

### 4. Protecting an Application with Authelia SSO

To gate any ingress behind Authelia ForwardAuth, add the Traefik middleware annotation:

```yaml
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: default-authelia-forwardauth@kubernetescrd
```

Unauthenticated requests will automatically redirect to `https://auth.littlehomelab.com/` for authentication and redirect back upon successful login.

---

### 5. Cluster Automation & Maintenance

Maintenance scripts are located in the `automation/` directory.

#### Health & Hardware Diagnostics
Runs an Ansible playbook to inspect Raspberry Pi core temperatures, throttling/undervoltage flags, disk utilization, and k3s pod resource metrics:
```bash
./automation/cluster-checkup-script/cluster-checkup.sh
```

#### System Updates & Rolling Reboots
Performs `apt update && apt dist-upgrade` across all nodes. If a kernel update triggers `/var/run/reboot-required`, it safely reboots the control plane first, followed by each worker node sequentially (`serial: 1`) to preserve service availability:
```bash
./automation/cluster-update-script/cluster-update.sh
```

---

## Developer & Operator Prerequisites

Ensure the following tools are installed on your workstation or management node:

* **[kubectl](https://kubernetes.io/docs/tasks/tools/)**: Kubernetes CLI (`v1.30+`)
* **[kustomize](https://kustomize.io/)**: Declarative Kubernetes configuration management
* **[sops](https://github.com/getsops/sops)**: Secret operations (`v3.9.0+`)
* **[age](https://github.com/FiloSottile/age)**: Encryption tool (`age-keygen`)
* **[helm](https://helm.sh/)**: Kubernetes package manager (`v3.14+`)
* **[ansible](https://docs.ansible.com/)**: Cluster maintenance automation (`ansible-playbook`)
* **[jq](https://jqlang.github.io/jq/)**: JSON parsing for automation scripts
