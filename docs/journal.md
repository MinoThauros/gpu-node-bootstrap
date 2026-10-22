# Journal

What was done, decided and deferred on this node, newest first. The recipe (autoinstall, first-boot script, serving docs) says how to build it; this says what happened and why.

## 2026-10-22: Docling on the GPU

**Done**

- Ran Docling (`docling-serve-cu128:v1.37.0`) on the GPU to convert a 417-page PDF for the RAG lab, with vLLM stopped for the duration. Guide: [../serving/docling.md](../serving/docling.md).
- Formula enrichment needed `ibm-granite/granite-docling-258M`, which the image doesn't ship and won't auto-download; downloaded it into the container with `docling-tools`.

**Findings**

- During the run: 3.7 of 16 GB GPU memory, ~25% utilization (CPU-side work between batches).
- On the Mac's CPU image, a whole-book job was killed by Docker Desktop's 7.75 GiB memory cap. Large documents belong here, or in page ranges.
- vLLM at 90% and Docling don't fit together. Options: stop vLLM during ingestion (current), cap vLLM at ~60–65%, or a second GPU.

**Idea: the spare RTX 2080 as a second GPU**

8 GB, Turing (compute capability 7.5): no FP8 or BF16, so weak for modern quantized LLMs, but enough for Docling, embedding and reranker models. One driver serves both cards; each container gets its own with `--gpus '"device=N"'`. To check first: physical fit next to the 5070 Ti, the second slot's lanes, PCIe power cables (no daisy-chained pigtails).

## 2026-10-20: Open WebUI, tool calling

**Done**

- Open WebUI in front of vLLM with Docker Compose: [../serving/compose.yaml](../serving/compose.yaml), on the node at `~/serving/`. Published on the Tailscale address, port 3000; chats and accounts live in the `serving_open-webui` volume.
- vLLM recreated with `--enable-auto-tool-choice --tool-call-parser hermes`: Open WebUI sends tools with every chat, and vLLM rejected those requests without a parser.

**Findings**

- `docker attach` connects the terminal to the container's main process, so Ctrl-C there stops vLLM. Use `docker logs -f` to watch.
- After a vLLM restart, Open WebUI can keep an empty model list ("Model '' was not found"): reload the page and start a new chat.

## 2026-10-19: Tailscale, Docker, vLLM serving

**Done**

- Tailscale: the server was already signed in (`<gpu-host>`, `<tailscale-ip>`, `tailscaled` enabled at boot). Installed on the MacBook Air and signed in to the same account.
- SSH from the Mac over Tailscale from outside home (`ssh herimino@<gpu-host>`). The host key matched the one already trusted on the LAN address.
- Docker installed, NVIDIA runtime configured; `nvidia-smi` works inside a CUDA container.
- vLLM serving `Qwen/Qwen3-8B-FP8` on the Tailscale address, port 8000. `/health` returns 200 from the Mac; a chat completion works. Run command in [../serving/vllm.md](../serving/vllm.md).
- Docker + NVIDIA runtime setup added to `firstboot/gpu-node-setup.sh`, so a rebuild has them.

**Findings**

- The home router runs OpenWrt 14.07 "Barrier Breaker" (2014) with MiniUPnPd 1.6, long out of security updates.
- UPnP / NAT-PMP is on: Tailscale opened UDP 41641 to the server automatically. Low risk (only WireGuard answers, and it ignores unauthenticated packets), but any device at home can open router ports.
- The NAT is the "easy" kind (`MappingVariesByDestIP: false`), so direct connections should survive turning UPnP off.

**Deferred: security hardening**

Reason: the server is about to move (Montreal) and isn't in its permanent place. These steps can lock out remote access if done before the new network is confirmed. Do them after the move, with a keyboard and monitor available as a fallback.

- [ ] SSH key login (ed25519 key from the Mac, `ssh-copy-id`)
- [ ] Host firewall (`ufw`): deny inbound, allow SSH and 8000 only on `tailscale0`
- [ ] SSH: password login and root login off
- [ ] Tailscale ACLs: only the Mac may reach this node, on 22 and 8000
- [ ] vLLM `--api-key`
- [ ] Turn off UPnP on whatever router the node ends up behind

**Before the move**

- [ ] Tailscale admin console → Machines → `<gpu-host>` → Disable key expiry (an expired key drops the node off the tailnet)
- [ ] BIOS: Restore AC Power Loss → Power On (with Last State, a node shut down cleanly stays off when plugged in)
- [ ] Transport the GPU safely: PC on its side, or the card removed and boxed (it came unseated twice)
- [ ] At the destination: wired Ethernet with normal internet (no captive portal); Wi-Fi isn't configured

**Future goal: zero-touch provisioning**

The first-boot script should end with the node joined to the cluster: install the k3s agent with the server URL and a join token, then label and taint the node. The token is a secret, so it can't live in this repo; decide where it comes from when the cluster exists.

**Tailscale isn't in the recipe yet.** It was installed and signed in by hand on Oct 18. Automating it means `tailscale up --auth-key=…` in the first-boot script, and the auth key is a secret that can't live in this repo. Same problem as the k3s join token. Likely approach: a one-time, short-lived, tagged auth key placed on the installer partition at build time (outside Git), used once on first boot, then deleted.

## 2026-10-18: install

- BIOS 1407 → 5021; CSM off, Above 4G Decoding on, Re-Size BAR Auto, SVM on, D.O.C.P. 3200, Restore AC Power Loss → Last State.
- RTX 2080 swapped for the RTX 5070 Ti. A white VGA Q-LED twice: the card wasn't fully seated, and once a PCIe 6+2 plug was half-connected. Fixed by seating it with the PC on its side and screwing the bracket down.
- Installer: black screen, then "out of range". `nomodeset` gave a black screen; forcing a resolution gave "out of range". What worked: `gfxpayload=keep` + `modprobe.blacklist=nouveau nouveau.modeset=0`. Now in the GRUB entries and on the installer partition (`sdb2`).
- Installed: Ubuntu 24.04.5, kernel 7.0.0-38 (HWE), NVIDIA 615.71.09 server-open, container toolkit 1.20.1. Details in [../hosts/tuf-x570-gpu1.md](../hosts/tuf-x570-gpu1.md).
