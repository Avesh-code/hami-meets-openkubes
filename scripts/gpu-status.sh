#!/usr/bin/env bash
# GPU availability across the cluster. Works before AND after HAMi is installed,
# so the same command gives the before/after comparison.
#
#   1. GPU capacity / allocatable per node        (before HAMi: physical GPUs, after: physical x split)
#   2. GPU slots requested by pods per node       (Running + Pending)
#   3. Pending GPU pods (and why)
#   4. HAMi only: registered physical GPUs, pods per GPU, completely free GPUs
#
# Usage: scripts/gpu-status.sh
set -uo pipefail
table() { if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi; }

NODES_JSON=$(kubectl get nodes -o json)
PODS_JSON=$(kubectl get pods -A -o json)

echo "== 1. GPU capacity per node =="
{ printf 'NODE\tCAPACITY\tALLOCATABLE\n'
  echo "$NODES_JSON" | jq -r '.items[]
    | select(.status.capacity["nvidia.com/gpu"] != null)
    | [.metadata.name, .status.capacity["nvidia.com/gpu"], .status.allocatable["nvidia.com/gpu"]] | @tsv'
} | table

echo
echo "== 2. nvidia.com/gpu requested by pods (Running + Pending) =="
{ printf 'NODE\tGPU_REQUESTED\tPODS\n'
  echo "$PODS_JSON" | jq -r '.items[]
    | select(.status.phase=="Running" or .status.phase=="Pending")
    | {node: (.spec.nodeName // "<unscheduled>"),
       gpu: ([.spec.containers[].resources.limits["nvidia.com/gpu"] // "0" | tonumber] | add // 0)}
    | select(.gpu > 0) | [.node, .gpu] | @tsv' \
  | awk -F'\t' '{s[$1]+=$2; c[$1]++} END {for (n in s) print n"\t"s[n]"\t"c[n]}'
} | table

echo
echo "== 3. Pending GPU pods =="
PENDING=$(echo "$PODS_JSON" | jq -r '.items[]
  | select(.status.phase=="Pending")
  | select([.spec.containers[].resources.limits["nvidia.com/gpu"] // empty] | length > 0)
  | "\(.metadata.namespace)/\(.metadata.name)"')
if [[ -z "$PENDING" ]]; then
  echo "(none)"
else
  echo "$PENDING"
  FIRST=$(echo "$PENDING" | head -1)
  echo "-- reason for ${FIRST}:"
  kubectl get events -n "${FIRST%%/*}" --field-selector involvedObject.name="${FIRST##*/}" \
    -o jsonpath='{range .items[*]}{.reason}{": "}{.message}{"\n"}{end}' 2>/dev/null | tail -2
fi

# ---------------- HAMi view ----------------
REGISTERED=$(echo "$NODES_JSON" | jq -r '.items[].metadata.annotations["hami.io/node-nvidia-register"] // empty' \
  | grep -oE 'GPU-[0-9a-fA-F-]+' | sort -u)
if [[ -z "$REGISTERED" ]]; then
  echo
  echo "(HAMi not detected: no hami.io/node-nvidia-register annotation on any node)"
  exit 0
fi

USED=$(echo "$PODS_JSON" | jq -r '.items[] | select(.status.phase=="Running")
  | .metadata.annotations["hami.io/vgpu-devices-allocated"] // empty' | grep -oE 'GPU-[0-9a-fA-F-]+')

echo
echo "== 4. HAMi: pods per physical GPU =="
{ printf 'GPU_UUID\tPODS\n'
  for U in $REGISTERED; do
    printf '%s\t%s\n' "$U" "$(echo "$USED" | grep -c "^$U$" || true)"
  done
} | table

FREE=$(for U in $REGISTERED; do echo "$USED" | grep -q "^$U$" || echo "$U"; done)
echo
echo "Physical GPUs registered: $(echo "$REGISTERED" | wc -l | tr -d ' ')"
echo "Completely free (no pods): $( [[ -z "$FREE" ]] && echo 0 || echo "$FREE" | wc -l | tr -d ' ')"
echo "Tip: map UUIDs to GPU index with 'nvidia-smi -L' on the node."
