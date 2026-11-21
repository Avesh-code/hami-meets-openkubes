# 01 — Introduction to GPUs

> Start here. This page explains what a GPU is, why AI workloads need one, and how Kubernetes hands a GPU to a pod.

---

## 1. What is a GPU, and why does AI need it?

A **CPU** has a few powerful cores built for sequential work. A **GPU** has **thousands of small cores** built to do the same maths on a lot of data at once. Training and running neural networks is mostly that kind of work: huge matrix multiplications.

What's inside a data-centre GPU:

| Part | What it is | Why it matters for sharing |
|---|---|---|
| **SMs** (Streaming Multiprocessors) | Blocks of compute cores (CUDA cores + Tensor Cores) | This is the **compute** you'd want to split |
| **GPU memory** (HBM / GDDR) | On-card memory: 16, 24, 48, 80, 141 GB… | The model and its data must **fit here**. This is the **memory** you'd want to split. |
| **L2 cache, copy engines, decoders** | Shared hardware units | Only hardware partitioning (MIG) splits these |

**The cost problem:** a single data-centre GPU costs as much as a car, yet many workloads (notebooks, small inference services, dev jobs) use only **a few GB and a few % of compute**.

---

## 2. How a container gets a GPU in Kubernetes

```
NVIDIA driver (host)  →  NVIDIA Container Toolkit (runtime)  →  Device plugin  →  kubelet  →  Pod
   talks to the card        injects GPU into containers         advertises           schedules
                                                                nvidia.com/gpu: 4
```

| Layer | Job |
|---|---|
| **NVIDIA driver** | Runs on the host and talks to the physical card |
| **NVIDIA Container Toolkit** | Container runtime hook that makes the GPU visible inside a container |
| **Device plugin** | Tells the kubelet how many GPUs the node has (`nvidia.com/gpu: 4`) |
| **kubelet / scheduler** | Places pods on nodes that still have free `nvidia.com/gpu` |

Pods request a GPU like CPU or memory:

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
```

---

## 3. The catch: a GPU is handed out whole

`nvidia.com/gpu` is an **extended resource**, and extended resources are **whole numbers**. You can't ask for `0.5`. So by default:

- 1 pod = 1 **whole** physical GPU, even if it uses 3 GB of an 80 GB card
- 4 GPUs on a node = **at most 4 GPU pods** on that node
- Pod #5 → `Pending: Insufficient nvidia.com/gpu`

```
Without sharing                            With sharing
┌──────────── GPU 80 GB ─────────────┐     ┌──────────── GPU 80 GB ─────────────┐
│ notebook (uses 3 GB)               │     │ 5G│ 5G│ 5G│ 5G│ 5G│ 5G│ 5G│ 5G│... │
│ ░░░░░░░░░ 77 GB idle ░░░░░░░░░░░░░ │     │ each pod capped & isolated         │
└────────────────────────────────────┘     └────────────────────────────────────┘
5 pods Pending                              0 pods Pending
```

> If your GPU utilisation graphs look mostly empty while your `Pending` queue is full, it's usually not a hardware problem. **It's a scheduling granularity problem.**

This is exactly the problem I hit (see [04 — My scaling issue](04-my-scaling-issue.md)). The next page looks at the ways to fix it.

**Next:** [02 — GPU slicing: the ways to share a GPU](02-gpu-slicing-methods.md)
