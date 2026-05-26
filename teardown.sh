#!/bin/bash
# Completely tears down the GKE cluster, NAT, Router, Subnet, and VPC.

set -e

REGION="asia-southeast1"
ZONE="${REGION}-a"
CLUSTER_NAME="cos-cis-cluster"
NETWORK="cos-cis-net"
SUBNET="cos-cis-subnet"

echo -e "\e[1;31m=============================================================\e[0m"
echo -e "\e[1;31m             GKE DEMO ENVIRONMENT TEARDOWN\e[0m"
echo -e "\e[1;31m=============================================================\e[0m"

echo -e "\e[1;33m[1/5] Deleting GKE Cluster (This takes a few minutes)...\e[0m"
gcloud container clusters delete $CLUSTER_NAME --zone $ZONE --quiet

echo -e "\e[1;33m[2/5] Deleting Cloud NAT Config...\e[0m"
gcloud compute routers nats delete nat-config --router=nat-router --region=$REGION --quiet || true

echo -e "\e[1;33m[3/5] Deleting Cloud Router...\e[0m"
gcloud compute routers delete nat-router --region=$REGION --quiet || true

echo -e "\e[1;33m[4/5] Deleting Subnet...\e[0m"
gcloud compute networks subnets delete $SUBNET --region=$REGION --quiet || true

echo -e "\e[1;33m[5/5] Deleting VPC Network...\e[0m"
gcloud compute networks delete $NETWORK --quiet || true

echo -e "\e[1;32m\n✅ Teardown complete. All resources have been removed.\e[0m"
