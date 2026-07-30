# Cluster provisioning

The episode stack needs a Kubernetes cluster with a **default StorageClass** and a
**LoadBalancer**. Two provisioning paths are provided; pick whichever matches your
environment. Both end with a `KUBECONFIG` you can point the rest of the tutorial at.

| Path | Use when | Provides LB / storage |
|------|----------|-----------------------|
| **[Cluster API (CAPI) on Proxmox](#option-a--cluster-api-capi-on-proxmox)** | Self-hosted / on-prem / bare metal | MetalLB + csi-driver-nfs (installed for you) |
| **[GKE](#option-b--gke)** | Google Cloud | Native LB + `standard-rwo` StorageClass |

> All IP addresses in these files use the RFC 5737 documentation range
> `192.0.2.0/24`. Replace them with real, free addresses on your network before
> applying. Nothing here is tied to a specific lab.

---

## Option A — Cluster API (CAPI) on Proxmox

Provisions a single-control-plane + 3-worker cluster on **Proxmox VE** using the
Cluster API Proxmox provider (**CAPMOX**), with Cilium, Istio ambient, MetalLB and
csi-driver-nfs delivered as CAAPH add-ons.

### Prerequisites

- A **Proxmox VE** cluster and a CAPI **management cluster** with the CAPMOX
  infrastructure provider and the CAAPH add-on provider installed
  (`clusterctl init --infrastructure proxmox --addon helm`).
- An **Ubuntu 24.04 + Kubernetes** golden template VM on Proxmox (build one with the
  `proxmox-template` workflow). Note its **VMID** and the **node** it lives on.
- A Proxmox API token stored as the `proxmox-credentials` secret in the management
  cluster (per the CAPMOX quick-start).

### 1. Edit the inputs

Set your values in [`capi/values.env`](./capi/values.env), then mirror them into
[`capi/cluster.yaml`](./capi/cluster.yaml) and [`capi/metallb.yaml`](./capi/metallb.yaml):

- **IP layout** — a free control-plane VIP, a node pool, and a MetalLB pool, all
  disjoint from each other and from live hosts on your LAN.
- **`allowedNodes`** — the real Proxmox node names (`pvesh get /nodes`).
- **`sourceNode` / `templateID`** — the node holding your golden template and its VMID.
- **`addons/csi-driver-nfs.yaml`** — your NFS `server` and `share`.

### 2. Apply to the management cluster

```bash
# Add-ons first (installed by CAAPH once the Cluster is created)
kubectl apply -f cluster/capi/addons/metallb.yaml
kubectl apply -f cluster/capi/addons/csi-driver-nfs.yaml

# The workload cluster
kubectl apply -f cluster/capi/cluster.yaml

# Watch it come up
clusterctl describe cluster otel-arrow-demo
kubectl get machines -w
```

### 3. Fetch the kubeconfig and finish LB wiring

```bash
clusterctl get kubeconfig otel-arrow-demo > otel-arrow-demo.kubeconfig
export KUBECONFIG=$PWD/otel-arrow-demo.kubeconfig

# MetalLB address pool (needs the MetalLB CRDs the add-on installed)
kubectl apply -f cluster/capi/metallb.yaml

kubectl get nodes
kubectl get storageclass       # nfs-csi should be default
```

You now have a cluster with a default StorageClass and a LoadBalancer. Cilium and
Istio ambient are installed by the platform add-ons; if you provision Istio yourself,
see Option B step 3.

---

## Option B — GKE

### Prerequisites

- `gcloud` authenticated to a project with the Kubernetes Engine API enabled.
- `kubectl`, `helm` v3, and `istioctl`.

### 1. Create the cluster

```bash
export PROJECT_ID=$(gcloud config get-value project)
export REGION=us-central1

gcloud container clusters create otel-arrow-demo \
  --project "$PROJECT_ID" --region "$REGION" \
  --release-channel regular \
  --num-nodes 1 \
  --machine-type e2-standard-4 \
  --enable-ip-alias

gcloud container clusters get-credentials otel-arrow-demo --region "$REGION"
kubectl get nodes
```

GKE ships a default StorageClass (`standard-rwo`) and native LoadBalancer Services —
nothing extra to install for those.

### 2. (optional) A single larger node pool for the benchmark

The three-way benchmark pushes real load. If you want more headroom:

```bash
gcloud container clusters resize otel-arrow-demo \
  --region "$REGION" --num-nodes 3 --quiet
```

### 3. Install Istio ambient

The OTel Demo runs inside an Istio **ambient** mesh in this episode.

```bash
istioctl install --set profile=ambient --skip-confirmation
# The demo namespace is labelled for ambient in deploy/deploy.sh:
#   kubectl label ns otel-demo istio.io/dataplane-mode=ambient --overwrite
```

---

## Next step

With `KUBECONFIG` pointing at your cluster, continue with the core stack in
[`../deploy/`](../deploy/) and the walkthrough in [`../TUTORIAL.md`](../TUTORIAL.md).
