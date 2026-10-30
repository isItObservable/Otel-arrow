# The small benchmark — three pipeline *engines*, head to head

This benchmark compares **three telemetry pipeline engines** shipping the **same
telemetry** with the **same feature set** — an engine-to-engine comparison, not just a
wire-format one:

| Variant | Engine | Version under test | Language / model | Manifests |
|---------|--------|--------------------|------------------|-----------|
| **A — OTel-Arrow native** | `df_engine` / `otap-dataflow` | `df-engine:0.61.0` (Rust) | **Rust**, Arrow-first, thread-per-core, shared-nothing | [`otel-arrow/`](./otel-arrow/) |
| **B — OTel Collector** | collector-contrib | `0.163.1` (Go) | **Go**, OTLP-shaped in-memory | [`otel-collector/`](./otel-collector/) |
| **C — Fluent Bit v5** | Fluent Bit | `5.1.5` (C) | **C**, native processors | [`fluentbit-v5/`](./fluentbit-v5/) |

Each variant runs the **same shape**: an **agent** (per-node DaemonSet) receives/tails
telemetry, applies a **feature-parity** transform (attributes + a minimal OTTL-style
edit — no tail sampling, because the native engine has none), and forwards to a
**gateway**. The load is identical across all three (see [`loadtest/`](./loadtest/)).

> **📊 Our results:** we ran this benchmark end to end — see **[`RESULTS.md`](./RESULTS.md)**
> for the full numbers. There are two readings there:
>
> - **12-hour production soak** (ships to Dynatrace): all three engines survived a full
>   day of real mesh traffic with a **drop rate far below 1 %** and **zero restarts** —
>   including Fluent Bit v5.1.5 clearing the long-standing Istio-HTTP/2 soak hazard.
> - **Isolated leaf-cost** (nop-sink, equal load), cost per engine in **millicores per 1M
>   spans** (lower is cheaper): Fluent Bit v5 **5.87** · OTel Collector **10.40** ·
>   OTel-Arrow `df_engine` **11.27**. The order flips completely on an **Arrow-native
>   (OTAP) hop**, where the engine drops to **~0.72** because it skips the row→columnar
>   unpack — that inter-engine hop is where OTAP pays off, not the leaf.

> **Shipping the signals:** the configs in each variant export to **Dynatrace** via the
> `otlphttp` / `opentelemetry` output — set your tenant endpoint and apply the ingest
> token from [`dynatrace-secret.example.yaml`](./dynatrace-secret.example.yaml). To
> measure the engine's own cost **without backend variability**, point the exporter at a
> local `nop`-style sink instead (that is how the isolated leaf-cost reading in
> `RESULTS.md` was produced).

---

## Same scope, three engines (this is the whole point)

All three variants run the **identical pipeline scope** — there is no hidden asymmetry
that would flatter one engine:

- **Same signals in:** traces, metrics and logs from the same OTel Demo **and
  hipster-shop**, over OTLP.
- **Same work in the middle:** receive → parse → **attributes** enrichment → a
  **minimal OTTL-style transform** → **batch** → forward. No engine does more or less.
- **Same load out:** each forwards to a gateway that exports to the same backend (or a
  `nop`-style sink for the isolated cost reading) so we measure the engine, not the
  backend.

So the **OTel Collector** pipeline and the **Fluent Bit v5** pipeline cover **exactly the
same scope as the OTel-Arrow `df_engine`** — the comparison is engine-vs-engine on
identical work, which is why the per-span cost numbers are directly comparable. (The one
capability none of them uses is **tail sampling**, because the native engine has none —
see [Fairness boundary](#fairness-boundary).)

> **Enrichment-parity caveat.** The native `df_engine` has **no** `k8sattributes`
> processor, so Variant A does its live k8s-metadata enrichment on the **contrib agent**
> in front of the engine (and the Dynatrace cumulative→delta guard on a thin **contrib
> forwarder** behind it), keeping `df_engine` a pure relay. Variants B and C enrich
> in-engine (`k8sattributes` / the Fluent Bit `kubernetes` filter). Same "enrich" step,
> documented difference in where it runs — not a hidden asymmetry.

---

## Environment the numbers were produced on

| Component | Version | Notes |
|-----------|---------|-------|
| Kubernetes | `1.35.3` | 1 control-plane + 3 × 16 GiB workers |
| Istio | `1.29.2` | **ambient** mesh (ztunnel) + an L7 **waypoint** on the export hop |
| Cilium | `v1.17.4` | CNI |
| OpenTelemetry Operator | chart `0.126.1` | manages the demo-app instrumentation |

The apps (OTel Demo + hipster-shop) point their OTLP exporters at the engine-under-test's
gateway Service, and their Services carry an `appProtocol` on the OTLP ports so the Istio
ambient **waypoint** can L7-route the gRPC/HTTP OTLP traffic. The environment manifests
(mesh, waypoints, demo apps, load generator) and the `appProtocol` explanation live
alongside this benchmark in [`environment/`](./environment/); a full step-by-step
reproduction is in the reproduction guide.

---

## How the benchmark works — ramp-up load + soak

The load is **not** a synthetic packet blaster: it drives the real **OTel Demo
(Astronomy Shop)** (plus hipster-shop) with [Locust](./loadtest/), so the telemetry is
*produced by an actual application under user load*. That matters because the relationship
is direct:

> **more load → more requests → more spans, more logs, more metrics** flowing through the
> engine under test.

Every extra virtual user (VU) exercises more of the shop (checkout, cart, recommendations,
…), and each request fans out into more child spans, more log lines and more metric data
points. So turning the load up is how we turn the *telemetry volume* — and therefore the
engine's work — up in a controlled way.

The profile is **one Locust shape class, phase selected by the `LOAD_PHASE` env var**
([`loadshape.py`](./loadtest/loadshape.py)), so each phase is a cleanly-bounded,
reproducible run:

| Phase (`LOAD_PHASE`) | Load | Duration | What it proves |
|----------------------|------|----------|----------------|
| **`stable30`** | 50 VU held | 30 min | **Baseline** — steady-state cost at a fixed volume. |
| **`rampup2h`** | 50 → 100 → 150 → 200 VU (`+50` every 30 min) | 2 h | **Scaling** — how CPU/memory track as spans/logs/metrics climb. |
| **`leak24h`** | 50 VU held | 24 h | **Soak** — run flat for a day; the tail must stay flat (no memory leak, no creeping restart). |

The **ramp-up** phase is where you see each engine's cost curve as volume rises; the
**soak** phase is the endurance test — a leak or slow degradation only shows up after
hours at steady load, so the long hold is read at its **tail**, not first-vs-last. Run the
**same phase** against **one engine at a time**, tear it down, then repeat for the next, so
every number is attributable to a single engine at a known load.

---

## What to measure

- **Throughput** — records/sec pushed through each engine under the same load.
- **CPU and memory per engine** — from `kubectl top pods` (metrics-server) or cAdvisor
  (`container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`), scoped to
  the agent + gateway pods of one variant at a time.
- **Data integrity** — records in vs out and drop rate from the engine's own counters
  (`fluentbit_output_*`, `otelcol_receiver_accepted_* / otelcol_exporter_sent_*`), and the
  backend-side receipt in Dynatrace; the gate is drop < 1 %, refused = 0, send_failed = 0.
- **Self-telemetry** — the Go collector (and the contrib agent/forwarder) expose a
  Prometheus page on `:8888`; Fluent Bit exposes its metrics on `:2020`.

## Number discipline (say the baseline every time)

- OTAP efficiency is **relative to a named baseline**: **~2× vs OTLP+zstd** (typical), up
  to **~8×** on multivariate metrics, **15–30× only vs *uncompressed* OTLP**. The famous
  **"10×"** is the vs-uncompressed headline — **never quote it bare**.
- The **CPU/memory cost is real** — always show it next to the bandwidth savings.

## Fairness boundary

The native engine has **no tail sampling** and only a **minimal OTTL transform**, so the
benchmark is limited to what all three can do: **receive → parse → light-transform →
batch → forward**. No tail sampling in any variant. State that as the on-camera boundary.

---

## Run it

Prerequisites: a cluster with the OpenTelemetry Operator installed and the OTel Demo (or
any OTLP source) producing telemetry. Create the ingest secret in each engine namespace
first (copy [`dynatrace-secret.example.yaml`](./dynatrace-secret.example.yaml) to
`dynatrace-secret.yaml`, fill in your token, and set the exporter endpoint host in each
config to your tenant). Run **one variant at a time** so the resource numbers are
attributable, tear it down, then run the next against the identical load.

### Variant B — OTel Collector (reference / baseline)

```bash
kubectl create namespace bench-collector
kubectl -n bench-collector apply -f dynatrace-secret.yaml
kubectl apply -f otel-collector/otel-agent-otlp-rbac.yaml
kubectl apply -f otel-collector/otel-gateway-otlp.yaml
kubectl apply -f otel-collector/otel-agent-otlp.yaml
kubectl -n bench-collector rollout status deployment/bench-collector-gateway
```

### Variant C — Fluent Bit v5

```bash
kubectl create namespace bench-fluentbit
kubectl -n bench-fluentbit apply -f dynatrace-secret.yaml
kubectl apply -f fluentbit-v5/fluentbit-configmap.yaml
kubectl apply -f fluentbit-v5/otel-gateway-fluentbit.yaml
kubectl apply -f fluentbit-v5/fluentbit-daemonset.yaml
kubectl -n bench-fluentbit rollout status deployment/bench-fluentbit-gateway
```

### Variant A — OTel-Arrow native (`df_engine`)

```bash
kubectl create namespace bench-arrow
kubectl -n bench-arrow apply -f dynatrace-secret.yaml
kubectl apply -f otel-arrow/df-engine-config.yaml
kubectl apply -f otel-arrow/df-engine-deployment.yaml
kubectl -n bench-arrow rollout status deployment/bench-arrow-dfengine
# df_engine runs one pipeline instance per core and exposes an engine-internal
# admin HTTP server on 127.0.0.1:8080 inside the pod.
```

### Generate load

```bash
kubectl apply -f loadtest/
# LOAD_PHASE / BASE_USERS env in loadshape.py drive the three-phase ramp.
```

### Capture the numbers

```bash
# CPU / memory for the variant currently deployed (swap the namespace per variant)
kubectl top pods -n bench-collector
kubectl top pods -n bench-fluentbit
kubectl top pods -n bench-arrow
```

Take a reading at steady state under each load step, tear the variant down, and repeat.
Report each engine's CPU, memory, drop rate and throughput next to each other — with the
OTLP baseline named every time.
