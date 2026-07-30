#!/usr/bin/env bash
# Deploy the OTel-Arrow episode stack.
#
# Prereqs: a Kubernetes cluster with a default StorageClass and a LoadBalancer
#   (e.g. a service mesh such as Istio ambient is optional but used in the tutorial).
#
# Required env:
#   DT_API_URL        Dynatrace API base (default https://<your-tenant>.live.dynatrace.com/api)
#   DT_OPERATOR_TOKEN Dynatrace operator token  (dt0c01....)
#   DT_INGEST_TOKEN   Dynatrace data-ingest token (dt0c01....)
#
# Usage:  KUBECONFIG=~/.kube/config ./deploy.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DT_API_URL="${DT_API_URL:-https://<your-tenant>.live.dynatrace.com/api}"
CLUSTER_NAME="otel-arrow-demo"

echo "==> [0/6] helm repos"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add dynatrace https://raw.githubusercontent.com/Dynatrace/dynatrace-operator/main/config/helm/repos/stable >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "==> [1/6] cert-manager (webhook dependency for the operators)"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.16.2 --set crds.enabled=true --wait

echo "==> [2/6] Dynatrace operator + DynaKube (ActiveGate, sole DT egress)"
kubectl create namespace dynatrace --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install dynatrace-operator dynatrace/dynatrace-operator \
  --namespace dynatrace --version 1.9.0 --set installCRD=true --wait
kubectl create secret generic "${CLUSTER_NAME}" -n dynatrace \
  --from-literal=apiToken="${DT_OPERATOR_TOKEN:?set DT_OPERATOR_TOKEN}" \
  --from-literal=dataIngestToken="${DT_INGEST_TOKEN:?set DT_INGEST_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${HERE}/dynatrace/dynakube.yaml"

echo "==> [3/6] OpenTelemetry Operator"
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --namespace opentelemetry-operator-system --create-namespace \
  --set "manager.collectorImage.repository=otel/opentelemetry-collector-contrib" \
  --wait

echo "==> [4/6] Gateway + agent collectors (OTAP edge->gateway, gateway->Dynatrace)"
kubectl create secret generic gateway-dynatrace -n default \
  --from-literal=endpoint="${DT_API_URL}" \
  --from-literal=apiToken="${DT_INGEST_TOKEN:?set DT_INGEST_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${HERE}/collectors/otel-agent-rbac.yaml"
kubectl apply -f "${HERE}/collectors/otel-gateway.yaml"
kubectl apply -f "${HERE}/collectors/otel-agent.yaml"
kubectl -n default rollout status statefulset/otel-gateway-collector --timeout=180s || true

echo "==> [5/6] otel-demo WITH Istio ambient"
kubectl create namespace otel-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl label ns otel-demo istio.io/dataplane-mode=ambient --overwrite
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  --namespace otel-demo -f "${HERE}/otel-demo/values.yaml" --wait --timeout 10m

echo "==> [6/6] done. Verify:"
echo "    kubectl get opentelemetrycollector,pods -n default"
echo "    kubectl get dynakube -n dynatrace"
echo "    kubectl get pods -n otel-demo"
