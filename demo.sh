#!/bin/bash

# ==============================================================================
# GKE COS CIS Level 1 & 2 Compliance Demo
# ==============================================================================

set -e

# Configuration Variables
PROJECT_ID=$(gcloud config get-value project)
REGION="asia-southeast1"
ZONE="${REGION}-a"
CLUSTER_NAME="cos-cis-cluster"
NETWORK="cos-cis-net"
SUBNET="cos-cis-subnet"

# --- Helper Function for the Executive Summary ---
print_summary() {
  local raw_output="$1"
  local compliant=$(echo "$raw_output" | grep -E '^[[:space:]]*compliant_benchmarks' | wc -l)
  local non_compliant=$(echo "$raw_output" | grep -E '^[[:space:]]*non_compliant_benchmarks' | wc -l)
  local total=$((compliant + non_compliant))
  
  local level="CIS Level 1"
  if [ "$total" -ge 80 ]; then
      level="CIS Level 2"
  fi
  
  echo -e "\e[1;36m\n=============================================================\e[0m"
  echo -e "\e[1;36m             COMPLIANCE SUMMARY\e[0m"
  echo -e "\e[1;36m=============================================================\e[0m"
  echo -e "\e[1;37m Active Profile:   \e[1;32m$level Enforced\e[0m"
  echo -e "\e[1;37m Checks Passed:    \e[1;32m$compliant / $total\e[0m"
  
  if [ "$non_compliant" -eq 0 ]; then
      echo -e "\e[1;37m Checks Failed:    \e[1;32m0\e[0m"
  else
      echo -e "\e[1;37m Checks Failed:    \e[1;31m$non_compliant\e[0m"
  fi
  echo -e "\e[1;36m=============================================================\n\e[0m"
}
# -----------------------------------------------

echo -e "\e[1;34m[1/8] Enabling required Google Cloud APIs...\e[0m"
gcloud services enable container.googleapis.com compute.googleapis.com --quiet

echo -e "\e[1;34m[2/8] Setting up VPC, Subnet, and Cloud NAT (Required for Private Nodes)...\e[0m"

# Create Network
if gcloud compute networks describe $NETWORK --format="value(name)" 2>/dev/null; then
    echo "  -> [INFO] Network '$NETWORK' already exists, skipping."
else
    gcloud compute networks create $NETWORK --subnet-mode=custom
fi

# Create Subnet
if gcloud compute networks subnets describe $SUBNET --region=$REGION --format="value(name)" 2>/dev/null; then
    echo "  -> [INFO] Subnet '$SUBNET' already exists, skipping."
else
    gcloud compute networks subnets create $SUBNET \
      --network=$NETWORK \
      --region=$REGION \
      --range=10.20.0.0/24
fi

# Create Router
if gcloud compute routers describe nat-router --region=$REGION --format="value(name)" 2>/dev/null; then
    echo "  -> [INFO] Router 'nat-router' already exists, skipping."
else
    gcloud compute routers create nat-router --network $NETWORK --region $REGION
fi

# Create NAT Config
if gcloud compute routers nats describe nat-config --router=nat-router --region=$REGION --format="value(name)" 2>/dev/null; then
    echo "  -> [INFO] NAT config 'nat-config' already exists, skipping."
else
    gcloud compute routers nats create nat-config \
        --router=nat-router \
        --auto-allocate-nat-external-ips \
        --nat-all-subnet-ip-ranges \
        --region=$REGION
fi

echo -e "\e[1;34m[3/8] Checking GKE Cluster Status...\e[0m"
# Fetching current IP for Master Authorized Networks
CURRENT_IP=$(curl -s ifconfig.me)

if gcloud container clusters describe $CLUSTER_NAME --zone=$ZONE --format="value(name)" 2>/dev/null; then
    echo "  -> [INFO] Cluster '$CLUSTER_NAME' already exists, skipping creation."
    
    # Optional: Update the master authorized networks just in case the Cloud Shell IP changed
    gcloud container clusters update $CLUSTER_NAME \
      --zone "$ZONE" \
      --enable-master-authorized-networks \
      --master-authorized-networks="${CURRENT_IP}/32" \
      --quiet > /dev/null 2>&1 || true
else
    echo "  -> [INFO] Creating new cluster (this will take several minutes)..."
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
      --enable-intra-node-visibility
fi

echo -e "\e[1;34m[4/8] Fetching Cluster Credentials...\e[0m"
gcloud container clusters get-credentials $CLUSTER_NAME --zone "$ZONE"

echo -e "\e[1;34m[5/8] Deploying a temporary 'Reader' pod to check the baseline...\e[0m"
cat << 'EOF' > cos-cis-reader.yaml
apiVersion: v1
kind: Pod
metadata:
  name: cos-cis-reader
  namespace: kube-system
spec:
  hostPID: true
  containers:
  - name: reader
    image: ubuntu
    securityContext:
      privileged: true
    command: ["/bin/bash", "-c", "sleep infinity"]
EOF

# Ensure we have a clean slate if the pod was left running
kubectl delete -f cos-cis-reader.yaml --ignore-not-found=true --wait=false &>/dev/null
kubectl apply -f cos-cis-reader.yaml
kubectl wait --for=condition=Ready pod/cos-cis-reader -n kube-system --timeout=120s

echo -e "\e[1;33m\n[ Waiting for Boot Scanner to Finish (up to 60s) ]...\e[0m"
# Loop until the file is written and contains "SUCCEEDED"
for i in {1..30}; do
  RAW_BASELINE=$(kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- cat /var/lib/google/cis_scanner_scan_result.textproto 2>/dev/null || true)
  if echo "$RAW_BASELINE" | grep -q "SUCCEEDED"; then
    break
  fi
  sleep 2
done

echo -e "\e[1;33m\n[ BASELINE RESULTS ]\e[0m"
echo "By default, GKE COS images are configured for CIS Level 1."
print_summary "$RAW_BASELINE"

# Wait for customer input
read -p $'\e[1;32mPress [ENTER] to deploy the DaemonSet, enforce CIS Level 2, and update the periodic scanner...\e[0m'

echo -e "\e[1;34m[6/8] Generating and applying the CIS Level 2 Enforcer DaemonSet...\e[0m"
cat << 'EOF' > cos-cis-enforcer.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cos-cis-enforcer
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: cos-cis-enforcer
  template:
    metadata:
      labels:
        name: cos-cis-enforcer
    spec:
      hostPID: true
      containers:
      - name: enforcer
        image: ubuntu
        securityContext:
          privileged: true
        command:
        - /bin/bash
        - -c
        - |
          nsenter -t 1 -m -u -i -n -p -- /bin/bash -c "
            systemctl start cis-level2.service
            sed -i 's/^LEVEL=.*$/LEVEL=\"2\"/' /etc/cis-scanner/env_vars
            systemctl start cis-compliance-scanner.timer
          "
          sleep infinity
EOF
kubectl apply -f cos-cis-enforcer.yaml

echo -e "\e[1;34m[7/8] Waiting for DaemonSet to execute on all nodes (approx 30 seconds)...\e[0m"
kubectl rollout status daemonset/cos-cis-enforcer -n kube-system --timeout=120s
sleep 15 # Give systemd time to configure the OS and run the new scan

echo -e "\e[1;33m\n[ ENFORCED RESULTS ]\e[0m"
RAW_ENFORCED=$(kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- cat /var/lib/google/cis_scanner_scan_result.textproto)
print_summary "$RAW_ENFORCED"

echo -e "\e[1;33mDemo complete!\e[0m"

# Cleanup the reader pod
kubectl delete -f cos-cis-reader.yaml --wait=false &>/dev/null
