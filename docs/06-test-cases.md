# 06 — Test Cases

Nine cases, each proving one thing on a **4-GPU node** (tested on 4 × NVIDIA L40S, Kubernetes v1.31.14, HAMi chart 2.11.0):

| # | Case | What it proves | Manifest |
|---|---|---|---|
| 0 | Before HAMi vs after HAMi | The scaling problem, and HAMi fixing it | `case0-before-hami.yaml`, `case0-after-hami.yaml` |
| 1 | Fractional sharing | Many pods share one physical GPU, each with its own slice | `case1-fractional.yaml` |
| 2 | Whole GPU | One pod can still get a full card | `case2-whole-gpu.yaml` |
| 3 | Multi-GPU, whole | One pod gets several full cards | `case3-multi-gpu-whole.yaml` |
| 4 | Multi-GPU, sliced | One pod gets a slice on each of several cards | `case4-multi-gpu-sliced.yaml` |
| 5 | OOM enforcement | The memory cap holds under real allocation | `case5-oom-enforcement.yaml` |
| 6 | Multi-tenant | A noisy tenant can't hurt a neighbour on the same card | `case6-multi-tenant.yaml` |
| 7 | Over quota | A namespace can't go past its GPU-memory quota | `case7-over-quota.yaml` |
| 8 | Schedule pattern change | binpack vs spread, and why it matters for whole-GPU jobs | `case8-spread.yaml`, `case8-binpack.yaml` |

---

## How each case is checked

Everything is checked with plain `kubectl`, because HAMi stores its decisions in ordinary Kubernetes objects:

| Question | How to check |
|---|---|
| What did the pod ask for? | `resources.limits` in the manifest |
| Which physical GPU did HAMi give it? | The `hami.io/vgpu-devices-allocated` annotation, or `scripts/verify-allocation.sh <ns> <selector>` for all pods at once |
| What does the container see? | `nvidia-smi` **inside** the pod |
| Does the cap hold under real load? | OOM probe logs (Cases 5–6) |
| How much GPU memory does a team use? | `kubectl get pods -o custom-columns="$GPU_COLS"` (below). `describe resourcequota` always shows `Used 0`. |

```bash
# Which physical GPU(s) a single pod got
kubectl -n <ns> get pod <pod> -o jsonpath='{.metadata.annotations.hami\.io/vgpu-devices-allocated}{"\n"}'

# What a pod sees
kubectl -n <ns> exec <pod> -- nvidia-smi --query-gpu=uuid,memory.total --format=csv

# What every pod in a namespace asked for (used in Cases 6–8 to show quota usage)
export GPU_COLS='NAME:.metadata.name,GPU:.spec.containers[*].resources.limits.nvidia\.com/gpu,GPUMEM:.spec.containers[*].resources.limits.nvidia\.com/gpumem,STATUS:.status.phase'
kubectl -n <ns> get pods -o custom-columns="$GPU_COLS"
# team-b-steady   1   5120   Running   → 5120 of team-b's 20480 used
```

> Set `GPU_COLS` once per terminal. Cases 6–8 use it.

> **Run cases one at a time on an empty node** and clean up between them (`scripts/cleanup.sh <case>`). Leftover pods change where the next case lands.

### One-time setup (after HAMi is installed)

```bash
kubectl apply -f manifests/00-namespace.yaml

# The probe script ConfigMap is created inside Cases 5 and 6, in the namespace each case uses.

# Pre-pull images on the GPU node, so pull time doesn't slow the demo
#   nvidia/cuda:12.4.1-base-ubuntu22.04
#   pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime   (~3+ GB)
```

---

## Case 0 — Before HAMi vs after HAMi

**Goal:** reproduce [my scaling issue](04-my-scaling-issue.md), then show the same test passing with HAMi.

### Case 0a: BEFORE (stock NVIDIA plugin, HAMi not installed yet)

> Run this **before** installing HAMi ([05 — Installation](05-hami-installation.md), before pre-check A). Once the stock plugin is removed you can't go back to this state easily.

**Contract:**
```yaml
resources:
  limits:
    nvidia.com/gpu: 1        # = one WHOLE physical GPU
```

**Run:**
```bash
scripts/gpu-status.sh                                       # capacity: 4

kubectl apply -f manifests/case0-before-hami.yaml
kubectl -n gpu-demo scale deploy gpu-app --replicas=10
sleep 30
kubectl -n gpu-demo get pods -o wide

# Why are they Pending?
PENDING=$(kubectl -n gpu-demo get pods --field-selector=status.phase=Pending -o name | head -1)
kubectl -n gpu-demo describe $PENDING | sed -n '/Events/,$p'

# How much of the card does a running pod see?
RUNNING=$(kubectl -n gpu-demo get pods --field-selector=status.phase=Running -o name | head -1)
kubectl -n gpu-demo exec $RUNNING -- nvidia-smi
```

**Expected:**
- Node capacity **4**
- **4 Running, 6 Pending**, with `FailedScheduling … Insufficient nvidia.com/gpu`
- The running pod's `nvidia-smi` shows the **whole card**

```bash
kubectl delete namespace gpu-demo
```

### Case 0b: AFTER (HAMi installed)

**Contract:** the same app, one line added:
```yaml
resources:
  limits:
    nvidia.com/gpu: 1          # 1 physical GPU to share from
    nvidia.com/gpumem: 4096    # NEW: only 4 GB of it
```

**Run:**
```bash
scripts/gpu-status.sh                                       # capacity: 40

kubectl apply -f manifests/case0-after-hami.yaml
kubectl -n gpu-demo scale deploy gpu-app --replicas=10
kubectl -n gpu-demo rollout status deploy/gpu-app --timeout=180s
kubectl -n gpu-demo get pods -o wide

scripts/verify-allocation.sh gpu-demo case=case0             # which GPU each replica landed on

RUNNING=$(kubectl -n gpu-demo get pods -o name | head -1)
kubectl -n gpu-demo exec $RUNNING -- nvidia-smi --query-gpu=memory.total --format=csv
```

**Expected:**
- Node capacity **40**
- **10/10 Running**, spread over the 4 cards (default GPU policy is `spread`, so roughly 3 + 3 + 2 + 2)
- Each pod sees **4096 MiB**, not the whole card

> **The request has to change too.** If you apply `case0-before-hami.yaml` unchanged after installing HAMi (only `nvidia.com/gpu: 1`, no `gpumem`), **only 4 pods run again**. A request without `gpumem` means "the whole card" (that's Case 2). The fix is one line: add `nvidia.com/gpumem`.

```bash
kubectl delete namespace gpu-demo
```

---

## Case 1 — Fractional sharing

**Goal:** show that many pods share one physical GPU, each limited to its own memory slice.

**Contract (per pod, 15 replicas):**
```yaml
annotations:
  hami.io/gpu-scheduler-policy: "binpack"
resources:
  limits:
    nvidia.com/gpu: 1          # one physical GPU to share from
    nvidia.com/gpumem: 5120    # 5 GB visible in this container
```

**Run:**
```bash
kubectl apply -f manifests/case1-fractional.yaml
kubectl -n hami-lab rollout status deploy/case1-fractional --timeout=300s
scripts/verify-allocation.sh hami-lab case=case1

POD=$(kubectl -n hami-lab get pods -l case=case1 -o name | head -1)
kubectl -n hami-lab exec $POD -- nvidia-smi --query-gpu=memory.total --format=csv
```

**Expected:** it depends on **how much memory each card has**. Whichever ceiling is hit first, the split count (10) or the memory, decides:

| Card memory | Ceiling hit first | Pods per GPU (binpack) |
|---|---|---|
| ≥ 50 GB (e.g. A100/H100 80GB) | split count (10) | **10 + 5** |
| 24 GB (e.g. L4, A10, RTX 4090) | memory (4 × 5 GB = 20 GB) | **4 + 4 + 4 + 3** |
| 16 GB (e.g. T4) | memory (3 × 5 GB = 15 GB) | **3 + 3 + 3 + 3**, 3 pods Pending |

Every running pod sees **5120 MiB**. Either way, **15 pods run on 4 physical GPUs**, instead of 4.

> **Why the binpack annotation?** The chart's default GPU policy is `spread`, which would scatter the 15 pods across all 4 cards (~4 per card). Sharing still works but is harder to see. Case 8 compares the two policies on purpose.

**Gotcha:** these pods only `sleep`, so **host `nvidia-smi` shows 0% and no processes** even with 10 pods on one card. That's expected. The allocation annotation is the right proof for idle pods.

```bash
scripts/cleanup.sh case1
```

---

## Case 2 — Whole GPU

**Goal:** show that "1 pod = 1 full card" still works for workloads that need it.

**Contract:**
```yaml
resources:
  limits:
    nvidia.com/gpu: 1          # no gpumem / gpucores → no cap → full card
```

**Run:**
```bash
kubectl apply -f manifests/case2-whole-gpu.yaml
kubectl -n hami-lab wait --for=condition=Ready pod/case2-whole-gpu --timeout=180s
kubectl -n hami-lab exec case2-whole-gpu -- nvidia-smi --query-gpu=uuid,memory.total --format=csv
```

**Expected:** the pod sees the **full card memory** (e.g. ~23034 MiB on a 24 GB L4, ~81559 MiB on an H100 80GB). No other pod can be placed on that card while this one runs.

```bash
scripts/cleanup.sh case2
```

---

## Case 3 — Multi-GPU, whole

**Goal:** give several full physical GPUs to one pod (e.g. multi-GPU training).

**Contract:**
```yaml
resources:
  limits:
    nvidia.com/gpu: 2          # 2 DISTINCT physical GPUs
```

**Run:**
```bash
kubectl apply -f manifests/case3-multi-gpu-whole.yaml
kubectl -n hami-lab wait --for=condition=Ready pod/case3-multi-gpu-whole --timeout=180s
kubectl -n hami-lab exec case3-multi-gpu-whole -- nvidia-smi -L
scripts/verify-allocation.sh hami-lab case=case3
```

**Expected:** `nvidia-smi -L` lists **two different UUIDs**, each with full memory, and the annotation contains two `GPU-…` entries.

**Key point:** HAMi will **not** stack two slices of the same card to satisfy `gpu: 2`. It needs two free physical cards **on one node**. Case 8 uses this to show fragmentation.

```bash
scripts/cleanup.sh case3
```

---

## Case 4 — Multi-GPU, sliced

**Goal:** combine multi-GPU allocation with per-card memory slicing.

**Contract:**
```yaml
resources:
  limits:
    nvidia.com/gpu: 2          # 2 physical GPUs
    nvidia.com/gpumem: 20480   # 20 GB on EACH → 40 GB total
```

**Run:**
```bash
kubectl apply -f manifests/case4-multi-gpu-sliced.yaml
kubectl -n hami-lab wait --for=condition=Ready pod/case4-multi-gpu-sliced --timeout=180s
kubectl -n hami-lab exec case4-multi-gpu-sliced -- nvidia-smi --query-gpu=uuid,memory.total --format=csv
```

**Expected:** two GPUs visible, **each showing 20480 MiB** (40 GB in total, not 20 GB split across two cards). Needs cards with at least 20 GB; on 16 GB cards, lower `gpumem` first.

**Portability tip:** for clusters with mixed GPU models (80 GB and 48 GB, say), use `nvidia.com/gpumem-percentage: 25` instead of an absolute MiB value.

```bash
scripts/cleanup.sh case4
```

---

## Case 5 — OOM enforcement

**Goal:** prove **isolation**, not just allocation. `nvidia-smi` showing a smaller number is necessary but **not sufficient**. A real workload must fail when it reaches its cap.

| Pod | Contract | Tries to allocate | Must |
|---|---|---|---|
| `case5a-capped` | 5 GB | 8 GB | **OOM** close to 5 GB |
| `case5b-control` | 10 GB | 8 GB | **Succeed** |

The control proves that the failure in 5a comes from **HAMi's cap**, not from the script or the card.

**How the script gets into the pod:** the ConfigMap `gpu-alloc-test` is created from `scripts/gpu_alloc_test.py`, so its key is `gpu_alloc_test.py`. The pod mounts it at `/probe`, which makes the file `/probe/gpu_alloc_test.py`, and runs it with the stock PyTorch image. You don't need a custom image.

**Run:**
```bash
# 1. Clean start
scripts/cleanup.sh
scripts/gpu-status.sh                                    # nothing allocated

# 2. Namespace + probe script
kubectl apply -f manifests/00-namespace.yaml
kubectl -n hami-lab create configmap gpu-alloc-test --from-file=scripts/gpu_alloc_test.py

# 3. Apply both pods
kubectl apply -f manifests/case5-oom-enforcement.yaml
kubectl -n hami-lab get pods -o wide -w                   # Ctrl-C when both are Running

# 4. Capped pod: watch it hit the wall
kubectl -n hami-lab logs -f case5a-capped                 # Ctrl-C after the [verdict] line

# 5. Control pod: same script, bigger contract
kubectl -n hami-lab logs case5b-control | grep -E '\[info\]|\[result\]|\[verdict\]'

# 6. What each pod sees (pods hold for 600 s)
kubectl -n hami-lab exec case5a-capped  -- nvidia-smi --query-gpu=memory.total,memory.used --format=csv
kubectl -n hami-lab exec case5b-control -- nvidia-smi --query-gpu=memory.total,memory.used --format=csv

# 7. Where HAMi placed them
scripts/verify-allocation.sh hami-lab case=case5
```

**Expected logs:**
```
# case5a-capped
[info] device=NVIDIA L40S visible_total_mib=5120 free_mib=...
[alloc] total_allocated_mib=256
...
[alloc] total_allocated_mib=4608
[HAMI-core ERROR (... allocator.c:40)]: Device 0 OOM 5544869888 / 5368709120
[result] OOM allocated_mib=4608 target_mib=8192 error=CUDA out of memory ...
[verdict] PASS expected=oom observed=oom

# case5b-control
[info] device=NVIDIA L40S visible_total_mib=10240 ...
[result] SUCCESS allocated_mib=8192 target_mib=8192
[verdict] PASS expected=success observed=success
```

- **The `HAMI-core ERROR` line** shows HAMi itself refusing the allocation. The pod tried to reach 5544869888 bytes (about 5.16 GiB) against a cap of 5368709120 bytes (exactly 5120 MiB).
- **The OOM happens a little below 5120 MiB** because the CUDA context and PyTorch's allocator use part of the slice.

```bash
scripts/cleanup.sh case5
```

---

## Case 6 — Multi-tenant

**Goal:** show that a noisy tenant **can't hurt** a neighbour on the same physical GPU.

| Tenant | Quota (`limits.nvidia.com/gpumem`) | Pods |
|---|---|---|
| `team-b` | 20 GB | `team-b-steady`: holds 4 GB, runs matmul, heartbeat every 5 s |
| `team-a` | 10 GB | `team-a-noisy`: waits 45 s, then tries 8 GB inside a 5 GB slice<br>`team-a-filler`: 5 GB, brings team-a to exactly its quota |

All pods use the `binpack` annotation, so the tenants land on the **same physical GPU**.

**Run:**
```bash
# 1. Clean start (leftover pods change which card the tenants land on)
kubectl delete namespace team-a team-b --ignore-not-found --wait=true
scripts/cleanup.sh
scripts/gpu-status.sh                                     # nothing allocated

# 2. Tenants + probe script (--save-config avoids the "last-applied-configuration" warning)
kubectl create namespace team-a --save-config
kubectl create namespace team-b --save-config
kubectl -n team-a create configmap gpu-alloc-test --from-file=scripts/gpu_alloc_test.py
kubectl -n team-b create configmap gpu-alloc-test --from-file=scripts/gpu_alloc_test.py

# 3. Apply
kubectl apply -f manifests/case6-multi-tenant.yaml
kubectl get pods -A -l case=case6 -o wide                 # wait until all 3 are Running

# 4. The quotas (Hard = the limit; Used stays 0, see the note below)
kubectl -n team-a describe resourcequota gpu-quota        # Hard 10240
kubectl -n team-b describe resourcequota gpu-quota        # Hard 20480

# 5. What each team really uses
kubectl -n team-a get pods -o custom-columns="$GPU_COLS"   # 5120 + 5120 = 10240 of 10240 (full)
kubectl -n team-b get pods -o custom-columns="$GPU_COLS"   # 5120 of 20480

# 6. Both tenants on one card
scripts/verify-allocation.sh -A case=case6                # same GPU UUID for team-a and team-b

# 7. Two terminals, start straight away (team-a-noisy starts allocating 45 s after it starts)
kubectl -n team-b logs -f team-b-steady                   # Terminal 1: good neighbour
kubectl -n team-a logs -f team-a-noisy                    # Terminal 2: noisy neighbour

# 8. team-b was not disturbed: heartbeats continue past the OOM time
kubectl -n team-a logs team-a-noisy --timestamps | grep '\[result\]'
kubectl -n team-b logs team-b-steady --timestamps | tail -15
```

**Expected:**
- `verify-allocation.sh` shows `team-a/*` and `team-b/*` on the **same UUID**.
- `team-a-noisy` shows `[HAMI-core ERROR] Device 0 OOM … / 5368709120`, then `[result] OOM allocated_mib=4608 … [verdict] PASS`.
- `team-b-steady` shows `[heartbeat]` lines that **continue without a gap** before, during and after team-a's OOM, with a stable `matmul_ms`.

> **Why `describe resourcequota` shows `Used 0`:** Kubernetes' own quota controller only counts `requests.`-prefixed keys for extended resources, so it ignores `limits.nvidia.com/*` and leaves `Used` at 0. **HAMi's scheduler** reads the same ResourceQuota, keeps its own count of usage, and enforces it. It doesn't write the count back to the quota object. HAMi uses `limits.` on purpose: `gpumem` is **per card**, so a pod with `gpu: 2, gpumem: 20480` really takes 40 GB, which native Kubernetes would count as 20 GB. Step 5 shows the real usage. Case 7 proves it's enforced.

> **Don't clean up yet.** Case 7 needs team-a at its full quota.

---

## Case 7 — Over quota

**Goal:** show that per-namespace **GPU-memory quotas** are enforced. Run it **right after Case 6**, while team-a holds 10 GB, exactly its quota.

**Contract:**
```yaml
# team-a's ResourceQuota (from case6-multi-tenant.yaml)
limits.nvidia.com/gpumem: "10240"
# the new pod
nvidia.com/gpumem: 5120        # would push team-a to 15 GB > 10 GB
```

**Run:**
```bash
# 1. A pod asking for 5 GB more: HAMi's webhook rejects it at creation
kubectl apply -f manifests/case7-over-quota.yaml
# Error from server (Forbidden): error when creating "manifests/case7-over-quota.yaml":
#   admission webhook "vgpu.hami.io" denied the request: exceeding resource quota for device NVIDIA

# 2. Usage: team-a holds its full 10240; the new pod was never created
kubectl -n team-a get pods -o custom-columns="$GPU_COLS"

# 3. The GPU still has room, so the block comes from the quota, not the hardware
scripts/gpu-status.sh

# 4. The quota is per team: team-b still has 15360 MiB left
kubectl -n team-b get pods -o custom-columns="$GPU_COLS"

# 5. Free quota, and the same pod is accepted
kubectl -n team-a delete pod team-a-filler
kubectl apply -f manifests/case7-over-quota.yaml           # → pod/team-a-over-quota created
kubectl -n team-a get pods -o custom-columns="$GPU_COLS"   # back to 10240 of 10240
```

**Expected (observed on chart 2.11.0):**

| Step | Result | team-a total |
|---|---|---|
| 1 | `admission webhook "vgpu.hami.io" denied the request: exceeding resource quota for device NVIDIA` | 10240 of 10240 |
| 2 | filler 5120 Running · noisy 5120 Running (no over-quota pod) | 10240 |
| 5 | noisy 5120 Running · over-quota 5120 Running | 10240 |

HAMi enforces the quota **at admission**: the pod is refused before it exists, so it never shows up as `Pending`.

> **Version note:** this needs a HAMi release with NVIDIA ResourceQuota support (tested on chart 2.11.0). If the over-quota pod is created anyway, check `kubectl -n kube-system logs deploy/hami-scheduler -c vgpu-scheduler-extender | grep -i quota`.

```bash
kubectl delete namespace team-a team-b --wait=true
scripts/gpu-status.sh                                     # nothing allocated, Case 8 needs empty GPUs
```

---

## Case 8 — Schedule pattern change: binpack vs spread

**Goal:** show how the GPU scheduling policy affects fragmentation. The **same 8 pods** (2 GB each) are run with two different policies, then a 2-GPU job (Case 3) tries to fit.

**Contract (per pod, 8 replicas):**
```yaml
annotations:
  hami.io/gpu-scheduler-policy: "spread"   # or "binpack"
resources:
  limits:
    nvidia.com/gpu: 1
    nvidia.com/gpumem: 2048
```

**Run spread:**
```bash
kubectl apply -f manifests/00-namespace.yaml

# 1. 8 small pods, spread
kubectl apply -f manifests/case8-spread.yaml
kubectl -n hami-lab rollout status deploy/case8-spread

# 2. Usage and placement
kubectl -n hami-lab get pods -o custom-columns="$GPU_COLS"  # 8 × 2048 = 16384 MiB of 4 × 48 GB
scripts/verify-allocation.sh hami-lab policy=spread        # 2, 2, 2, 2 → no empty card

# 3. Can a 2-GPU training job still fit?
kubectl apply -f manifests/case3-multi-gpu-whole.yaml
sleep 15
kubectl -n hami-lab get pods -o custom-columns="$GPU_COLS"  # case3-multi-gpu-whole  2  <none>  Pending
kubectl -n hami-lab describe pod case3-multi-gpu-whole | sed -n '/Events/,$p'

# 4. Clean up spread
kubectl -n hami-lab delete pod case3-multi-gpu-whole
kubectl -n hami-lab delete deploy case8-spread --wait=true
kubectl -n hami-lab get pods                               # wait until empty
```

**Run binpack:**
```bash
# 1. Same 8 pods, binpack
kubectl apply -f manifests/case8-binpack.yaml
kubectl -n hami-lab rollout status deploy/case8-binpack
scripts/verify-allocation.sh hami-lab policy=binpack       # 8 on ONE card, 3 cards empty

# 2. The same 2-GPU job
kubectl apply -f manifests/case3-multi-gpu-whole.yaml
kubectl -n hami-lab wait --for=condition=Ready pod/case3-multi-gpu-whole --timeout=180s
kubectl -n hami-lab get pods -o custom-columns="$GPU_COLS"  # case3-multi-gpu-whole  2  <none>  Running
kubectl -n hami-lab logs case3-multi-gpu-whole             # 2 distinct GPU UUIDs

# 3. Clean up
kubectl -n hami-lab delete pod case3-multi-gpu-whole
kubectl -n hami-lab delete deploy case8-binpack
```

**Expected:**

| Policy | Pods per GPU (4-GPU node) | Whole GPUs left free | 2-GPU job (Case 3) |
|---|---|---|---|
| spread | 2, 2, 2, 2 | **0** | **Pending**, even though only 16 GB of 192 GB is used |
| binpack | 8, 0, 0, 0 | **3** | **Running** |

**Why it matters:** a card holding even one small slice can't be given out as a whole GPU (Cases 2–3) until that slice finishes. **binpack keeps whole cards free for training. spread lowers contention between inference pods.** Pick per workload, or split node pools (taint/label `pool=training` vs `pool=inference`).

### If something goes wrong (Cases 6–8)

| Symptom | Fix |
|---|---|
| Case 6 tenants on **different** UUIDs | Leftovers from an earlier case. Delete the namespaces, run `scripts/cleanup.sh`, start again. |
| Pods stuck in `ContainerCreating` | The `gpu-alloc-test` ConfigMap is missing in that namespace, or the image is still pulling. |
| Case 7 pod is **created** instead of rejected | Quota not enforced by your HAMi release; check the scheduler logs (see the version note). |
| Case 8 spread shows 8 pods on one card, or the 2-GPU job runs | The node wasn't empty before 8a. `scripts/gpu-status.sh` must show nothing allocated. |

---

## Clean up everything

```bash
scripts/cleanup.sh          # deletes gpu-demo, hami-lab, team-a, team-b (HAMi stays installed)
```

**Next:** [07 — Conclusion](07-conclusion.md)
