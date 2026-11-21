# HAMi Meets openkubes

### Fractional GPUs, multi-tenant isolation and smarter scheduling on Kubernetes

> A reproducible test environment for **HAMi** (Heterogeneous AI Computing Virtualization Middleware, a CNCF Sandbox project).
> Prepared for **"HAMi Meets OpenKubes: GPU Sharing for Sovereign AI Infrastructure"**, Kubernauts Worldwide Meetup, **Dec 3, 2026, 18:00 CET**.
>
> Author: **Avesh Padaya** · Background: *Stop Wasting Your GPUs: A Practical Guide to Sharing NVIDIA GPUs in Kubernetes with HAMi* (Medium)

---

## The problem in one picture

```
Without HAMi                               With HAMi
┌──────────── GPU 80 GB ─────────────┐     ┌──────────── GPU 80 GB ─────────────┐
│ notebook (uses 3 GB)               │     │ 5G│ 5G│ 5G│ 5G│ 5G│ 5G│ 5G│ 5G│... │
│ ░░░░░░░░░ 77 GB idle ░░░░░░░░░░░░░ │     │ each pod capped & isolated         │
└────────────────────────────────────┘     └────────────────────────────────────┘
5 pods Pending                              0 pods Pending
```

Kubernetes hands out GPUs **whole**. HAMi slices each physical GPU into **virtual GPUs limited by memory and compute**, enforces those limits inside each container, and still lets big jobs claim whole cards. **No application changes.**

**How this started:** I had a node with **4 GPUs** and needed to scale a GPU workload to 10 replicas. Only **4 pods ran, and 6 sat in `Pending`** (`Insufficient nvidia.com/gpu`), while each card was mostly empty. After installing HAMi, the same node advertised **40 vGPUs** and all 10 replicas ran, each limited to its own memory slice.

---

## Read in order

| # | Doc | What's inside |
|---|---|---|
| 01 | [Introduction to GPUs](docs/01-introduction-to-gpu.md) | What a GPU is, how Kubernetes hands one to a pod, why it's all-or-nothing |
| 02 | [GPU slicing methods](docs/02-gpu-slicing-methods.md) | Time-slicing vs MPS vs MIG vs vGPU vs HAMi, side by side |
| 03 | [HAMi & architecture](docs/03-hami-and-architecture.md) | What HAMi is, resource fields, components, the 7-step pod flow |
| 04 | [My scaling issue](docs/04-my-scaling-issue.md) | 4 GPUs = 4 pods: the problem I hit and the options I weighed |
| 05 | [How HAMi solved it & installation](docs/05-hami-installation.md) | Pre-checks, Helm install, verification, HAMi values explained |
| 06 | [Test cases](docs/06-test-cases.md) | Cases 0–8: contract, commands, expected results |
| 07 | [Conclusion](docs/07-conclusion.md) | Results, operating tips, honest caveats, next steps |

---

## Test cases

| # | Case | What it proves | Manifest |
|---|---|---|---|
| 0 | Before HAMi vs after HAMi | capacity 4 → 40; 4/10 → 10/10 replicas Running | `case0-before-hami.yaml`, `case0-after-hami.yaml` |
| 1 | Fractional sharing | 15 pods share 4 GPUs, each sees only its 5 GB slice | `case1-fractional.yaml` |
| 2 | Whole GPU | One pod can still get a full card | `case2-whole-gpu.yaml` |
| 3 | Multi-GPU, whole | One pod gets 2 distinct full cards | `case3-multi-gpu-whole.yaml` |
| 4 | Multi-GPU, sliced | One pod gets 20 GB on **each** of 2 cards | `case4-multi-gpu-sliced.yaml` |
| 5 | OOM enforcement | Capped pod OOMs at its limit; control succeeds | `case5-oom-enforcement.yaml` |
| 6 | Multi-tenant | Noisy tenant OOMs; neighbour on the same card is unaffected | `case6-multi-tenant.yaml` |
| 7 | Over quota | Pod beyond the namespace GPU-memory quota is rejected by HAMi's webhook | `case7-over-quota.yaml` |
| 8 | Schedule pattern change | spread blocks a 2-GPU job; binpack leaves room for it | `case8-spread.yaml`, `case8-binpack.yaml` |

---

## Quick start

```bash
git clone https://github.com/Avesh-code/hami-meets-openkubes.git && cd hami-meets-openkubes
export GPU_NODE=<your-gpu-node>

# Case 0a: BEFORE (stock NVIDIA plugin still installed)
scripts/gpu-status.sh                                      # capacity: 4
kubectl apply -f manifests/case0-before-hami.yaml
kubectl -n gpu-demo scale deploy gpu-app --replicas=10     # → 4 Running, 6 Pending
kubectl delete namespace gpu-demo

# Install (full guide: docs/05-hami-installation.md)
kubectl -n kube-system delete daemonset <nvidia-device-plugin-daemonset>   # remove the stock plugin
kubectl label node $GPU_NODE gpu=on --overwrite
kubectl version | grep -i server                                          # → imageTag below
helm repo add hami-charts https://project-hami.github.io/HAMi && helm repo update
helm install hami hami-charts/hami \
  --set scheduler.kubeScheduler.imageTag=<vX.YY.Z> \
  -n kube-system

# Case 0b: AFTER
scripts/gpu-status.sh                                      # capacity: 40
kubectl apply -f manifests/case0-after-hami.yaml           # same app + nvidia.com/gpumem: 4096
kubectl -n gpu-demo scale deploy gpu-app --replicas=10     # → 10/10 Running
kubectl delete namespace gpu-demo

# Then any other case, e.g. Case 1
kubectl apply -f manifests/00-namespace.yaml -f manifests/case1-fractional.yaml
scripts/verify-allocation.sh hami-lab case=case1           # 15 pods sharing 4 physical GPUs
scripts/cleanup.sh case1
```

All cases, step by step: [docs/06-test-cases.md](docs/06-test-cases.md)

---

## Repository layout

```
hami-meets-openkubes/
├── README.md
├── docs/                           # 01–07, read in order
├── manifests/
│   ├── hami-values.yaml            # optional Helm values (explained in docs/05, section 5.5)
│   ├── 00-namespace.yaml           # hami-lab namespace for Cases 1–5 and 8
│   ├── case0-before-hami.yaml      # the problem: gpu: 1 = whole card
│   ├── case0-after-hami.yaml       # the fix: + gpumem
│   ├── case1-fractional.yaml       # 15 × 5 GB, binpack
│   ├── case2-whole-gpu.yaml
│   ├── case3-multi-gpu-whole.yaml
│   ├── case4-multi-gpu-sliced.yaml
│   ├── case5-oom-enforcement.yaml
│   ├── case6-multi-tenant.yaml     # team-a / team-b + quotas
│   ├── case7-over-quota.yaml
│   ├── case8-spread.yaml
│   └── case8-binpack.yaml
└── scripts/
    ├── gpu-status.sh               # GPU capacity and pending pods, before & after HAMi
    ├── verify-allocation.sh        # which pod is on which physical GPU
    ├── gpu_alloc_test.py           # OOM probe + steady "good neighbour" workload (Cases 5–6)
    └── cleanup.sh
```

---

## Resource fields: cheat sheet

| Field | Unit | Meaning |
|---|---|---|
| `nvidia.com/gpu` | count | **Physical** GPUs the pod needs (on the node it shows physical × split) |
| `nvidia.com/gpumem` | MiB | Memory slice **per physical GPU** |
| `nvidia.com/gpumem-percentage` | % | Memory slice as a % of each card |
| `nvidia.com/gpucores` | % | Compute cap per card |
| `hami.io/gpu-scheduler-policy` (annotation) | `binpack` / `spread` | How pods are placed across GPUs |
| `hami.io/node-scheduler-policy` (annotation) | `binpack` / `spread` | How pods are placed across nodes |

---

## Test environment

| Item | Value |
|---|---|
| GPUs | 4 × NVIDIA L40S |
| Kubernetes | v1.31.14 (kubeadm, containerd 2.2.1) |
| HAMi chart | 2.11.0 |
| Driver / CUDA | _fill in_ |

---

## References

- HAMi documentation: https://project-hami.io/docs/
- HAMi GitHub: https://github.com/Project-HAMi/HAMi
- Helm chart values: https://github.com/Project-HAMi/HAMi/blob/master/charts/hami/README.md
- CNCF Sandbox: https://www.cncf.io/projects/

## License

Licensed under the [Apache License 2.0](LICENSE). Copyright 2026 Avesh Padaya.
