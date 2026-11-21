#!/usr/bin/env bash
# Shows which physical GPU each pod was bound to, and how many pods share each GPU.
# Source of truth: the pod annotation hami.io/vgpu-devices-allocated written by the HAMi scheduler.
#
# Usage: scripts/verify-allocation.sh <namespace> <label-selector>
#   e.g. scripts/verify-allocation.sh hami-lab case=case1
#        scripts/verify-allocation.sh --all-namespaces case=case6
set -euo pipefail
table() { if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi; }

NS_ARG=(-n "${1:?namespace or --all-namespaces}")
[[ "$1" == "--all-namespaces" || "$1" == "-A" ]] && NS_ARG=(-A)
SEL="${2:?label selector, e.g. case=case0}"

JSON=$(kubectl get pods "${NS_ARG[@]}" -l "$SEL" -o json)

echo "== Per-pod mapping (namespace/pod  phase  node  ->  allocated devices) =="
echo "$JSON" | jq -r '.items[] |
  "\(.metadata.namespace)/\(.metadata.name)\t\(.status.phase)\t\(.spec.nodeName // "-")\t->  \(.metadata.annotations["hami.io/vgpu-devices-allocated"] // "none")"' \
  | table

echo
echo "== Pods per physical GPU (UUID) =="
echo "$JSON" | jq -r '.items[].metadata.annotations["hami.io/vgpu-devices-allocated"] // empty' \
  | grep -oE 'GPU-[0-9a-fA-F-]+' | sort | uniq -c | sort -rn || echo "(no allocations found)"

echo
echo "Tip: map UUIDs to GPU index with 'nvidia-smi -L' on the node."
