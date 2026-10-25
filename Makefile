# Everything here runs on a laptop or a free CI runner. The only target that
# touches a paid cloud is `cloud-up`, and `cloud-down` undoes it.

# bash for `<(...)` in the vm target.
SHELL := /bin/bash

BACKEND_DIR ?= ../zombie_vocab_backend
CLUSTER     ?= zombie-vocab
ECK_VERSION ?= 3.5.0
ARGOCD_VERSION ?= v3.5.6
NS          := zombie-vocab

.PHONY: help up down sweep load kind-up kind-down image deploy eck observability argocd \
        vm provision validate cloud-up cloud-down

help:
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-14s %s\n", $$1, $$2}'

## --- Docker Compose (fastest path) ---
up: ## API + Postgres + Elasticsearch + Kibana + Filebeat on localhost
	docker compose up -d --build
	@printf 'waiting for the API'; for i in $$(seq 90); do curl -fs localhost:8000/v1/health >/dev/null && break; printf .; sleep 2; done; echo
	@echo "API     http://localhost:8000/docs"
	@echo "Kibana  http://localhost:5601  (data view: Zombie Vocab API logs)"

down: ## Stop the compose stack (keeps volumes; add -v to wipe)
	docker compose down

sweep: ## Run the reconcile + prune-events jobs once, CronJob-style
	docker compose --profile sweep run --rm reconcile
	docker compose --profile sweep run --rm prune-events

load: ## Send mixed traffic (200/401/404) for the dashboards
	scripts/loadgen.sh http://localhost:8000 300

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
validate: ## kustomize build | kubeconform, terraform fmt/validate, ansible syntax
	@for o in k8s/overlays/kind k8s/overlays/gke k8s/observability; do \
	  echo "== $$o"; kubectl kustomize $$o | kubeconform -strict -summary -ignore-missing-schemas \
	    -schema-location default \
	    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' || exit 1; \
	done
	terraform fmt -check -recursive terraform
	@for e in terraform/envs/*; do (cd $$e && terraform init -backend=false -input=false >/dev/null && terraform validate) || exit 1; done
	cd ansible && ansible-playbook site.yml --syntax-check -i inventory.example.ini

## --- Paid cloud (ephemeral) ---
cloud-up: ## GKE Autopilot demo env. Remember cloud-down.
	cd terraform/envs/gcp-demo && terraform init && terraform apply

cloud-down: ## Destroy the demo env (back to $0)
	cd terraform/envs/gcp-demo && terraform destroy
