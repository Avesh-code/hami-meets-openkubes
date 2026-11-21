# 02 — GPU Slicing: The Ways to Share a GPU

> Every common way to share one GPU between several pods: time-slicing, MPS, MIG, NVIDIA vGPU and HAMi. How each works, and where each falls short.

---

## 1. Two families of sharing

- **Temporal sharing:** pods **take turns** on the whole GPU (time-slicing)
- **Spatial sharing:** pods each get a **portion** of the GPU at the same time (MPS, MIG, HAMi)

---

## 2. Time-slicing (NVIDIA device plugin)

**How:** the admin sets a number of **replicas** per GPU. One GPU with 4 replicas is advertised as `nvidia.com/gpu: 4`. The pods' processes take turns on the GPU, and the GPU gives an equal share of time to every process.

```yaml
# device plugin config
sharing:
  timeSlicing:
    resources:
      - name: nvidia.com/gpu
        replicas: 4
```

| ✅ Good | ❌ Falls short |
|---|---|
| Works on **any** NVIDIA GPU | **No memory isolation:** every pod sees the full card, and one pod can use all the memory |
| Easy to enable | **No fault isolation:** NVIDIA's docs state there's no memory or fault isolation between replicas |
| | Asking for 2 replicas does **not** give a pod more compute |
| | Scheduler doesn't know how much memory each pod needs |

---

## 3. MPS: Multi-Process Service (NVIDIA)

**How:** a control daemon lets several processes run **at the same time** on one GPU, with a cap on memory (pinned device memory limit) and compute (active thread %) for each process.

| ✅ Good | ❌ Falls short |
|---|---|
| True concurrent execution, good throughput | In the k8s device plugin, MPS support is **experimental** |
| Memory and compute limits for each process | The plugin splits the card into **equal fractions** only (e.g. 4 × ¼). No per-pod sizes. |
| Works on most modern NVIDIA GPUs | **Shared fault domain:** a fatal fault in one client can affect the others |

---

## 4. MIG: Multi-Instance GPU (hardware partitioning)

**How:** the GPU is physically divided into separate **GPU instances**, each with its own SMs, memory, cache and engines. MIG is supported only on specific GPUs, not on every Ampere-or-later card: **up to 7 instances** on A100, H100, H200 and B200, fewer on A30 (4) and RTX PRO Blackwell (4 or 2).

```
H100 80GB with MIG:   [1g.10gb][1g.10gb][1g.10gb][1g.10gb][1g.10gb][1g.10gb][1g.10gb]
                  or: [   3g.40gb   ][  2g.20gb  ][  2g.20gb  ]   … fixed profiles only
```

| ✅ Good | ❌ Falls short |
|---|---|
| **Strongest isolation:** memory, cache and compute separated in hardware | **Only certain GPUs.** Many common cards (T4, A10, L4, L40S, consumer GPUs) **don't support MIG** |
| Predictable performance (QoS) | **Fixed profile shapes** (e.g. 1g.10gb, 3g.40gb). You can't ask for "6 GB" |
| Good for untrusted multi-tenancy | **Repartitioning** means draining the GPU, so it's hard to adapt to changing demand |
| | Maximum of 7 slices per card |

---

## 5. NVIDIA vGPU (for virtual machines)

A licensed product that shares GPUs between **virtual machines** at the hypervisor level. It's mentioned for completeness, but it's aimed at VM platforms rather than Kubernetes pod scheduling.

---

## 6. HAMi (software virtualization + GPU-aware scheduling)

**How:** HAMi's device plugin advertises each GPU as N virtual GPUs. Its **scheduler** places pods using real memory and compute numbers. **HAMi-core**, inside each container, intercepts CUDA calls and **enforces each pod's memory cap** (plus a compute limit).

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
    nvidia.com/gpumem: 6000      # any size you want, in MiB
    nvidia.com/gpucores: 30      # % of compute
```

| ✅ Good | ❌ Falls short |
|---|---|
| **Any size**: 3 GB, 6 GB, 25%. Not fixed profiles. | Isolation is in **software**: good for cooperating teams, but **not** a security boundary like MIG |
| Works on **any** NVIDIA GPU (and other vendors) | Compute limit is throttled in software, not hard partitioning |
| **Memory hard cap per pod**: going over → OOM in **that pod only** | One more component to operate (scheduler + webhook + device plugin) |
| **GPU-aware scheduler**: binpack / spread, per-namespace quotas | |
| No app changes; whole-GPU requests still work | |

More on HAMi in [03 — HAMi & architecture](03-hami-and-architecture.md).

---

## 7. Side-by-side comparison

| | Time-slicing | MPS | MIG | **HAMi** |
|---|---|---|---|---|
| Sharing type | Temporal (take turns) | Spatial (concurrent) | Spatial (hardware) | Spatial (software) |
| GPUs supported | Any NVIDIA | Most NVIDIA | A100, A30, H100, H200, B200, RTX PRO Blackwell | Any NVIDIA (+ other vendors) |
| Memory isolation | ❌ None | ✅ Per-process limit | ✅ Hardware | ✅ Per-pod hard cap |
| Fault isolation | ❌ | ⚠️ Shared fault domain | ✅ | ⚠️ Software (process-level) |
| Slice sizes | Equal replicas | Equal fractions (k8s plugin) | Fixed profiles | **Any size (MiB or %)** |
| Max slices per GPU | Configurable | Limited | 7 | Configurable (`deviceSplitCount`) |
| Scheduler knows memory needs | ❌ | ❌ | Per profile | ✅ |
| Namespace GPU-memory quota | ❌ | ❌ | Per profile count | ✅ |
| Change sizes without draining | ✅ | ✅ | ❌ | ✅ |
| Best for | Bursty dev/notebooks, trusted | Throughput of many small jobs | Strict isolation, untrusted tenants | Mixed workloads, flexible sizes, many teams |

### The honest summary

> **Time-slicing** shares a GPU **without protection**.
> **MPS** shares it **concurrently**, but in equal slices and with a shared fault domain.
> **MIG** shares it **safely**, but only on certain cards and only in fixed shapes.
> **HAMi** shares it **flexibly**, with any size on any card and a scheduler that understands memory, at the cost of software-level (not hardware-level) isolation.
>
> They aren't strict competitors. HAMi can run on MIG-capable cards too, and MIG remains the choice when you need hardware isolation.

**Next:** [03 — HAMi & architecture](03-hami-and-architecture.md)

---

*Sources: NVIDIA GPU Operator docs (time-slicing), NVIDIA MIG User Guide (supported GPUs and profiles), NVIDIA k8s-device-plugin (MPS, experimental), HAMi docs.*
