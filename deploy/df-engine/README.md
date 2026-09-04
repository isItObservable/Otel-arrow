# The native OTel-Arrow engine (`otap-dataflow` / `df_engine`)

This is the **centerpiece** of the episode: the new **Rust** OpenTelemetry pipeline
engine where **Apache Arrow is the in-pipeline representation end to end** — not just
the wire format. It is thread-per-core, shared-nothing, with bounded channels and
built-in backpressure.

- **Pipeline model** — an explicit **DAG**: a `nodes` map + a `connections` edge list
  (the engine does *not* infer flow from node roles). A node's kind comes from its
  `type` prefix: `receiver:*`, `processor:*`, `exporter:*`. One `otap` pipeline is
  multi-signal (logs+metrics+traces in one graph).
- **Config format is EXPERIMENTAL / unstable** — pin to the commit you build from and
  re-verify `type:` strings and `config:` keys.

## The engine image

A prebuilt image is published and **publicly pullable** (no imagePullSecret) — it is
already wired into `df-engine-deployment.yaml`:

```
ghcr.io/isitobservable/df_engine:0.50.0     # linux/amd64, distroless, ~171MB
```

- ENTRYPOINT is `/home/nonroot/df_engine`; the Deployment passes `--config` and
  `--http-admin-bind` as args. Other flags: `--num-cores`, `--core-id-range`,
  `--validate-and-exit`.
- **Rebuild / bump the version** via the `workflow_dispatch` on
  `.github/workflows/build-df-engine.yml` in this repo, then update the `image:` tag.

## Files

| Path | What |
|------|------|
| `PLUGIN-COVERAGE.md` | Every engine node, in/out decision, and where it's demonstrated. |
| `pipelines/main.yaml` | The runnable episode pipeline (mounted by the ConfigMap). |
| `pipelines/transform-opl.yaml` | `processor:transform` driven by **OPL** — conditional severity + PII (e-mail) hash redaction (the "OPL vs KQL" beat, runtime-proven). |
| `pipelines/test/` | Self-contained OPL test config + `test-opl-transform.sh` (feeds 100 logs, asserts the OPL branched off the wire). |
| `pipelines/otap-hop.yaml` | Two engines exchanging columnar Arrow (OTAP) — the headline. |
| `pipelines/host-and-self.yaml` | host_metrics + internal_telemetry (observe the engine itself). |
| `pipelines/routing.yaml` | content_router / fanout / partition / log_sampling / temporal_reaggregation / delay. |
| `pipelines/topics.yaml` | In-process pub/sub between pipelines. |
| `pipelines/contrib-processors.yaml` | condense_attributes / recordset_kql / resource_validator. |
| `pipelines/reference-sources.yaml` | syslog_cef / journald / kafka / etw / user_events (platform-specific). |
| `pipelines/reference-exports.yaml` | otlp_grpc / parquet / kafka / clickhouse / geneva / azure_monitor. |
| `df-engine-configmap.yaml` | ConfigMap of `main.yaml`. |
| `df-engine-deployment.yaml` | Deployment + Service (image placeholder). |

## Plugin coverage in one line

We exercise **every node the engine ships except the four designed for testing**
(`traffic_generator`, `noop`, `error`, `perf`). Full matrix + rationale, plus the
engine's honest gaps (no filelog, no prometheus scrape, no k8sattributes, no tail
sampling), are in [`PLUGIN-COVERAGE.md`](./PLUGIN-COVERAGE.md).

## Deploy the engine

```bash
# 1) build + push the image, set it in df-engine-deployment.yaml (see above)
# 2) create the Dynatrace egress secret (same as the Go-collector path)
kubectl create secret generic gateway-dynatrace -n default \
  --from-literal=endpoint="${DT_API_URL}" \
  --from-literal=apiToken="${DT_INGEST_TOKEN}"
# 3) apply
kubectl apply -f df-engine-configmap.yaml
kubectl apply -f df-engine-deployment.yaml
# 4) point otel-demo at the engine's OTLP endpoint (df-engine-gateway:4317)
```

## Admin / self-observability

The engine exposes an **admin HTTP endpoint** (`--http-admin-bind`, port 8080 here)
that serves current pipeline state, config, debug logs and Prometheus metrics, plus a
live-reconfiguration API. Combined with `pipelines/host-and-self.yaml`
(`internal_telemetry` receiver), this is the "observe OTel-Arrow itself" pillar.
