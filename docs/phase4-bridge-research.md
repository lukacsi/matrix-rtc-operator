# Phase 4 Research: lk-jwt-service + .well-known Pipeline Design

## 1. What is lk-jwt-service?

**Purpose:** Bridges Matrix auth to LiveKit JWT tokens. Matrix users get an OpenID token from their homeserver, send it to lk-jwt-service, which validates it and returns a LiveKit JWT for SFU access.

**Image:** `ghcr.io/element-hq/lk-jwt-service` (Go binary, latest tag is `0.3.0`)

**Environment variables:**
| Env Var | Description | Source in operator |
|---------|-------------|-------------------|
| `LIVEKIT_URL` | LiveKit WebSocket URL (e.g. `wss://livekit.lukacsi.org`) | `"wss://" + LiveKitNetworkingView.spec.host` |
| `LIVEKIT_KEY` | LiveKit API key | `secretKeyRef: {name: LiveKitServerView.spec.livekit.keys.existingSecret, key: LiveKitServerView.spec.livekit.keys.apiKeyKey}` |
| `LIVEKIT_SECRET` | LiveKit API secret | `secretKeyRef: {name: LiveKitServerView.spec.livekit.keys.existingSecret, key: LiveKitServerView.spec.livekit.keys.apiSecretKey}` |
| `LIVEKIT_FULL_ACCESS_HOMESERVERS` | Comma-separated homeserver domains that can auto-create rooms | `MatrixServerView.spec.synapse.serverName` |
| `LK_JWT_PORT` | Listen port (default 8080) | Hardcoded `"8080"` |

**Does NOT need** a direct Synapse URL — it validates OpenID tokens by calling the user's homeserver (discovered from the Matrix user ID), not a preconfigured one.

## 2. Current Manual Deployment (cluster state)

### lk-jwt-service
- **Deployment:** 1 replica, image `ghcr.io/element-hq/lk-jwt-service:latest`, port 8080
- **Env vars:** `LIVEKIT_URL=wss://livekit.lukacsi.org`, `LIVEKIT_KEY/SECRET` from secret `livekit-auth` (keys: `api-key`, `api-secret`), `LK_JWT_PORT=8080`
- **Missing from manual:** `LIVEKIT_FULL_ACCESS_HOMESERVERS` (should be `lukacsi.org`)
- **Service:** ClusterIP on 8080
- **HTTPRoute:** `lk-jwt.lukacsi.org` → lk-jwt-service:8080 via traefik-gateway

### well-known (matrix-wellknown)
- **ConfigMap** with 3 keys:
  - `client`: `{"m.homeserver":{"base_url":"https://matrix.lukacsi.org"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://lk-jwt.lukacsi.org"}]}`
  - `server`: `{"m.server":"matrix.lukacsi.org:443"}`
  - `nginx.conf`: serves the above at `/.well-known/matrix/client` and `/.well-known/matrix/server`
- **Deployment:** nginx:1.27-alpine serving the ConfigMap
- **HTTPRoute:** `lukacsi.org` path `/.well-known/matrix` → matrix-wellknown:80 via traefik-gateway

## 3. Data Sources for Pipeline

### lk-jwt-service needs:
| Data | View Source | Field Path |
|------|-------------|------------|
| LiveKit WS URL | LiveKitNetworkingView | `"wss://" + spec.host` |
| API key secret name | LiveKitServerView | `spec.livekit.keys.existingSecret` |
| API key key | LiveKitServerView | `spec.livekit.keys.apiKeyKey` |
| API secret key | LiveKitServerView | `spec.livekit.keys.apiSecretKey` |
| Full-access homeservers | MatrixServerView | `spec.synapse.serverName` |
| HTTP gateway | MatrixNetworkingView | `spec.httpGatewayRef` |
| JWT service host | Derived | `"lk-jwt." + RTCInfrastructure.spec.domain` or configurable |

### well-known needs:
| Data | View Source | Field Path |
|------|-------------|------------|
| Homeserver base URL | MatrixNetworkingView | `"https://" + spec.host` |
| Server name + port | MatrixServerView | `spec.synapse.serverName + ":443"` |
| lk-jwt-service URL | Derived | `"https://lk-jwt." + domain` (from lk-jwt HTTPRoute host) |
| Server name (domain) | MatrixServerView | `spec.synapse.serverName` |
| HTTP gateway | MatrixNetworkingView | `spec.httpGatewayRef` |

## 4. Pipeline Design

### File: `matrix-bridge.yaml` (as documented in CLAUDE.md project structure)

This is a **cross-CRD join** operator — the only pipeline that touches both LiveKit and Matrix views.

### Controller 1: `jwt-service-deployment`

**Sources:** LiveKitServerView + LiveKitNetworkingView + MatrixServerView

**Join condition:**
```yaml
"@join":
  "@and":
    - "@eq": ["$.LiveKitNetworkingView.metadata.name", "$.LiveKitServerView.spec.stack"]
    - "@eq": ["$.LiveKitNetworkingView.metadata.namespace", "$.LiveKitServerView.metadata.namespace"]
    - "@eq": ["$.MatrixServerView.metadata.name", "$.LiveKitServerView.spec.stack"]
    - "@eq": ["$.MatrixServerView.metadata.namespace", "$.LiveKitServerView.metadata.namespace"]
```

All three views share the same `metadata.name` (the stack name, e.g. `my-matrix`) and namespace — this is the join key.

**Output:** Deployment with:
- Image: `ghcr.io/element-hq/lk-jwt-service:0.3.0` (pinned, no `:latest`)
- Env vars using `secretKeyRef` for LIVEKIT_KEY/SECRET (late-binding, NOT `@concat` with secret data)
- LIVEKIT_URL as plain value from `"wss://" + LiveKitNetworkingView.spec.host`
- LIVEKIT_FULL_ACCESS_HOMESERVERS from MatrixServerView.spec.synapse.serverName
- `@hash` annotation on LiveKitServerView spec for rolling restart on credential rotation

**IMPORTANT:** Unlike livekit-config-generator which uses `@concat` with `$.Secret.data['api-key']` (because LiveKit config is a YAML file), lk-jwt-service uses `secretKeyRef` in the Deployment pod spec. This is the Kubernetes-native way — no need to join on the Secret resource itself.

### Controller 2: `jwt-service-service`

**Sources:** LiveKitNetworkingView (single source, like existing `networking-view-to-svc`)

**Output:** Service ClusterIP on port 8080, selector `app: lk-jwt-service`

### Controller 3: `jwt-service-httproute`

**Sources:** LiveKitNetworkingView + MatrixNetworkingView (need gateway ref from either)

**Output:** HTTPRoute for `lk-jwt.{domain}` → lk-jwt-service:8080

**Host derivation:** Need a dedicated host. Options:
- (a) `"lk-jwt." + RTCInfrastructure.spec.domain` — requires joining on RTCInfrastructure
- (b) Add `jwtServiceHost` to a view — cleanest
- **Recommendation:** Add to MatrixNetworkingView during `matrix-to-networking-view` pipeline, derived as `"lk-jwt." + domain`. This keeps the cross-CRD join clean.

### Controller 4: `wellknown-configmap`

**Sources:** MatrixServerView + MatrixNetworkingView

**Join:** Same stack name + namespace (no LiveKit views needed here — lk-jwt host comes from MatrixNetworkingView)

**Output:** ConfigMap with:
- `client` key: JSON with `m.homeserver.base_url` + `org.matrix.msc4143.rtc_foci` (livekit_service_url)
- `server` key: JSON with `m.server`
- `nginx.conf` key: static nginx config

### Controller 5: `wellknown-deployment`

**Sources:** MatrixNetworkingView (single source)

**Output:** nginx:1.27-alpine Deployment mounting the ConfigMap

### Controller 6: `wellknown-service`

**Sources:** MatrixNetworkingView (single source)

**Output:** Service ClusterIP on port 80

### Controller 7: `wellknown-httproute`

**Sources:** MatrixNetworkingView + MatrixServerView (need serverName for the host)

**Output:** HTTPRoute for `{serverName}` (e.g. `lukacsi.org`) path `/.well-known/matrix` → matrix-wellknown:80

**Note:** The well-known hostname is the Matrix **server name** (e.g. `lukacsi.org`), NOT the Synapse host (e.g. `matrix.lukacsi.org`). This is because clients discover the homeserver via `{serverName}/.well-known/matrix/client`.

## 5. View Modifications Needed

### MatrixNetworkingView — add `jwtService` field

In `matrix-to-networking-view`, add:
```yaml
spec:
  jwtService:
    host:
      "@definedOr":
        - "$.MatrixStack.spec.bridge.jwtService.host"
        - "@concat":
            - "lk-jwt."
            - "$.RTCInfrastructure.spec.domain"
    image:
      "@definedOr": ["$.MatrixStack.spec.bridge.jwtService.image", "ghcr.io/element-hq/lk-jwt-service:0.3.0"]
    replicas:
      "@definedOr": ["$.MatrixStack.spec.bridge.jwtService.replicas", 1]
```

### MatrixStack CRD — add `spec.bridge` section

```yaml
spec:
  bridge:
    jwtService:
      host: lk-jwt.lukacsi.org     # optional, default: lk-jwt.{domain}
      image: ghcr.io/element-hq/lk-jwt-service:0.3.0  # optional
      replicas: 1                    # optional
```

### LiveKitNetworkingView — no changes needed

Already has `spec.host` which gives us the LiveKit WebSocket URL.

## 6. Decision: well-known approach

FUTURE.md P4-2 says "Patch Synapse ConfigMap to include serve_server_wellknown + rtc_foci". This would mean Synapse serves `.well-known` directly. However:

**Current deployment uses standalone nginx** — this is simpler and more reliable:
- Synapse's `serve_server_wellknown` only serves the server well-known, not custom extensions like `rtc_foci`
- Standalone nginx is a 2MB container, no Synapse restart needed when well-known changes
- Well-known host (`lukacsi.org`) differs from Synapse host (`matrix.lukacsi.org`) — separate HTTPRoute needed anyway

**Recommendation:** Keep standalone nginx approach (matches current working deployment). Update P4-2 description.

## 7. Summary: Resources Created by matrix-bridge.yaml

| Controller | Sources | Output Resource |
|-----------|---------|----------------|
| jwt-service-deployment | LiveKitServerView + LiveKitNetworkingView + MatrixServerView | Deployment (lk-jwt-service) |
| jwt-service-service | MatrixNetworkingView | Service (lk-jwt-service:8080) |
| jwt-service-httproute | MatrixNetworkingView | HTTPRoute (lk-jwt.{domain}) |
| wellknown-configmap | MatrixServerView + MatrixNetworkingView | ConfigMap (matrix-wellknown) |
| wellknown-deployment | MatrixNetworkingView | Deployment (matrix-wellknown) |
| wellknown-service | MatrixNetworkingView | Service (matrix-wellknown:80) |
| wellknown-httproute | MatrixServerView + MatrixNetworkingView | HTTPRoute ({serverName}/.well-known/matrix) |

Total: 7 controllers in 1 Operator CR in `matrix-bridge.yaml`.
