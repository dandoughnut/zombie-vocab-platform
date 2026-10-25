# zombie-vocab-platform

Infrastructure for **Zombie Vocab**, a vocabulary game for iOS/Android with
a FastAPI backend (cloud saves, leaderboards, App Store / Play / Stripe billing
webhooks, analytics ingest). Production runs on a single Railway instance. This
repo is the multi-replica version of that service: containerized, on
Kubernetes, delivered by GitOps, observed with the Elastic Stack, with the
cloud described in Terraform and hosts provisioned by Ansible.

**Running cost: $0.** Everything runs on a laptop or on free GitHub Actions
runners. The one cloud environment (GKE) is designed to be applied for a demo
and destroyed afterwards, with a budget alert as the safety net.

```
                    ┌────────────── GitHub Actions (free) ──────────────┐
 backend repo ──push──▶ test → docker build → push ghcr.io/…:sha-abc123 │
                    │                         │                         │
                    │      commit new tag to k8s/overlays/kind          │
                    └─────────────────────────┼─────────────────────────┘
                                              ▼
                          this repo (desired state in git)
                                              │  watches
                                              ▼
 ┌──────────────────────── Kubernetes (kind / GKE) ───────────────────────┐
 │ Argo CD ── sync ──▶ wave -1: ConfigMap, Secret, Postgres               │
 │                     wave  0: migrate Job (alembic, runs once)          │
 │                     wave  1: API Deployment (HPA 2–6, PDB, probes)     │
 │                              CronJobs: reconcile billing, prune events │
 │                                                                        │
 │ Filebeat DaemonSet ── JSON logs ──▶ Elasticsearch ──▶ Kibana   (ECK)   │
 └────────────────────────────────────────────────────────────────────────┘
```

| Path | Stack |
|---|---|
| `docker-compose.yml`, `observability/` | Docker, Elasticsearch, Kibana, Filebeat |
| `k8s/base`, `k8s/overlays/{kind,gke}`, `k8s/components/postgres` | Kubernetes, Kustomize, Gateway API, External Secrets |
| `k8s/observability` | Elastic Stack on Kubernetes via ECK |
| `argocd/` | GitOps: Argo CD app of apps |
| `terraform/envs/gcp-demo` | GCP: GKE Autopilot, VPC, Artifact Registry, billing budget |
| `terraform/envs/aws-ci` | AWS: GitHub OIDC → IAM role, ECR (keyless CI, $0) |
| `ansible/` | Linux host hardening + Docker + app deploy |
| `.github/workflows/` | CI: schema validation, Terraform validate, ansible-lint, kind e2e |

The backend changes that made this possible (Dockerfile, JSON logging,
CronJob-ready sweeps) live in the backend repo. See
[docs/interview-stories.md](docs/interview-stories.md) for the reasoning behind
each decision.

## Quick start (GitHub Codespaces, nothing to install)

**Code → Codespaces → Create codespace on main.** Approve the read access
to `zombie_vocab_backend` when prompted. The devcontainer installs Docker,
kind, kubectl, Terraform, Ansible and kubeconform, and clones the backend next
to this repo. Pick **2-core** for Compose + ELK and **4-core** for Kubernetes.
Ports 8000 (API), 5601 (Kibana) and 8080 (Argo CD) open as browser tabs.
Stop the codespace when done; it fits inside the free monthly quota.

Running locally instead needs Docker (~6 GB RAM for the Elastic stack) and the
backend checked out at `../zombie_vocab_backend`.

```bash
make up      # API :8000, Kibana :5601
make load    # mixed 200/401/404 traffic
make sweep   # run the reconcile + prune jobs once
```

Kibana → Discover → data view **Zombie Vocab API logs**. Useful fields:
`http.route` (the route template, so `/v1/friends/{friend_id}` is one bucket),
`http.response.status_code`, `event.duration_ms`, `log.logger`.

## Kubernetes (kind)

Extra prereqs: `kind`, `kubectl`.

```bash
make kind-up         # 1 control plane + 2 workers
make deploy          # build + load image, apply overlay, wait for migration + rollout
kubectl -n zombie-vocab port-forward svc/zombie-vocab-api 8000:80

make observability   # ECK operator + Elasticsearch + Kibana + Filebeat
```

### GitOps

```bash
make argocd          # install Argo CD, apply argocd/root.yaml
```

From then on the cluster follows `main`. To roll out a backend release, change
the tag in `k8s/overlays/kind/kustomization.yaml` and commit it. The backend's
CI does exactly that when `PLATFORM_REPO_TOKEN` is set. If you `kubectl edit`
something by hand, Argo reverts it (`selfHeal`).

## Ansible (local VM)

Extra prereqs: `multipass`, `ansible`.

```bash
make vm          # Ubuntu 24.04 VM, writes ansible/inventory.ini
make provision   # harden + Docker + stack; a second run shows changed=0
```

## Cloud demo (GCP, ephemeral)

```bash
cp terraform/envs/gcp-demo/terraform.tfvars.example terraform/envs/gcp-demo/terraform.tfvars
make cloud-up     # GKE Autopilot ~10 min
# push image to the output image_repository, set PROJECT_ID in k8s/overlays/gke, apply
make cloud-down   # back to $0
```

## Checks

`make validate` runs the same checks as CI: every overlay is rendered and
validated against Kubernetes and CRD schemas (kubeconform), `terraform fmt` /
`validate` on both envs, and Ansible syntax checks. CI also runs
`ansible-lint` (production profile). `e2e (kind)` builds a real 3-node cluster
on each PR, deploys, runs migrations, smoke-tests through the Service, and
triggers a CronJob.
