# 04 — My Issue: GPU Pods That Wouldn't Scale

> ✏️ *Personalise this page with your own details: cluster, workload, dates.*

---

## 1. The setup

A Kubernetes node with **4 NVIDIA GPUs**, running GPU workloads (*e.g. inference services / notebooks / dev jobs*), with the **stock NVIDIA device plugin**.

## 2. What happened

I needed to **scale out** a GPU workload, more replicas to handle more requests. Each pod only needed a few GB of GPU memory. But:

```bash
$ kubectl scale deploy gpu-app --replicas=10
$ kubectl get pods
NAME            READY   STATUS
gpu-app-...     1/1     Running   ← 4 pods running
gpu-app-...     1/1     Running
gpu-app-...     1/1     Running
gpu-app-...     1/1     Running
gpu-app-...     0/1     Pending   ← 6 pods stuck
...
$ kubectl describe pod gpu-app-... | grep -A3 Events
  Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient nvidia.com/gpu.
```

**Meanwhile, `nvidia-smi` showed each GPU mostly empty:** each pod used a few GB of a large card, with low utilisation.

## 3. The diagnosis

This wasn't a hardware shortage. Each replica requested `nvidia.com/gpu: 1`, and with the stock plugin that means **one whole card** (see [01 — Introduction to GPUs](01-introduction-to-gpu.md#3-the-catch-a-gpu-is-handed-out-whole)). 4 GPUs = 4 pods, no matter how small each pod is. I had a **scheduling granularity problem**.

| | What I had | What I needed |
|---|---|---|
| Node `nvidia.com/gpu` capacity | 4 | enough slots for 10 replicas |
| Replicas Running | **4 / 10** | 10 / 10 |
| Memory each pod could see | the **whole card** | only the few GB it needs |

You can reproduce this exactly with **[Case 0a](06-test-cases.md#case-0--before-hami-vs-after-hami)** before installing HAMi.

## 4. What I tried / looked at

| Option | Why it didn't fit |
|---|---|
| **Buy more GPUs** | Expensive, and it doesn't fix the waste: each new card would also sit mostly idle |
| **Time-slicing** | More pods, but **no memory isolation**: one pod could take the whole card |
| **MPS** | Experimental in the k8s plugin, equal slices only, shared fault domain |
| **MIG** | Hardware isolation, but **only on certain GPU models and in fixed sizes** |
| **HAMi** | Any slice size, a per-pod memory cap, a scheduler that understands GPU memory, and no app changes |

## 5. Why HAMi fit my needs

| What I needed | Time-slicing | MPS | MIG | HAMi |
|---|---|---|---|---|
| More GPU pods than physical GPUs | ✅ | ✅ | ✅ (if card supports it) | ✅ |
| Each pod limited to its own memory | ❌ | ✅ | ✅ | ✅ |
| Different sizes per workload | ❌ | ❌ | ⚠️ fixed shapes | ✅ |
| Works on my GPUs | ✅ | ✅ | ⏳ *depends on model* | ✅ |
| Whole GPUs still possible for big jobs | ⚠️ | ⚠️ | ⚠️ repartition | ✅ |
| No app changes | ✅ | ✅ | ✅ | ✅ |

**The result with HAMi:** the node went from advertising **4 GPUs → 40 vGPUs**, and all 10 replicas ran, each limited to its own memory slice. How: [05 — How HAMi solved it & installation](05-hami-installation.md).

**Next:** [05 — How HAMi solved it & installation](05-hami-installation.md)
