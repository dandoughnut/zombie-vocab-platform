#!/usr/bin/env bash
# Tools the devcontainer features don't cover, plus the backend checkout.
set -euo pipefail

KIND_VERSION=v0.33.0
KUBECONFORM_VERSION=v0.8.0
PROMETHEUS_VERSION=3.15.1
ALERTMANAGER_VERSION=0.34.1
ARCH=$(dpkg --print-architecture)

curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
sudo install /tmp/kind /usr/local/bin/kind

curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${ARCH}.tar.gz" \
  | sudo tar -xz -C /usr/local/bin kubeconform

# promtool / amtool for `make validate` (rule unit tests, routing config).
curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}.tar.gz" \
  | sudo tar -xz -C /usr/local/bin --strip-components=1 "prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}/promtool"
curl -fsSL "https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-${ARCH}.tar.gz" \
  | sudo tar -xz -C /usr/local/bin --strip-components=1 "alertmanager-${ALERTMANAGER_VERSION}.linux-${ARCH}/amtool"

pip install --user --quiet ansible ansible-lint pyyaml
(cd ansible && ansible-galaxy collection install -r requirements.yml >/dev/null)

# Sibling checkout, matching the default BACKEND_DIR=../zombie_vocab_backend.
BACKEND="$(dirname "$PWD")/zombie_vocab_backend"
if [ ! -d "$BACKEND" ]; then
  git clone --branch "${BACKEND_REF:-main}" https://github.com/dandoughnut/zombie_vocab_backend.git "$BACKEND"
fi
if [ ! -f "$BACKEND/Dockerfile" ]; then
  echo "WARNING: $BACKEND (branch ${BACKEND_REF:-main}) has no Dockerfile yet." >&2
  echo "Merge the backend's infra/containerize branch, or: (cd $BACKEND && git checkout infra/containerize)" >&2
fi

[ -f .env ] || cp .env.example .env

cat <<'EOF'

Ready. Try:
  make up && make demo && make load   # Grafana opens on port 3000
  make kind-up deploy      # Kubernetes (pick a 4-core codespace)
  make help
EOF
