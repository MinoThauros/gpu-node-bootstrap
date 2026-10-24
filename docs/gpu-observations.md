# GPU behavior observations

How a consumer GPU (RTX 5070 Ti, 16 GB, on `<gpu-host>`) behaves under real workloads: model serving, document conversion, and later fine-tuning. One row per observation, measured, with the interpretation kept separate from the numbers.

## Reading the numbers

| Number (from `nvidia-smi`) | What it measures | Common misreading |
|---|---|---|
| **Memory-Usage** | GPU memory reserved by each process | "Full memory = working hard." vLLM reserves its share (`--gpu-memory-utilization`) at startup and holds it while idle |
| **GPU-Util** | Share of the last sample period during which *any* GPU kernel ran | "19% = using 19% of the cores." It's a share of *time*: 19% means idle ~80% of the time |
| **Pwr: Usage / Cap** | Power draw against the card's limit (300 W) | The best quick proxy for real effort: low watts at high memory = waiting, not computing |
| **Perf (P0–P8)** | Power/clock state; P0–P2 are working states | P1 doesn't mean busy, only ready |

There are no memory limits between processes. Each takes what it asks for, and when the total exceeds 16 GB, whichever process allocates last fails with "CUDA out of memory". Running two workloads together is an arithmetic exercise, done before starting them.

## Observations

| Date | Workload | Setup | GPU memory | Util | Power | Throughput | Notes |
|---|---|---|---|---|---|---|---|
| 2026-10-22 | Docling, *Mathematics for ML* (417 pages), formulas on | Docling alone | ~3.7 GB | ~25% | — | — | Part of each page is CPU work; the GPU waits between page batches |
| 2026-10-22 | Starting Qwen3-VL-4B (vision) for figure descriptions | vLLM, `0.60` util, 8192 context | — | — | — | — | Failed: 0.11 GiB left for the KV cache. Worked with `0.70` util, 4096 context, 4 parallel requests |
| 2026-10-23 | Docling, 3-page test, formulas on | ingest mode (Docling + vision) | — | — | — | 25 s for 3 pages, 11 formulas | All 11 formulas decoded to LaTeX |
| 2026-10-23 | Docling, *Designing Data-Intensive Applications* (491 pages), formulas off, figure descriptions on | ingest mode | — | — | — | **85 s for 491 pages** (~0.17 s/page); 88 figures described | Without formulas the GPU only runs the layout model. 40 of 88 descriptions hit the 300-token cap |
| 2026-10-23 | Docling, *Algorithmic and High-Frequency Trading*, formulas on, figure descriptions on | ingest mode | **14.6 / 16.3 GB**: Docling 4.6 GB, vision model 10.0 GB | **19%** | **57 W / 300 W** | in progress | Memory nearly full, compute mostly idle. Only ~1.7 GB free, so a second Docling worker (~4.6 GB) would not have fit |

## Lessons so far

- **Memory and compute are separate budgets.** A run can exhaust memory while the cores sit idle. Memory decides *what can run together*; compute decides *how fast*.
- **Reserved memory isn't used memory.** vLLM's reservation is mostly space for requests in flight (KV cache). The vision model held 10 GB while describing nothing.
- **Document conversion doesn't saturate this GPU.** Layout analysis is fast (~0.17 s/page). Formula conversion is slow but still leaves the GPU ~80% idle. Likely cause (inference, not confirmed): the formula model generates LaTeX one token at a time for a few formulas, which is limited by memory bandwidth rather than compute; other parts of each page are CPU work.
- **Sequential beats concurrent here.** With the vision model resident, there's no room for a second Docling worker; a queue that converts one document at a time is the safe default.
- **Knobs for next time:** `DOCLING_NUM_THREADS` (CPU threads, if the node has idle cores), `DOCLING_PERF_PAGE_BATCH_SIZE` (needs free GPU memory), the vision model's share (`0.50` would free ~3 GB), and its description cap (300 tokens truncates ~45% of descriptions).

## Capturing an observation

```bash
nvidia-smi
```
One snapshot: memory per process, utilization, power.

```bash
nvidia-smi dmon -s pucm
```
One line per second: power, utilization, clocks, memory. Ctrl-C to stop. Better than single snapshots for workloads that pulse.

```bash
nvidia-smi --query-gpu=timestamp,utilization.gpu,memory.used,power.draw --format=csv -l 5 > gpu-log.csv
```
A CSV sample every 5 seconds for the whole run, for charting afterwards.

```bash
htop
```
CPU per core: shows whether the CPU is the bottleneck while the GPU waits.

```bash
curl -s http://<gpu-host>:8001/metrics | grep -E "num_requests_(running|waiting)"
```
What a vLLM server is doing right now (requests running and queued).
