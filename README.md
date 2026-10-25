# zombie-vocab-platform

Infrastructure for **Zombie Vocab**, an SAT vocabulary game for iOS/Android
with a FastAPI backend (cloud saves, leaderboards, App Store / Play / Stripe /
RevenueCat billing webhooks, analytics ingest). Production runs on one Railway
instance. This repo is the version of that service built to scale out:
containerized, on Kubernetes, delivered by GitOps, observed with **both** the
Elastic Stack and Prometheus + Grafana, with the cloud in Terraform and hosts
provisioned by Ansible.

**Running cost: $0.** Everything runs in GitHub Codespaces or on free GitHub
Actions runners. The one cloud environment (GKE) is built to be applied for a
demo and destroyed afterwards, with a budget alert as the safety net.

```
                 ┌──────────────── GitHub Actions (free) ────────────────┐
 backend repo ─push─▶ test → docker build → push ghcr.io/…:sha-abc123    │
                 │            commit new tag to this repo ─────────┐      │
                 └─────────────────────────────────────────────────┼──────┘
                                                                   ▼
 ┌────────────────────────── Kubernetes (kind / GKE) ─────────────────────────┐
 │ Argo CD ─sync─▶ wave -1 config, secret, Postgres                           │
 │                 wave  0 migrate Job (once)                                 │
 │                 wave  1 API (HPA 2–6, PDB, probes), CronJobs               │
 │                                                                            │
 │ LOGS     api stdout ─▶ Filebeat ─▶ Elasticsearch ─▶ Kibana          (ECK)  │
 │ METRICS  api /metrics ◀─ Prometheus ─▶ Alertmanager, Grafana  (kube-prom)  │
 └────────────────────────────────────────────────────────────────────────────┘

 Compose adds: Logstash (user-id pseudonymising, health-check drop, email
 redaction), a JDBC feedback index, and Grafana over Postgres product metrics.
```

## Two observability stacks, two jobs

| Question | Tool | What it shows here |
|---|---|---|
| *Is something wrong, and since when?* | **Prometheus + Alertmanager** | RED metrics per route template, a 99.5% availability SLO with multi-window burn-rate alerts, billing webhook outcomes, CronJob failures and a dead man's switch for the reconcile job. 5 alert unit tests |
| *What exactly happened?* | **Elasticsearch + Kibana** | One structured line per request and per billing webhook, joined by `http.request.id`. Saved searches for billing problems, 5xx, slow requests |
| *What are users telling us?* | **Logstash JDBC → Elasticsearch** | Full-text feedback search (English analyzer: "crash" finds "crashed"), emails redacted before indexing |
| *How many users, are they staying?* | **Grafana → Postgres** | DAU/WAU, signups, D1/D7 retention, the onboarding → paywall funnel, subscriptions. Read by a role that can only see aggregate views |
| *All of it on one screen* | **Grafana** | Prometheus, Elasticsearch and Postgres data sources side by side |

## Layout

| Path | Stack |
|---|---|
| `docker-compose.yml` | The whole platform locally (16 services) |
| `observability/logstash` | Two pipelines: app logs (Beats) and feedback (JDBC) |
| `observability/elasticsearch`, `observability/kibana` | Index templates (14-day retention), data views and saved searches as code |
| `observability/prometheus`, `observability/alertmanager` | Scrape config, generated rules, **alert unit tests**, severity routing |
| `observability/grafana`, `k8s/monitoring/dashboards` | Data sources and 3 dashboards as code (shared by Compose and Kubernetes) |
| `k8s/base`, `k8s/overlays/{kind,gke}`, `k8s/components/postgres` | Kubernetes, Kustomize, Gateway API, External Secrets |
| `k8s/observability` | Elastic Stack on Kubernetes via ECK |
| `k8s/monitoring` | kube-prometheus-stack values, ServiceMonitor, PrometheusRule (the single source of alert rules) |
| `argocd/` | GitOps: app of apps, including the Helm-based monitoring stack |
| `terraform/envs/gcp-demo`, `terraform/envs/aws-ci` | GKE Autopilot + budget; GitHub OIDC → IAM + ECR (keyless CI, $0) |
| `ansible/` | Linux host hardening, Docker, app deploy |
| `.github/workflows/` | Schema validation, Terraform, ansible-lint, observability checks, kind e2e |

## Quick start (GitHub Codespaces, nothing to install)

**Code → Codespaces → Create codespace on main.** Approve the read access
to `zombie_vocab_backend` when prompted. The devcontainer installs Docker,
kind, kubectl, Helm, Terraform, Ansible, kubeconform, promtool and amtool, and
clones the backend next to this repo. Pick **2-core** for Compose and
**4-core** for Kubernetes. Stop the codespace when done; it fits inside the
free monthly quota.

```bash
make up      # everything; Grafana opens on port 3000
make demo    # 30 days of synthetic users, runs, funnel events, feedback
make load    # live mixed traffic (200/401/404)
make sweep   # run the reconcile + prune jobs once, CronJob-style
```

| Port | Open | Look at |
|---|---|---|
| 3000 | Grafana | *Zombie Vocab* folder: **API: RED + SLO**, **Billing operations**, **Product: users and growth** |
| 5601 | Kibana | Discover → saved searches: *Billing webhook problems*, *Feedback: crashes and bugs* |
| 9090 | Prometheus | Alerts tab (all 15 rules), Status → Targets |
| 9093 | Alertmanager | Where each alert would be routed (page / ticket / dashboard) |
| 8000 | API | `/docs`; every response carries `X-Request-ID` |

Running locally instead needs Docker with ~8 GB for the containers and the
backend checked out at `../zombie_vocab_backend`.

## Kubernetes (kind)

```bash
make kind-up         # 1 control plane + 2 workers
make deploy          # build + load image, apply overlay, wait for migration + rollout
make monitoring      # kube-prometheus-stack + ServiceMonitor + alerts + dashboard
make observability   # ECK: Elasticsearch + Kibana + Filebeat DaemonSet
make argocd          # Argo CD; from now on the cluster follows git
```

## Ansible (local VM)

```bash
make vm          # Ubuntu 24.04 VM via Multipass, writes ansible/inventory.ini
make provision   # harden + Docker + stack; a second run shows changed=0
```

## Cloud demo (GCP, ephemeral)

```bash
cp terraform/envs/gcp-demo/terraform.tfvars.example terraform/envs/gcp-demo/terraform.tfvars
make cloud-up     # GKE Autopilot ~10 min
make cloud-down   # back to $0
```

## Checks

`make validate` runs what CI runs without Docker:
- every overlay rendered and validated against Kubernetes and CRD schemas
- Terraform fmt/validate
- Ansible syntax
- the rules drift check
- promtool rule checks and **alert unit tests**
- amtool

CI adds ansible-lint, Logstash's own config test, and JSON checks on dashboards
and saved objects. `e2e (kind)` builds a 3-node cluster per PR, deploys,
migrates, smoke-tests through the Service, and runs a CronJob.

See [docs/interview-stories.md](docs/interview-stories.md) for why each
decision was made.
