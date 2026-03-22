# Element Web Pipeline Research

## 1. Element Web config.json Structure

### Required fields for operator-managed config:

```json
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://matrix.lukacsi.org",
      "server_name": "lukacsi.org"
    }
  },
  "brand": "Element",
  "disable_custom_urls": true,
  "disable_guests": true,
  "features": {
    "feature_group_calls": true,
    "feature_video_rooms": true,
    "feature_element_call_video_rooms": true
  },
  "element_call": {
    "url": "https://call.element.io"
  }
}
```

### Key fields by category:

| Field | Source | Notes |
|-------|--------|-------|
| `default_server_config.m.homeserver.base_url` | `https://{MatrixNetworkingView.spec.host}` | Full URL to Synapse |
| `default_server_config.m.homeserver.server_name` | `MatrixServerView.spec.synapse.serverName` | Federation identity |
| `brand` | Hardcoded `"Element"` or from MatrixStack spec | |
| `disable_custom_urls` | Hardcoded `true` | Prevents users changing homeserver |
| `disable_guests` | Hardcoded `true` | Security default |
| `features.feature_group_calls` | `true` when LiveKit integration exists | Enables call UI |
| `features.feature_video_rooms` | `true` when LiveKit integration exists | Enables video room UI |
| `features.feature_element_call_video_rooms` | `true` when LiveKit integration exists | Element Call for video rooms |
| `element_call.url` | Optional — Element Call standalone URL | Only if self-hosted Element Call |

### MatrixRTC/Call behavior:

- **Element Call integration does NOT need `element_call.url` in config for embedded calls.**
  The `element_call.url` is only for standalone Element Call (the separate app). For native
  MatrixRTC calls (MSC4143), Element Web discovers LiveKit via `.well-known/matrix/client`
  which returns `org.matrix.msc4143.rtc_foci`. This is served by Synapse (Phase 4 pipeline).
- The `features.feature_group_calls` flag enables the call button in rooms.
- Per-domain config (`config.element.lukacsi.org.json`) is NOT needed — single config.json suffices
  for single-deployment scenarios.

## 2. Element Web Docker Image

- **Image**: `vectorim/element-web:v1.11.86`
- **Config mount path**: `/app/config.json` (subPath mount from ConfigMap)
- **Web server**: nginx (serves static SPA)
- **Port**: 80
- **Caching**: nginx configured with `Cache-Control: no-cache` for `/` and no-cache for `/config.*.json`
- **No other config files needed** for basic deployment

### Currently deployed on cluster:

```yaml
# ConfigMap: element-config (namespace: matrix)
data:
  config.json: |
    {
      "default_server_config": {
        "m.homeserver": {
          "base_url": "https://matrix.lukacsi.org",
          "server_name": "lukacsi.org"
        }
      },
      "brand": "Element",
      "disable_custom_urls": true,
      "disable_guests": true
    }

# Deployment: element-web (namespace: matrix)
# - image: vectorim/element-web:v1.11.86
# - volumeMount: /app/config.json from ConfigMap (subPath: config.json)
# - port: 80
# - labels: app=element-web, app.kubernetes.io/managed-by=matrix-rtc-operator
# - Status: 1/1 ready
```

## 3. Data Sources for Element Config

### From MatrixNetworkingView (already exists):
- `spec.host` → homeserver base_url (`https://{host}`)
- `spec.clients.element.enabled` → whether to create resources at all
- `spec.clients.element.host` → Element subdomain for HTTPRoute
- `spec.httpGatewayRef` → Gateway parentRef for HTTPRoute

### From MatrixServerView (already exists):
- `spec.synapse.serverName` → `m.homeserver.server_name`

### From MatrixStack.spec.clients.element (via views):
- `enabled` (default: true)
- `host` (default: `element.{domain}`)
- `image` (default: `vectorim/element-web:v1.11.86`)
- `resources` (default: none)

### NOT needed from LiveKit (yet):
- LiveKit integration is via `.well-known/matrix/client` (Phase 4), not Element config
- `element_call.url` only needed if self-hosting standalone Element Call app

## 4. Pipeline Design Recommendation

### Approach: Add to existing `matrix-views-to-k8s.yaml`

The Element Web pipeline is simple enough (ConfigMap + Deployment + Service + HTTPRoute) to live
alongside Synapse in the existing materializer. No new CRD needed — MatrixNetworkingView already
carries `clients.element.{enabled, host}` and MatrixServerView carries `synapse.serverName`.

### Why NOT a separate operator file:
- Only 4 controllers (config, deployment, service, httproute) — same as Synapse
- Sources are the same Views already used by Synapse pipelines
- Keeps materializer cohesive: "matrix-views-to-k8s produces all K8s resources from Matrix views"

### Why NOT a MatrixClientView intermediate CRD (yet):
- The FUTURE.md P3-1 suggests `MatrixClientView` with `@unwind` for generic client handling
- But dcontroller's `@unwind` is untested and `@switch` for config shapes adds complexity
- **Recommendation**: Start with direct Element-specific pipelines now, refactor to
  MatrixClientView when Cinny is added (if the pattern proves valuable)

### Pipeline controllers to add to `matrix-views-to-k8s.yaml`:

#### 4a. `element-config` — ConfigMap generation
```
Sources: MatrixServerView + MatrixNetworkingView
Join: same name + same namespace
@select: MatrixNetworkingView.spec.clients.element.enabled == true
Output: ConfigMap "element-config" with config.json
```

The config.json is built via `@concat` (same pattern as homeserver.yaml):
```json
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://{NetworkingView.spec.host}",
      "server_name": "{ServerView.spec.synapse.serverName}"
    }
  },
  "brand": "Element",
  "disable_custom_urls": true,
  "disable_guests": true
}
```

#### 4b. `element-deployment` — Deployment
```
Sources: MatrixNetworkingView + ConfigMap (element-config)
Join: element-config in same namespace
@select: MatrixNetworkingView.spec.clients.element.enabled == true
Output: Deployment "element-web"
  - image from view (defaulted in matrix-to-views)
  - volumeMount /app/config.json from ConfigMap (subPath)
  - @hash on ConfigMap data for rollout trigger
  - Security: runAsNonRoot, readOnlyRootFilesystem, drop ALL
  - emptyDir for /tmp and /var/cache/nginx (nginx needs writable dirs)
```

#### 4c. `element-service` — Service
```
Sources: MatrixNetworkingView
@select: clients.element.enabled == true
Output: Service "element-web" → port 80
```

#### 4d. `element-httproute` — HTTPRoute
```
Sources: MatrixNetworkingView
@select: clients.element.enabled == true
Output: HTTPRoute for clients.element.host → element-web:80
```

### Data flow:

```
MatrixStack.spec.clients.element
    │
    ├─(matrix-to-views)──► MatrixNetworkingView.spec.clients.element.{enabled, host}
    │                       MatrixServerView.spec.synapse.serverName
    │
    └─(matrix-views-to-k8s)──► ConfigMap (config.json)
                                Deployment (element-web)
                                Service (element-web)
                                HTTPRoute (element.{domain})
```

### Status pipeline addition to `matrix-status-writers.yaml`:

```
element-web Deployment status → MatrixNetworkingView.status.clients.element.{ready, replicas}
```

### MatrixNetworkingView CRD update needed:

Add status fields for client readiness:
```yaml
status:
  clients:
    element:
      ready: true
      replicas: 1
      readyReplicas: 1
```

### Values to propagate through views:

The `matrix-to-views.yaml` already passes `clients` through to both ServerView and NetworkingView.
For Element deployment, we need the NetworkingView to also carry:
- `clients.element.image` (default: `vectorim/element-web:v1.11.86`)
- `clients.element.resources` (optional resource limits)

These should be added to the NetworkingView projection in `matrix-to-views.yaml`.

## 5. Implementation Checklist

1. **Update `matrix-to-views.yaml`**: Add `clients.element.image` and `clients.element.resources`
   to NetworkingView projection (with `@definedOr` defaults)
2. **Update MatrixNetworkingView CRD**: Add `clients.element.image`, `clients.element.resources`
   to spec schema; add `status.clients.element` fields
3. **Add 4 controllers to `matrix-views-to-k8s.yaml`**: element-config, element-deployment,
   element-service, element-httproute
4. **Add status writer to `matrix-status-writers.yaml`**: element-web Deployment → NetworkingView
5. **Update example CRs**: Add `clients.element` section to MatrixStack examples
6. **Test**: `helm template` + deploy to homelab
