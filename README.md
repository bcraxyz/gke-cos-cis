# GKE COS CIS Compliance Demo Toolkit

This toolkit automates a 3-stage proof-of-concept demonstrating how Google Kubernetes Engine (GKE) utilizes Container-Optimized OS (COS) to dynamically enforce Center for Internet Security (CIS) Level 1 and Level 2 benchmarks.

## Included Scripts
* `demo.sh`: The main, interactive 3-stage demo script. Idempotent and safe to rerun (provided you reset the nodes).
* `reset.sh`: Refreshes the cluster between demos by destroying the hardened VMs and provisioning fresh CIS Level 1 baselines.
* `authorize.sh`: A "break glass" script to heal your `kubectl` connection if your Cloud Shell IP address changes due to a timeout.
* `destroy.sh`: Completely tears down all GCP resources (Cluster, NAT, VPC) to stop billing.

## Demo Flow
1. **Stage 1 (Baseline):** Scans the default COS nodes, proving they satisfy CIS Level 1 out of the box (~64 checks).
2. **Stage 2 (Enforcement):** Deploys a privileged DaemonSet to dynamically harden the immutable nodes via `nsenter`, elevating them to CIS Level 2 (~112 checks).
3. **Stage 3 (Granular Control):** Modifies the OS configuration to opt-in to the `logging-service-running` check, proving the compliance engine dynamically adapts and starts local services to satisfy auditor requirements (~113 checks).

## Important Nuances

### 1. Cloud Shell Timeouts & Master Authorized Networks
The GKE control plane is locked down to your specific Cloud Shell IP address. If your session is inactive for 20+ minutes, Google assigns you a new IP address, and `kubectl` commands will fail with a `dial tcp i/o timeout`. 
* **Fix:** Run `./authorize.sh` to automatically whitelist your new IP.

### 2. The CIS Logging "Opt-Out"
CIS Level 2 mandates a local logging service (like `fluent-bit`) running on the host OS. By default, Google opts-out of this specific check in COS. This is because enterprise GKE customers use Google's centralized, managed logging architecture (DaemonSets) rather than local OS logs. We maintain a perfect "0 Checks Failed" score by honoring this documented opt-out in Stages 1 and 2. 

### 3. The "Ghost" DaemonSet (Why you must use `reset.sh`)
Once you run `demo.sh`, the `cos-cis-enforcer` DaemonSet permanently modifies the underlying VM kernels and files. If you run `demo.sh` a second time on the same cluster without resetting, the baseline scan will immediately show Level 2 enforcement.
* **Fix:** Always run `./reset.sh` between demos. It deletes the DaemonSet, scales the node pool to 0, and scales back to 2 to provide fresh, untouched Level 1 nodes for your next audience.
