# Join the GPU node to k3s

Starting point: the node is installed, `nvidia-smi` works ([install-walkthrough.md](install-walkthrough.md)),
and you have an existing k3s server. At the end, the node is a k3s agent that advertises `nvidia.com/gpu: 1`
and a test pod has run `nvidia-smi` through Kubernetes.

Nothing here runs on Windows. You use three places:

| Where | What you run |
|---|---|
| **k3s server** | read the join token; `kubectl` (or `sudo k3s kubectl`) for the cluster-side steps |
| **GPU node** | `k3s/join-agent.sh` |
| any machine with this repo | `scp` the files over |

In the commands below, replace `<server-ip>`, `<user>`, `<gpu-node>` with yours.

## 1. Check the network

The node must reach the server, and the nodes must reach each other:

| From → to | Port | For |
|---|---|---|
| GPU node → server | TCP 6443 | k3s API / join |
| all nodes ↔ all nodes | UDP 8472 | flannel VXLAN (pod network) |
| server → GPU node | TCP 10250 | kubelet: `kubectl logs`, `exec` |

Ubuntu's `ufw` is off by default. If the server has a firewall, open these.

## 2. Get the server's URL, token and version

On the **k3s server**:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token   # the join token, a long K10...::server:... string
kubectl get nodes                                 # VERSION column, e.g. v1.33.4+k3s1
hostname -I                                       # server IP -> K3S_URL=https://<server-ip>:6443
```

The token grants full cluster join rights: don't commit it, paste it in chats, or leave it in shell history.

Use the server's version for the agent (`INSTALL_K3S_VERSION` below). An agent newer than the server is unsupported.

## 3. Copy the files over

From a machine that has this repo (PowerShell or bash, both have `scp`):

```bash
scp k3s/join-agent.sh <user>@<gpu-node>:~/
scp -r k3s/cluster <user>@<server-ip>:~/gpu-cluster
```

## 4. Run the join script on the GPU node

SSH in, put the token in a root-only file (keeps it out of `ps` and shell history), then join:

```bash
ssh <user>@<gpu-node>
sudo install -m 600 /dev/null /root/k3s-token
sudo nano /root/k3s-token            # paste the token, save
sudo INSTALL_K3S_VERSION=v1.33.4+k3s1 bash ~/join-agent.sh \
    --url https://<server-ip>:6443 --token-file /root/k3s-token
```

`K3S_URL` / `K3S_TOKEN` env vars or `--token <token>` work too. Run `bash ~/join-agent.sh --help` for all options;
arguments after `--` go to `k3s agent` (e.g. `-- --node-name gpu-node-1`).

What it does, in order (stops at the first failure):

1. `nvidia-smi -L` lists the GPU and `nvidia-container-runtime` is on the PATH (from `firstboot/gpu-node-setup.sh`).
2. `https://<server-ip>:6443/ping` answers.
3. Installs the agent with `curl -sfL https://get.k3s.io | ... sh -s - agent --node-label nvidia.com/gpu.present=true`.
   Skipped if `k3s-agent` is already running against the same URL (`--reinstall` forces it).
4. Waits for `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` and checks it has a `nvidia` runtime.
   k3s adds it by itself when it finds the NVIDIA Container Toolkit; there is nothing to configure.

Expected end of the output: `OK: nvidia runtime present in ...config.toml` and a `Done.` message.
Once it worked, delete the token file: `sudo rm /root/k3s-token`.

## 5. Apply the cluster manifests

On the **k3s server** (or anywhere `kubectl` points at the cluster):

```bash
kubectl apply -f ~/gpu-cluster/
```

This applies (not the `test/` subfolder):

| File | What |
|---|---|
| `00-runtimeclass-nvidia.yaml` | `RuntimeClass nvidia` → containerd handler `nvidia`. Recent k3s servers create it themselves; re-applying is harmless. |
| `10-nvidia-device-plugin.yaml` | NVIDIA device plugin **v0.20.1** DaemonSet in `kube-system`, only on nodes labelled `nvidia.com/gpu.present=true`, run with `runtimeClassName: nvidia` |

k3s keeps `runc` as the default runtime, so only pods that ask for `runtimeClassName: nvidia` get the GPU
driver libraries mounted in. That includes the device plugin itself and every GPU workload you write.

## 6. Verify

```bash
kubectl get nodes -L nvidia.com/gpu.present
# NAME         STATUS   ROLES    AGE   VERSION        GPU.PRESENT
# gpu-node-1   Ready    <none>   3m    v1.33.4+k3s1   true

kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds -o wide   # Running, on the GPU node

kubectl describe node gpu-node-1 | grep -A8 -E '^(Capacity|Allocatable)'
# Capacity:
#   ...
#   nvidia.com/gpu:     1
```

Then the end-to-end test (a pod that asks for 1 GPU and runs `nvidia-smi` from `nvidia/cuda:12.8.2-base-ubuntu24.04`):

```bash
kubectl apply -f ~/gpu-cluster/test/gpu-test-pod.yaml
kubectl get pod gpu-test -w          # Pending -> ContainerCreating -> Completed (image pull ~100 MB)
kubectl logs gpu-test                # the nvidia-smi table, showing the RTX 5070 Ti
kubectl delete pod gpu-test
```

Your own GPU pods need the same two things as the test pod:

```yaml
spec:
  runtimeClassName: nvidia
  containers:
    - resources:
        limits:
          nvidia.com/gpu: 1
```

## Optional: keep non-GPU pods off the node

By default the scheduler can put any pod on the GPU node. To reserve it for GPU work, taint it:

```bash
kubectl taint nodes gpu-node-1 nvidia.com/gpu=present:NoSchedule
```

Then only pods that tolerate the taint run there. The device plugin and the test pod already do; add this to your GPU workloads:

```yaml
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
```

Side effect: DaemonSets without that toleration (e.g. ServiceLB `svclb-*` pods, log or monitoring agents) stop running
on the node. Remove the taint with `kubectl taint nodes gpu-node-1 nvidia.com/gpu-`.
Not applied by default.

## Troubleshooting

| Symptom | Check / fix |
|---|---|
| Script: `nvidia-smi failed` | Driver not loaded. `sudo tail /var/log/gpu-node-setup.log`; reboot; see [install-walkthrough.md](install-walkthrough.md). With Secure Boot on, a DKMS-built (unsigned) module won't load: `mokutil --sb-state`. |
| Script: `cannot reach .../ping` | Wrong IP/port, server firewall on TCP 6443, or no route. Try `curl -k https://<server-ip>:6443/ping` from the node. |
| Agent never becomes Ready | `sudo journalctl -u k3s-agent -f` on the node. `401 Unauthorized` → wrong token. `Node password rejected` → a node with this hostname joined before: `kubectl delete node <name>` and `kubectl -n kube-system delete secret <name>.node-password.k3s` on the server, then `--reinstall`. |
| Script: `did not register the nvidia runtime` | `sudo which nvidia-container-runtime` must succeed. Then `sudo systemctl restart k3s-agent` and re-run the script. |
| Node shows no `GPU.PRESENT` | The label is only applied at first registration. Add it: `kubectl label node <name> nvidia.com/gpu.present=true`. |
| Device plugin pod not created | Node lacks the label (above), or the RuntimeClass is missing: `kubectl get runtimeclass nvidia`. |
| Device plugin logs `could not load NVML library` / `Incompatible strategy` | It is running without the NVIDIA runtime: check `runtimeClassName: nvidia` in the DaemonSet and the runtime in the agent's `config.toml`. `kubectl -n kube-system logs -l name=nvidia-device-plugin-ds`. |
| Node has no `nvidia.com/gpu` capacity | Device plugin not Running on that node; see its logs. |
| Test pod `Pending`, `Insufficient nvidia.com/gpu` | Device plugin not ready, or another pod already holds the GPU (one pod per GPU, no sharing by default). |
| Test pod fails with `unsatisfied condition: cuda>=12.8` | Driver too old for the image. `nvidia-smi` on the node shows the max CUDA version; needs driver >= 570. |
| Test pod `ImagePullBackOff` | Node has no internet / DNS; `sudo k3s crictl pull nvidia/cuda:12.8.2-base-ubuntu24.04` on the node shows the error. |

Start over on the node: `sudo /usr/local/bin/k3s-agent-uninstall.sh`, then `kubectl delete node <name>` on the server.
