# Serving an LLM with vLLM (standalone, Docker)

Runs an OpenAI-compatible API on the node's GPU, reachable only over Tailscale. Verified on `<gpu-host>` (RTX 5070 Ti 16 GB, driver 615.71.09) on 2026-10-19.

## One-time setup

The first-boot script does this. On a node built before Docker was added to it:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
sudo docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi   # must show the GPU
```

## Run

```bash
TS_IP=$(tailscale ip -4)

sudo docker run -d --name vllm --gpus all --ipc=host \
  -p "$TS_IP":8000:8000 \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  vllm/vllm-openai@sha256:befccf0e7e4089aa23926bb6f887a85c0d46c2a99e6de5c5ffdf5cb7957c5b34 \
  --model Qwen/Qwen3-8B-FP8 --max-model-len 8192 --gpu-memory-utilization 0.90
```

The image is pinned by digest (it was `vllm/vllm-openai:latest` on 2026-10-19). RTX 50 cards need a recent vLLM build, so if you move to a newer image, re-test.

| Flag | Why |
|---|---|
| `--gpus all` | Gives the container the GPU (the NVIDIA runtime injects the device files and driver libraries) |
| `--ipc=host` | PyTorch needs more shared memory than Docker's default |
| `-p "$TS_IP":8000:8000` | Publishes the API **only on the Tailscale address**: reachable from tailnet devices, not from the home LAN or the internet |
| `-v ~/.cache/huggingface:...` | Keeps downloaded weights on the host, so restarts don't re-download ~9 GB |
| `--model Qwen/Qwen3-8B-FP8` | Hugging Face repo ID; vLLM downloads `config.json`, tokenizer and `.safetensors` weights at startup. A local folder path also works |
| `--max-model-len 8192` | Max tokens per conversation; caps per-request KV cache |
| `--gpu-memory-utilization 0.90` | Share of the 16 GB for weights + KV cache |

First start takes 10–30 minutes (image ~10 GB + model ~9 GB). Watch with `sudo docker logs -f vllm`; ready when it prints `Uvicorn running on http://0.0.0.0:8000`.

## Test (from any tailnet device)

```bash
curl -i http://<gpu-host>:8000/health          # 200 OK when ready; connection refused while loading
curl -s http://<gpu-host>:8000/v1/models

curl -s http://<gpu-host>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-8B-FP8",
    "messages": [{"role": "user", "content": "In two sentences, what is a KV cache?"}],
    "max_tokens": 200,
    "chat_template_kwargs": {"enable_thinking": false}
  }' | python3 -m json.tool
```

Other endpoints: `/version`, `/metrics` (Prometheus: running/waiting requests, KV cache usage).

## Notes

- **Qwen3 thinking mode** is on by default (reasoning in `<think>…</think>` before the answer). `"chat_template_kwargs": {"enable_thinking": false}` turns it off per request.
- **Offline / air-gapped:** once the weights are in the cache, add `-e HF_HUB_OFFLINE=1` so vLLM never contacts Hugging Face, then block the container's internet access. Pin the weights with `--revision <commit>` for exact reproducibility.
- **No auth yet:** vLLM accepts any request that reaches it. Access is limited by Tailscale only. Add `--api-key` (key kept out of this repo) before sharing the tailnet. See `docs/journal.md`.
- **Port binding at boot:** the publish address is the Tailscale IP, so the container can only start once `tailscaled` is up. There is no restart policy for now; start it by hand after a reboot.
- **Stop / remove:** `sudo docker stop vllm && sudo docker rm vllm`.
