# OTel-Arrow (`otap-dataflow`) engine — plugin coverage

This episode is built on the **native Rust OTel-Arrow pipeline engine** (`otap-dataflow`,
a.k.a. `df_engine`) — Arrow-first, thread-per-core, shared-nothing. The engine ships a
**limited but growing set of nodes** (receivers / processors / exporters). Our goal is to
**exercise every node the engine ships, except the ones designed for testing**.

> **Source of truth:** node list enumerated directly from the repo at
> `rust/otap-dataflow/crates/{core-nodes,contrib-nodes}/src/{receivers,processors,exporters}`
> and the example configs under `rust/otap-dataflow/configs/`. The config format is
> **experimental and not yet stable** — re-verify exact `type:` strings and `config:` keys
> against the commit you build the image from.

## Legend

- ✅ **Covered** — demonstrated in a pipeline config in `pipelines/`.
- 🧪 **Excluded (testing)** — designed for load-testing / benchmarking / fault-injection,
  not a real production node. Per board direction we deliberately leave these out.
- 🖥️ **Covered (reference)** — platform- or backend-specific (Windows ETW, systemd
  journald, Kafka, ClickHouse, Azure/Geneva…). Shown as a validated **reference config**
  snippet rather than wired into the live otel-demo pipeline, because it needs an
  environment we don't stand up in the episode.

---

## Receivers

| Node (`type:`) | Crate | Status | Where |
|---|---|---|---|
| `receiver:otlp` | core | ✅ | `pipelines/main.yaml` (otel-demo apps → engine) |
| `receiver:otap` | core | ✅ | `pipelines/otap-hop.yaml` (edge→gateway Arrow hop) |
| `receiver:host_metrics` | core | ✅ | `pipelines/host-and-self.yaml` |
| `receiver:internal_telemetry` | core | ✅ | `pipelines/host-and-self.yaml` (self-observability) |
| `receiver:syslog_cef` | core | 🖥️ | `pipelines/reference-sources.yaml` |
| `receiver:journald` | core | 🖥️ | `pipelines/reference-sources.yaml` |
| `receiver:topic` | core | ✅ | `pipelines/topics.yaml` (in-process pub/sub) |
| `receiver:traffic_generator` | core | 🧪 **excluded** | synthetic load source — we use the real otel-demo instead |
| `receiver:etw` | contrib | 🖥️ | `pipelines/reference-sources.yaml` (Windows ETW) |
| `receiver:kafka` | contrib | 🖥️ | `pipelines/reference-sources.yaml` |
| `receiver:user_events` | contrib | 🖥️ | `pipelines/reference-sources.yaml` (Linux user_events) |

## Processors

| Node (`type:`) | Crate | Status | Where |
|---|---|---|---|
| `processor:batch` | core | ✅ | every pipeline (last processor) |
| `processor:retry` | core | ✅ | `pipelines/main.yaml` |
| `processor:attributes` | core | ✅ | `pipelines/main.yaml` (add/remove/rename/upsert) |
| `processor:filter` | core | ✅ | `pipelines/main.yaml` |
| `processor:transform` | core | ✅ | `pipelines/main.yaml` (OTTL-style); `pipelines/transform-opl.yaml` (**OPL** — native surface: conditional severity + PII hash redaction, runtime-proven via `pipelines/test/test-opl-transform.sh`) |
| `processor:signal_type_router` | core | ✅ | `pipelines/main.yaml` (logs/metrics/traces fan-out) |
| `processor:content_router` | core | ✅ | `pipelines/routing.yaml` |
| `processor:fanout` | core | ✅ | `pipelines/routing.yaml` |
| `processor:partition` | core | ✅ | `pipelines/routing.yaml` |
| `processor:log_sampling` | core | ✅ | `pipelines/routing.yaml` (**head** sampling — NOT tail) |
| `processor:temporal_reaggregation` | core | ✅ | `pipelines/routing.yaml` |
| `processor:delay` | core | ✅ | `pipelines/routing.yaml` |
| `processor:durable_buffer` | core | ✅ | `pipelines/otap-hop.yaml` (disk-backed queue) |
| `processor:debug` | core | ✅ *(debug aid)* | `pipelines/host-and-self.yaml` |
| `processor:condense_attributes` | contrib | ✅ | `pipelines/contrib-processors.yaml` |
| `processor:recordset_kql` | contrib | ✅ | `pipelines/contrib-processors.yaml` (KQL over record sets) |
| `processor:resource_validator` | contrib | ✅ | `pipelines/contrib-processors.yaml` |

## Exporters

| Node (`type:`) | Crate | Status | Where |
|---|---|---|---|
| `exporter:otlp_http` | core | ✅ | `pipelines/main.yaml` (→ Dynatrace, sole egress) |
| `exporter:otlp_grpc` | core | ✅ | `pipelines/reference-exports.yaml` |
| `exporter:otap` | core | ✅ | `pipelines/otap-hop.yaml` (Arrow between engines) |
| `exporter:parquet` | core | ✅ | `pipelines/reference-exports.yaml` (local / S3) |
| `exporter:console` | core | ✅ *(debug aid)* | `pipelines/host-and-self.yaml` |
| `exporter:topic` | core | ✅ | `pipelines/topics.yaml` |
| `exporter:kafka` | contrib | 🖥️ | `pipelines/reference-exports.yaml` |
| `exporter:clickhouse` | contrib | 🖥️ | `pipelines/reference-exports.yaml` |
| `exporter:geneva` | contrib | 🖥️ | `pipelines/reference-exports.yaml` (Microsoft Geneva) |
| `exporter:azure_monitor` | contrib | 🖥️ | `pipelines/reference-exports.yaml` |
| `exporter:noop` | core | 🧪 **excluded** | discards data — benchmark/testing sink |
| `exporter:error` | core | 🧪 **excluded** | deliberately errors — fault-injection testing |
| `exporter:perf` | core | 🧪 **excluded** | throughput-measurement sink for benchmarks |

---

## Excluded on purpose (designed for testing)

| Node | Why it exists | Why we skip it |
|---|---|---|
| `receiver:traffic_generator` | synthesises fake telemetry for load tests | we have a **real** source (otel-demo) |
| `exporter:noop` | drops everything | measures upstream throughput only |
| `exporter:error` | returns errors on purpose | exercises retry/backpressure in tests |
| `exporter:perf` | counts records/bytes, no real sink | benchmark instrumentation |

`processor:debug` and `exporter:console` are **debug/inspection aids** (print telemetry).
They are included because they are genuinely useful while learning the engine — flip them
off for production. If the board considers them "testing", drop the two nodes from
`host-and-self.yaml`; nothing else depends on them.

---

## Known engine gaps (state these honestly on camera)

The `otap-dataflow` engine does **not** (yet) have:

- **No `filelog` / pod-log-tail receiver** — pod-log collection must come in as OTLP (apps'
  SDK logs) or via an edge Go collector. Confirmed absent from the receivers tree.
- **No `prometheus` scrape receiver** — no HTTP `/metrics` target scraping. `host_metrics`
  covers node metrics; app metrics arrive over OTLP.
- **No `k8sattributes` processor** — no live Kubernetes-metadata enrichment (asked upstream;
  still unimplemented on `main` and all visible branches). Use `attributes` for static
  attributes only.
- **No tail sampling** — only head-style `log_sampling`. This is the episode's honest
  scope boundary.
