This is a initial commit while I am testing ths on my local stack, see gap section for what i been reviewing.

# 3-Tier Scaling Stack

A local Kubernetes lab for **elasticity and failure-recovery testing** of a 3-tier web application (nginx → FastAPI → PostgreSQL). It provisions a [kind](https://kind.sigs.k8s.io/) cluster via Terraform, preps the host with Ansible, deploys the app via raw Kubernetes manifests with HPAs/PDBs/NetworkPolicies, and drives it with k6 load tests and chaos scripts to observe autoscaling and recovery behavior. It's a sibling project to `ffeijo_3tier_hardened_stack`, which focuses on container/pod hardening — this one focuses on scaling under load and surviving pod/node failure.

## Architecture

```
Host machine
   │
   ▼
Terraform ── provisions a local kind cluster (1 control-plane + N workers)
   │           Calico CNI · metrics-server · ingress-nginx
   ▼
ingress-nginx (host ports 8080/8443 → cluster)
   │
   ▼
Tier 1 — nginx (frontend)      2–10 replicas via HPA · ClusterIP :80
   │  reverse-proxies /api/* → backend-service:8000
   ▼
Tier 2 — FastAPI/uvicorn (backend)   2–8 replicas via HPA · ClusterIP :8000
   │  psycopg2 ThreadedConnectionPool → PgBouncer (defined, not yet wired) → PostgreSQL
   ▼
Tier 3 — PostgreSQL 16 (Alpine, StatefulSet)   1 replica · ClusterIP :5432 + headless
```

Ansible prepares the Docker host (kernel sysctls, Docker Engine, pinned tool versions); Terraform then stands up the kind cluster itself (not cloud infrastructure — there is no AWS/GCP/Azure provider here). Scaling is Kubernetes-native (`HorizontalPodAutoscaler`), not cloud ASGs/load balancers.

## Components

### `terraform/` — provisions the local kind cluster
- **versions.tf** — Terraform ≥ 1.8; providers `tehcyx/kind` ~> 0.6.0, `hashicorp/local` ~> 2.5, `hashicorp/null` ~> 3.2.
- **variables.tf** — `cluster_name` (`three-tier`), `kubernetes_version` (`v1.34.0`), `worker_count` (default 3, validated ≥ 2 so PDBs/anti-affinity are meaningful), `control_plane_host_port_http`/`_https` (8080/8443), `kubeconfig_path` (`~/.kube/three-tier-config`, kept separate from the default kubeconfig).
- **main.tf** — `kind_cluster.main` with `wait_for_ready = true`, `disable_default_cni = true` (Calico is installed separately for NetworkPolicy enforcement), pod/service CIDRs `10.244.0.0/16`/`10.96.0.0/12`. One control-plane node (`ingress-ready=true` label, extra port mappings 80→8080/443→8443) plus a `dynamic "node"` block generating `worker_count` workers. Every node gets a host-path `extra_mounts` bind (`/tmp/three-tier-kind/...`) so PVC data survives node/container restarts. Three chained `null_resource` provisioners bootstrap Calico v3.28.0, `metrics-server` (via Helm, `--kubelet-insecure-tls` for kind's self-signed kubelet certs — required for HPA metrics), and `ingress-nginx` v1.11.0.
- **outputs.tf** — `cluster_name`, `kubeconfig_path`, `cluster_endpoint`, `http_port`, `https_port`.

### `ansible/` — host preparation (not app configuration)
- **inventory/hosts.yml** — single `infra-host` (`ansible_connection: local`); group vars pin `kind_version: 0.24.0`, `kubectl_version: 1.34.0`, `helm_version: 3.15.0`, `k6_version: 0.52.0`, plus Docker log-rotation settings.
- **playbooks/site.yml** — the "run before Terraform" playbook: applies `common`, `docker`, `kind` roles, then verifies `docker info` and prints installed tool versions.
- **playbooks/upgrade.yml** + **upgrade-worker.yml** — rolling Kubernetes version upgrade: backs up all namespaced resources in `apps` to `/tmp/pre-upgrade-backup-<epoch>.yaml`, checks PDB status, then per worker: cordon → drain (PDB-respecting) → replace the node's `kindest/node` image → rejoin via `kubeadm token create --print-join-command` → uncordon → smoke-test rollout status. *(Note: a `upgrade-control-plane.yml` task file is referenced but not present in the repo — control-plane upgrades aren't currently implemented.)*
- **roles/common** — disables swap, sets kind/k8s-critical sysctls (`bridge-nf-call-iptables`, `ip_forward`, inotify limits, `vm.max_map_count`, `kernel.pid_max`), loads `br_netfilter`, creates the PVC host-mount directories Terraform references.
- **roles/docker** — installs Docker CE + buildx/compose, templates `/etc/docker/daemon.json` (log rotation, `nofile` ulimits, buildkit, overlay2, systemd cgroup driver), adds the user to the `docker` group.
- **roles/kind** — installs pinned kind, kubectl, Helm, and k6 binaries and verifies each.

### `manifests/` — raw Kubernetes YAML, applied in numeric order, all in one `apps` namespace
| Path | Purpose |
|---|---|
| `00-namespace.yaml` | `apps` namespace + one ServiceAccount per tier (no default SA) + minimal RBAC (backend can `get`/`list` pods, for graceful-drain awareness) |
| `frontend/01-configmap.yaml` | nginx config — proxies `/api/` to `backend-service:8000`, gzip/keepalive, `/health`, CIDR-restricted `/nginx_status` |
| `frontend/02-deployment.yaml` | nginx:1.27-alpine, 2 replicas, `maxUnavailable:0/maxSurge:1`, pod anti-affinity, `preStop: sleep 3 && nginx -s quit` |
| `frontend/03-service.yaml` | ClusterIP :80 |
| `frontend/04-hpa.yaml` | **HPAs for both frontend (2–10 replicas, CPU 70%/mem 80%) and backend (2–8 replicas, CPU 65%/mem 75%)** |
| `frontend/05-pdb.yaml` | **PDBs for both frontend and backend**, `minAvailable: 1` |
| `backend/03-deployment.yaml` | FastAPI (`backend:local`, built and `kind load`-ed locally, not registry-pulled), 2 replicas, initContainer polls `postgres-service:5432`, env from `postgres-secret`, `DB_POOL_MIN=1`/`MAX=5` |
| `backend/04-service.yaml` | ClusterIP :8000 |
| `backend/01-configmap.yaml`, `02-secret.yaml`, `05-hpa.yaml`, `06-pdb.yaml` | present but **empty placeholders** — the real backend HPA/PDB live in `frontend/04-hpa.yaml`/`05-pdb.yaml` instead |
| `database/01-secret.yaml` | `postgres-secret` (`appuser`/`apppassword`/`appdb`, base64 — explicitly lab-only, not production-safe) |
| `database/02-configmap.yaml` | tuned `postgresql.conf` (`max_connections=100`, `shared_buffers=128MB`) + `init.sql` seeding an `items` table with 1000 rows for load testing |
| `database/03-statefulset.yaml` | postgres:16-alpine, **1 replica** (StatefulSet chosen for stable DNS/ordered lifecycle/per-pod PVC), `chown 999:999` initContainer, liveness via `pg_isready`, readiness via `pg_isready` + `SELECT 1 FROM items`, 10Gi PVC on `storageClassName: standard` |
| `database/04-service.yaml` | headless `postgres-headless` + ClusterIP `postgres-service` :5432 |
| `database/05-pdb.yaml` | `minAvailable: 1` — intentionally **blocks node drains** with only one DB replica, to force conscious handling during upgrades |
| `database/pgbouncer-deployment.yaml` | bitnami/pgbouncer:1.23.0, transaction pooling, `MAX_CLIENT_CONN=200`/`DEFAULT_POOL_SIZE=20`, sized for backend scaling to 8 pods × 5 connections against Postgres's `max_connections=100`. **Defined but not yet wired in** — the backend's `DB_HOST` doesn't point at it yet |
| `networking/01-network-policies.yaml` | Calico default-deny-all ingress+egress, then an explicit allow chain: ingress-nginx → frontend → backend:8000 → database:5432 (plus UDP/53 for DNS everywhere) |
| `networking/02-ingress.yaml` | `nginx` ingressClass, host `three-tier.local`, 10m body-size cap, `limit-rps: 1000`, routes `/` → `frontend-service:80` |

Every tier has its own ServiceAccount, pod anti-affinity (preferred), zero-downtime rolling updates, and tuned liveness/readiness/startup probes — database readiness gates backend readiness, which gates frontend's ability to serve, an intentional fail-safe cascade.

### `backend/app/` — the FastAPI service
- **app.py** — FastAPI 0.111 + `psycopg2.ThreadedConnectionPool` (1–5 connections, exponential-backoff retry up to 10 attempts on cold start), CORS wide open, request-timing middleware.
  - `GET /health` — liveness, no DB dependency.
  - `GET /ready` — readiness, runs `SELECT 1`.
  - `GET/POST /api/items` — CRUD against the seeded `items` table.
  - `GET /api/stats` — item count, active DB connections (`pg_stat_activity`), DB size — used by load tests to correlate traffic with DB pressure.
  - Run via uvicorn with 4 workers; multi-stage `python:3.12-slim` Dockerfile, non-root `appuser`.

### `scripts/` — operational scripts
- **bootstrap.sh** — full setup: preflight check → `ansible-playbook site.yml` → `terraform init/plan/apply` → wait for node readiness → `docker build backend:local` + `kind load docker-image` → `kubectl apply` manifests in order (namespace → database → backend → frontend → networking) → wait for rollout → smoke test (`curl localhost:8080/health`, `/api/items`).
- **scale-observe.sh** — 5s watch-loop printing `kubectl get hpa`, `get pods`, `top pods` in `apps`, meant to run in a side terminal during load tests to watch HPA reactions live.
- **teardown.sh** — destructive: requires a typed "yes" confirmation, deletes the `apps` namespace, `terraform destroy -auto-approve`, removes `/tmp/three-tier-kind`.
- **upgrade.sh** — wraps the Ansible upgrade flow: pre-checks nodes/pods/PDBs, updates `terraform/terraform.tfvars` with the new version, runs the upgrade playbook, then only `terraform plan` (leaves `apply` as a manual step).
- **preflight-check.sh** — present but empty; its intended content (checking for `docker terraform ansible kubectl helm kind k6 jq yq` and inotify sysctl limits) currently lives in the root **`test_env.ksh`** instead (see below — likely a misplaced file).

### `tests/` — load and chaos testing
- **tests/load/frontend-load.js** (k6) — staged ramp 20→50→200→200→50→50→0 VUs over ~16 min against `/` and `/health`; thresholds p95<200ms/p99<500ms, error rate <0.5–1%.
- **tests/load/backend-load.js** (k6) — 80/20 read/write mix against `/api/items`, ramps to 80 VUs (sized to trigger backend HPA at ~65% CPU per its own comment); thresholds p95<500ms reads / <1000ms writes, error rate <1%.
- **tests/load/db-pgbench.sh** — pgbench in ephemeral pods against `postgres-service`: init schema at scale factor 50 (~500k rows) → read-only benchmark → mixed TPC-B write benchmark → force-delete `postgres-0` and verify row counts match after StatefulSet recreation (proves PVC persistence).
- **tests/chaos/kill-frontend-pods.sh** — scales frontend to 4 replicas, force-deletes all frontend pods at once, times recovery, validates PDB/Deployment self-healing.
- **tests/chaos/kill-backend-pods.sh** — runs background k6 traffic while force-killing all backend pods, observes the error window and confirms readiness-gated recovery.
- **tests/chaos/kill-db-pod.sh** — most thorough: baselines item count, runs background write traffic via a `curlimages/curl` pod, force-kills `postgres-0`, waits for recreation + backend readiness, verifies no data loss, checks WAL/recovery state (`pg_is_in_recovery()`, `pg_current_wal_lsn()`).
- `tests/chaos/backend-load.js`, `frontend-load.js`, `db-pgbench.sh` also exist as empty placeholder files (unused stubs — the chaos scripts call into `tests/load/` directly instead).

### `test_env.ksh` (root)
Despite the name, it's a bash script whose header comment reads `# scripts/preflight-check.sh` — it appears to be the real content for the (currently empty) `scripts/preflight-check.sh`. It checks for required tools (`docker terraform ansible kubectl helm kind k6 jq yq`) and validates `/proc/sys/fs/inotify` watch/instance limits against the thresholds the Ansible `common` role sets, exiting with remediation instructions if anything is missing.

## Scaling & resilience mechanisms

- **Horizontal scaling** — `HorizontalPodAutoscaler` (autoscaling/v2) on frontend (2–10 replicas) and backend (2–8 replicas), driven by CPU/memory targets and `metrics-server`. The database tier does not autoscale; a single-replica Postgres StatefulSet is instead protected from connection fan-out by PgBouncer (defined, not yet plugged into the backend's connection string).
- **Availability** — PodDisruptionBudgets (`minAvailable: 1`) on all three tiers; pod anti-affinity spreads replicas across nodes; rolling updates use `maxUnavailable: 0`/`maxSurge: 1` for zero-downtime deploys.
- **Network segmentation** — Calico NetworkPolicies default-deny everything in `apps`, then explicitly allow only ingress → frontend → backend:8000 → database:5432 (plus DNS).
- **Persistence** — PVCs use kind's local-path-provisioner backed by host-mounted directories, so Postgres data survives node/container restarts during chaos and upgrade testing.
- **Upgrades** — a full Ansible-driven cordon/drain/replace/uncordon workflow for bumping the cluster's Kubernetes version, with pre-upgrade backups and post-upgrade smoke tests (control-plane node upgrades are not yet implemented).
- **Secrets** — plain base64 Kubernetes `Secret`s with hardcoded lab credentials, explicitly commented as not production-safe; Sealed Secrets/SOPS/Vault are recommended for real use.

## Running locally

```bash
# 1. Prep the host (kernel sysctls, Docker, pinned kind/kubectl/helm/k6)
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/site.yml

# 2. Provision the kind cluster, Calico, metrics-server, ingress-nginx
cd terraform && terraform init && terraform apply

# 3. Build, load, deploy, and smoke-test the app
./scripts/bootstrap.sh

# App available at:
open http://localhost:8080

# Watch autoscaling react to load in a side terminal
./scripts/scale-observe.sh

# Drive load / chaos tests
k6 run tests/load/frontend-load.js
k6 run tests/load/backend-load.js
./tests/load/db-pgbench.sh
./tests/chaos/kill-backend-pods.sh

# Tear down
./scripts/teardown.sh
```

## Known gaps

- `scripts/preflight-check.sh` is empty; use the equivalent logic in `test_env.ksh` until it's moved into place.
- `manifests/backend/01-configmap.yaml`, `02-secret.yaml`, `05-hpa.yaml`, `06-pdb.yaml` are empty placeholders — the effective backend HPA/PDB live in the `frontend/` manifest files.
- `tests/chaos/backend-load.js`, `frontend-load.js`, and `db-pgbench.sh` are empty stub duplicates of the `tests/load/` scripts.
- PgBouncer is deployed but not yet referenced by the backend's `DB_HOST` — connections currently go straight to Postgres.
- `ansible/playbooks/upgrade.yml` references an `upgrade-control-plane.yml` task file that doesn't exist yet, so control-plane version upgrades aren't implemented.
