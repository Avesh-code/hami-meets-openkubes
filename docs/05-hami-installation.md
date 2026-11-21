# 05 — How HAMi Solved It & Installation

## How HAMi solved my scaling issue

HAMi replaces the stock NVIDIA device plugin. It advertises each physical GPU as **10 virtual GPUs**, and caps each pod at the memory it asks for.

| | Before HAMi | After HAMi |
|---|---|---|
| Node `nvidia.com/gpu` capacity | **4** | **40** (4 × 10) |
| Scale `gpu-app` to 10 replicas | 4 Running, 6 Pending | **10 Running** |
| What each pod sees | the whole card | only its slice (e.g. 4096 MiB) |
| Change to the app | — | one line: `nvidia.com/gpumem: 4096` |

> Run **[Case 0a](06-test-cases.md#case-0--before-hami-vs-after-hami)** (the "before" test) **before** you remove the stock plugin in 5.2.

---

## 5. Installation

### 5.1 Prerequisites

- A working Kubernetes cluster with GPU nodes.
- NVIDIA driver installed on each GPU node.
- NVIDIA container runtime configured as the default runtime (if the stock NVIDIA
  device plugin already exposes GPUs, this is already satisfied).
- Helm installed and configured against the cluster.

### 5.2 Important pre-checks

**A. Remove the stock NVIDIA device plugin.**
HAMi ships its own device plugin that also registers `nvidia.com/gpu`. The HAMi
plugin and the official NVIDIA plugin **must not coexist** on the same node — both
registering the same resource causes conflicts.

```bash
# find how it was deployed first
helm list -A | grep -i gpu
kubectl -n kube-system get daemonset | grep -i nvidia

# if it is a standalone daemonset, remove it
kubectl -n kube-system delete daemonset <nvidia-device-plugin-daemonset>
```
> If the plugin was installed by the NVIDIA GPU Operator, do **not** delete the
> daemonset directly — instead disable the operator's built-in plugin
> (`devicePlugin.enabled=false`).

**B. Label your GPU nodes.**
HAMi's scheduler only manages nodes labeled `gpu=on`. Without this label the node
cannot be scheduled by HAMi.

```bash
kubectl label node <gpu-node> gpu=on --overwrite
```

**C. Match the scheduler image to your Kubernetes version.**
`scheduler.kubeScheduler.imageTag` must match the cluster's **API-server** version.
A mismatch is the most common cause of a silent scheduling failure.

```bash
kubectl version | grep -i server     # e.g. Server Version: v1.33.x
```

### 5.3 Install with Helm

```bash
helm repo add hami-charts https://project-hami.github.io/HAMi
helm repo update

helm install hami hami-charts/hami \
  --set scheduler.kubeScheduler.imageTag=<vX.YY.Z> \
  -n kube-system
```

Replace `<vX.YY.Z>` with the server version from the pre-check.

### 5.4 Verify the install

```bash
kubectl -n kube-system get pods | grep hami
```

Expected — one device-plugin pod **per GPU node** plus the scheduler, all `Running`:

```
hami-device-plugin-xxxxx   2/2   Running   0   ...
hami-device-plugin-yyyyy   2/2   Running   0   ...
hami-scheduler-zzzzz       2/2   Running   0   ...
```

Confirm the nodes now advertise vGPUs (physical × split count, default ×10):

```bash
kubectl get node <gpu-node> -o jsonpath='{.status.capacity.nvidia\.com/gpu}{"\n"}'
# a node with 8 physical GPUs should now report 80
```

Confirm HAMi inventoried the physical cards:

```bash
kubectl get node <gpu-node> -o yaml | grep -i hami.io/node-nvidia-register
# lists each GPU UUID, index, count (split), devmem (MiB), devcore
```

### 5.5 HAMi values explained

The defaults work out of the box. [`manifests/hami-values.yaml`](../manifests/hami-values.yaml) writes down the ones this lab cares about; to use it, add `-f manifests/hami-values.yaml` to the `helm install` command.

| Key | Value | What it means |
|---|---|---|
| `devices.nvidia.deviceSplitCount` | `10` | Max pods sharing one physical GPU. Node capacity = GPUs × 10. |
| `devices.nvidia.deviceMemoryScaling` | `1` | `1` = no memory overcommit |
| `devices.nvidia.deviceCoreScaling` | `1` | `1` = no compute overcommit |
| `devicePlugin.nvidiaDriverRoot` | `/` | Where the driver lives. `/run/nvidia/driver` if the GPU Operator installed it. |
| `scheduler.defaultSchedulerPolicy.nodeSchedulerPolicy` | `binpack` | Fill one node before the next |
| `scheduler.defaultSchedulerPolicy.gpuSchedulerPolicy` | `spread` | Put each new pod on the least-used GPU. Pods can override this with the `hami.io/gpu-scheduler-policy` annotation (see [Case 8](06-test-cases.md#case-8--schedule-pattern-change-binpack-vs-spread)). |

---

Now run **[Case 0b](06-test-cases.md#case-0--before-hami-vs-after-hami)** (the "after" test), then the other cases.

**Next:** [06 — Test cases](06-test-cases.md)
