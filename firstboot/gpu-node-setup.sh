#!/usr/bin/env bash
# Runs once on first boot (gpu-node-setup.service), then reboots so the driver loads.
# Installs: NVIDIA open server driver, branch NVIDIA_DRIVER_BRANCH (default 615, the branch verified on the
#           RTX 5070 Ti in Oct 2026); falls back to the newest >= 570 if that branch is no longer in apt.
#           Set NVIDIA_DRIVER_BRANCH=latest to always take the newest.
#           + NVIDIA Container Toolkit (k3s picks up the nvidia runtime automatically when it's installed later).
# Log: /var/log/gpu-node-setup.log    Re-run: sudo rm /var/lib/gpu-node-setup.done && sudo systemctl start gpu-node-setup
set -euo pipefail
exec > >(tee -a /var/log/gpu-node-setup.log) 2>&1
echo "=== gpu-node-setup start $(date -Is)"
export DEBIAN_FRONTEND=noninteractive

for i in $(seq 1 60); do
  getent hosts archive.ubuntu.com >/dev/null && break
  echo "waiting for network ($i)..."; sleep 5
done

apt-get update
apt-get -y full-upgrade
apt-get -y install ubuntu-drivers-common curl gnupg

# Driver branch: pinned for reproducible rebuilds, newest >= 570 (Blackwell minimum) as fallback
NVIDIA_DRIVER_BRANCH="${NVIDIA_DRIVER_BRANCH:-615}"
newest=$(apt-cache search --names-only '^nvidia-driver-[0-9]+-server-open$' \
      | awk '{print $1}' | sed -E 's/nvidia-driver-([0-9]+)-server-open/\1/' | sort -n | tail -1)
if [ "$NVIDIA_DRIVER_BRANCH" != "latest" ] && apt-cache show "nvidia-driver-${NVIDIA_DRIVER_BRANCH}-server-open" >/dev/null 2>&1; then
  ver="$NVIDIA_DRIVER_BRANCH"
else
  [ "$NVIDIA_DRIVER_BRANCH" != "latest" ] && echo "WARNING: branch $NVIDIA_DRIVER_BRANCH not in apt, using newest ($newest)"
  ver="$newest"
fi
if [ -z "$ver" ] || [ "$ver" -lt 570 ]; then
  echo "ERROR: no nvidia-driver >=570 server-open in apt (found '${ver:-none}')"; exit 1
fi
echo "Installing NVIDIA driver $ver (server, open kernel modules)"
# Prefer Ubuntu's prebuilt signed modules (works with Secure Boot); fall back to the DKMS package.
ubuntu-drivers install --gpgpu "nvidia:${ver}-server-open" || apt-get -y install "nvidia-driver-${ver}-server-open"
apt-get -y install "nvidia-utils-${ver}-server"

# NVIDIA Container Toolkit (official repo)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update
apt-get -y install nvidia-container-toolkit

# Keep the GPU initialised between jobs (faster pod start, stable clocks)
systemctl enable nvidia-persistenced 2>/dev/null || true

touch /var/lib/gpu-node-setup.done
echo "=== gpu-node-setup done $(date -Is); rebooting to load the driver"
systemctl reboot
