#!/bin/bash

set -e

CLUSTER_NAME="cos-cis-cluster"
ZONE="asia-southeast1-a"

echo -e "\e[1;33m[1/2] Fetching current Cloud Shell IP...\e[0m"
CURRENT_IP=$(curl -s ifconfig.me)
echo "Current IP: $CURRENT_IP"

echo -e "\e[1;33m[2/2] Updating master authorized networks and fetching credentials...\e[0m"
gcloud container clusters update $CLUSTER_NAME \
  --zone "$ZONE" \
  --enable-master-authorized-networks \
  --master-authorized-networks="${CURRENT_IP}/32" \
  --quiet

gcloud container clusters get-credentials $CLUSTER_NAME --zone "$ZONE" --quiet

echo -e "\e[1;32m\n✅ Access restored. kubectl is ready.\e[0m"
