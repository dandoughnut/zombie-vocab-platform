#!/usr/bin/env bash
# Tools the devcontainer features don't cover, plus the backend checkout.
set -euo pipefail

KIND_VERSION=v0.33.0
KUBECONFORM_VERSION=v0.8.0
ARCH=$(dpkg --print-architecture)

curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
sudo install /tmp/kind /usr/local/bin/kind

curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${ARCH}.tar.gz" \
  | sudo tar -xz -C /usr/local/bin kubeconform

pip install --user --quiet ansible ansible-lint
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
  make up && make load     # Compose + ELK; Kibana opens on port 5601
  make kind-up deploy      # Kubernetes (pick a 4-core codespace)
  make help
EOF
