#!/bin/bash

set -e

ZONE="asia-southeast1-a"
CLUSTER_NAME="cos-cis-cluster"

echo -e "\e[1;34m=============================================================\e[0m"
echo -e "\e[1;34m             GKE DEMO ENVIRONMENT RESET\e[0m"
echo -e "\e[1;34m=============================================================\e[0m"

echo -e "\e[1;33m[1/3] Removing the CIS Level 2 Enforcer DaemonSet...\e[0m"
kubectl delete daemonset cos-cis-enforcer -n kube-system --ignore-not-found=true

echo -e "\e[1;33m[2/3] Scaling node pool to 0 (destroying hardened VMs)...\e[0m"
gcloud container clusters resize $CLUSTER_NAME --node-pool default-pool --num-nodes 0 --zone $ZONE --quiet

echo -e "\e[1;33m[3/3] Scaling node pool back to 2 (provisioning fresh VMs)...\e[0m"
gcloud container clusters resize $CLUSTER_NAME --node-pool default-pool --num-nodes 2 --zone $ZONE --quiet

echo -e "\e[1;32m\n✅ Cluster reset. Nodes are back to the default CIS Level 1 baseline.\e[0m"
