# The small benchmark — three pipeline *engines*, head to head

This benchmark compares **three telemetry pipeline engines** shipping the **same
telemetry** with the **same feature set** — an engine-to-engine comparison, not just a
wire-format one:

| Variant | Engine | Language / model | Manifests |
|---------|--------|------------------|-----------|
| **A — OTel-Arrow native** | `df_engine` / `otap-dataflow` | **Rust**, Arrow-first, thread-per-core, shared-nothing | [`otel-arrow/`](./otel-arrow/) |
| **B — OTel Collector** | collector-contrib | **Go**, OTLP-shaped in-memory | [`otel-collector/`](./otel-collector/) |
| **C — Fluent Bit v5** | Fluent Bit | **C**, native processors | [`fluentbit-v5/`](./fluentbit-v5/) |

Each variant runs the **same shape**: an **agent** (per-node DaemonSet) receives/tails
telemetry, applies a **feature-parity** transform (attributes + a minimal OTTL-style
edit — no tail sampling, because the native engine has none), and forwards to a
**gateway**. The load is identical across all three (see [`loadtest/`](./loadtest/)).

> **Isolation by design:** the gateway in each variant uses a **`nop` sink** (Variant A
> exports to a local `127.0.0.1` OTLP endpoint you can point at `nop`; B and C export to
> `[nop]`). This measures **the engine's own CPU / memory / bytes-on-wire without
> backend variability**. To actually ship the benchmarked signals to Dynatrace, swap the
> sink for the `otlphttp` exporter exactly as [`../deploy/df-engine/`](../deploy/df-engine/)
> does for the tutorial pipeline.

---

## What to measure

- **Throughput** — records/sec pushed through each engine under the same load.
- **CPU and memory per engine** — from `kubectl top pods` (metrics-server) or cAdvisor
  (`container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`), scoped to
  the agent + gateway pods of one variant at a time.
- **Bytes on the wire** — `container_network_transmit_bytes_total` on the agent pods; for
  the Arrow path, report the compression ratio **against a named OTLP baseline**.
- **Self-telemetry** — Variant A exposes its own Prometheus page on the admin endpoint
  (`:8080/metrics`); the Go collector (Variant B) exposes `:8888`.

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

Prerequisite: a cluster with the OpenTelemetry Operator installed (see
[`../deploy/`](../deploy/)) and the OTel Demo (or any OTLP source) producing telemetry.
Run **one variant at a time** so the resource numbers are attributable, tear it down,
then run the next against the identical load.

### Variant B — OTel Collector (baseline)

```bash
kubectl apply -f otel-collector/otel-agent-otlp-rbac.yaml
kubectl apply -f otel-collector/otel-gateway-otlp.yaml
kubectl apply -f otel-collector/otel-agent-otlp.yaml
kubectl -n default rollout status statefulset/otel-gateway-otlp-collector
```

### Variant C — Fluent Bit v5

```bash
kubectl apply -f fluentbit-v5/otel-gateway-fluentbit.yaml
kubectl apply -f fluentbit-v5/fluentbit-configmap.yaml
kubectl apply -f fluentbit-v5/fluentbit-daemonset.yaml
```

### Variant A — OTel-Arrow native (`df_engine`)

```bash
kubectl apply -f otel-arrow/df-engine-config.yaml
kubectl apply -f otel-arrow/df-engine-deployment.yaml
kubectl -n default rollout status deployment/df-engine
# Self-telemetry / live pipeline state:
kubectl -n default port-forward deployment/df-engine 8080:8080 &
curl -s localhost:8080/metrics | head
```

### Generate load

```bash
kubectl apply -f loadtest/locust-otel-demo.yaml
kubectl apply -f loadtest/loadtest_job.yaml
# LOAD_PHASE / BASE_USERS env in loadshape.py drive the three-phase ramp.
```

### Capture the numbers

```bash
# CPU / memory for the variant currently deployed
kubectl top pods -n default | grep -E 'otel-gateway|df-engine|fluent-bit|otel-agent'
```

Take a reading at steady state under each load step, tear the variant down, and repeat.
Report each engine's CPU, memory and (for Variant A) bytes-on-wire next to the throughput
it sustained — with the OTLP baseline named every time.
