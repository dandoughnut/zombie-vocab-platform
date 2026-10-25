# Everything here runs on a laptop or a free CI runner. The only target that
# touches a paid cloud is `cloud-up`, and `cloud-down` undoes it.

# bash for `<(...)` in the vm target.
SHELL := /bin/bash

BACKEND_DIR ?= ../zombie_vocab_backend
CLUSTER     ?= zombie-vocab
ECK_VERSION ?= 3.5.0
ARGOCD_VERSION ?= v3.5.6
KPS_VERSION ?= 92.13.1
NS          := zombie-vocab

.PHONY: help up down sweep demo load rules kind-up kind-down image deploy eck observability \
        monitoring argocd vm provision validate cloud-up cloud-down

help:
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-14s %s\n", $$1, $$2}'

## --- Docker Compose (fastest path) ---
up: ## API + Postgres + ELK (with Logstash) + Prometheus + Alertmanager + Grafana
	docker compose up -d --build
	@printf 'waiting for the API'; for i in $$(seq 90); do curl -fs localhost:8000/v1/health >/dev/null && break; printf .; sleep 2; done; echo
	@echo "API           http://localhost:8000/docs"
	@echo "Grafana       http://localhost:3000   (dashboards: Zombie Vocab folder)"
	@echo "Kibana        http://localhost:5601   (Discover → saved searches)"
	@echo "Prometheus    http://localhost:9090   (Alerts tab)"
	@echo "Alertmanager  http://localhost:9093"

down: ## Stop the compose stack (keeps volumes; add -v to wipe)
	docker compose down

sweep: ## Run the reconcile + prune-events jobs once, CronJob-style
	docker compose --profile sweep run --rm reconcile
	docker compose --profile sweep run --rm prune-events

demo: ## Seed 30 days of synthetic users, runs, funnel events, feedback
	docker compose --profile demo run --rm demo-data

load: ## Send mixed traffic (200/401/404) for the dashboards
	scripts/loadgen.sh http://localhost:8000 300

rules: ## Re-render Compose alert rules from k8s/monitoring/prometheus-rule.yaml
	python3 scripts/render-rules.py

## --- Kubernetes on kind ---
kind-up: ## 3-node local cluster
	kind create cluster --config kind/cluster.yaml

kind-down:
	kind delete cluster --name $(CLUSTER)

image: ## Build the API image and load it into every kind node
	docker build -t zombie-vocab-api:dev $(BACKEND_DIR)
	kind load docker-image zombie-vocab-api:dev --name $(CLUSTER)

deploy: image ## Apply the kind overlay directly (no Argo CD)
	kubectl apply -k k8s/overlays/kind
	kubectl -n $(NS) wait --for=condition=complete job/zombie-vocab-migrate --timeout=180s
	kubectl -n $(NS) rollout status deploy/zombie-vocab-api --timeout=120s
	@echo "kubectl -n $(NS) port-forward svc/zombie-vocab-api 8000:80"

eck: ## Install the ECK operator (CRDs + operator)
	kubectl create -f https://download.elastic.co/downloads/eck/$(ECK_VERSION)/crds.yaml || true
	kubectl apply -f https://download.elastic.co/downloads/eck/$(ECK_VERSION)/operator.yaml

observability: eck ## Elasticsearch + Kibana + Filebeat DaemonSet via ECK
	kubectl apply --server-side -k k8s/observability
	@echo "Password: kubectl -n observability get secret logs-es-elastic-user -o go-template='{{.data.elastic | base64decode}}'"
	@echo "Kibana:   kubectl -n observability port-forward svc/logs-kb-http 5601"

monitoring: ## kube-prometheus-stack (Helm) + the app's ServiceMonitor, alerts, dashboards
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack --version $(KPS_VERSION) \
	  -n monitoring --create-namespace -f k8s/monitoring/values.yaml --wait --timeout 10m
	kubectl apply -k k8s/monitoring
	@echo "Grafana:    kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80   (admin / admin)"
	@echo "Prometheus: kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090"

argocd: image eck ## Install Argo CD and hand the cluster to git (app of apps)
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd --server-side --force-conflicts \
	  -f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
	kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
	kubectl apply -f argocd/root.yaml
	@echo "UI: kubectl -n argocd port-forward svc/argocd-server 8080:443"
	@echo "Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

## --- Ansible on a local VM ---
vm: ## Ubuntu 24.04 VM via Multipass + inventory.ini
	multipass launch 24.04 --name zv-vm --cpus 2 --memory 4G --disk 15G \
	  --cloud-init <(printf '#cloud-config\nssh_authorized_keys:\n  - %s\n' "$$(cat ~/.ssh/id_ed25519.pub)")
	@printf '[zombie_vocab]\nzv-vm ansible_host=%s ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_ed25519\n' \
	  "$$(multipass info zv-vm --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["zv-vm"]["ipv4"][0])')" \
	  > ansible/inventory.ini

provision: ## Harden the VM and run the stack on it (re-run: 0 changes)
	cd ansible && ansible-galaxy collection install -r requirements.yml && ansible-playbook site.yml

## --- Checks (same as CI) ---
validate: ## Everything CI checks that runs without Docker
	@for o in k8s/overlays/kind k8s/overlays/gke k8s/observability k8s/monitoring; do \
	  echo "== $$o"; kubectl kustomize $$o | kubeconform -strict -summary -ignore-missing-schemas \
	    -schema-location default \
	    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' || exit 1; \
	done
	terraform fmt -check -recursive terraform
	@for e in terraform/envs/*; do (cd $$e && terraform init -backend=false -input=false >/dev/null && terraform validate) || exit 1; done
	cd ansible && ansible-playbook site.yml --syntax-check -i inventory.example.ini
	python3 scripts/render-rules.py --check
	promtool check rules observability/prometheus/rules.generated.yml
	cd observability/prometheus && promtool test rules rules.test.yml
	amtool check-config observability/alertmanager/alertmanager.yml

## --- Paid cloud (ephemeral) ---
cloud-up: ## GKE Autopilot demo env. Remember cloud-down.
	cd terraform/envs/gcp-demo && terraform init && terraform apply

cloud-down: ## Destroy the demo env (back to $0)
	cd terraform/envs/gcp-demo && terraform destroy
