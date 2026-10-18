# gpu-node-bootstrap

Turn a spare PC with an NVIDIA GPU into a headless Ubuntu Server node in an existing k3s cluster, with the GPU schedulable from Kubernetes.

1. **Install:** Ubuntu Server 24.04 LTS + SSH + NVIDIA driver + NVIDIA Container Toolkit. Nothing else.
2. **Join:** k3s agent labelled `nvidia.com/gpu.present=true`, plus the cluster-side `RuntimeClass` and NVIDIA device plugin,
   so pods can request `nvidia.com/gpu: 1`.

## How it works

```
Windows (old OS)                    Ubuntu installer                 Ubuntu, first boot
──────────────────                  ────────────────                 ──────────────────
make-installer-partition.ps1  ──►   autoinstall/user-data      ──►   firstboot/gpu-node-setup.sh
 • carve 6 GB FAT32 partition        • asks "Continue? yes/no"        • NVIDIA driver (open, >= 570)
 • unpack Ubuntu ISO onto it         • you type keyboard + user       • NVIDIA Container Toolkit
 • add AUTOINSTALL boot entry        • wipes ONLY the target SSD      • reboot, never runs again
                                     • installs Ubuntu + SSH

GPU node                                     k3s server (cluster side)
────────                                     ─────────────────────────
k3s/join-agent.sh                      ──►   kubectl apply -f k3s/cluster/
 • checks nvidia-smi + container runtime      • RuntimeClass nvidia
 • installs k3s agent, GPU label               • NVIDIA device plugin (GPU nodes only)
 • confirms k3s found the nvidia runtime      • test pod: nvidia-smi via Kubernetes
```

No USB stick needed: the installer boots from a small partition on a **different** disk than the one being wiped.
If you do have a USB stick, the same `autoinstall/` + `firstboot/` files work from it too (see the walkthrough).

## What gets installed

**During the install** ([autoinstall/user-data](autoinstall/user-data))

| Item | Why |
|---|---|
| Ubuntu Server 24.04 LTS, no desktop | Base OS, uses the whole target SSD |
| OpenSSH server (password login on) | Manage it from other machines |
| All available updates | Security patches from the start |
| `curl`, `gnupg` | Needed by the first-boot script to add NVIDIA's apt repo |
| `pciutils` | `lspci` — check the GPU is detected |
| `htop` | Process monitor (optional) |
| `ntfs-3g` | Read old Windows NTFS drives (optional) |
| first-boot script + one-shot systemd unit | Runs the GPU setup below once |

**On first boot** ([firstboot/gpu-node-setup.sh](firstboot/gpu-node-setup.sh))

| Item | Why |
|---|---|
| NVIDIA driver, newest `-server-open` >= 570 | Required for RTX 50xx (Blackwell); also drives 20xx/30xx/40xx |
| `nvidia-smi` (nvidia-utils) | Check the GPU works |
| NVIDIA Container Toolkit | Lets containers use the GPU; k3s detects it automatically |
| `nvidia-persistenced` enabled | Keeps the GPU initialised between jobs (optional) |
| one reboot | Loads the driver |

**Not installed:** Docker, a desktop, the CUDA toolkit (containers bring their own CUDA). k3s comes in the join step.

**When joining** ([k3s/join-agent.sh](k3s/join-agent.sh) on the node, [k3s/cluster/](k3s/cluster/) on the cluster)

| Item | Why |
|---|---|
| k3s agent (official `get.k3s.io` installer) | Joins the existing cluster; URL and token passed at run time, never stored in the repo |
| node label `nvidia.com/gpu.present=true` | Lets GPU-only DaemonSets and workloads target the node |
| `RuntimeClass nvidia` | Pods that set `runtimeClassName: nvidia` get the GPU; k3s keeps `runc` as the default |
| NVIDIA k8s-device-plugin v0.20.1 | Advertises `nvidia.com/gpu` capacity on the node |
| `gpu-test` pod (`k3s/cluster/test/`) | End-to-end check: runs `nvidia-smi` in a CUDA 12.8 container |

**Defaults you may want to change** in `autoinstall/user-data`: timezone `America/Toronto`, locale `en_US.UTF-8`,
SSH password login allowed (turn off once you've added a key).

## Safety

- The target disk is matched by **serial number** (and must be an SSD). If it isn't found, the install stops — it never falls back to another disk.
- The installer asks **"Continue with autoinstall? (yes|no)"** before writing anything.
- The Windows script refuses to run if the installer disk and target disk are the same, or if the drive you shrink isn't on the disk you named.

## Quick start

1. Set the BIOS up: [docs/bios-settings.md](docs/bios-settings.md)
2. Back up anything on the target disk. It will be erased.
3. From an **Administrator** PowerShell on the old Windows install:
   ```powershell
   Get-PhysicalDisk | Select-Object DeviceId, FriendlyName, MediaType, SerialNumber
   .\windows\make-installer-partition.ps1 -Iso <path-to-ubuntu-24.04.x-live-server-amd64.iso> `
       -ShrinkDrive D -InstallerDiskSerial <disk-that-keeps-data> -TargetDiskSerial <ssd-to-wipe>
   ```
4. Plug in Ethernet, reboot, boot menu key (F8 on ASUS) → `UEFI: <installer disk>, Partition N`.
5. Follow [docs/install-walkthrough.md](docs/install-walkthrough.md). About 30 minutes, mostly waiting.
6. Log in and run `nvidia-smi`.
7. Join the cluster: [docs/join-cluster.md](docs/join-cluster.md). On the node:
   ```bash
   sudo INSTALL_K3S_VERSION=<server's version> bash join-agent.sh --url https://<server-ip>:6443 --token-file /root/k3s-token
   ```
   then on the server:
   ```bash
   kubectl apply -f k3s/cluster/
   kubectl apply -f k3s/cluster/test/gpu-test-pod.yaml && kubectl logs gpu-test
   ```

## Layout

```
gpu-node-bootstrap/
├── README.md                         this file
├── autoinstall/
│   ├── user-data                     Ubuntu autoinstall config (template: __TARGET_DISK_SERIAL__)
│   └── meta-data                     required by cloud-init's nocloud source
├── firstboot/
│   ├── gpu-node-setup.sh             NVIDIA driver + container toolkit, runs once
│   └── gpu-node-setup.service        systemd one-shot unit that runs it
├── windows/
│   └── make-installer-partition.ps1  no-USB installer builder (run from the old Windows)
├── k3s/
│   ├── join-agent.sh                 run on the node: join k3s as a GPU agent
│   └── cluster/                      apply from the cluster side: kubectl apply -f k3s/cluster/
│       ├── 00-runtimeclass-nvidia.yaml
│       ├── 10-nvidia-device-plugin.yaml
│       └── test/
│           └── gpu-test-pod.yaml     one-shot nvidia-smi pod (applied separately)
├── docs/
│   ├── install-walkthrough.md        step by step, including what you type
│   ├── bios-settings.md              firmware settings and why
│   └── join-cluster.md               token, join script, manifests, verify, troubleshooting
└── hosts/
    └── tuf-x570-gpu1.md              per-machine notes: hardware, serials, history
```

## Roadmap

- [x] `k3s/join-agent.sh` — join the node to the cluster with GPU labels
- [x] cluster side: `RuntimeClass nvidia` + NVIDIA device plugin manifests, test pod
