# Tutorial — OTel-Arrow (OTAP) end to end

This is the ordered, copy-paste walkthrough for the **Is It Observable** OTel-Arrow
episode. By the end you will have the OpenTelemetry Astronomy Shop demo sending logs,
metrics and traces through the **native OTel-Arrow engine** (the Rust `otap-dataflow`
/ `df_engine`), a single Dynatrace egress, and the engine's own self-telemetry.

> **The centerpiece is the Rust engine**, not the Go collector. `otap-dataflow` is
> where Apache Arrow is the representation end-to-end. In **Step 5** you deploy the
> engine (**Track A**, primary). The Go collector-contrib `otelarrow` path
> (**Track B**) is included only as a **transport reference** for signals the engine
> can't yet source (pod-log `filelog`, `prometheus` scrape, `k8sattributes`).

Each step below is a stop in the video. The one-shot `deploy/deploy.sh` installs the
supporting stack (cert-manager, operators, DynaKube, otel-demo); Step 5 deploys the
engine itself.

**Contents**

- [Step 0 — Prerequisites & concepts](#step-0--prerequisites--concepts)
- [Step 1 — Clone the repository](#step-1--clone-the-repository)
- [Step 2 — cert-manager](#step-2--cert-manager)
- [Step 3 — Dynatrace operator + DynaKube (sole egress)](#step-3--dynatrace-operator--dynakube-sole-egress)
- [Step 4 — OpenTelemetry Operator](#step-4--opentelemetry-operator)
- [Step 5 — Deploy the native OTel-Arrow engine (Track A)](#step-5--deploy-the-native-otel-arrow-engine-track-a)
- [Step 6 — Deploy the otel-demo app](#step-6--deploy-the-otel-demo-app)
- [Step 7 — Verify the engine pipeline is flowing](#step-7--verify-the-engine-pipeline-is-flowing)
- [Step 8 — Observe OTel-Arrow itself (self-telemetry)](#step-8--observe-otel-arrow-itself-self-telemetry)
- [Appendix — Track B: Go collector-contrib (transport reference)](#appendix--track-b-go-collector-contrib-transport-reference)
- [Step 9 — The benchmark & the honest scope](#step-9--the-benchmark--the-honest-scope)
- [Step 10 — Cleanup](#step-10--cleanup)

---

## Step 0 — Prerequisites & concepts

**Tools:** `kubectl`, `helm` v3, and a `KUBECONFIG` pointing at a cluster with a
default StorageClass and a LoadBalancer. The tutorial puts the demo in an **Istio
ambient** mesh; any recent Kubernetes cluster with a CNI, a LoadBalancer and a
storage driver works.

**Dynatrace:** a tenant plus an **operator token** and a **data-ingest token**
(scopes `metrics.ingest`, `logs.ingest`, `openTelemetryTrace.ingest`).

**The one concept to hold on to:**

> **OTLP** encodes telemetry **row by row** (protobuf). **OTAP** ("OpenTelemetry
> Protocol with Apache Arrow") encodes the same data **column by column** (Apache
> Arrow) and streams it over a **long-lived gRPC** connection. Columnar layout plus
> dictionary and batch-level delta compression means the same telemetry costs
> **less bandwidth to move** — at the price of a little more CPU/memory in the
> collector for the OTLP↔Arrow translation.

Crucially, OTAP is **100% compatible** with the OTel data model, so OTLP↔OTAP↔OTLP is
a non-lossy round-trip. The episode's focus is the **native Rust engine**, where Arrow
is the representation *inside* the pipeline (not just on the wire). For contrast, the
appendix shows the Go collector-contrib path, where adopting OTAP-on-the-wire is a
one-line change — **swap `otlp` → `otelarrow`**.

```bash
export KUBECONFIG=~/.kube/otel-arrow-demo.kubeconfig
export DT_API_URL=https://<your-tenant>.live.dynatrace.com/api
export DT_OPERATOR_TOKEN=dt0c01....
export DT_INGEST_TOKEN=dt0c01....
```

---

## Step 1 — Clone the repository

```bash
git clone https://github.com/isItObservable/Otel-arrow.git
cd Otel-arrow
```

Everything you deploy lives under `deploy/`.

---

## Step 2 — cert-manager

The OpenTelemetry and Dynatrace operators both use admission webhooks, which need
TLS certificates. Install cert-manager first.

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.16.2 --set crds.enabled=true --wait
```

---

## Step 3 — Dynatrace operator + DynaKube (sole egress)

We keep **one auditable path to Dynatrace**. Cluster/K8s metrics leave through a
Dynatrace **ActiveGate** (via DynaKube); *all application telemetry* leaves through
the OTel-Arrow engine (Step 5). There is **no OneAgent** — the DynaKube is
ActiveGate-only.

```bash
kubectl create namespace dynatrace --dry-run=client -o yaml | kubectl apply -f -

helm repo add dynatrace https://raw.githubusercontent.com/Dynatrace/dynatrace-operator/main/config/helm/repos/stable
helm upgrade --install dynatrace-operator dynatrace/dynatrace-operator \
  --namespace dynatrace --version 1.9.0 --set installCRD=true --wait

# Tokens secret (operator + data-ingest).
kubectl create secret generic otel-arrow-demo -n dynatrace \
  --from-literal=apiToken="${DT_OPERATOR_TOKEN}" \
  --from-literal=dataIngestToken="${DT_INGEST_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f deploy/dynatrace/dynakube.yaml
kubectl get dynakube -n dynatrace   # wait for STATUS: Running
```

> **Gotcha (fixed in `dynakube.yaml`):** the ActiveGate image is pinned to the
> **public ECR** image (`public.ecr.aws/dynatrace/dynatrace-activegate:1.337.30…`).
> The tenant-registry default tag is not present on every tenant and
> `ImagePullBackOff`s — the pin avoids that.

---

## Step 4 — OpenTelemetry Operator

The operator turns our `OpenTelemetryCollector` custom resources into running
collectors and manages their Services.

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --namespace opentelemetry-operator-system --create-namespace \
  --set "manager.collectorImage.repository=otel/opentelemetry-collector-contrib" \
  --wait
```

We pin the **contrib** image because the `otelarrow` receiver/exporter (and
`k8sattributes`) live there, not in the core distribution.

---

## Step 5 — Deploy the native OTel-Arrow engine (Track A)

This is the episode: the **native Rust `otap-dataflow` engine** running a real
pipeline. Its config is an explicit **DAG** — a `nodes` map plus a `connections`
edge list (the engine does not infer flow from node roles). One `otap` pipeline
handles logs, metrics and traces together.

### 5.1 The engine image (already published)

The Deployment uses a prebuilt, **publicly pullable** image (no imagePullSecret) —
nothing to build:

```
ghcr.io/isitobservable/df_engine:0.50.0     # linux/amd64, distroless, ~171MB
```

Its ENTRYPOINT is `/home/nonroot/df_engine`; the Deployment passes `--config` and
`--http-admin-bind` as args. To rebuild or bump the version, run the
`workflow_dispatch` on `.github/workflows/build-df-engine.yml` in this repo and update
the `image:` tag in `deploy/df-engine/df-engine-deployment.yaml`.

### 5.2 Egress secret (the engine is the only workload talking to Dynatrace)

```bash
kubectl create secret generic gateway-dynatrace -n default \
  --from-literal=endpoint="${DT_API_URL}" \
  --from-literal=apiToken="${DT_INGEST_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 5.3 Deploy the engine + its pipeline

```bash
kubectl apply -f deploy/df-engine/df-engine-configmap.yaml
kubectl apply -f deploy/df-engine/df-engine-deployment.yaml
kubectl -n default rollout status deployment/df-engine-gateway --timeout=180s
```

### What the pipeline does (`deploy/df-engine/pipelines/main.yaml`)

```
receiver:otlp ▸ attributes ▸ transform ▸ filter ▸ signal_type_router
              ▸ batch (per signal) ▸ retry ▸ exporter:otlp_http  →  Dynatrace
```

- **`receiver:otlp`** — the otel-demo apps push traces/metrics/logs here.
- **`attributes`** — static enrichment (there is **no `k8sattributes`** in the engine;
  it stamps `k8s.cluster.name` and pipeline identity only).
- **`transform`** — OTTL-style edits (**experimental & minimal** — literal sets).
- **`filter`** — drop noisy health-check spans.
- **`signal_type_router`** — split the multi-signal stream into logs / metrics /
  traces named output ports, wired with `from: router["logs"]` etc.
- **`batch` + `retry`** — batch per signal (always last), retry on export failure.
- **`exporter:otlp_http`** — the single Dynatrace egress.

**Cover the rest of the engine.** `main.yaml` uses the core path; the other files in
`pipelines/` exercise **every remaining node except the four testing-only ones**
(`traffic_generator`, `noop`, `error`, `perf`): the Arrow hop between two engines
(`otap-hop.yaml`), self-telemetry (`host-and-self.yaml`), routing/sampling/shaping
(`routing.yaml`), topics (`topics.yaml`), contrib processors
(`contrib-processors.yaml`), and platform-specific sources/exporters
(`reference-*.yaml`). The full matrix is
[`deploy/df-engine/PLUGIN-COVERAGE.md`](./deploy/df-engine/PLUGIN-COVERAGE.md).

> The engine's config format is **experimental / unstable** — pin to the commit you
> built the image from and re-verify `type:` strings and `config:` keys.

---

## Step 6 — Deploy the otel-demo app

The Astronomy Shop is a pure **telemetry source** here — every bundled backend is
turned off, and each service points its OTLP at the engine.

```bash
kubectl create namespace otel-demo --dry-run=client -o yaml | kubectl apply -f -
# Put the demo in the Istio ambient mesh.
kubectl label ns otel-demo istio.io/dataplane-mode=ambient --overwrite

helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  --namespace otel-demo -f deploy/otel-demo/values.yaml --wait --timeout 10m
```

`deploy/otel-demo/values.yaml` sets `OTEL_COLLECTOR_NAME` to
`df-engine-gateway.default.svc.cluster.local` (the engine's OTLP endpoint) and
disables the demo's bundled collector/Jaeger/Prometheus/Grafana/OpenSearch —
Dynatrace, reached via the engine, is the only backend.

---

## Step 7 — Verify the engine pipeline is flowing

```bash
kubectl get pods -n default -l app=df-engine
kubectl get dynakube -n dynatrace          # STATUS: Running
kubectl get pods -n otel-demo

# Engine logs: pipeline started, nodes wired, no config errors.
kubectl logs -n default deployment/df-engine-gateway | tail -30

# Ask the engine's admin endpoint for live pipeline state.
kubectl -n default port-forward deployment/df-engine-gateway 8080:8080 &
curl -s localhost:8080/status   # pipeline state / node health (see admin API)
```

In Dynatrace, filter by `k8s.cluster.name = otel-arrow-demo`. You should see
traces, logs and metrics from the Astronomy Shop services arriving through the
engine, stamped with `telemetry.pipeline.engine = otap-dataflow`.

---

## Step 8 — Observe OTel-Arrow itself (self-telemetry)

The engine reports on itself two ways
(`deploy/df-engine/pipelines/host-and-self.yaml`):

- **`receiver:internal_telemetry`** — the engine's own pipeline metrics: throughput
  per node, channel saturation / backpressure (bounded channels + Ack/Nack make
  overload **visible** instead of silently buffering), Tokio runtime stats. These are
  emitted as OTLP and land in Dynatrace like any other signal.
- **The admin HTTP endpoint** (`--http-admin-bind`, `:8080`) — current pipeline state,
  the running config, debug logs, a **Prometheus** metrics page, and a
  **live-reconfiguration** API:

```bash
kubectl -n default port-forward deployment/df-engine-gateway 8080:8080 &
curl -s localhost:8080/api/v1/metrics | head    # Prometheus self-metrics
```

> ⚠️ **A gateway collector is required to convert metrics to delta.** Dynatrace — like
> most delta-native backends — only accepts **delta** temporality on OTLP metric ingest,
> and the experimental `df_engine` has **no `cumulativetodelta` node**. Sending its
> cumulative Prometheus self-metrics (or any cumulative app counter) straight to
> Dynatrace gets them **silently rejected**. Route them through a **gateway OTel
> Collector** running the **`cumulativetodelta`** processor first. This repo ships it:
>
> ```bash
> # scrapes df-engine :8080/metrics → cumulativetodelta → OTLP → Dynatrace
> kubectl apply -f dashboards/df-engine-internal-metrics-collector.yaml
> ```
>
> The app-signal path uses the same trick in
> [`deploy/collectors/otel-gateway.yaml`](./deploy/collectors/otel-gateway.yaml)
> (`processors: [..., cumulativetodelta, batch]`, `batch` always last). If your metrics
> never show up in Dynatrace, this delta conversion is almost always the missing step.

Build a Dynatrace dashboard on the engine's self-telemetry: pipeline throughput, a
CPU/memory pair, and channel-saturation so you can see the engine's backpressure
behaviour under load.

---

## Step 9 — The benchmark & the honest scope

`benchmark/README.md` frames the head-to-head across **three pipeline engines** —
the **native OTel-Arrow `df_engine`** (Rust), the **OTel Collector** (Go), and
**Fluent Bit v5** (C) — shipping the same telemetry with the same feature set, so the
comparison is engine-to-engine, not just wire format.

**Number discipline (say the baseline every time):**

- OTAP is typically **~2× vs OTLP+zstd** for standard signals; up to **~8×** on
  multivariate metrics; **15–30×** only **vs uncompressed** OTLP. The famous "10×"
  is the vs-uncompressed headline — never quote it bare.
- The CPU/memory cost is **real** — show it next to the savings, not hidden.

**Engine scope (the honest boundary — the engine is experimental):**

- **No `filelog` / pod-log receiver, no `prometheus` scrape, no `k8sattributes`.** App
  logs/metrics arrive as OTLP; node metrics come from `host_metrics`; enrichment is
  static `attributes` only. For pod-log tailing or live k8s metadata you need an edge
  Go collector (Track B, appendix).
- **No tail sampling** — only head-style `log_sampling`. **OTTL transform** is
  experimental and minimal.
- We cover **every engine node except the four testing-only ones** — see
  [`deploy/df-engine/PLUGIN-COVERAGE.md`](./deploy/df-engine/PLUGIN-COVERAGE.md).

---

## Step 10 — Cleanup

```bash
helm uninstall otel-demo -n otel-demo
kubectl delete -f deploy/df-engine/df-engine-deployment.yaml
kubectl delete -f deploy/df-engine/df-engine-configmap.yaml
kubectl delete -f deploy/dynatrace/dynakube.yaml
helm uninstall dynatrace-operator -n dynatrace
helm uninstall opentelemetry-operator -n opentelemetry-operator-system
helm uninstall cert-manager -n cert-manager
kubectl delete ns otel-demo dynatrace opentelemetry-operator-system --ignore-not-found
```

---

## Appendix — Track B: Go collector-contrib (transport reference)

The `otelarrow` receiver/exporter in `opentelemetry-collector-contrib` (GA since
v0.104.0) are **not** the episode's engine, but they are useful as a **transport
reference** and for the signals the native engine can't yet source — **pod-log
`filelog`, `prometheus` scrape, `k8sattributes`**. `deploy/collectors/` contains an
agent (DaemonSet) → gateway (StatefulSet) OTAP transport path for exactly those cases:

```bash
kubectl apply -f deploy/collectors/otel-agent-rbac.yaml
kubectl apply -f deploy/collectors/otel-gateway.yaml
kubectl apply -f deploy/collectors/otel-agent.yaml
```

> **Gotcha (fixed in `otel-gateway.yaml`):** the operator does not auto-expose a
> Service port for the `otelarrow` receiver, so the manifest declares
> `spec.ports: [{name: otel-arrow, port: 4317}]` explicitly — otherwise agents log
> `cannot start arrow stream`.

Use Track B when you want pod logs / k8s metadata in the pipeline today; use Track A
(the native engine) for everything the episode is actually about.

---

*Built for the Is It Observable episode on OpenTelemetry-Arrow.*
