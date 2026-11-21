# 07 — Conclusion

---

## 1. Back to the problem

I had **4 GPUs** and needed **10 pods**. Kubernetes hands out GPUs whole, so 4 pods ran and 6 sat in `Pending` while the cards were mostly empty. That was never a hardware shortage. It was a **scheduling granularity problem**.

With HAMi, the same node advertised **40 vGPUs**, and all 10 replicas ran, each capped at its own memory slice. The app didn't change. The YAML gained **one line**: `nvidia.com/gpumem`.

---

## 2. What the cases showed

| # | Case | Expected | Observed |
|---|---|---|---|
| 0 | Before vs after HAMi | capacity 4 → 40; 4/10 → 10/10 Running | ⏳ |
| 1 | Fractional sharing | 15 pods on 4 GPUs, each sees 5120 MiB | ⏳ |
| 2 | Whole GPU | full card visible, no sharing | ⏳ |
| 3 | Multi-GPU, whole | 2 distinct UUIDs, full memory | ⏳ |
| 4 | Multi-GPU, sliced | 2 UUIDs, 20480 MiB each | ⏳ |
| 5 | OOM enforcement | capped pod OOMs just below 5120 MiB; control succeeds | OOM at ⏳ MiB |
| 6 | Multi-tenant | team-a OOMs; team-b heartbeat uninterrupted | team-a OOM at 4608 MiB (HAMi-core: `5544869888 / 5368709120`); heartbeat ⏳ |
| 7 | Over quota | over-quota pod is refused | Rejected at creation: `admission webhook "vgpu.hami.io" denied the request: exceeding resource quota for device NVIDIA` |
| 8 | binpack vs spread | spread 2,2,2,2 → 2-GPU job Pending; binpack 8,0,0,0 → it runs | ⏳ |

Together, they cover the four things a GPU-sharing layer has to get right:

- **Allocation** (Cases 0–4): any slice size, and whole or multiple GPUs when needed.
- **Isolation** (Cases 5–6): the cap is enforced, and a noisy pod hurts only itself.
- **Multi-tenancy** (Case 7): namespaces can't take more than their quota.
- **Scheduling** (Case 8): the placement policy decides whether big jobs still fit.

---

## 3. Running HAMi well

| Tip | Why |
|---|---|
| **Always set `gpumem`** (or `gpumem-percentage`) on pods meant to share | A request with only `nvidia.com/gpu: 1` still means "the whole card" |
| **Use `gpumem-percentage` on mixed hardware** | `25` gives 25% of *whichever card* the pod lands on |
| **binpack for small pods, or separate pools** | A card with even one slice on it can't be given out whole (Case 8). Use `gpuSchedulerPolicy: binpack`, or label/taint `pool=training` vs `pool=inference`. |
| **Tune `deviceSplitCount`** | Pick it so the split ceiling and the memory ceiling are hit together. With split 10 and 5 GB pods on an 80 GB card, ~30 GB can never be used. |
| **One GPU device plugin per node** | HAMi's plugin and the stock NVIDIA plugin both register `nvidia.com/gpu`. With the GPU Operator, use `devicePlugin.enabled=false`. |
| **Multi-GPU requests need distinct cards on one node** | `nvidia.com/gpu: N` needs N free physical GPUs on the same node; slices are never combined. |
| **Pin the chart version** | Values keys, metrics and features (e.g. GPU-memory quotas) change between releases. |

---

## 4. Honest caveats

| Topic | What to know |
|---|---|
| **Software isolation** | Enforcement happens in user space, inside the container, by intercepting CUDA/NVML calls. That's how it works without MIG. Treat it as **resource isolation between cooperating tenants**, not a hard security boundary against hostile code. For strict security isolation, use MIG or dedicated GPUs. |
| **Compute cap (`gpucores`)** | Implemented by throttling in software, not by partitioning SMs. Measure how accurate it is for your workloads. |
| **glibc in workload images** | Older guidance says HAMi-core breaks with glibc ≥ 2.34 in the workload image. Current images (e.g. ubuntu 22.04 / the PyTorch image used here, glibc 2.35) are used in official examples. Check `ldd --version` in your images and test with Case 5. |
| **Overcommit** | `deviceMemoryScaling > 1` is a *logical* trick. It doesn't create memory. A pod can never use more than the physical card has. |
| **Idle pods look idle** | Pods that never open a CUDA context show 0% on host `nvidia-smi`. Use the allocation annotation, not host utilisation, to see sharing. |
| **Quota support depends on version** | `limits.nvidia.com/gpumem` quotas need a HAMi release with NVIDIA ResourceQuota support (Case 7). |

---

## 5. When to choose what

| If you need… | Use |
|---|---|
| More pods than GPUs, flexible sizes, cooperating teams | **HAMi** |
| Hard isolation for untrusted tenants, on a supported card | **MIG** (HAMi can still run alongside) |
| Quick, unprotected sharing for bursty dev work | Time-slicing |
| Whole cards for big training jobs | Any of them, including HAMi with plain `nvidia.com/gpu: N` |

---

## 6. Next steps

- [ ] **Compute cap accuracy:** two matmul pods with `gpucores: 30` and `gpucores: 70` on the same card; compare throughput against the ratio
- [ ] **Overcommit:** `deviceMemoryScaling > 1`. What happens when total promised memory exceeds the card?
- [ ] **Upgrade path:** re-run Cases 0–8 after a HAMi chart upgrade
- [ ] **Mixed GPU models:** `gpumem-percentage` across e.g. 80 GB and 48 GB cards
- [ ] **HAMi vs MIG** on the same MIG-capable card: isolation strength vs flexibility
- [ ] **DRA:** upstream Kubernetes is moving to Dynamic Resource Allocation for devices; HAMi has a DRA-based variant (HAMi-DRA) in progress

> **In one line:** Kubernetes treats a GPU like a light switch. HAMi turns it into a dimmer, with a cap on every pod, a scheduler that understands memory, and no change to the application.
