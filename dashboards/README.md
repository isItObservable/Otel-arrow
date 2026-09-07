# OTel-Arrow df-engine Dynatrace Dashboard

**Published** in tenant `oat05854.dev.apps.dynatracelabs.com`.

| | |
|---|---|
| Dashboard ID | `37e6f014-6167-45be-a9f9-85a0d71a7385` |
| URL | https://oat05854.dev.apps.dynatracelabs.com/ui/apps/dynatrace.dashboards/dashboard/37e6f014-6167-45be-a9f9-85a0d71a7385 |
| Dashboard definition | [`otel-arrow-dashboard.yaml`](./otel-arrow-dashboard.yaml) (id pinned — `dtctl apply` updates in place) |
| Internal-metrics pipeline | [`df-engine-internal-metrics-collector.yaml`](./df-engine-internal-metrics-collector.yaml) |
| Publish tool | `dtctl`, context `dynatrace-dev` (stored in `~/.config/dtctl`) |

## What it shows

The subject is the OTel-Arrow **df-engine** (the Rust engine). The dashboard opens with an
operator overview and then drills into detail.

### Operator overview (top row)
At-a-glance answers to "is it healthy?":

- **Engines running** — distinct df-engine pods reporting (`countDistinct(k8s.pod.name)`)
- **Data in** — records received by the engine's receiver nodes (`recv_count_total`, delta)
- **Data out** — records exported by the engine's exporter nodes (`send_count_total`, delta)
- **Errors** — backpressure + closed-channel + dropped/nacked signals summed to one number
  (0 = healthy; green/red threshold)
- **Data flow in vs out over time** and **Errors over time** trend charts

### Engine internals — detail
The df-engine's **own** registry-backed self-telemetry (Prometheus counters on
`:8080 /api/v1/metrics`, delivered to Grail via the scrape pipeline below):

- Node throughput sent / intake received per bin, by internal DAG node
  (`send_count_total` / `recv_count_total`, grouped by `node_id` / `node_type`)
- Payload throughput — bytes moved per bin (`payload_size_bytes_total`)
- Channel backpressure & closed-channel errors (`send_error_full_total` / `_closed_total`)
- Signals dropped & nacked (`signals_dropped_*` / `signals_nacked_*`)
- Runtime CPU utilization (`cpu_utilization`) and process memory (`process_memory_usage_bytes`)
- Saturation — global task queue & buffered pending sends
  (`global_task_queue_size` / `pending_sends_buffered`)

### Pod resources — detail (Dynatrace operator, `dt.kubernetes.*`)
Scope: cluster `observable-otelarrow`, `matchesValue(k8s.workload.name, "*df-engine*")`,
resolving to `bench-df-engine-otap` (ns `default`) and `df-engine-opl` (ns `dfopl-test`).

- CPU per pod, CPU utilization vs limit (%)
- Memory working set per pod, memory utilization vs limit (%)
- CPU throttling, pod network RX/TX

## Getting the engine-internal metrics into Dynatrace (the pipeline)

The df-engine's internal counters are **cumulative**, which the Dynatrace OTLP metric ingest
rejects (it wants delta temporality) — so the engine cannot export them directly, and its
own observability pipeline sinks them to a noop exporter. The fix is a small collector that
scrapes the Prometheus endpoint, converts cumulative→delta, and exports OTLP to Dynatrace:
[`df-engine-internal-metrics-collector.yaml`](./df-engine-internal-metrics-collector.yaml).

```bash
export KUBECONFIG=<observable-otelarrow kubeconfig>
kubectl apply -f df-engine-internal-metrics-collector.yaml   # OpenTelemetryCollector CR, ns default
kubectl -n default logs deploy/df-engine-internal-collector  # expect no export errors
```

The collector reuses the same Dynatrace API token the gateway already uses (referenced from
the `gateway-dynatrace` secret via env — never inlined). To add a second engine target
(e.g. `df-engine-opl`), append it to `scrape_configs[].static_configs[].targets`.

## Verify every query yourself (all validated 2026-09-07)

```bash
export XDG_CONFIG_HOME=/home/hrexed/.config   # dtctl context dynatrace-dev lives here

dtctl describe dashboard 37e6f014-6167-45be-a9f9-85a0d71a7385
# engine-internal throughput by DAG node (delta):
dtctl query 'timeseries sent = sum(send_count_total), by:{node_id, node_type}'
# engine-internal backpressure gate (flat 0 = healthy):
dtctl query 'timeseries full = sum(send_error_full_total), by:{node_id}'
# pod resource usage (operator), df-engine only:
dtctl query 'timeseries mem = avg(dt.kubernetes.container.memory_working_set), by:{k8s.workload.name, k8s.pod.name}, filter:{ matchesValue(k8s.workload.name, "*df-engine*") }'
```

## Update the live dashboard

```bash
export XDG_CONFIG_HOME=/home/hrexed/.config
dtctl apply --file otel-arrow-dashboard.yaml     # id is pinned -> updates in place
```

## Notes

- Engine-internal counters are exported as **delta**, so a `sum(...)` bin is the work done
  in that bin. Idle looks near-zero — set the timeframe to a benchmark/soak window for signal.
- Health gates (backpressure, closed-channel, signals-dropped, receiver-refused, send-failed)
  rendering **flat/empty is the healthy state** — series only rise when something is wrong.
- The dashboard is **public in the tenant** (`isPrivate: false`). Note `dtctl apply` ignores
  the `isPrivate:` field in the YAML — visibility is managed at the API level.
