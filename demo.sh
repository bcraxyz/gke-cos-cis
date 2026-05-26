#!/bin/bash

# ==============================================================================
# GKE COS CIS Level 1 & 2 Compliance Demo (3-Stage)
# ==============================================================================

set -e

PROJECT_ID=$(gcloud config get-value project 2>/dev/null) 
REGION="asia-southeast1"
ZONE="${REGION}-a"
CLUSTER_NAME="cos-cis-cluster"
NETWORK="cos-cis-net"
SUBNET="cos-cis-subnet"

# --- Updated Helper Function with Dynamic "Skipped" Math ---
print_summary() {
  local raw_output="$1"
  local loaded_checks="$2"
  
  local compliant=$(echo "$raw_output" | grep -E '^[[:space:]]*compliant_benchmarks' | wc -l)
  local non_compliant=$(echo "$raw_output" | grep -E '^[[:space:]]*non_compliant_benchmarks' | wc -l)
  local evaluated=$((compliant + non_compliant))
  
  local level="CIS Level 1"
  if [ "$evaluated" -ge 80 ]; then
      level="CIS Level 2"
  fi
  
  echo -e "\e[1;36m\n=============================================================\e[0m"
  echo -e "\e[1;36m             COMPLIANCE SUMMARY\e[0m"
  echo -e "\e[1;36m=============================================================\e[0m"
  echo -e "\e[1;37m Active Profile:   \e[1;32m$level Enforced\e[0m"
  
  # Dynamically calculate skipped checks if we successfully pulled the loaded count
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
# -----------------------------------------------

echo -e "\e[1;34m[1/8] Enabling required Google Cloud APIs...\e[0m"
gcloud services enable container.googleapis.com compute.googleapis.com > /dev/null 2>&1

echo -e "\e[1;34m[2/8] Setting up VPC, Subnet, and Cloud NAT...\e[0m"
if gcloud compute networks describe $NETWORK --format="value(name)" >/dev/null 2>&1; then
    echo "  -> [INFO] Network '$NETWORK' already exists, skipping."
else
    gcloud compute networks create $NETWORK --subnet-mode=custom > /dev/null 2>&1
fi

if gcloud compute networks subnets describe $SUBNET --region=$REGION --format="value(name)" >/dev/null 2>&1; then
    echo "  -> [INFO] Subnet '$SUBNET' already exists, skipping."
else
    gcloud compute networks subnets create $SUBNET --network=$NETWORK --region=$REGION --range=10.20.0.0/24 > /dev/null 2>&1
fi

if gcloud compute routers describe nat-router --region=$REGION --format="value(name)" >/dev/null 2>&1; then
    echo "  -> [INFO] Router 'nat-router' already exists, skipping."
else
    gcloud compute routers create nat-router --network $NETWORK --region $REGION > /dev/null 2>&1
fi

if gcloud compute routers nats describe nat-config --router=nat-router --region=$REGION --format="value(name)" >/dev/null 2>&1; then
    echo "  -> [INFO] NAT config 'nat-config' already exists, skipping."
else
    gcloud compute routers nats create nat-config --router=nat-router --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges --region=$REGION > /dev/null 2>&1
fi

echo -e "\e[1;34m[3/8] Checking GKE Cluster Status...\e[0m"
CURRENT_IP=$(curl -s ifconfig.me)

if gcloud container clusters describe $CLUSTER_NAME --zone=$ZONE --format="value(name)" >/dev/null 2>&1; then
    echo "  -> [INFO] Cluster '$CLUSTER_NAME' already exists, skipping creation."
    gcloud container clusters update $CLUSTER_NAME --zone "$ZONE" --enable-master-authorized-networks --master-authorized-networks="${CURRENT_IP}/32" --quiet > /dev/null 2>&1 || true
else
    echo "  -> [INFO] Creating new cluster (this will take several minutes)..."
    gcloud container clusters create $CLUSTER_NAME --zone "$ZONE" --network "$NETWORK" --subnetwork "$SUBNET" --num-nodes 2 --image-type "COS_CONTAINERD" --release-channel stable --enable-network-policy --enable-shielded-nodes --shielded-integrity-monitoring --shielded-secure-boot --enable-private-nodes --enable-ip-alias --enable-master-authorized-networks --master-authorized-networks="${CURRENT_IP}/32" --master-ipv4-cidr 172.16.1.0/28 --enable-intra-node-visibility > /dev/null
fi

echo -e "\e[1;34m[4/8] Fetching Cluster Credentials...\e[0m"
gcloud container clusters get-credentials $CLUSTER_NAME --zone "$ZONE" > /dev/null 2>&1

echo -e "\e[1;34m[5/8] Deploying a temporary 'Reader' pod to interact with the OS...\e[0m"
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

# ==============================================================================
# STAGE 1: BASELINE
# ==============================================================================
echo -e "\e[1;33m\n[ Waiting for Boot Scanner to Finish (up to 60s) ]...\e[0m"
for i in {1..30}; do
  RAW_BASELINE=$(kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- cat /var/lib/google/cis_scanner_scan_result.textproto 2>/dev/null || true)
  if echo "$RAW_BASELINE" | grep -q "SUCCEEDED"; then break; fi
  sleep 2
done

# Dynamically pull the "Loaded" count from the system journal
LOADED_L1=$(kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- journalctl -u cis-level1.service | grep "Running scan of" | tail -n 1 | grep -o 'scan of [0-9]*' | awk '{print $3}')

echo -e "\e[1;35m\n[ STAGE 1: DEFAULT BASELINE ]\e[0m"
echo "By default, GKE COS images are configured for CIS Level 1 with logging opted-out."
print_summary "$RAW_BASELINE" "$LOADED_L1"

# ==============================================================================
# STAGE 2: ENFORCE LEVEL 2 (DEFAULT)
# ==============================================================================
read -p $'\e[1;32mPress [ENTER] to deploy the DaemonSet and enforce CIS Level 2...\e[0m'

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
            systemctl restart cis-level2.service
            sed -i 's/^LEVEL=.*$/LEVEL=\"2\"/' /etc/cis-scanner/env_vars
            systemctl restart cis-compliance-scanner.timer
          "
          sleep infinity
EOF

# Delete the Stage 1 file so we can accurately wait for the Stage 2 file
kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- rm -f /var/lib/google/cis_scanner_scan_result.textproto >/dev/null 2>&1
kubectl apply -f cos-cis-enforcer.yaml 2>/dev/null

echo -e "\e[1;34m[7/8] Waiting for DaemonSet to execute on all nodes (approx 30 seconds)...\e[0m"
kubectl rollout status daemonset/cos-cis-enforcer -n kube-system --timeout=120s >/dev/null 2>&1

echo -e "\e[1;33m[ Waiting for Scanner to Finish (up to 15s) ]...\e[0m"
for i in {1..15}; do
  RAW_ENFORCED=$(kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- cat /var/lib/google/cis_scanner_scan_result.textproto 2>/dev/null || true)
  if echo "$RAW_ENFORCED" | grep -q "SUCCEEDED"; then break; fi
  sleep 2
done

echo -e "\e[1;34mChecking systemctl status for proof of execution...\e[0m"
echo -e "\e[1;30m-------------------------------------------------------------\e[0m"
# Filter output to only show the clean scanner lines
kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- systemctl status cis-level2.service --no-pager | grep -E 'Reading scan config|Running scan of|Scan status:|Found.*non-compliant|Writing scan results'
echo -e "\e[1;30m-------------------------------------------------------------\e[0m"

# Extract the loaded count for Level 2
LOADED_L2=$(kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- journalctl -u cis-level2.service | grep "Running scan of" | tail -n 1 | grep -o 'scan of [0-9]*' | awk '{print $3}')

echo -e "\e[1;35m\n[ STAGE 2: ENFORCED RESULTS (CIS Level 2) ]\e[0m"
print_summary "$RAW_ENFORCED" "$LOADED_L2"

# ==============================================================================
# STAGE 3: GRANULAR CONTROL (OPTING-IN TO LOGGING)
# ==============================================================================
read -p $'\e[1;32mPress [ENTER] to remove the logging opt-out and demonstrate granular control...\e[0m'

echo -e "\e[1;34mStarting fluent-bit daemon to satisfy OS dependencies...\e[0m"
# We MUST start fluent-bit first, otherwise Google's configure.sh auto-skips the check!
kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- systemctl start fluent-bit

echo -e "\e[1;34mModifying /etc/cis-scanner/env_vars to remove logging exclusion...\e[0m"
# Run sed sequentially and directly to ensure clean execution without bash quote conflicts
kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- sed -i 's/logging-service-running//g' /etc/cis-scanner/env_vars
kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- sed -i 's/,,/,/g' /etc/cis-scanner/env_vars
kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- sed -i 's/=,/=/g' /etc/cis-scanner/env_vars
kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- sed -i 's/,\"$/\"/g' /etc/cis-scanner/env_vars
kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- sed -i 's/,$//g' /etc/cis-scanner/env_vars

# CRITICAL: Delete the old file so we don't read stale data
kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- rm -f /var/lib/google/cis_scanner_scan_result.textproto

echo -e "\e[1;34mTriggering cis-level2.service to apply changes and rescan...\e[0m"
kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- systemctl restart cis-level2.service

echo -e "\e[1;33m[ Waiting for Scanner to Finish (up to 15s) ]...\e[0m"
for i in {1..15}; do
  RAW_OPTIN=$(kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- cat /var/lib/google/cis_scanner_scan_result.textproto 2>/dev/null || true)
  if echo "$RAW_OPTIN" | grep -q "SUCCEEDED"; then break; fi
  sleep 2
done

# Grab the newly updated loaded count
LOADED_L2_OPTIN=$(kubectl exec -n kube-system cos-cis-reader -- nsenter -t 1 -m -u -i -n -p -- journalctl -u cis-level2.service | grep "Running scan of" | tail -n 1 | grep -o 'scan of [0-9]*' | awk '{print $3}')

echo -e "\e[1;35m\n[ STAGE 3: LEVEL 2 WITH LOGGING OPTED-IN ]\e[0m"
print_summary "$RAW_OPTIN" "$LOADED_L2_OPTIN"
echo "Notice the 'Checks Skipped' count decreased, and 'Checks Evaluated' increased! The OS dynamically utilized fluent-bit to stay compliant."

echo -e "\e[1;33mDemo complete!\e[0m"

kubectl delete -f cos-cis-reader.yaml --wait=false >/dev/null 2>&1
