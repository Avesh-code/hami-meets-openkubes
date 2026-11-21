#!/usr/bin/env bash
# Removes everything created by the test cases. HAMi itself is left installed.
# Usage: scripts/cleanup.sh            (all lab namespaces)
#        scripts/cleanup.sh case1      (only one case in hami-lab)
set -euo pipefail

if [[ $# -eq 1 ]]; then
  kubectl delete deploy,pod -n hami-lab -l "case=$1" --ignore-not-found
  exit 0
fi

kubectl delete namespace gpu-demo hami-lab team-a team-b --ignore-not-found
echo "Lab namespaces deleted. To uninstall HAMi: helm uninstall hami -n kube-system"
