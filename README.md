# matrix-rtc-operator

Declarative Kubernetes operator for the full Matrix + LiveKit + STUNner real-time communication stack. Built on the [dcontroller](https://github.com/l7mp/dcontroller) framework -- pure YAML pipelines, no Go code.

**Status: Proof of Concept** -- lower-level CRDs (MatrixStack, LiveKitStack) are tested and deployed. The top-level MatrixRTCStack decomposition exists but is not yet end-to-end tested.

## Overview

matrix-rtc-operator manages the complete stack for Matrix-native real-time communication:

- **Matrix (Synapse)** -- homeserver with CNPG-managed PostgreSQL
- **Clients (Element Web, Cinny)** -- web frontends with auto-configured homeserver discovery
- **LiveKit** -- SFU for voice/video with Redis state store
- **STUNner** -- Kubernetes-native TURN/STUN media gateway
- **Networking** -- Gateway API standard (HTTPRoute/UDPRoute), works with Traefik, Envoy, or Cilium

A single `MatrixRTCStack` custom resource provisions the entire stack. Infrastructure components (STUNner, cert-manager, CNPG) can be operator-managed or brought-your-own via the cluster-scoped `RTCInfrastructure` resource.

## Architecture

The operator uses a three-layer CRD hierarchy. Each layer decomposes into the next via dcontroller pipelines, with status aggregated back up.

```
MatrixRTCStack (user-facing, namespaced)
├── LiveKitStack
│   ├── LiveKitServerView    → Deployment, Service, ConfigMap, Secret
│   └── LiveKitNetworkingView → HTTPRoute, UDPRoute
└── MatrixStack
    ├── MatrixServerView     → Deployment, Service, ConfigMap, CNPG Cluster
    ├── MatrixNetworkingView → HTTPRoute (.well-known, federation)
    └── MatrixClientView     → Deployment, Service, HTTPRoute (per client)

RTCInfrastructure (cluster-scoped, one per cluster)
└── Manages/references: STUNner Gateway, cert-manager ClusterIssuer, CNPG operator
```

Split-view reconciliation (ServerView + NetworkingView) decouples compute and routing failure domains. Feature flags use `@select` conditional lifecycle for proper garbage collection on toggle.

## Prerequisites

- Kubernetes 1.27+
- [dcontroller](https://github.com/l7mp/dcontroller) runtime installed on the cluster
- [CNPG operator](https://cloudnative-pg.io/) (for managed PostgreSQL)
- [cert-manager](https://cert-manager.io/) (optional, can be operator-managed or BYO)
- [STUNner](https://github.com/l7mp/stunner) (optional, can be operator-managed or BYO)
- A Gateway API implementation (Traefik, Envoy Gateway, Cilium, etc.)

## Quickstart

```bash
# Install the operator (CRDs + dcontroller pipelines)
helm install matrix-rtc charts/matrix-rtc-operator

# Create the cluster-scoped infrastructure config
kubectl apply -f hack/infrastructure.yaml

# Create platform secrets (edit values first!)
kubectl apply -f hack/secrets.yaml

# Deploy a full stack
kubectl apply -f hack/matrix/matrix-stack.yaml
```

## Example

Minimal `MatrixRTCStack`:

```yaml
apiVersion: lukacsi.org/v1alpha1
kind: MatrixRTCStack
metadata:
  name: my-stack
  namespace: matrix
spec:
  matrix:
    synapse:
      serverName: "example.com"
      signingKey:
        existingSecret: "synapse-signing-key"
        signingKeyKey: "signing.key"
    database:
      mode: "managed"
      storage:
        size: "10Gi"
    clients:
      - name: element
        enabled: true
      - name: cinny
        enabled: true
  livekit:
    keys:
      existingSecret: "livekit-auth"
      apiKeyKey: "api-key"
      apiSecretKey: "api-secret"
    redis:
      mode: "managed"
```

## Project Structure

```
charts/matrix-rtc-operator/
  ├── Chart.yaml
  ├── values.yaml              # Full configuration with @param comments
  ├── values.schema.json       # Helm validation schema
  ├── templates/
  │   ├── operator/            # dcontroller pipeline definitions
  │   ├── crds/                # Custom Resource Definitions
  │   └── rbac.yaml            # RBAC for dcontroller runtime
  └── ci/                      # CI test values
hack/                          # Example CRs for testing
docs/                          # Research and design documents
```

## Key Design Patterns

- **Split-view reconciliation**: CRD decomposes into ServerView (compute) + NetworkingView (routing), decoupling failure domains
- **Late-binding secrets**: Config templates with placeholder tokens + env var substitution at runtime
- **Managed/BYO infrastructure**: Every infrastructure component supports both operator-managed and bring-your-own modes
- **Fan-in status aggregation**: K8s resource status flows up through Views to CRDs via Patcher pipelines
- **`@hash` rollout triggers**: Secret data hashed into pod annotations to force rolling updates on credential rotation

## Development

```bash
# Lint the chart
helm lint charts/matrix-rtc-operator

# Template render (dry-run)
helm template my-release charts/matrix-rtc-operator

# Install (requires dcontroller runtime)
helm install matrix-rtc charts/matrix-rtc-operator
```

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.
