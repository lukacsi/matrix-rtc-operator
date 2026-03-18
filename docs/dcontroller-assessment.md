# Phase 0: dcontroller Assessment

**Date:** 2026-03-18
**Conclusion:** All critical blockers are clear. dcontroller is more capable than the thesis documented.

## P0-1: CNPG Cluster CRD Creation — CLEAR

**Can dcontroller create third-party CRDs?** YES.

Sources and targets accept any `apiGroup` and `kind` — the `Resource` struct is fully generic (`pkg/api/operator/v1alpha1/controller_types.go`). No hardcoded restrictions.

**What's needed:** RBAC ClusterRole rules must enumerate the target resources explicitly:
```yaml
- apiGroups: ["postgresql.cnpg.io"]
  resources: ["clusters"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```

**Example target:**
```yaml
target:
  apiGroup: postgresql.cnpg.io
  kind: Cluster
  type: Updater
```

**Status:** No blocker. Proceed with CNPG Cluster creation in Phase 2.

## P0-2: @concat for homeserver.yaml — CLEAR (with pattern)

**Can @concat generate multiline YAML config?** YES — proven by existing livekit-operator.

The `livekit-config-generator` controller in `views-to-k8s.yaml` (line 102) generates a complete `livekit.yaml` via @concat with embedded `\n` characters:

```yaml
stringData:
  livekit.yaml:
    "@concat":
      - "keys:\n  "
      - "$.Secret.data['api-key']"
      - ": "
      - "$.Secret.data['api-secret']"
      - "\nlog_level: info\nport: 7880\nredis:\n  address: "
      - "$.LiveKitNetworkingView.spec.redis.url"
      - "\n  password: "
      - "$.Secret.data['redis-password']"
      - "\n\nrtc:\n  port_range_end: 60000\n  ..."
```

**Pattern for homeserver.yaml:** Same approach. Concat static YAML fragments with dynamic values:
```yaml
stringData:
  homeserver.yaml:
    "@concat":
      - "server_name: "
      - "$.MatrixServerView.spec.domain"
      - "\npublic_baseurl: https://"
      - "$.MatrixNetworkingView.spec.subdomain"
      - "."
      - "$.MatrixServerView.spec.domain"
      - "\n\nserve_server_wellknown: true"
      - "\n\ndatabase:\n  name: psycopg2\n  args:\n    host: "
      - "$.MatrixServerView.spec.database.host"
      - "\n    port: 5432\n    database: synapse\n    user: synapse\n    password: "
      - "$.Secret.data['password']"
      - "\n    cp_min: 5\n    cp_max: 10"
      - "\n\nexperimental_features:\n  msc3266_enabled: true\n  msc4140_enabled: true\n  msc4222_enabled: true"
      - "\n\nmax_event_delay_duration: 24h"
      - "\n\nrc_message:\n  per_second: 0.5\n  burst_count: 30"
      - "\n\nrc_delayed_event_mgmt:\n  per_second: 1\n  burst_count: 20"
      - "\n\nenable_registration: "
      - "@string": "$.MatrixServerView.spec.config.enableRegistration"
      - "\n\nlisteners:\n  - port: 8008\n    tls: false\n    type: http\n    x_forwarded: true\n    resources:\n      - names: [client, federation]\n        compress: false"
```

**Status:** No blocker. homeserver.yaml is larger than livekit.yaml but same pattern works.

## P0-3: FR Assessment — Revised

### FR-1: Secret Reading — ALREADY IMPLEMENTED

**Critical discovery:** dcontroller has `DecodeSecretData()` which auto-decodes base64 Secret `.data` values. Pipelines read plaintext directly via `$.Secret.data['key']`.

This was implemented after the thesis was written (the `@hash` commit `caff246` added credential rotation). The existing livekit-operator uses this extensively:
- `$.Secret.data['api-key']`, `$.Secret.data['api-secret']`
- `$.Secret.data['redis-password']`, `$.Secret.data['stunner-password']`

**Impact:** No late-binding sed workaround needed for matrix-rtc-operator. Config files can be generated directly with real credentials. @hash annotation triggers rolling restart on credential changes.

**FR-1 status: NOT A BLOCKER. Already works.**

### FR-2: Namespace-Scoped RBAC — Workaround Available

dcontroller itself needs a ClusterRole with explicit permissions per apiGroup/resource. Not truly "cluster-wide god-mode" — it must enumerate what it can access. But it doesn't auto-generate RBAC from the Operator CR's declared sources/targets.

**Workaround:** Manually craft ClusterRole rules in the Helm chart RBAC template. List exactly the apiGroups/resources/verbs needed. This is what all operators do (cert-manager, CNPG, etc.).

**FR-2 status: Workaround sufficient. Nice-to-have improvement, not a blocker.**

### FR-3: Pipeline Testing — No Workaround

No `dctl test` or dry-run capability. Testing requires a live cluster.

**Workaround:**
- `helm template` validates Helm rendering
- Manual `kubectl apply --dry-run=server` validates generated Operator CRs
- Integration tests on real cluster (mirror thesis evaluation methodology)
- Can test pipeline logic indirectly via `kubectl get <view>` after applying

**FR-3 status: Not a blocker for building the operator, but a blocker for sustainable development and CI. File issue.**

### FR-4: Webhook Validation — Workaround Available

No auto-generated admission webhooks.

**Workaround:** `values.schema.json` catches invalid Helm values at install time. For CRD validation, use OpenAPI v3 schema in the CRD definition itself (standard K8s validation).

**FR-4 status: Workaround sufficient for v1.**

### FR-5: Strategic Merge Patch — Workaround Available

Patcher works for targeted status updates. Updater for full resource creation.

**Workaround:** Use Updater (full replacement) for all forward-propagating pipelines. Use Patcher only for status writes (already proven pattern from thesis).

**FR-5 status: Not a blocker.**

## P0-4: dcontroller Issues to File

| FR | Priority | Status | Action |
|----|----------|--------|--------|
| FR-1 | ~~CRITICAL~~ | ALREADY WORKS | No issue needed — update plan to remove workaround |
| FR-2 | HIGH | Workaround | File: "Auto-generate RBAC from Operator CR sources/targets" |
| FR-3 | HIGH | No workaround | File: "Pipeline testing framework — dctl test" |
| FR-4 | MEDIUM | Workaround | File: "Auto-generate ValidatingWebhookConfiguration from CRD schema" |
| FR-5 | LOW | Workaround | Defer |
| FR-6 | HIGH | N/A | File: "Developer experience — tutorials, cookbook, dctl init" |
| FR-7 | MEDIUM | N/A | File: "dcontroller-common Helm library chart" |
| FR-8 | FUTURE | N/A | Defer |

## Available Pipeline Operators (Complete List)

| Category | Operators |
|----------|-----------|
| **Pipeline stages** | `@join`, `@select`, `@project`, `@unwind/@demux`, `@gather/@mux` |
| **List ops** | `@map`, `@filter`, `@len`, `@min`, `@max`, `@in`, `@range` |
| **Logical** | `@and`, `@or`, `@not`, `@cond`, `@switch`, `@noop` |
| **Comparison** | `@eq`, `@gt`, `@gte`, `@lt`, `@lte` |
| **String** | `@concat`, `@string` |
| **Type** | `@int`, `@float`, `@bool` |
| **Utility** | `@hash` (MD5 base36, 6 chars), `@exists`, `@isnil`, `@definedOr`, `@rnd`, `@now` (RFC3339) |

Useful for Matrix that weren't used in thesis:
- `@switch` — per-client config.json generation (Element vs Cinny)
- `@map` — transform arrays
- `@now` — timestamp injection
- `@rnd` — potential for generated secrets (though not cryptographically secure)

## Conclusion

**No critical blockers.** The two highest risks from the plan are both clear:
1. CNPG CRD creation: fully supported via generic targets
2. homeserver.yaml generation: @concat with \n proven by existing livekit-operator
3. Secret reading: already works (DecodeSecretData) — eliminates need for sed entrypoint workaround

**Key simplification:** FR-1 being solved means:
- No late-binding secret pattern needed
- No custom entrypoint scripts
- Direct config generation with real credentials
- @hash annotation for credential rotation works out of the box
- Dramatically simpler Synapse, LiveKit, and lk-jwt-service deployments

**Proceed to Phase 1** with high confidence.
