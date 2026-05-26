#!/bin/bash

# ==============================================================================
# GKE COS CIS Level 2 Compliance — Production Setup
# ==============================================================================

set -e

REGION="asia-southeast1"
ZONE="${REGION}-a"
CLUSTER_NAME="cos-cis-prod-cluster"
NETWORK="cos-cis-net"
SUBNET="cos-cis-subnet"
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

CLOUD_INIT_USERDATA='#cloud-config
runcmd:
  - systemctl start cis-level2.service
  - sed -i "s/^LEVEL=.*$/LEVEL=\"2\"/" /etc/cis-scanner/env_vars
  - systemctl start cis-compliance-scanner.timer'

echo -e "\e[1;34m[1/5] Enabling required Google Cloud APIs...\e[0m"
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  logging.googleapis.com > /dev/null 2>&1

echo -e "\e[1;34m[2/5] Setting up VPC, Subnet, and Cloud NAT...\e[0m"
if ! gcloud compute networks describe $NETWORK --format="value(name)" >/dev/null 2>&1; then
  gcloud compute networks create $NETWORK --subnet-mode=custom > /dev/null 2>&1
else
  echo "  -> [INFO] Network '$NETWORK' already exists, skipping."
fi

if ! gcloud compute networks subnets describe $SUBNET --region=$REGION --format="value(name)" >/dev/null 2>&1; then
  gcloud compute networks subnets create $SUBNET --network=$NETWORK --region=$REGION --range=10.20.0.0/24 > /dev/null 2>&1
else
  echo "  -> [INFO] Subnet '$SUBNET' already exists, skipping."
fi

if ! gcloud compute routers describe nat-router --region=$REGION --format="value(name)" >/dev/null 2>&1; then
  gcloud compute routers create nat-router --network $NETWORK --region $REGION > /dev/null 2>&1
else
  echo "  -> [INFO] Router 'nat-router' already exists, skipping."
fi

if ! gcloud compute routers nats describe nat-config --router=nat-router --region=$REGION --format="value(name)" >/dev/null 2>&1; then
  gcloud compute routers nats create nat-config --router=nat-router \
    --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges --region=$REGION > /dev/null 2>&1
else
  echo "  -> [INFO] NAT config 'nat-config' already exists, skipping."
fi

echo -e "\e[1;34m[3/5] Creating GKE cluster with CIS Level 2 node pool...\e[0m"
CURRENT_IP=$(curl -s ifconfig.me)

if gcloud container clusters describe $CLUSTER_NAME --zone=$ZONE --format="value(name)" >/dev/null 2>&1; then
  echo "  -> [INFO] Cluster '$CLUSTER_NAME' already exists, skipping creation."
  gcloud container clusters update $CLUSTER_NAME --zone "$ZONE" \
    --enable-master-authorized-networks \
    --master-authorized-networks="${CURRENT_IP}/32" \
    --quiet > /dev/null 2>&1 || true
else
  echo "  -> [INFO] Creating cluster (this will take several minutes)..."
  gcloud container clusters create $CLUSTER_NAME \
    --zone "$ZONE" \
    --network "$NETWORK" \
    --subnetwork "$SUBNET" \
    --num-nodes 2 \
    --image-type "COS_CONTAINERD" \
    --release-channel stable \
    --enable-network-policy \
    --enable-shielded-nodes \
    --shielded-integrity-monitoring \
    --shielded-secure-boot \
    --enable-private-nodes \
    --enable-ip-alias \
    --enable-master-authorized-networks \
    --master-authorized-networks="${CURRENT_IP}/32" \
    --master-ipv4-cidr 172.16.1.0/28 \
    --enable-intra-node-visibility \
    --metadata "user-data=${CLOUD_INIT_USERDATA}" > /dev/null
fi

echo -e "\e[1;34m[4/5] Fetching cluster credentials...\e[0m"
gcloud container clusters get-credentials $CLUSTER_NAME --zone "$ZONE" > /dev/null 2>&1

echo -e "\e[1;34m[5/5] Waiting 90s for nodes to boot and run cloud-init...\e[0m"
sleep 90

echo -e "\e[1;33m\nQuerying Cloud Logging for CIS scan results...\e[0m"
echo -e "\e[1;30m-------------------------------------------------------------\e[0m"
gcloud logging read \
  'resource.type="gce_instance"
   log_name="projects/'$PROJECT_ID'/logs/cos_containers"
   jsonPayload.SYSLOG_IDENTIFIER="cis_scanner"' \
  --project="$PROJECT_ID" \
  --freshness=10m \
  --format="value(jsonPayload.MESSAGE)" \
  --limit=20 2>/dev/null \
  | grep -E 'Running scan of|Scan status:|Found.*non-compliant|Writing scan results' \
  || echo "  -> [INFO] No entries yet — scanner may still be running. Retry in a few minutes."
echo -e "\e[1;30m-------------------------------------------------------------\e[0m"

echo -e "\e[1;34m\nLog filter for ongoing monitoring in Cloud Logging:\e[0m"
cat << EOF

  resource.type="gce_instance"
  log_name="projects/${PROJECT_ID}/logs/cos_containers"
  jsonPayload.SYSLOG_IDENTIFIER="cis_scanner"
  jsonPayload.MESSAGE=~"non_compliant"

EOF

echo -e "\e[1;33mSetup complete.\e[0m"
