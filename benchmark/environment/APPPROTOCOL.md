# appProtocol and Istio Ambient Waypoints

This benchmark runs the two demo applications (OTel Demo and hipster-shop)
inside an **Istio ambient mesh**. In ambient mode, L7 processing is performed by
a **waypoint proxy** rather than by per-pod sidecars. Getting OpenTelemetry data
out of the applications and into the engine-under-test depends on one
easily-missed detail: the `appProtocol` field on every Kubernetes `Service` port
that carries OTLP traffic. This document explains why it matters, the exact
change that was made, how the applications are wired to the engine gateway, and
the mesh resources that tie it together.

The concrete Service manifests this document describes are the
`services-appprotocol.yaml` files in `otel-demo/` and `hipster-shop/`, captured
live from a validated run; the mesh resources are in `istio/`.

## Why the waypoint needs `appProtocol`

A waypoint proxy only applies L7 behaviour — HTTP/gRPC routing, retries, and the
tracing/metrics defined through the Telemetry API — to traffic whose protocol it
can identify. Istio determines a port's protocol in one of two ways:

1. a port **name** with a recognized prefix (`grpc-...`, `http-...`, `http2-...`), or
2. the port's explicit **`appProtocol`** field.

If neither is present, Istio falls back to treating the port as **opaque TCP**.
For an opaque-TCP port the waypoint does no L7 inspection at all: it passes bytes
through as an undifferentiated stream.

OTLP is carried either over **gRPC (HTTP/2)** on port `4317` or over **HTTP** on
port `4318`. When the destination Service port is left as opaque TCP, the
waypoint cannot frame the HTTP/2 streams that gRPC-OTLP depends on, cannot apply
the mesh Telemetry configuration, and cannot L7-route the request onward. The
practical, visible symptom is that **no spans arrive at the engine** even though
the applications appear healthy and are emitting data — the telemetry is
silently dropped at the mesh layer.

Setting `appProtocol` correctly tells the waypoint exactly how to handle each
port, restores HTTP/2 framing for gRPC, and lets the Telemetry API apply to OTLP
traffic. Spans, metrics and logs then flow end to end.

## The concrete change

Every `Service` that exposes an OTLP (or otherwise L7) port in the otel-demo and
hipster-shop deployments carries an explicit `appProtocol`:

| Port  | Protocol       | `appProtocol` |
|-------|----------------|---------------|
| 4317  | OTLP over gRPC | `grpc`        |
| 4318  | OTLP over HTTP  | `http`       |
| other gRPC service ports | gRPC | `grpc` |
| other HTTP service ports | HTTP | `http` |

Concretely:

- `appProtocol: grpc` is set on every gRPC port, including the engine gateway's
  `4317` ingest port and the gRPC ports of the application services.
- `appProtocol: http` is set on every HTTP port, including the engine gateway's
  `4318` ingest port and the applications' HTTP ports.

A Service port with `appProtocol` looks like this:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ad
  namespace: otel-demo
spec:
  ports:
    - name: tcp-service
      port: 8080
      targetPort: 8080
      appProtocol: grpc        # <-- required for the ambient waypoint
```

The change is applied to **every** otel-demo Service and **every** hipster-shop
Service that participates in L7 traffic through the mesh — not only to the
OTLP endpoint. A waypoint sits in front of the whole namespace, so any port that
should be L7-handled needs the annotation. The `services-appprotocol.yaml` files
hold the full, live-captured set (otel-demo in namespace `otel-demo`,
hipster-shop in namespace `hipster-shop`).

## How the applications are wired to the engine gateway

The two applications discover the engine-under-test's ingest gateway through
different environment variables. Both resolve to the same gateway Service for
whichever engine arm is deployed (its name is per-arm, e.g.
`bench-collector-otlp.bench-collector…:4317`).

- **otel-demo** uses the standard OpenTelemetry SDK variable
  **`OTEL_EXPORTER_OTLP_ENDPOINT`**. Note that the demo Helm chart does **not**
  render this variable into the application Deployments by default, so the SDKs
  otherwise fall back to `localhost:4317` and export nothing to the gateway. It
  must be set explicitly to the engine gateway — gRPC-native apps to `:4317`
  (`OTEL_EXPORTER_OTLP_PROTOCOL=grpc`), HTTP-native apps to `:4318`
  (`OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`). The required values are
  documented in `otel-demo/values.yaml`.

- **hipster-shop** (Online Boutique) uses its own variable
  **`COLLECTOR_SERVICE_ADDR`** (a bare `host:port` for OTLP/gRPC), pointed at the
  engine gateway on **`:4317`**. This is the variable the application code
  actually reads; it is set in `hipster-shop/manifests.yaml`.

Because the gateway is reached through the mesh, both of these endpoints only
work once the ports along the path carry the matching `appProtocol`
(`grpc` for `:4317`, `http` for `:4318`).

## The mesh pieces: waypoint, extensionProvider, Telemetry

Three mesh resources, all under `istio/`, complete the picture:

1. **Waypoint** (`waypoints.yaml`, `namespace-labels.yaml`) — a waypoint proxy is
   deployed per application namespace using a `Gateway` with
   `gatewayClassName: istio-waypoint`. Each app namespace is enrolled in the
   ambient data plane and opted into the waypoint with the labels
   `istio.io/dataplane-mode: ambient` and `istio.io/use-waypoint: waypoint`.
   This is what performs the L7 processing that `appProtocol` enables.

2. **extensionProvider (`bench-otlp`)** (`mesh-extensionprovider.yaml`) — the
   Istio mesh configuration defines an OpenTelemetry tracing extension provider,
   named `bench-otlp`, under `meshConfig.extensionProviders`. It points the
   mesh's tracing output at the OTLP endpoint.

   ```yaml
   meshConfig:
     extensionProviders:
       - name: bench-otlp
         opentelemetry:
           service: <engine-gateway>.<namespace>.svc.cluster.local
           port: 4317
   ```

3. **Telemetry** (`telemetry.yaml`) — a `Telemetry` resource selects the
   `bench-otlp` provider (at 100% sampling) so the waypoint emits mesh tracing to
   the engine for the namespace's L7 traffic.

   ```yaml
   apiVersion: telemetry.istio.io/v1
   kind: Telemetry
   metadata:
     name: bench-tracing
   spec:
     tracing:
       - providers:
           - name: bench-otlp
   ```

Together: the waypoint provides L7 handling, `appProtocol` makes the OTLP ports
L7-eligible, the `bench-otlp` extensionProvider names the engine, and the
`Telemetry` resource wires the provider into the mesh. Omitting the
`appProtocol` on the Service ports breaks the chain at the first link — the
waypoint treats OTLP as opaque TCP and the engine receives nothing.

## Quick checklist

- [ ] Every OTLP `:4317` Service port has `appProtocol: grpc`.
- [ ] Every OTLP `:4318` Service port has `appProtocol: http`.
- [ ] Other gRPC/HTTP Service ports carry the matching `appProtocol`.
- [ ] otel-demo workloads have `OTEL_EXPORTER_OTLP_ENDPOINT` pointing at the engine gateway.
- [ ] hipster-shop workloads have `COLLECTOR_SERVICE_ADDR` pointing at the engine gateway on `:4317`.
- [ ] Both app namespaces carry `istio.io/dataplane-mode: ambient` and `istio.io/use-waypoint: waypoint`.
- [ ] The `bench-otlp` extensionProvider and the `Telemetry` resource are applied.
