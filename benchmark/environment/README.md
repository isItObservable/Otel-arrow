# benchmark/environment — application + mesh manifests

The infrastructure the benchmark runs the engine arms against: the two demo
applications, the Istio ambient mesh that carries their telemetry, and the
controlled load generators. The engine-under-test (Fluent Bit / OTel Collector
/ OTel-Arrow `df_engine`) is **not** here — these manifests are identical across
all arms; only the ingest gateway the apps point at changes per arm.

```
environment/
  APPPROTOCOL.md            why every Service port needs appProtocol under a waypoint
  istio/
    namespace-labels.yaml   ambient + use-waypoint labels on the app namespaces
    waypoints.yaml          per-namespace waypoint Gateway (istio-waypoint class)
    mesh-extensionprovider.yaml  the bench-otlp OpenTelemetry extensionProvider
    telemetry.yaml          Telemetry: 100% sampling bound to bench-otlp
  otel-demo/
    values.yaml             Helm values (chart opentelemetry-demo 0.42.6)
    services-appprotocol.yaml  the appProtocol'd Service specs (captured live)
  hipster-shop/
    manifests.yaml          Online Boutique rendered manifests (COLLECTOR_SERVICE_ADDR wiring)
    services-appprotocol.yaml  the appProtocol'd Service specs (captured live)
  loadgenerator/
    30-loadgen-rampup.yaml  base rampup (locust + k6)
    30-locust-otel-demo-job{1,2,3}.yaml  otel-demo step-up Jobs (T+30/60/90m)
    31-loadgen-soak.yaml    12h soak jobs
```

## Bring-up order

1. Install Istio in ambient mode with the `bench-otlp` extensionProvider
   (`istio/mesh-extensionprovider.yaml`).
2. Label the app namespaces and apply the waypoints + Telemetry
   (`istio/namespace-labels.yaml`, `istio/waypoints.yaml`,
   `istio/telemetry.yaml`).
3. Deploy the apps (otel-demo via Helm with `otel-demo/values.yaml`;
   hipster-shop via `hipster-shop/manifests.yaml`).
4. Apply the appProtocol'd Service specs and the collector-endpoint env wiring
   (see `APPPROTOCOL.md`). Verify spans arrive.
5. Run the load (`loadgenerator/`).

The `services-appprotocol.yaml` files were captured from a validated live run
with `kubectl get svc -o yaml` and sanitized; all manifests pass
`kubectl apply --dry-run=server`. Secrets, tokens, and kubeconfigs are never
checked in.
