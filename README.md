# GKE COS CIS Compliance Demo

This toolkit automates a 3-stage proof-of-concept demonstrating how Google Kubernetes Engine (GKE) utilizes Container-Optimized OS (COS) to dynamically enforce Center for Internet Security (CIS) Level 1 and Level 2 benchmarks.

## Included Scripts

- `demo.sh`: The main, interactive 3-stage demo script. Idempotent and safe to rerun (provided you reset the nodes first).
- `reset.sh`: Refreshes the cluster between demos by destroying the hardened VMs and provisioning fresh CIS Level 1 baselines.
- `authorize.sh`: Heals your `kubectl` connection if your Cloud Shell IP changes due to a session timeout.
- `teardown.sh`: Completely tears down all GCP resources (cluster, NAT, VPC) to stop billing.

## Demo Flow

1. **Stage 1 (Baseline):** Scans the default COS nodes, proving they satisfy CIS Level 1 out of the box (~64 checks).
2. **Stage 2 (Enforcement):** Deploys a privileged DaemonSet to harden the nodes via `nsenter`, elevating them to CIS Level 2 (~112 checks).
3. **Stage 3 (Granular Control):** Removes the `logging-service-running` opt-out from `/etc/cis-scanner/env_vars`, proving the compliance engine dynamically adapts — `cis-level2.service` auto-starts fluent-bit and picks up the additional check (~113 checks evaluated).

## Important Nuances

### Cloud Shell Timeouts & Master Authorized Networks

The GKE control plane is locked to your Cloud Shell IP. If your session is inactive for 20+ minutes, Google assigns a new IP and `kubectl` commands fail with a `dial tcp i/o timeout`.

Run `./authorize.sh` to whitelist your new IP automatically.

### The CIS Logging Opt-Out

CIS Level 2 mandates a local logging service (`fluent-bit`) on the host OS. Google opts out of this check by default in COS because enterprise GKE customers use managed DaemonSet-based logging rather than local OS logs. Stages 1 and 2 honor this opt-out and maintain 0 failed checks. Stage 3 demonstrates removing it.

### The "Ghost" DaemonSet (Why you must use `reset.sh`)

Once `demo.sh` runs, the `cos-cis-enforcer` DaemonSet permanently modifies the underlying VM kernels. Running `demo.sh` again on the same cluster without resetting will show Level 2 results in Stage 1.

Always run `./reset.sh` between demos. It deletes the DaemonSet, scales the node pool to 0, and scales back to 2 to provision fresh Level 1 nodes.
