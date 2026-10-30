# Reproducing the Benchmark End to End

This runbook reproduces the telemetry-pipeline benchmark from an empty
Kubernetes cluster through to a pass/fail KPI gate. Follow the steps in order;
each assumes the previous one succeeded.

The benchmark compares three **engines** — the component that receives OTLP from
the applications, applies a feature-parity transform, and forwards to the
backend. You run **one engine at a time** so every number is attributable to a
single engine at a known load.

| Variant | Engine                         | Manifests          |
|---------|--------------------------------|--------------------|
| **A**   | OTel-Arrow native (`df_engine`)| `otel-arrow/`      |
| **B**   | OTel Collector (reference baseline) | `otel-collector/` |
| **C**   | Fluent Bit v5                  | `fluentbit-v5/`    |

Variant **B** is the reference baseline; start there if you are reproducing for
the first time.

## Repository layout used by this runbook

```
benchmark/
  environment/              shared app + mesh manifests (identical across all engines)
    APPPROTOCOL.md          why the Service ports carry appProtocol (read this)
    istio/                  ambient mesh: namespace labels, waypoints, extensionProvider, Telemetry
    otel-demo/              OTel Demo Helm values + appProtocol'd Services
    hipster-shop/           Online Boutique manifests + appProtocol'd Services
    loadgenerator/          rampup + step-up + soak load jobs
  otel-arrow/               Variant A engine manifests
  otel-collector/           Variant B engine manifests
  fluentbit-v5/             Variant C engine manifests
  loadtest/                 Locust load profile (loadshape.py: stable30 / rampup2h / leak24h)
  dynatrace-secret.example.yaml   copy to dynatrace-secret.yaml and fill in your token
  RESULTS.md                recorded results per engine
  README.md                 benchmark overview
  REPRODUCE.md              this file
```

Run commands from the `benchmark/` directory unless noted.

## 0. Prerequisites

- `kubectl` configured against the target cluster.
- `istioctl` matching the Istio ambient version you intend to run.
- `helm` (OTel Demo is deployed via its Helm chart).
- A Dynatrace tenant and ingest token (or a local `nop`-style sink if you only
  want the isolated engine-cost reading — see `README.md`).

## 1. Provision or select a Kubernetes cluster

Use a dedicated cluster so the measurements are not disturbed by other
workloads. The recorded runs used Kubernetes `1.35.3` on one control-plane node
plus three ~16 GiB workers, with Cilium `v1.17.4` as the CNI. Any equivalent
cluster with a CNI that supports Istio ambient works.

```bash
kubectl get nodes -o wide
```

Install the OpenTelemetry Operator (it manages the demo-app instrumentation);
the recorded runs used chart `0.126.1`.

## 2. Install Istio ambient and bring up the mesh

Install Istio in **ambient** mode, including the `bench-otlp` extension provider
in the mesh config:

```bash
istioctl install --set profile=ambient -y
kubectl apply -f environment/istio/mesh-extensionprovider.yaml
```

Enrol the application namespaces in the ambient data plane, deploy the
per-namespace waypoints, and bind the Telemetry to `bench-otlp`:

```bash
kubectl apply -f environment/istio/namespace-labels.yaml
kubectl apply -f environment/istio/waypoints.yaml
kubectl apply -f environment/istio/telemetry.yaml
kubectl get gateways.gateway.networking.k8s.io -A
```

> Read `environment/APPPROTOCOL.md` before continuing. The waypoint only
> L7-handles OTLP if the application and engine-gateway Service ports carry the
> correct `appProtocol`. Without it the waypoint treats OTLP as opaque TCP and
> **no spans reach the engine**.

## 3. Deploy the applications

The namespaces (`otel-demo`, `hipster-shop`) are created by the namespace-labels
manifest in step 2. Deploy OTel Demo via Helm with the provided values, and
hipster-shop from its rendered manifests:

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo -f environment/otel-demo/values.yaml

kubectl apply -f environment/hipster-shop/manifests.yaml
kubectl -n otel-demo rollout status deployment --timeout=10m
kubectl -n hipster-shop rollout status deployment --timeout=10m
```

The exporter wiring is baked into these manifests:

- **otel-demo** sets `OTEL_EXPORTER_OTLP_ENDPOINT` (gRPC `:4317` / HTTP `:4318`);
  the chart does not render it by default, so `values.yaml` supplies it.
- **hipster-shop** sets `COLLECTOR_SERVICE_ADDR` (`:4317`), the variable the
  Online Boutique services actually read.

Both point at the engine-under-test's ingest gateway (deployed in step 5).

## 4. Apply the appProtocol'd Services

Apply the live-captured Service specs that carry `appProtocol` on every OTLP and
L7 port so the waypoint can route the traffic (see `APPPROTOCOL.md` for the why):

```bash
kubectl apply -f environment/otel-demo/services-appprotocol.yaml
kubectl apply -f environment/hipster-shop/services-appprotocol.yaml
```

## 5. Choose and deploy one engine (A, B, or C)

Pick exactly one engine, create its namespace, apply the ingest secret, then the
engine manifests. Each engine exposes the gateway Service on `:4317` (gRPC) /
`:4318` (HTTP) that the applications export to.

First create the ingest secret in the engine namespace (copy the example, fill
in your token, and set the exporter endpoint host in the engine config to your
tenant):

```bash
cp dynatrace-secret.example.yaml dynatrace-secret.yaml   # then edit the token
```

**Variant B — OTel Collector (reference baseline; recommended first):**

```bash
kubectl create namespace bench-collector
kubectl -n bench-collector apply -f dynatrace-secret.yaml
kubectl apply -f otel-collector/otel-agent-otlp-rbac.yaml
kubectl apply -f otel-collector/otel-gateway-otlp.yaml
kubectl apply -f otel-collector/otel-agent-otlp.yaml
kubectl -n bench-collector rollout status deployment/bench-collector-gateway
```

**Variant A — OTel-Arrow native (`df_engine`):**

```bash
kubectl create namespace bench-arrow
kubectl -n bench-arrow apply -f dynatrace-secret.yaml
kubectl apply -f otel-arrow/df-engine-config.yaml
kubectl apply -f otel-arrow/df-engine-deployment.yaml
kubectl -n bench-arrow rollout status deployment/bench-arrow-dfengine
# df_engine runs one pipeline instance per core and exposes an engine-internal
# admin HTTP server on 127.0.0.1:8080 inside the pod.
```

**Variant C — Fluent Bit v5:**

```bash
kubectl create namespace bench-fluentbit
kubectl -n bench-fluentbit apply -f dynatrace-secret.yaml
kubectl apply -f fluentbit-v5/fluentbit-configmap.yaml
kubectl apply -f fluentbit-v5/otel-gateway-fluentbit.yaml
kubectl apply -f fluentbit-v5/fluentbit-daemonset.yaml
kubectl -n bench-fluentbit rollout status deployment/bench-fluentbit-gateway
```

> If the application `OTEL_EXPORTER_OTLP_ENDPOINT` / `COLLECTOR_SERVICE_ADDR`
> values were set for a different engine namespace, update them to the gateway
> Service of the engine you just deployed and restart the app workloads.

Before starting load, confirm the engine is receiving and forwarding with no
refusals or send failures (see the counters in step 7).

## 6. Run the load: ramp-up, then soak

Load drives the real OTel Demo and hipster-shop with Locust, so telemetry is
produced by an application under user load. The profile is one shape class with
the phase selected by `LOAD_PHASE` (in `loadtest/loadshape.py`):

| Phase (`LOAD_PHASE`) | Load | Duration | Purpose |
|----------------------|------|----------|---------|
| `stable30` | 50 VU held | 30 min | baseline / steady-state |
| `rampup2h` | 50 → 100 → 150 → 200 VU (`+50` every 30 min) | 2 h | scaling under rising volume |
| `leak24h`  | 50 VU held | 24 h | soak / endurance |

Run the same phase against one engine at a time. The `environment/loadgenerator/`
jobs implement the ramp-up (base + step-up at T+30/60/90m) and the soak:

**6a. Ramp-up.** Start the base load and the otel-demo step-up jobs. This also
establishes the load start time used when reading the soak window:

```bash
kubectl apply -f environment/loadgenerator/30-loadgen-rampup.yaml
kubectl apply -f environment/loadgenerator/30-locust-otel-demo-job1.yaml   # T+30m step
kubectl apply -f environment/loadgenerator/30-locust-otel-demo-job2.yaml   # T+60m step
kubectl apply -f environment/loadgenerator/30-locust-otel-demo-job3.yaml   # T+90m step
```

**6b. Soak.** Once the ramp-up is holding at the target level, start the soak and
let it run for the full soak duration. Record the soak start time; evaluate KPIs
over a bounded window of wall-clock time, read at the **tail**, not by waiting
for load pods to complete:

```bash
kubectl apply -f environment/loadgenerator/31-loadgen-soak.yaml
```

## 7. Evaluate the KPI gate

At the end of the soak window, collect the engine's own counters over the window
and the backend-side receipt, and check them against the gate. A run **passes**
when, for the deployed engine:

- **Drop rate < 1%** — records accepted at the engine match records sent to the
  backend to within 1% (per signal).
- **Receiver refusals = 0.**
- **Exporter send failures = 0.**
- **0 engine restarts** across the soak window.
- Backend-received counts (in Dynatrace) correlate with what the engine sent.

Where the counters live:

- **OTel Collector** (and the contrib agent/forwarder used by Variant A) expose a
  Prometheus page on **`:8888`** — `otelcol_receiver_accepted_*`,
  `otelcol_receiver_refused_*`, `otelcol_exporter_sent_*`,
  `otelcol_exporter_send_failed_*`.
- **Fluent Bit** exposes its metrics on **`:2020`** — `fluentbit_input_*`,
  `fluentbit_output_*`.

Example (Collector / Variant B):

```bash
kubectl -n bench-collector port-forward deploy/bench-collector-gateway 8888:8888 &
curl -s localhost:8888/metrics | grep -E \
  'otelcol_receiver_(accepted|refused)|otelcol_exporter_(sent|send_failed)'

kubectl -n bench-collector get pods -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}'; echo
```

Compute the drop rate as `(accepted - sent) / accepted` per signal and confirm it
is under 1%, that refusals and send failures are zero, and that restart count is
zero. Record the CPU/memory (`kubectl top pods -n bench-<engine>`), throughput,
and drop rate for the engine in `RESULTS.md`, with the OTLP baseline named every
time (see `README.md` → *Number discipline*).

Tear the engine down, then repeat steps 5–7 for the next variant against the
identical load.

## Troubleshooting

- **Zero spans at the engine.** Almost always one of two causes: (1) a Service
  port is missing its `appProtocol`, so the waypoint treats OTLP as opaque TCP —
  recheck step 4 and `APPPROTOCOL.md`; or (2) the application is pointed at the
  wrong gateway, or its endpoint variable is unset — recheck
  `OTEL_EXPORTER_OTLP_ENDPOINT` (otel-demo) and `COLLECTOR_SERVICE_ADDR`
  (hipster-shop) in step 3/5.
- **Engine receiving but backend empty.** Check the exporter counters for
  `send_failed` and inspect the engine logs for export errors; confirm the
  ingest token and tenant endpoint in `dynatrace-secret.yaml` / the engine config.
- **Receiver refusals climbing.** The engine is shedding load; check its memory
  limiter and batch settings and confirm the cluster has headroom.
