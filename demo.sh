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

echo -e "\e[1;34m[1/8] Enabling required Google Cloud APIs...\e[0m"
gcloud services enable container.googleapis.com compute.googleapis.com

echo -e "\e[1;34m[2/8] Setting up VPC, Subnet, and Cloud NAT (Required for Private Nodes)...\e[0m"
# Create Network and Subnet
gcloud compute networks create $NETWORK --subnet-mode=custom || true
gcloud compute networks subnets create $SUBNET \
  --network=$NETWORK \
  --region=$REGION \
  --range=10.20.0.0/24 || true

# Create Cloud Router and NAT (so private nodes can pull the ubuntu image)
gcloud compute routers create nat-router --network $NETWORK --region $REGION || true
gcloud compute routers nats create nat-config \
    --router=nat-router \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ips-ranges \
    --region=$REGION || true

echo -e "\e[1;34m[3/8] Creating GKE Cluster with COS & strong defaults...\e[0m"
# Fetching current IP for Master Authorized Networks
CURRENT_IP=$(curl -s ifconfig.me)

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

echo -e "\e[1;34m[4/8] Fetching Cluster Credentials...\e[0m"
gcloud container clusters get-credentials $CLUSTER_NAME --zone "$ZONE"

echo -e "\e[1;34m[5/8] Deploying a temporary 'Reader' pod to check the baseline (CIS Level 1)...\e[0m"
# We deploy a sleep pod with host access to read the local COS file
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
kubectl apply -f cos-cis-reader.yaml
kubectl wait --for=condition=Ready pod/cos-cis-reader -n kube-system --timeout=120s

echo -e "\e[1;33m\n====================================================================\e[0m"
echo -e "\e[1;33m BASELINE RESULTS (CIS LEVEL 1)\e[0m"
echo -e "\e[1;33m====================================================================\e[0m"
echo "By default, GKE COS images are configured for CIS Level 1."
echo "Fetching the built-in scanner results directly from the node's disk..."
sleep 2 # Ensure systemd has written the file

# Read the file and summarize it
kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- cat /var/lib/google/cis_scanner_scan_result.textproto > baseline_results.txt
grep -A 1 "status {" baseline_results.txt
NON_COMPLIANT_L1=$(grep -c "id:" baseline_results.txt || true)
echo -e "\e[1;31mTotal IDs found in report (Review baseline_results.txt for details)\e[0m"
echo -e "\e[1;33m====================================================================\n\e[0m"

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
            echo 'Applying CIS Level 2...'
            systemctl start cis-level2.service
            sed -i 's/^LEVEL=.*$/LEVEL=\"2\"/' /etc/cis-scanner/env_vars
            systemctl start cis-compliance-scanner.timer
          "
          sleep infinity
EOF
kubectl apply -f cos-cis-enforcer.yaml

echo -e "\e[1;34m[7/8] Waiting for DaemonSet to execute on all nodes (approx 30 seconds)...\e[0m"
kubectl rollout status daemonset/cos-cis-enforcer -n kube-system --timeout=120s
sleep 15 # Give the systemd service time to configure the OS and run the new scan

echo -e "\e[1;33m\n====================================================================\e[0m"
echo -e "\e[1;33m ENFORCED RESULTS (CIS LEVEL 2)\e[0m"
echo -e "\e[1;33m====================================================================\e[0m"
echo "Fetching the updated scanner results..."

kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- cat /var/lib/google/cis_scanner_scan_result.textproto > enforced_results.txt
echo -e "\n\e[1;32mScan Status:\e[0m"
grep -A 1 "status {" enforced_results.txt

echo -e "\n\e[1;31mNon-Compliant Benchmarks (If Any):\e[0m"
# Extract only the non-compliant section using awk
awk '/non_compliant_benchmarks: \{/{flag=1; print; next} /compliant_benchmarks: \{/{flag=0} flag' enforced_results.txt

echo -e "\e[1;33m====================================================================\e[0m"
echo -e "Demo complete! Full logs saved locally to 'baseline_results.txt' and 'enforced_results.txt'."

# Cleanup the reader pod
kubectl delete -f cos-cis-reader.yaml --wait=false &>/dev/null
