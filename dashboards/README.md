# Dashboards

A Dynatrace dashboard to observe the **OTel-Arrow engine** and the **benchmark** —
delivered as **dtctl-compatible YAML** so it version-controls cleanly alongside the rest
of the stack.

## What it shows

- **Engine self-telemetry** — pipeline throughput per node, channel saturation /
  backpressure, and a CPU / memory pair for the `df_engine` pod (the self-telemetry
  pillar from `TUTORIAL.md` Step 8).
- **Benchmark comparison** — CPU, memory and throughput side by side for the three
  engines (otel-collector, Fluent Bit v5, otel-arrow), with the bytes-on-wire /
  compression view and the number-discipline baseline.

## Deploy it

### With `dtctl`

```bash
# https://github.com/dynatrace-oss/dtctl
export DT_ENVIRONMENT=https://<your-tenant>.apps.dynatrace.com
export DT_API_TOKEN=dt0c01....           # scope: documents:documents:write
dtctl apply --file dashboards/otel-arrow-dashboard.yaml
```

The shipped YAML has **no `id`** field, so the first `apply` **creates** a new dashboard
and prints its `id`. To keep updating that same dashboard in place, add the returned
`id:` to the top of the file and re-run `apply` — with an `id` present, `apply`
**updates** rather than creating a duplicate.

### From the Dynatrace UI

**Dashboards → ⋯ → Upload** and select `otel-arrow-dashboard.yaml`.

---

> **Note:** the three **live** tiles are scoped to cluster `otel-arrow-demo` /
> namespace `otel-arrow` via a placeholder `filter:` clause. If your cluster or the
> `df_engine` namespace differ, edit that clause in the CPU / memory / restarts tiles.
> The benchmark-reference tiles embed validated numbers as literals so they render
> identically for everyone.
