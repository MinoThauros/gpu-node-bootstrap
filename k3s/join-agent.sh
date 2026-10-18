#!/usr/bin/env bash
# Join this GPU node to an existing k3s cluster as an agent. Run on the node, after firstboot/gpu-node-setup.sh.
# Checks the NVIDIA driver + Container Toolkit, installs the k3s agent (get.k3s.io) with the label
# nvidia.com/gpu.present=true, then confirms k3s registered the "nvidia" runtime in its containerd config.
#
# Usage:  sudo K3S_URL=https://<server>:6443 K3S_TOKEN=<token> ./join-agent.sh
#    or:  sudo ./join-agent.sh --url https://<server>:6443 --token-file /root/k3s-token
# Token:  on the server, /var/lib/rancher/k3s/server/node-token
# Safe to re-run: skips the install when the agent is already running against the same server.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo join-agent.sh [options] [-- extra k3s agent args]

  --url URL          k3s server URL, e.g. https://192.168.1.10:6443   (or env K3S_URL)
  --token TOKEN      cluster join token                               (or env K3S_TOKEN)
  --token-file FILE  read the token from FILE                         (or env K3S_TOKEN_FILE)
  --reinstall        run the k3s installer even if the agent is already running
  -h, --help         this help

Optional env: INSTALL_K3S_VERSION (e.g. v1.33.4+k3s1) to match the server's version,
              INSTALL_K3S_CHANNEL (default: stable).
Anything after "--" is appended to the k3s agent command line (e.g. -- --node-name gpu-node-1).
EOF
}

K3S_URL="${K3S_URL:-}"
K3S_TOKEN="${K3S_TOKEN:-}"
K3S_TOKEN_FILE="${K3S_TOKEN_FILE:-}"
REINSTALL=0
EXTRA_ARGS=()
GPU_LABEL="nvidia.com/gpu.present=true"
CONTAINERD_CFG_DIR=/var/lib/rancher/k3s/agent/etc/containerd

while [ $# -gt 0 ]; do
  case "$1" in
    --url)        K3S_URL="${2:?--url needs a value}"; shift 2 ;;
    --token)      K3S_TOKEN="${2:?--token needs a value}"; shift 2 ;;
    --token-file) K3S_TOKEN_FILE="${2:?--token-file needs a value}"; shift 2 ;;
    --reinstall)  REINSTALL=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; EXTRA_ARGS=("$@"); break ;;
    *)            echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"

if [ -z "$K3S_TOKEN" ] && [ -n "$K3S_TOKEN_FILE" ]; then
  [ -r "$K3S_TOKEN_FILE" ] || die "cannot read token file $K3S_TOKEN_FILE"
  K3S_TOKEN="$(tr -d '[:space:]' < "$K3S_TOKEN_FILE")"
fi
[ -n "$K3S_URL" ]   || die "K3S_URL is required (--url or env). See --help."
[ -n "$K3S_TOKEN" ] || die "K3S_TOKEN is required (--token, --token-file or env). See --help."
case "$K3S_URL" in https://*) ;; *) die "K3S_URL must start with https:// (got '$K3S_URL')" ;; esac

# --- 1. GPU prerequisites (installed by firstboot/gpu-node-setup.sh) -------------------------
log "Checking NVIDIA driver and Container Toolkit"
command -v nvidia-smi >/dev/null || die "nvidia-smi not found. Run firstboot/gpu-node-setup.sh first."
nvidia-smi -L || die "nvidia-smi failed: driver not loaded (reboot after gpu-node-setup?)"
command -v nvidia-container-runtime >/dev/null \
  || die "nvidia-container-runtime not found. Install the NVIDIA Container Toolkit (firstboot/gpu-node-setup.sh)."

# --- 2. Server reachable? (k3s answers /ping with "pong") -------------------------------------
log "Checking the server at $K3S_URL"
command -v curl >/dev/null || die "curl not found (apt-get install curl)"
curl -fsk --max-time 10 "${K3S_URL%/}/ping" >/dev/null \
  || die "cannot reach ${K3S_URL%/}/ping. Check the URL, the server's firewall (TCP 6443) and the network."

# --- 3. Install / reuse the k3s agent ---------------------------------------------------------
already_joined() {
  # The installer saves K3S_URL in this env file, quoted.
  local current
  systemctl is-active --quiet k3s-agent 2>/dev/null || return 1
  current="$(sed -n 's/^K3S_URL=//p' /etc/systemd/system/k3s-agent.service.env 2>/dev/null | tr -d "'\"")"
  [ "$current" = "$K3S_URL" ]
}

if [ "$REINSTALL" -eq 0 ] && already_joined; then
  log "k3s-agent already running against $K3S_URL; skipping install (use --reinstall to force)"
else
  if [ -z "${INSTALL_K3S_VERSION:-}" ]; then
    echo "NOTE: INSTALL_K3S_VERSION not set; installing the latest ${INSTALL_K3S_CHANNEL:-stable} k3s." \
         "An agent newer than the server is unsupported: set it to the server's version (kubectl get nodes)."
  fi
  log "Installing k3s agent (label $GPU_LABEL)"
  exec_args="agent --node-label $GPU_LABEL"
  if [ ${#EXTRA_ARGS[@]} -gt 0 ]; then exec_args="$exec_args ${EXTRA_ARGS[*]}"; fi
  curl -sfL https://get.k3s.io \
    | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" INSTALL_K3S_EXEC="$exec_args" sh -s -
fi

# --- 4. Confirm k3s detected the nvidia runtime ------------------------------------------------
# k3s writes its containerd config on agent start and adds a "nvidia" runtime when it finds
# nvidia-container-runtime. containerd 1.x (config v2) and 2.x (config v3) quote the key differently.
log "Waiting for k3s to write its containerd config"
cfg="$CONTAINERD_CFG_DIR/config.toml"
for _ in $(seq 1 60); do
  [ -s "$cfg" ] && break
  sleep 2
done
[ -s "$cfg" ] || die "no containerd config under $CONTAINERD_CFG_DIR after 120 s. Check: journalctl -u k3s-agent"

if grep -qE "runtimes\.['\"]?nvidia['\"]?\]" "$cfg"; then
  log "OK: nvidia runtime present in $cfg"
  grep -A3 -E "runtimes\.['\"]?nvidia['\"]?\]" "$cfg" | sed 's/^/    /'
else
  die "k3s did not register the nvidia runtime in $cfg.
       Is nvidia-container-runtime on root's PATH? Then: systemctl restart k3s-agent and re-run this script."
fi

systemctl is-active --quiet k3s-agent || die "k3s-agent is not active. Check: journalctl -u k3s-agent"

cat <<EOF

Done. This node is joining the cluster as $(hostname) with label $GPU_LABEL.
Next, from a machine with kubectl access to the cluster:
  kubectl get nodes -L nvidia.com/gpu.present
  kubectl apply -f k3s/cluster/
See docs/join-cluster.md.
EOF
