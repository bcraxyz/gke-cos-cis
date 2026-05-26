# GKE COS CIS Compliance Demo

This toolkit automates a 2-stage proof-of-concept demonstrating how Google Kubernetes Engine (GKE) utilizes Container-Optimized OS (COS) to enforce Center for Internet Security (CIS) Level 1 and Level 2 benchmarks.

### Included Scripts

- `demo.sh`: The main, interactive 2-stage demo script. Idempotent and safe to rerun (provided you reset the nodes first).
- `reset.sh`: Refreshes the cluster between demos by destroying the hardened VMs and provisioning fresh CIS Level 1 baselines.
- `authorize.sh`: Heals your `kubectl` connection if your Cloud Shell IP changes due to a session timeout.
- `teardown.sh`: Completely tears down all GCP resources (cluster, NAT, VPC) to stop billing.

### Demo Flow

1. **Stage 1 (Baseline):** Scans the default COS nodes, proving they satisfy CIS Level 1 out of the box (~64 checks evaluated out of ~117 loaded; skipped checks are IPv6 firewall rules not applicable to GKE).
2. **Stage 2 (Enforcement):** Deploys a privileged DaemonSet to harden the nodes via `nsenter`, elevating them to CIS Level 2 (~112 checks evaluated, 0 failed).

### Remarks

#### Why a DaemonSet and not cloud-init?

The COS documentation describes a cloud-init approach using `--metadata-from-file user-data=...`. That works for **bare COS VMs on Compute Engine**. On GKE, `user-data` and `startup-script` are reserved metadata keys used internally by GKE for node bootstrapping — passing them is rejected at cluster creation. The DaemonSet is therefore the correct mechanism for GKE node configuration, and is also how this would be deployed in production: the `cos-cis-enforcer` DaemonSet would live in the cluster's base configuration from day one, automatically running on every new node before workloads are scheduled.

#### Skipped Checks

The scanner loads 117 benchmarks at Level 2 but evaluates ~112. The 5 skipped checks are: 4 IPv6 firewall rules (CIS 3.3.1.x) that `cis-level2.service` opts out of because GKE manages its own network policy layer, and 1 local logging check (`logging-service-running`, CIS 4.1.1.2) that Google opts out of by default because GKE uses managed DaemonSet-based logging rather than host OS logs. Both opt-outs are documented and intentional — 0 checks fail.

#### Cloud Shell Timeouts & Master Authorized Networks

The GKE control plane is locked to your Cloud Shell IP. If your session is inactive for 20+ minutes, Google assigns a new IP and `kubectl` commands fail with a `dial tcp i/o timeout`. Run `./authorize.sh` to whitelist your new IP automatically.

#### The "Ghost" DaemonSet (Why you must use `reset.sh`)

Once `demo.sh` runs, the `cos-cis-enforcer` DaemonSet permanently modifies the underlying VM kernels. Running `demo.sh` again on the same cluster without resetting will show Level 2 results in Stage 1. Always run `./reset.sh` between demos — it deletes the DaemonSet, scales the node pool to 0, and scales back to 2 to provision fresh Level 1 nodes.
