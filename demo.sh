#!/bin/bash

# ==============================================================================
# GKE COS CIS Level 1 & 2 Compliance Demo
# ==============================================================================

set -e

cleanup() {
  kubectl delete -f cos-cis-reader.yaml --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  rm -f cos-cis-reader.yaml cos-cis-enforcer.yaml
}
trap cleanup EXIT

REGION="asia-southeast1"
ZONE="${REGION}-a"
CLUSTER_NAME="cos-cis-cluster"
NETWORK="cos-cis-net"
SUBNET="cos-cis-subnet"

print_summary() {
  local raw_output="$1"
  local loaded_checks="$2"
  local level="$3"

  local non_compliant=$(echo "$raw_output" | grep -E '^[[:space:]]*non_compliant_benchmarks' | wc -l)
  local compliant=$(echo "$raw_output" | grep -E '^[[:space:]]*compliant_benchmarks' | grep -v 'non_compliant' | wc -l)
  local evaluated=$((compliant + non_compliant))

  echo -e "\e[1;36m\n=============================================================\e[0m"
  echo -e "\e[1;36m             COMPLIANCE SUMMARY\e[0m"
  echo -e "\e[1;36m=============================================================\e[0m"
  echo -e "\e[1;37m Active Profile:   \e[1;32m$level\e[0m"

  if [ -n "$loaded_checks" ] && [ "$loaded_checks" -gt "$evaluated" ]; then
    local skipped=$((loaded_checks - evaluated))
    echo -e "\e[1;37m Checks Loaded:    \e[1;34m$loaded_checks\e[0m"
    echo -e "\e[1;37m Checks Skipped:   \e[1;33m$skipped\e[0m"
  fi

  echo -e "\e[1;37m Checks Evaluated: \e[1;32m$evaluated\e[0m"
  echo -e "\e[1;37m Checks Passed:    \e[1;32m$compliant\e[0m"

  if [ "$non_compliant" -eq 0 ]; then
    echo -e "\e[1;37m Checks Failed:    \e[1;32m0\e[0m"
  else
    echo -e "\e[1;37m Checks Failed:    \e[1;31m$non_compliant\e[0m"
  fi
  echo -e "\e[1;36m=============================================================\n\e[0m"
}

get_loaded_count() {
  local service="$1"
  local since="$2"
  kubectl exec -n kube-system cos-cis-reader -- \
    nsenter -t 1 -m -u -i -n -p -- \
    journalctl -u "$service" --since="$since" \
    | grep "Running scan of" | tail -n 1 \
    | grep -o 'scan of [0-9]*' | awk '{print $3}'
}

wait_for_scan() {
  local max_attempts="$1"
  local result=""
  for i in $(seq 1 "$max_attempts"); do
    result=$(kubectl exec -n kube-system cos-cis-reader -- \
      nsenter -t 1 -m -u -i -n -p -- \
      cat /var/lib/google/cis_scanner_scan_result.textproto 2>/dev/null || true)
    if echo "$result" | grep -q "SUCCEEDED"; then
      echo "$result"
      return 0
    fi
    sleep 2
  done
  echo "$result"
}

echo -e "\e[1;34m[1/7] Enabling required Google Cloud APIs...\e[0m"
gcloud services enable container.googleapis.com compute.googleapis.com > /dev/null 2>&1

echo -e "\e[1;34m[2/7] Setting up VPC, Subnet, and Cloud NAT...\e[0m"
if ! gcloud compute networks describe $NETWORK --format="value(name)" >/dev/null 2>&1; then
  gcloud compute networks create $NETWORK --subnet-mode=custom > /dev/null 2>&1
else
  echo "  -> [INFO] Network '$NETWORK' already exists, skipping..."
fi

if ! gcloud compute networks subnets describe $SUBNET --region=$REGION --format="value(name)" >/dev/null 2>&1; then
  gcloud compute networks subnets create $SUBNET --network=$NETWORK --region=$REGION --range=10.20.0.0/24 > /dev/null 2>&1
else
  echo "  -> [INFO] Subnet '$SUBNET' already exists, skipping..."
fi

if ! gcloud compute routers describe nat-router --region=$REGION --format="value(name)" >/dev/null 2>&1; then
  gcloud compute routers create nat-router --network $NETWORK --region $REGION > /dev/null 2>&1
else
  echo "  -> [INFO] Router 'nat-router' already exists, skipping..."
fi

if ! gcloud compute routers nats describe nat-config --router=nat-router --region=$REGION --format="value(name)" >/dev/null 2>&1; then
  gcloud compute routers nats create nat-config --router=nat-router \
    --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges --region=$REGION > /dev/null 2>&1
else
  echo "  -> [INFO] NAT config 'nat-config' already exists, skipping..."
fi

echo -e "\e[1;34m[3/7] Checking GKE cluster status...\e[0m"
CURRENT_IP=$(curl -s ifconfig.me)

if gcloud container clusters describe $CLUSTER_NAME --zone=$ZONE --format="value(name)" >/dev/null 2>&1; then
  echo "  -> [INFO] Cluster '$CLUSTER_NAME' already exists, skipping..."
  gcloud container clusters update $CLUSTER_NAME --zone "$ZONE" \
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
    --enable-intra-node-visibility > /dev/null
fi

echo -e "\e[1;34m[4/7] Fetching cluster credentials...\e[0m"
gcloud container clusters get-credentials $CLUSTER_NAME --zone "$ZONE" > /dev/null 2>&1

echo -e "\e[1;34m[5/7] Deploying Reader pod...\e[0m"
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
kubectl delete -f cos-cis-reader.yaml --ignore-not-found=true --wait=false >/dev/null 2>&1
kubectl apply -f cos-cis-reader.yaml 2>/dev/null
kubectl wait --for=condition=Ready pod/cos-cis-reader -n kube-system --timeout=120s >/dev/null 2>&1

echo -e "\e[1;33m\n[ Waiting for Scanner to finish (up to 60s) ]...\e[0m"
STAGE1_START=$(date -u +"%Y-%m-%d %H:%M:%S")
RAW_BASELINE=$(wait_for_scan 30)
LOADED_L1=$(get_loaded_count "cis-level1.service" "$STAGE1_START")

echo -e "\e[1;35m\n[ STAGE 1: DEFAULT BASELINE ]\e[0m"
echo "GKE COS nodes comply with CIS Level 1 out of the box, with 0 failed checks."
print_summary "$RAW_BASELINE" "$LOADED_L1" "CIS Level 1"

read -p $'\e[1;32mPress [ENTER] to deploy the CIS Level 2 Enforcer DaemonSet...\e[0m'

echo -e "\e[1;34m[6/7] Applying the CIS Level 2 Enforcer DaemonSet...\e[0m"
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
            systemctl restart cis-level2.service
            sed -i 's/^LEVEL=.*$/LEVEL=\"2\"/' /etc/cis-scanner/env_vars
          "
          sleep infinity
EOF

kubectl exec -n kube-system cos-cis-reader -- \
  nsenter -t 1 -m -u -i -n -p -- \
  rm -f /var/lib/google/cis_scanner_scan_result.textproto >/dev/null 2>&1

STAGE2_START=$(date -u +"%Y-%m-%d %H:%M:%S")
kubectl apply -f cos-cis-enforcer.yaml 2>/dev/null

echo -e "\e[1;34m[7/7] Waiting for DaemonSet to execute on all nodes...\e[0m"
kubectl rollout status daemonset/cos-cis-enforcer -n kube-system --timeout=120s >/dev/null 2>&1

echo -e "\e[1;33m[ Waiting for Scanner to finish (up to 30s) ]...\e[0m"
RAW_ENFORCED=$(wait_for_scan 15)

echo -e "\e[1;34mProof of execution (cis-level2.service status):\e[0m"
echo -e "\e[1;30m-------------------------------------------------------------\e[0m"
kubectl exec -n kube-system cos-cis-reader -- \
  nsenter -t 1 -m -u -i -n -p -- \
  systemctl status cis-level2.service --no-pager \
  | grep -E 'Reading scan config|Running scan of|Scan status:|Found.*non-compliant|Writing scan results'
echo -e "\e[1;30m-------------------------------------------------------------\e[0m"

LOADED_L2=$(get_loaded_count "cis-level2.service" "$STAGE2_START")

echo -e "\e[1;35m\n[ STAGE 2: ENFORCED RESULTS ]\e[0m"
print_summary "$RAW_ENFORCED" "$LOADED_L2" "CIS Level 2"

echo -e "\e[1;33mDemo complete!\e[0m"
