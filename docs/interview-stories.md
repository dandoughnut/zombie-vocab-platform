# Interview stories

Each one: the situation, what I did, and why. They all come from the real
Zombie Vocab backend, not a tutorial app.

---

## 1. "Our background jobs would have run three times" (Kubernetes, CronJobs)

**Situation.** The FastAPI app ran two `asyncio` loops inside the web process:
a daily billing reconcile against the App Store / Play APIs, and a daily delete
of analytics events older than 12 months. On one Railway instance that's fine.

**Problem.** Scale to three replicas and each pod runs its own loop, so you get
three concurrent reconcile passes re-recording the same subscriptions against
rate-limited store APIs, and three delete sweeps.

**What I did.** I added a `RUN_BACKGROUND_LOOPS` setting (default on, so
Railway behaves exactly as before), pulled the prune logic into a shared
function, added a one-shot script, and moved both sweeps into Kubernetes
CronJobs with `concurrencyPolicy: Forbid` and `startingDeadlineSeconds`.

**Talking points.** Why not leader election? It adds moving parts to the app;
the scheduler already exists. Why `Forbid`? A slow store API must not cause
overlapping passes. Why keep the loops at all? Backwards compatibility. Ship
the change without forcing a platform migration.

## 2. "Migrations raced on every deploy" (Jobs, Argo CD hooks, sync waves)

**Situation.** Railway's start command was `alembic upgrade head && uvicorn`.

**Problem.** With N replicas that's N migrators at once, and a bad migration
would crash-loop every pod rather than stop the release.

**What I did.** The image no longer migrates. A dedicated Job does, as an Argo
CD **PreSync** hook, so a failed migration halts the rollout before new pods
take traffic.

**The bug I caught.** On the local cluster Postgres runs *inside* the cluster,
and PreSync hooks run before *every* sync wave, so the migration would run
before the database existed. The fix lives in the Postgres Kustomize
*component*: when you include an in-cluster database, it re-orders the release
(DB at wave −1, migration as a Sync hook at wave 0, app at wave 1).
Environments with an external DB keep PreSync. The dependency and its fix ship
together.

## 3. "Logs you can actually query" (Elastic Stack)

**What I did.** I added `LOG_FORMAT=json` with no new dependency (a stdlib
`logging.Formatter`) emitting ECS field names (`log.level`, `service.name`,
`http.response.status_code`, `event.duration_ms`). There's one structured
access line per request, uvicorn's duplicate access log is suppressed, and
Filebeat lifts the JSON keys into real fields.

**The detail that matters.** I log `http.route` as the route *template*
(`/v1/friends/{friend_id}`), not the raw path. Raw paths mean one Kibana bucket
per user ID: useless aggregations, and high cardinality in the index.

**The bug I caught.** My first version logged `/content/stages`, with no
`/v1`. FastAPI 0.16x stores the matched route relative to its included router,
and the only full-prefix data is a private object. Rather than depend on
internals, I rebuilt the prefix from public data: fill the template's params in,
and whatever precedes that suffix in the real path is the prefix. A test pins
it.

**Same pipeline in two places.** Compose (Filebeat autodiscover on Docker) and
Kubernetes (ECK-managed Elasticsearch/Kibana, Filebeat DaemonSet with RBAC).
ECK handles TLS and credentials, so none of it is hand-rolled.

## 4. "Keyless CI" (Terraform, AWS IAM, OIDC)

**What I did.** A Terraform module creates a GitHub OIDC provider, an IAM role
whose trust policy only accepts tokens whose `sub` claim is
`repo:dandoughnut/zombie_vocab_backend:ref:refs/heads/main`, and an ECR repo
with immutable tags, scan-on-push, and a keep-5 lifecycle policy. The role can
push to that one repository and nothing else.

**Talking points.** No long-lived AWS keys exist to leak or rotate. A fork or
a feature branch gets "not authorized". Cost: $0, since IAM/OIDC are free.

## 5. "A cloud environment that can't run up a bill" (Terraform, GCP)

**What I did.** GKE **Autopilot** (billed per pod request, not per node) on
its own VPC with explicit secondary ranges, Gateway API enabled, Artifact
Registry with cleanup policies, `deletion_protection = false` so destroy is
one command, and an optional billing budget alert at 50% / 100% of $5.

**Talking points.** Why Gateway API over Ingress? ingress-nginx is retired,
and GKE ships a managed Gateway controller. Secrets come from Secret Manager
through External Secrets + Workload Identity. Nothing sensitive is in git, and
there are no key files. State is local for a one-person ephemeral env; for a
shared env I'd use a GCS backend (or S3 with `use_lockfile`, native locking
since Terraform 1.10, no DynamoDB table).

## 6. "Safe to run twice" (Ansible, Linux)

**What I did.** Roles for a fresh Ubuntu 24.04 host: unattended security
upgrades, a deploy user, sshd hardening validated with `sshd -t` before it's
written (a typo can't lock you out), default-deny `ufw`, fail2ban, Docker from
Docker's repo with log rotation caps, and `vm.max_map_count` for
Elasticsearch. Elasticsearch and Kibana bind to loopback only and you reach
them through an SSH tunnel.

**The bug I caught.** `user: groups: []` in the base role would strip the
deploy user's `docker` group on every run, and the docker role would add it
back, so the play was never idempotent. Passes `ansible-lint` on the
production profile.

## 7. "Pods that survive a node drain" (Deployment hardening)

`maxUnavailable: 0`, topology spread across nodes, a PDB (`minAvailable: 1`),
an HPA (2–6) whose replica count Argo is told to ignore, and a `preStop` sleep
so the load balancer stops routing before uvicorn stops accepting. Probes hit
`/v1/health`, which is **DB-free on purpose**: a Postgres blip should fail
requests, not get every pod restarted at once. The pod runs as non-root,
read-only root filesystem, all capabilities dropped, seccomp `RuntimeDefault`.
The image uses a *numeric* UID, because `runAsNonRoot` can't verify a named
user. I hit that one in review before it hit a cluster.

## 8. "CI that proves it, for free" (GitHub Actions)

The platform repo renders every overlay and validates it against Kubernetes
*and* CRD schemas (ECK, External Secrets, Gateway API), plus Terraform
validate, ansible-lint, and compose config. The e2e job builds a 3-node kind
cluster per PR, deploys, migrates, curls through the Service, and runs a
CronJob on demand. The backend repo tests, builds, pushes to GHCR, then commits
the new tag here: CI never holds cluster credentials, so Argo CD pulls.

---

## 9. "Billing was silent" (audit logging at the right layer)

**Situation.** Four billing providers, about twenty early exits (bad
signature, unlinked account, duplicate, stale delivery, provider not
configured), and **one** log line in the whole module. "I paid but I'm not
Pro" meant reading database rows by hand.

**What I did.** A custom FastAPI `APIRoute` class wraps every webhook
handler. Each delivery ends in exactly one structured log line and one counter
tick, whichever exit it took: `applied`, `duplicate`, `stale`,
`coins_credited`, `refunded`, `ignored`, `rejected` (4xx), `unavailable` (5xx)
or `error`. Handlers only *declare* what they decided (`set_billing_outcome`)
at the point of decision, so none of the existing branches changed.

**Talking point.** I put it in one place on purpose: logging added branch by
branch is the logging that gets forgotten on the next branch.

## 10. "Metrics that won't melt Prometheus" (cardinality)

`/metrics` labels are route **templates** and closed enums (provider,
outcome), never user IDs or raw paths. One label value per user is one time
series per user. The endpoint is bearer-token gated and returns **404 when no
token is configured** (fail closed), because request rates and billing
outcomes are business data on a public API. Short-lived CronJob processes exit
before any scrape, so I monitor them through kube-state-metrics plus their log
line instead of adding a Pushgateway.

## 11. "Alerts are code, so they have tests" (SLOs, burn rates, promtool)

- **SLO:** 99.5% non-5xx over 30 days. Two multi-window burn-rate alerts
  (Google SRE workbook): 14.4× → **page**, 6× → **ticket**. A blip doesn't
  page; a real outage does within minutes.
- **One source of truth:** rules live in the Kubernetes `PrometheusRule`. A
  script renders them for the Compose Prometheus, and CI fails on drift.
- **Unit tests:** `promtool test rules` replays synthetic series. A 10% error
  rate pages. 0.2% stays quiet. A rotated Apple secret pages with the exact
  message "APPLE webhooks: 15 rejected in 15m". A reconcile that last succeeded
  30 h ago trips the dead man's switch. No targets at all trips `absent()`
  (`up == 0` can't fire when there's nothing to evaluate).
- **Routing:** Alertmanager sends page to on-call, ticket to a daily queue, and
  info to the dashboard. An inhibit rule mutes the downstream alerts while
  "API down" is firing.

## 12. "Logs without personal data" (Logstash)

Filebeat stays a thin shipper; Logstash does what an edge agent shouldn't own:
- **Pseudonymises** the billing user ID with a keyed SHA-256. Support can
  still follow one account's deliveries, but the index can't be joined back
  to a person without the key.
- **Drops health-check lines**, which are most of the volume and none of the
  value. Their metrics still reach Prometheus.
- **Routes into a data stream** with 14-day retention enforced by
  Elasticsearch.

A second pipeline polls feedback from Postgres over **JDBC**, incrementally on
`created_at`, and **redacts email addresses** before indexing. It never
selects `user_id`. I tested the SQL and the redaction regex against real
Postgres.

**Bug I caught:** Logstash only honours `\"` inside config strings when
`config.support_escapes` is on, and it's off by default, so the SQL moved to
its own file.

## 13. "Product metrics with least privilege" (Postgres + Grafana)

The database already knew how many users we have; it just needed asking
safely. A migration adds a `zombie_vocab_metrics` schema of aggregate
**views**: DAU/WAU, signups, D1/D7 retention, the funnel, subscriptions
(sandbox excluded). The Grafana role can read those views and nothing else.
Views run with their owner's rights, so they can aggregate tables the role
can't see. Sessions are read-only with a 15 s statement timeout. I verified it
on Postgres 16: per-user schema → "permission denied", public tables → denied,
writes → "read-only transaction".

**Bug I caught:** after a migration downgrade/upgrade cycle every product
panel went blank. `DROP SCHEMA … CASCADE` drops the grants too. The migration
now re-grants whenever the role exists. I found it by running every
dashboard query *as the dashboard's role*, not as a superuser.

## 14. "SQLite hid a foreign-key bug" (test on the real engine)

The demo seeder passed on SQLite and failed on Postgres: the models declare no
ORM relationships, so SQLAlchemy didn't order the inserts, and `events` went in
before their `profiles`. SQLite doesn't enforce foreign keys by default, so it
never complained. The fix is a flush per profile. The lesson: integration-test
against the engine you run, which I did with an embedded Postgres 16 and no
Docker.
