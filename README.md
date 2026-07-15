This is a initial commit while I am testing ths on my local stack, see gap section for what i been reviewing.

# 3-Tier Scaling Stack

A local Kubernetes lab for **elasticity and failure-recovery testing** of a 3-tier web application (nginx → FastAPI → PostgreSQL). It provisions a [kind](https://kind.sigs.k8s.io/) cluster via Terraform, preps the host with Ansible, and deploys the app via raw Kubernetes manifests with HPAs/PDBs/NetworkPolicies. It's a sibling project to `ffeijo_3tier_hardened_stack`, which focuses on container/pod hardening — this one focuses on scaling under load and surviving pod/node failure.

The load-testing and chaos-testing scripts (k6 load tests, pod/node-kill scripts) that used to live in `tests/` have been removed — they were never fully validated against this stack and shouldn't be trusted as a reference for how to exercise it. The stack itself (Terraform → Ansible → manifests → `bootstrap.sh`) is validated and known to come up clean; load/chaos testing is a gap to fill back in, not an existing capability.

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
   │  psycopg2 ThreadedConnectionPool (1 worker/pod, blocking calls run in
   │  FastAPI's thread pool) → PgBouncer → PostgreSQL
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
| `backend/03-deployment.yaml` | FastAPI (`backend:local`, built and `kind load`-ed locally, not registry-pulled), 2 replicas, initContainer polls `pgbouncer-service:5432` (the actual `DB_HOST`), env from `postgres-secret`, `DB_POOL_MIN=1`/`MAX=5`, resources sized for a single-worker pod (`requests: cpu 150m/mem 128Mi`, `limits: cpu 500m/mem 384Mi`) |
| `backend/04-service.yaml` | ClusterIP :8000 |
| `backend/01-configmap.yaml`, `02-secret.yaml`, `05-hpa.yaml`, `06-pdb.yaml` | present but **empty placeholders** — the real backend HPA/PDB live in `frontend/04-hpa.yaml`/`05-pdb.yaml` instead |
| `database/01-secret.yaml` | `postgres-secret` (`appuser`/`apppassword`/`appdb`, base64 — explicitly lab-only, not production-safe) |
| `database/02-configmap.yaml` | tuned `postgresql.conf` (`listen_addresses='*'` — required because passing `config_file=` directly bypasses the postgres image's usual auto-injection of this, otherwise Postgres only binds loopback and every other pod gets connection-refused; `max_connections=100`, `shared_buffers=128MB`) + `init.sql` seeding an `items` table with 1000 rows for load testing |
| `database/03-statefulset.yaml` | postgres:16-alpine, **1 replica** (StatefulSet chosen for stable DNS/ordered lifecycle/per-pod PVC), `chown 999:999` initContainer, liveness via `pg_isready`, readiness via `pg_isready` + `SELECT 1 FROM items`, 10Gi PVC on `storageClassName: standard` |
| `database/04-service.yaml` | headless `postgres-headless` + ClusterIP `postgres-service` :5432 |
| `database/05-pdb.yaml` | `minAvailable: 1` — intentionally **blocks node drains** with only one DB replica, to force conscious handling during upgrades |
| `database/pgbouncer-deployment.yaml` | `edoburu/pgbouncer:v1.25.2-p0` (actively maintained — the pinned Bitnami tag this originally used was pulled from Docker Hub's free tier), transaction pooling, `MAX_CLIENT_CONN=200`/`DEFAULT_POOL_SIZE=20`, `AUTH_TYPE=scram-sha-256` (matches Postgres 16's default), sized for backend scaling to 8 pods against Postgres's `max_connections=100`. **Wired in** — backend's `DB_HOST` points here, not straight at Postgres |
| `networking/01-network-policies.yaml` | Calico default-deny-all ingress+egress, then an explicit allow chain: ingress-nginx → frontend → backend:8000 → database:5432 (plus UDP/53 for DNS everywhere). The `database` tier's policy carries two ingress rules and two egress rules rather than one each, because it selects on `tier: database` — a label shared by both the Postgres pod *and* the pgbouncer pod, which needs its own inbound-from-backend and outbound-to-Postgres rules distinct from Postgres's own |
| `networking/02-ingress.yaml` | `nginx` ingressClass, host `three-tier.local`, 10m body-size cap, `limit-rps: 1000`, routes `/` → `frontend-service:80` |

Every tier has its own ServiceAccount, pod anti-affinity (preferred), zero-downtime rolling updates, and tuned liveness/readiness/startup probes — database readiness gates backend readiness, which gates frontend's ability to serve, an intentional fail-safe cascade.

### `backend/app/` — the FastAPI service
- **app.py** — FastAPI 0.111 + `psycopg2.ThreadedConnectionPool` (1–5 connections, exponential-backoff retry up to 10 attempts on cold start), CORS wide open, request-timing middleware.
  - `GET /health` — liveness, no DB dependency.
  - `GET /ready` — readiness, runs `SELECT 1`.
  - `GET/POST /api/items` — CRUD against the seeded `items` table.
  - `GET /api/stats` — item count, active DB connections (`pg_stat_activity`), DB size — used by load tests to correlate traffic with DB pressure.
  - All DB-touching endpoints are plain `def`, not `async def` — `psycopg2` is a blocking driver, and FastAPI/Starlette automatically runs synchronous path functions in a thread pool instead of on the event loop, so one blocking DB call can't stall every other in-flight request on the same worker.
  - Run via uvicorn with **1 worker** (concurrency comes from the thread pool above plus HPA's pod-level scaling, not OS-level multiprocessing — running multiple workers per pod on top of HPA was found to just split each pod's CPU limit into starved fractions without adding real parallelism); multi-stage `python:3.12-slim` Dockerfile, non-root `appuser`.

### `scripts/` — operational scripts
- **bootstrap.sh** — full setup: preflight check → `ansible-playbook site.yml` → `terraform init/plan/apply` → wait for node readiness → `docker build backend:local` + `kind load docker-image` → `kubectl apply` manifests in order (namespace → database → backend → frontend → networking) → wait for rollout → smoke test. The smoke test curls with `--resolve three-tier.local:8080:127.0.0.1` rather than plain `localhost:8080`, since the Ingress rule (`networking/02-ingress.yaml`) matches on `Host: three-tier.local` — a bare `localhost` request falls through to nginx's default backend and looks like a failure even when the stack is healthy.
- **build-and-load.sh** — rebuilds `backend:local`, loads it onto every node of the running kind cluster (however many there are), rolls out `deployment/backend`, and verifies every resulting pod's reported image digest actually matches what was just built. Use this instead of a manual `docker build` + `kind load` + `kubectl rollout restart` whenever `backend/app/` or its `Dockerfile` changes — a plain rollout restart silently reuses whatever image is already tagged, so a skipped or failed build/load step leaves pods running stale code with no visible error.
- **scale-observe.sh** — 5s watch-loop printing `kubectl get hpa`, `get pods`, `top pods` in `apps`, meant to run in a side terminal while driving load against the cluster to watch HPA reactions live (no bundled load generator ships in this repo anymore — see top of this README).
- **teardown.sh** — destructive: requires a typed "yes" confirmation, deletes the `apps` namespace, `terraform destroy -auto-approve`, removes `/tmp/three-tier-kind`.
- **upgrade.sh** — wraps the Ansible upgrade flow: pre-checks nodes/pods/PDBs, updates `terraform/terraform.tfvars` with the new version, runs the upgrade playbook, then only `terraform plan` (leaves `apply` as a manual step).
- **preflight-check.sh** — present but empty; its intended content (checking for `docker terraform ansible kubectl helm kind k6 jq yq` and inotify sysctl limits) currently lives in the root **`test_env.ksh`** instead (see below — likely a misplaced file).

### `test_env.ksh` (root)
Despite the name, it's a bash script whose header comment reads `# scripts/preflight-check.sh` — it appears to be the real content for the (currently empty) `scripts/preflight-check.sh`. It checks for required tools (`docker terraform ansible kubectl helm kind k6 jq yq`) and validates `/proc/sys/fs/inotify` watch/instance limits against the thresholds the Ansible `common` role sets, exiting with remediation instructions if anything is missing.

## Scaling & resilience mechanisms

- **Horizontal scaling** — `HorizontalPodAutoscaler` (autoscaling/v2) on frontend (2–10 replicas) and backend (2–8 replicas), driven by CPU/memory targets and `metrics-server`. The database tier does not autoscale; a single-replica Postgres StatefulSet is instead protected from connection fan-out by PgBouncer, which sits in the backend's actual connection path.
- **Availability** — PodDisruptionBudgets (`minAvailable: 1`) on all three tiers; pod anti-affinity spreads replicas across nodes; rolling updates use `maxUnavailable: 0`/`maxSurge: 1` for zero-downtime deploys.
- **Network segmentation** — Calico NetworkPolicies default-deny everything in `apps`, then explicitly allow only ingress → frontend → backend:8000 → database:5432 (plus DNS).
- **Persistence** — PVCs use kind's local-path-provisioner backed by host-mounted directories, so Postgres data survives node/container restarts during chaos and upgrade testing.
- **Upgrades** — a full Ansible-driven cordon/drain/replace/uncordon workflow for bumping the cluster's Kubernetes version, with pre-upgrade backups and post-upgrade smoke tests (control-plane node upgrades are not yet implemented).
- **Secrets** — plain base64 Kubernetes `Secret`s with hardcoded lab credentials, explicitly commented as not production-safe; Sealed Secrets/SOPS/Vault are recommended for real use.

None of the above elasticity/failure-recovery behavior has been exercised under real load or real chaos yet — the k6/chaos scripts that would have driven that were removed (see top of this README) before being fully validated. Treat this list as "what the manifests are configured to do," not "what's been proven to work under stress."

## Running locally

```bash
# 1. Prep the host (kernel sysctls, Docker, pinned kind/kubectl/helm/k6)
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/site.yml

# 2. Provision the kind cluster, Calico, metrics-server, ingress-nginx
cd terraform && terraform init && terraform apply

# 3. Build, load, deploy, and smoke-test the app
./scripts/bootstrap.sh

# App available at (note: the Ingress matches on Host: three-tier.local,
# so a plain `curl localhost:8080/...` will 404 — either add
# `127.0.0.1 three-tier.local` to /etc/hosts, or use
# `curl --resolve three-tier.local:8080:127.0.0.1 http://three-tier.local:8080/...`):
open http://three-tier.local:8080

# After changing backend/app/ or its Dockerfile, rebuild + reload + roll out
# in one verified step (see scripts/ above for why this matters):
./scripts/build-and-load.sh

# Watch pod/resource state live (useful once you have your own load source)
./scripts/scale-observe.sh

# Tear down
./scripts/teardown.sh
```

## Known gaps

- No load or chaos testing exists in this repo currently — the previous `tests/` directory was removed because it hadn't been validated against the actual stack. Re-adding k6 load scripts and pod/node-kill chaos scripts, validated end-to-end this time, is open work.
- `ansible/playbooks/upgrade.yml` references an `upgrade-control-plane.yml` task file that doesn't exist yet, so control-plane version upgrades aren't implemented.
- This is a single-Docker-host kind cluster — every "node" is a container sharing the same physical CPU/RAM, not independent hardware. Sizing HPA replica counts and pod resource requests/limits against the host's real core count matters here in a way it wouldn't on a real multi-machine cluster; `nproc` on the host is the relevant ceiling to check against, not just what looks reasonable in isolation per-pod.
