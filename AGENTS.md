# Repository Guide (`littlehomelab-infra`)

## Architecture & Environment
- **Platform**: 4-node Raspberry Pi ARM64 (`aarch64`) cluster running `k3s` (v1.36.2):
  - Control plane: `pi5-8gb-node` (`172.69.115.201` / localhost)
  - Workers: `pi4-8gb-node` (`.202`), `pi4-4gb-node` (`.203`), `pi4-2gb-node` (`.204`)
- **Networking & Ingress**: Cilium CNI (`kubeProxyReplacement`, L2 announcements, IP pool `172.69.115.210-250`), Traefik LoadBalancer (`172.69.115.211`), and Cloudflare Tunnel (`cloudflare` namespace) for `*.littlehomelab.com`.
  - *ARM64 Gotcha*: Cilium standalone Envoy is disabled (`envoy.enabled: false`) to bypass ARM64 TCMalloc crashes; eBPF map dynamic size ratio is tuned to `0.001`.
  - *Multi-Replica HA*: Stateless workloads (e.g. `cloudflared`) must include `podAntiAffinity` on `kubernetes.io/hostname` to ensure replicas schedule across different physical nodes.
- **Internal Split-DNS**: Pods resolve `*.littlehomelab.com` via `infrastructure/coredns/coredns-custom.yaml` (`coredns-custom` ConfigMap in `kube-system`). Fast-path routes `auth` and `argocd` to `172.69.115.211`, with dynamic fallback to Pi-hole (`172.69.115.201:53`). Without this, pod-to-pod OIDC/API calls fail with `no such host`.
- **TLS Certificates**: Managed by cert-manager `ClusterIssuer/letsencrypt-cloudflare` via Ingress annotations (`cert-manager.io/cluster-issuer: letsencrypt-cloudflare`). **DO NOT create standalone `Certificate` CRs** alongside Ingress TLS; having both creates duplicate objects that conflict over the same secret (`IncorrectCertificate` error).
- **Authentication & SSO (Authelia)**: Authelia (`apps/authelia`) runs in `default` with OIDC provider at `https://auth.littlehomelab.com`. Protect any Ingress behind SSO by adding:
  `traefik.ingress.kubernetes.io/router.middlewares: default-authelia-forwardauth@kubernetescrd`.
- **Storage**: `local-path` StorageClass (`ReadWriteOnce`). Pods bound to local volumes must remain on their scheduled node. `pi5-8gb-node` has an attached NVMe SSD; high-IOPS stateful applications (Postgres, Pi-hole, Uptime Kuma, Authelia) intentionally keep their PVCs on `pi5-8gb-node`.
- **Deployment Strategy Gotcha**: Single-replica stateful workloads with `hostPort` (e.g. Pi-hole on port 53) or node-bound local PVCs must use `strategy.type: Recreate` instead of default `RollingUpdate`; otherwise rollouts deadlock because the new pod cannot bind the host port or volume while the old pod is terminating.
- **Resource Sizing**: All deployments must declare `resources.requests` and `limits`. Otherwise, Kubernetes treats memory requirements as `0`, defaults to `BestEffort` QoS, and over-allocates workloads to the control plane.

## GitOps Workflow (Argo CD)
- **App-of-Apps**: `bootstrap/root-app.yaml` watches `argocd-apps/` on branch `main` (`HEAD`).
- **Adding an Application**:
  1. Add an Argo CD Application manifest in `argocd-apps/<app-name>.yaml` pointing `source.path` to `apps/<app-name>` (or `infrastructure/<component>`).
  2. Add Kubernetes manifests in `apps/<app-name>/`.
  3. Reference templates in `templates/stateless`, `templates/stateful-app`, or `templates/cronjob`.
- **Sync Behavior**: Auto-sync with prune and self-heal enabled. Pushing commits directly to `main` deploys changes.

## Secrets Management (SOPS + Age)
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

## Verification & Routine Commands
- **Dry-run & Manifest Validation**:
  - Kustomize build: `kubectl kustomize apps/<app>`
  - Manifest dry-run: `kubectl apply --dry-run=client -f <file>`
- **Cluster & Workload Inspection**:
  - Node health: `kubectl get nodes -o wide`
  - Argo CD apps: `kubectl get applications -n argocd`
  - Pod status: `kubectl get pods -n <namespace>`
  - Workload logs: `kubectl logs -n <namespace> deployment/<app>`
- **Cluster Automation Scripts**:
  - Hardware health & resources (temps, throttling, disk, k3s): `./automation/cluster-checkup-script/cluster-checkup.sh`
  - System packages update & serial reboots: `./automation/cluster-update-script/cluster-update.sh`

## Git Conventions
- Commits are pushed directly to `main`.
- Style: concise, imperative lowercase messages (e.g. `change status style to dot`, `add bentopdf to homepage`).
