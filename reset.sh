# 1. Remove the enforcer so it doesn't immediately harden the new nodes
kubectl delete daemonset cos-cis-enforcer -n kube-system --ignore-not-found=true

# 2. Refresh the nodes by scaling to 0 and immediately back to 2
gcloud container clusters resize cos-cis-cluster --node-pool default-pool --num-nodes 0 --zone asia-southeast1-a --quiet
gcloud container clusters resize cos-cis-cluster --node-pool default-pool --num-nodes 2 --zone asia-southeast1-a --quiet
