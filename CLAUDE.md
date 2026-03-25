# matrix-rtc-operator

Declarative Kubernetes operator for the full Matrix + LiveKit + STUNner real-time communication stack. Built on the dcontroller framework — pure YAML pipelines, no Go code.

## Architecture

Three-layer hybrid controller:
- **Platform Layer**: STUNner Operator, Gateway Controller (any), cert-manager, dcontroller runtime
- **Infrastructure Layer**: `RTCInfrastructure` CR (cluster-scoped) — managed/BYO for STUNner, cert-manager, CNPG
- **Application Layer**: `MatrixRTCStack` CR (namespaced) → decomposes to `LiveKitStack` + `MatrixStack` intermediate CRDs → Views → K8s resources

## CRD Hierarchy

```
MatrixRTCStack (user-facing)
  ├── LiveKitStack → LiveKitServerView + LiveKitNetworkingView → K8s resources
  └── MatrixStack  → MatrixServerView + MatrixNetworkingView + MatrixClientView → K8s resources
RTCInfrastructure (cluster-scoped, shared)
```

## Tech Stack

- **Framework**: dcontroller (declarative YAML pipelines)
- **Packaging**: Helm chart
- **Components managed**: Synapse, CNPG PostgreSQL, Element Web, Cinny, LiveKit Server, Redis, lk-jwt-service, STUNner
- **Networking**: Gateway API standard (HTTPRoute/UDPRoute) — works with Traefik, Envoy, Cilium

## Build / Test

```bash
# Lint the chart
helm lint charts/matrix-rtc-operator

# Template render (dry-run)
helm template my-release charts/matrix-rtc-operator

# Install (requires dcontroller runtime on cluster)
helm install matrix-rtc charts/matrix-rtc-operator
```

## Project Structure

```
charts/matrix-rtc-operator/
  ├── Chart.yaml
  ├── values.yaml              # Enterprise values with @param comments
  ├── values.schema.json       # Helm validation schema
  ├── templates/
  │   ├── operator/            # dcontroller Operator CRs (pipeline definitions)
  │   │   ├── stack-decompose.yaml      # Level 0: MatrixRTCStack → LiveKitStack + MatrixStack
  │   │   ├── stack-status.yaml         # Level 0: Status aggregation to top-level
  │   │   ├── livekit-to-views.yaml     # Level 1a: LiveKitStack decomposition
  │   │   ├── livekit-views-to-k8s.yaml # Level 1a: LiveKit materialization
  │   │   ├── livekit-status-writers.yaml
  │   │   ├── matrix-to-views.yaml      # Level 1b: MatrixStack decomposition
  │   │   ├── matrix-views-to-k8s.yaml  # Level 1b: Matrix materialization
  │   │   ├── matrix-bridge.yaml        # Level 1b: LiveKit↔Matrix integration
  │   │   ├── matrix-status-writers.yaml
  │   │   └── infra.yaml               # Infrastructure automation
  │   ├── crds/                # CRD templates (not crds/ dir)
  │   └── rbac.yaml
  └── ci/                      # CI test values
hack/
  ├── livekit/                 # LiveKit-only example CRs
  └── matrix/                  # Full stack example CRs
docs/
```

## Conventions

- **Secret references**: Standardized `{existingSecret, *Key}` pattern everywhere (Bitnami-style)
- **Gateway**: Standard Gateway API only — no controller-specific resources
- **Images**: Pinned versions, no `:latest`
- **Security**: All pods run non-root, read-only rootfs, drop all capabilities
- **Managed/BYO**: All infrastructure components support both managed (operator creates) and BYO (user provides)

## Key Design Patterns (from thesis)

- **Split-view reconciliation**: CRD → ServerView (compute) + NetworkingView (routing) — decouples failure domains
- **Late-binding secrets**: Config with `__PLACEHOLDER__` tokens + env var substitution at runtime (workaround for dcontroller FR-1)
- **@select conditional lifecycle**: Feature flags in pipeline, not labelSelector — enables proper garbage collection
- **Fan-in status aggregation**: K8s resource status → View status → CRD status (uses Patcher, not Updater)
- **@hash rollout triggers**: Secret data hash as pod annotation — forces rolling update on credential rotation

## Status

Proof of concept. Lower-level CRDs (MatrixStack, LiveKitStack) are tested and deployed. Top-level MatrixRTCStack decomposition exists but is not end-to-end tested.
