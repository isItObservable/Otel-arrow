#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# test-opl-transform.sh — prove the df_engine OPL transform works off the wire.
#
# Deploys the self-contained `transform-opl-test.yaml` (otlp → transform(opl) →
# console) into a scratch namespace, feeds 100 logs with telemetrygen (50 that
# contain "error"+an e-mail, 50 clean), reads the console exporter output, and
# asserts the OPL actually READ each body and BRANCHED:
#
#   50 severity=ERROR   50 severity=CLEARED
#   50 bodies redacted  50 pii.email.detected=true   0 e-mail leaks
#   50 clean bodies left untouched
#
# This is the RUNTIME oracle. `--validate-and-exit` accepts garbage on this
# engine, so a green validate is NOT proof — reading emitted bytes is.
#
# Requirements: kubectl context pointing at a cluster that can pull
#   ghcr.io/isitobservable/df_engine:0.50.0  and the contrib telemetrygen image.
# Usage:   ./test-opl-transform.sh            # deploy, test, tear down
#          KEEP=1 ./test-opl-transform.sh     # leave the namespace up for poking
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NS="${NS:-dfopl-test}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_CFG="${HERE}/transform-opl-test.yaml"
TGEN_IMG="ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest"
DFENGINE_IMG="ghcr.io/isitobservable/df_engine:0.50.0"
FAIL=0

cleanup() { [[ "${KEEP:-0}" == "1" ]] || kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> [1/5] create namespace + df_engine (OPL → console)"
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create configmap df-engine-opl-test \
  --from-file=config.yaml="$TEST_CFG" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: df-engine-opl, namespace: ${NS}, labels: { app: df-engine-opl, oneagent: "false" } }
spec:
  replicas: 1
  selector: { matchLabels: { app: df-engine-opl } }
  template:
    metadata: { labels: { app: df-engine-opl, oneagent: "false" } }
    spec:
      containers:
        - name: df-engine
          image: ${DFENGINE_IMG}
          args: ["--config", "/etc/otap/config.yaml", "--http-admin-bind", "0.0.0.0:8080"]
          ports: [ { containerPort: 4317 }, { containerPort: 4318 }, { containerPort: 8080 } ]
          volumeMounts: [ { name: config, mountPath: /etc/otap, readOnly: true } ]
          resources: { requests: { cpu: "250m", memory: 128Mi }, limits: { cpu: "1", memory: 512Mi } }
      volumes: [ { name: config, configMap: { name: df-engine-opl-test } } ]
---
apiVersion: v1
kind: Service
metadata: { name: df-engine-opl, namespace: ${NS} }
spec:
  selector: { app: df-engine-opl }
  ports: [ { name: otlp-grpc, port: 4317, targetPort: 4317 } ]
EOF

echo "==> [2/5] wait for the engine to load the OPL config (a bad query crashes the pod)"
kubectl -n "$NS" rollout status deploy/df-engine-opl --timeout=120s

EP="df-engine-opl.${NS}.svc.cluster.local:4317"
echo "==> [3/5] feed 50 error+e-mail logs and 50 clean logs → ${EP}"
kubectl -n "$NS" run tgen-error --image="$TGEN_IMG" --restart=Never -- \
  logs --logs 50 --rate 200 --otlp-insecure --otlp-endpoint "$EP" \
  --body "error connecting to db for user alice@example.com" >/dev/null
kubectl -n "$NS" run tgen-clean --image="$TGEN_IMG" --restart=Never -- \
  logs --logs 50 --rate 200 --otlp-insecure --otlp-endpoint "$EP" \
  --body "request completed successfully" >/dev/null
for p in tgen-error tgen-clean; do
  kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$p" --timeout=120s >/dev/null
done

echo "==> [4/5] flush the batch, read the console exporter output"
sleep 6
LOG="$(kubectl -n "$NS" logs deploy/df-engine-opl --tail=-1)"

count() { printf '%s\n' "$LOG" | grep -c "$1" || true; }
ERR=$(count 'ERROR'); CLR=$(count 'CLEARED'); RED=$(count 'REDACTED')
PII=$(count 'pii.email.detected'); LEAK=$(count 'alice@example.com')
CLEAN=$(count 'request completed successfully')

echo "==> [5/5] assertions"
check() { # name actual expected
  if [[ "$2" == "$3" ]]; then echo "    PASS  $1 = $2"; else echo "    FAIL  $1 = $2 (expected $3)"; FAIL=1; fi
}
check "severity ERROR"            "$ERR"   50
check "severity CLEARED"          "$CLR"   50
check "bodies REDACTED (hash)"    "$RED"   50
check "pii.email.detected=true"   "$PII"   50
check "e-mail leaks"              "$LEAK"  0
check "clean bodies untouched"    "$CLEAN" 50

echo
if [[ "$FAIL" == "0" ]]; then echo "RESULT: PASS — OPL read the body and branched (KQL could not)."; else
  echo "RESULT: FAIL — sample of engine output:"; printf '%s\n' "$LOG" | grep -E 'ERROR|CLEARED' | head; fi
exit "$FAIL"
