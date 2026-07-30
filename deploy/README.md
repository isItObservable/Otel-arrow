# Otel-Arrow — app + engine stack

Deploys the OpenTelemetry Astronomy Shop demo and the **native OTel-Arrow engine**
(`otap-dataflow` / `df_engine`) on a Kubernetes cluster, exporting all telemetry to
Dynatrace through a single egress.

## Topology

```
 otel-demo apps ──OTLP (traces / metrics / logs)──▶  df_engine  (native OTel-Arrow, Rust)
                                                          │  otlp ▸ attributes ▸ transform ▸ filter
                                                          │  ▸ signal_type_router ▸ batch ▸ retry
                                                          ├─ OTLP/HTTP ─▶ Dynatrace   ◀── SOLE egress
   engine internal_telemetry + admin :8080 ─────────────▶│   (observe the engine itself)
                                                          │
 K8s / cluster metrics ──── Dynatrace ActiveGate (DynaKube) ─▶ Dynatrace
```

- **The pipeline is the native Rust engine** (`df-engine/`). A second engine
  can receive over `receiver:otap` to show the Arrow-native hop between engines.
- **Sole Dynatrace egress**: only the engine (app telemetry) and the DynaKube ActiveGate
  (cluster metrics) talk to Dynatrace. A single, auditable egress path.
- **Engine image is published** — `ghcr.io/isitobservable/df_engine:0.50.0` (publicly
  pullable, no imagePullSecret), already set in `df-engine/df-engine-deployment.yaml`.
- **`collectors/` is a transport reference only** — the GA Go collector-contrib
  `otelarrow` path, for signals the engine can't source yet (filelog, prometheus,
  k8sattributes). Not the episode's pipeline.

## Layout

| Path | What |
|------|------|
| `df-engine/` | **The engine**: pipelines, `PLUGIN-COVERAGE.md`, ConfigMap + Deployment. |
| `dynatrace/dynakube.yaml` | ActiveGate-only DynaKube (cluster metrics egress). |
| `dynatrace/dynatrace-secret.example.yaml` | Operator + data-ingest token secret template. |
| `otel-demo/values.yaml` | otel-demo Helm values (backends off, apps → engine). |
| `collectors/` | **Transport reference** — Go collector `otelarrow` agent/gateway + RBAC + secret. |
| `benchmark/README.md` | Three-engine benchmark scope (df_engine vs collector vs fluentbit v5). |
| `deploy.sh` | One-shot installer for the supporting stack (cert-manager → operators → DynaKube → demo). |

## Deploy

```bash
export KUBECONFIG=~/.kube/config
export DT_API_URL=https://<your-tenant>.live.dynatrace.com/api
export DT_OPERATOR_TOKEN=dt0c01....   # operator token
export DT_INGEST_TOKEN=dt0c01....     # data-ingest token

# 1) supporting stack (cert-manager, operators, DynaKube, otel-demo)
./deploy.sh
# 2) deploy the native engine (image prebuilt + publicly pullable)
kubectl apply -f df-engine/df-engine-configmap.yaml
kubectl apply -f df-engine/df-engine-deployment.yaml
```

## Prerequisites

A Kubernetes cluster with a CNI, a LoadBalancer (e.g. MetalLB on bare metal), a
default StorageClass, and — for the demo's service mesh — Istio ambient (optional).
`cert-manager` and the two operators are installed by `deploy.sh`.

## Verify

```bash
kubectl get pods -n default -l app=df-engine
kubectl get dynakube -n dynatrace          # STATUS: Running
kubectl get pods -n otel-demo
# Engine up: `kubectl logs deployment/df-engine-gateway` shows the pipeline started;
# the admin endpoint (:8080) serves state + Prometheus metrics.
# In Dynatrace, filter by k8s.cluster.name=otel-arrow-demo.
```
