#!/bin/bash

set -e

echo -e "\e[1;34m=============================================================\e[0m"
echo -e "\e[1;34m             GKE DEMO ENVIRONMENT RESET\e[0m"
echo -e "\e[1;34m=============================================================\e[0m"

echo -e "\e[1;33m[1/3] Removing the CIS Level 2 Enforcer DaemonSet...\e[0m"
# Delete the DaemonSet first so it doesn't immediately harden the new nodes
kubectl delete daemonset cos-cis-enforcer -n kube-system --ignore-not-found=true

echo -e "\e[1;33m[2/3] Scaling node pool to 0 (Destroying hardened VMs)...\e[0m"
# Tear down the permanently modified underlying OS instances
gcloud container clusters resize cos-cis-cluster --node-pool default-pool --num-nodes 0 --zone asia-southeast1-a --quiet

echo -e "\e[1;33m[3/3] Scaling node pool back to 2 (Provisioning fresh VMs)...\e[0m"
# Spin up clean instances that default back to the CIS Level 1 baseline
gcloud container clusters resize cos-cis-cluster --node-pool default-pool --num-nodes 2 --zone asia-southeast1-a --quiet

echo -e "\e[1;32m\n✅ Cluster successfully reset! The nodes are now back to the default CIS Level 1 baseline.\e[0m"
