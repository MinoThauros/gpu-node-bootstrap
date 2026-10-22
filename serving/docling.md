# Document parsing with Docling (GPU, Docker)

Runs `docling-serve`, an HTTP API that converts PDFs and Office files into structured documents (Markdown and a typed JSON tree, optionally with equations as LaTeX). Used for batch ingestion, not kept running: it shares the GPU with vLLM. Verified on `<gpu-host>` (RTX 5070 Ti 16 GB, driver 615.71.09) on 2026-10-22.

## Free the GPU

vLLM reserves 90% of the GPU's memory, so stop it first:

```bash
sudo docker stop vllm
nvidia-smi            # Memory-Usage should drop to a few MiB, no processes listed
```

## Run

```bash
sudo docker run -d --name docling --gpus all \
  -p <tailscale-ip>:5001:5001 \
  -e DOCLING_SERVE_ENABLE_UI=1 \
  -e DOCLING_SERVE_RESULT_REMOVAL_DELAY=3600 \
  -e DOCLING_SERVE_MAX_SYNC_WAIT=600 \
  quay.io/docling-project/docling-serve-cu128:v1.37.0
```

| Flag | Why |
|---|---|
| `--gpus all` | Layout and formula models run on the GPU (the logs say `Accelerator device: 'cuda:0'` once a conversion starts) |
| `-p <tailscale-ip>:5001:5001` | Tailscale address only, same as vLLM |
| `DOCLING_SERVE_ENABLE_UI=1` | Web playground at `/ui`; API docs at `/docs` |
| `DOCLING_SERVE_RESULT_REMOVAL_DELAY=3600` | Keep finished results for an hour (default 300 s) |
| `DOCLING_SERVE_MAX_SYNC_WAIT=600` | The synchronous endpoint waits up to 10 minutes (default 120 s) |
| `docling-serve-cu128:v1.37.0` | CUDA 12.8 build, which supports Blackwell. CUDA images have no `latest` tag |

The image ships the layout and OCR models but **not** the formula model. Formula enrichment fails with "Model 'ibm-granite/granite-docling-258M' not found in artifacts_path" until it's downloaded into the container:

```bash
sudo docker exec docling docling-tools models download-hf-repo ibm-granite/granite-docling-258M
```

It lives in the container's filesystem: kept across `stop`/`start`, lost on `rm`.

## Use (from any tailnet device)

```bash
# Whole document, async
curl -sS -X POST "http://<gpu-host>:5001/v1/convert/file/async" \
  -F "files=@book.pdf;type=application/pdf" \
  -F "to_formats=md" -F "to_formats=json" -F "do_ocr=false" -F "do_formula_enrichment=true"
curl -sS http://<gpu-host>:5001/v1/status/poll/TASK_ID      # pending → started → success | failure
curl -sS http://<gpu-host>:5001/v1/result/TASK_ID -o book.json

# A page range, synchronous (the pair is sent by repeating the field)
curl -sS -X POST "http://<gpu-host>:5001/v1/convert/file" \
  -F "files=@book.pdf;type=application/pdf" -F "page_range=20" -F "page_range=30" -F "to_formats=md" -o pages.json
```

- Docling writes no files. Results stay in memory, can be downloaded **once**, and expire after the removal delay.
- `do_ocr=false` for PDFs that already have a text layer: faster, and the original text is kept.
- `do_formula_enrichment=true` converts equations to LaTeX. It's the slowest part, and it logs `TailRepetitionStopper` lines when it cuts off a formula that started repeating filler: expected.

## Restore

```bash
sudo docker stop docling && sudo docker start vllm
```

## Notes

- **Resource use (2026-10-22, full 417-page book):** 3.7 GB of GPU memory, ~25% GPU utilization. Part of each page is CPU work, so the GPU waits between batches; `DOCLING_PERF_PAGE_BATCH_SIZE` (default 4) is the knob to try.
- **CPU-only alternative:** `docling-serve-cpu` runs on a Mac (arm64), at ~3.5 s per prose page on an M1 with OCR and formulas off. It needs a lot of memory: a whole-book job hit Docker Desktop's 7.75 GiB cap and was killed (`OOMKilled`, exit 137). Use page ranges there.
- **Second GPU:** Docling fits in 8 GB, so the spare RTX 2080 could run it permanently next to vLLM, each container pinned to its own card with `--gpus '"device=N"'`. See the journal.
