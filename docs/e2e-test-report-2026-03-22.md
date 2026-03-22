# E2E Test Report — matrix-rtc-operator

**Date:** 2026-03-22
**Cluster:** homelab-admin@homelab
**Namespace:** matrix
**Stack:** my-matrix

---

## Layer 0: Top-level Decomposition

| # | Test | Result | Details |
|---|------|--------|---------|
| 1 | MatrixRTCStack status | PASS | `ready: true`, message: "Running", components.livekit and components.matrix both ready |
| 2 | Children exist | PASS | LiveKitStack `my-matrix` (true/Running), MatrixStack `my-matrix` (true/Running/lukacsi.org) |

## Layer 1: Views

| # | Test | Result | Details |
|---|------|--------|---------|
| 3 | All 4 view types exist | PASS | MatrixServerView, MatrixNetworkingView, LiveKitServerView, LiveKitNetworkingView all present |
| 4 | MatrixServerView fields | PASS | synapse image v1.121.1, serverName lukacsi.org, database effective fields: host=my-matrix-db-rw, name=synapse, secretName=my-matrix-db-app, port=5432, mode=managed |
| 5 | MatrixNetworkingView fields | PASS | host=matrix.lukacsi.org, httpGatewayRef=traefik/traefik-gateway, element enabled (v1.11.86, element.lukacsi.org), cinny disabled, bridge.jwtServiceHost=lk-jwt.lukacsi.org, bridge.wellknownHost=lukacsi.org |
| 6 | LiveKitServerView fields | PASS | image=livekit/livekit-server:v1.8.0, keys from livekit-auth secret, redis managed mode with redis:7-alpine, stunnerKeys configured |
| 7 | LiveKitNetworkingView fields | PASS | host=livekit.lukacsi.org, udpGatewayRef=stunner/udp-gateway, turnExternalAddress=turn.lukacsi.org, turnPort=3478, httpGatewayRef=traefik/traefik-gateway, redis.url populated |

## Layer 2: K8s Resources

| # | Test | Result | Details |
|---|------|--------|---------|
| 8 | All resources present | PASS | 7 pods (all Running), 9 services, 5 deployments, 1 StatefulSet (redis) |
| 9 | Labels correct | PASS | All resources have `app.kubernetes.io/managed-by: matrix-rtc-operator`, `matrixrtc.lukacsi.org/stack: my-matrix`, `matrixrtc.lukacsi.org/component` set per resource |
| 10 | Synapse Deployment | PASS | Liveness probe (/health:8008, 30s init, 30s period), readiness probe (/health:8008, 5s init, 10s period), 3 volume mounts (config, signing-key, data PVC), resources set (250m-1 CPU, 512Mi-1Gi) |
| 10a | Synapse PVC | PASS | `synapse-data` PVC bound, 10Gi, local-path |
| 10b | Synapse Service | PASS | ClusterIP 10.43.121.46:8008 |
| 10c | Synapse HTTPRoute | PASS | hostname matrix.lukacsi.org |
| 11 | LiveKit Deployment | PASS | Config from livekit-config secret, command `/livekit-server --config /etc/livekit/livekit.yaml`, port 7880 |
| 11a | LiveKit Service | PASS | livekit-sig ClusterIP 10.43.6.3:7880 |
| 11b | LiveKit HTTPRoute | PASS | hostname livekit.lukacsi.org |
| 11c | LiveKit UDPRoute | PASS | `livekit-media` (stunner.l7mp.io/v1 UDPRoute), parentRef=stunner/udp-gateway, backendRef=livekit-sig service, status: Accepted + ResolvedRefs |
| 11d | Redis StatefulSet | PASS | 1/1 ready, labels correct (component=redis) |
| 11e | LiveKit probes | WARN | No liveness/readiness probes configured on livekit-server deployment |
| 12 | Element Web ConfigMap | PASS | `element-config` CM with config.json: base_url=https://matrix.lukacsi.org, server_name=lukacsi.org, brand=Element, disable_guests=true |
| 12a | Element Web Deployment | PASS | image vectorim/element-web:v1.11.86, config.json mounted at /app/config.json from element-config CM |
| 12b | Element Web Service | PASS | ClusterIP 10.43.54.87:80 |
| 12c | Element Web HTTPRoute | PASS | hostname element.lukacsi.org |
| 13 | CNPG Cluster | PASS | Phase: "Cluster in healthy state", 1/1 instances ready, instance my-matrix-db-1 healthy |
| 13a | CNPG app secret | PASS | `my-matrix-db-app` secret exists with keys: dbname, host, password, port, uri, user, username, etc. |
| 13b | CNPG services | PASS | my-matrix-db-rw, my-matrix-db-ro, my-matrix-db-r services all present |
| 13c | CNPG PVC | PASS | `my-matrix-db-1` PVC bound, 5Gi |
| 14 | lk-jwt-service Deployment | PASS | image ghcr.io/element-hq/lk-jwt-service:0.3.0, env: LIVEKIT_URL=wss://livekit.lukacsi.org, LIVEKIT_KEY/SECRET from livekit-auth secret, LIVEKIT_FULL_ACCESS_HOMESERVERS=lukacsi.org, LK_JWT_PORT=8080 |
| 14a | lk-jwt-service Service | PASS | ClusterIP 10.43.147.254:8080 |
| 14b | lk-jwt-service HTTPRoute | PASS | hostname lk-jwt.lukacsi.org |
| 15 | well-known ConfigMap | PASS | `matrix-wellknown` CM with client JSON (m.homeserver + rtc_foci), server JSON (m.server: matrix.lukacsi.org:443), nginx.conf |
| 15a | well-known Deployment | PASS | nginx:1.27-alpine, 3 volume mounts from matrix-wellknown CM (nginx.conf, client data, server data) |
| 15b | well-known Service | PASS | ClusterIP 10.43.24.236:80 |
| 15c | well-known HTTPRoute | PASS | hostname lukacsi.org |

## Layer 3: External Access

| # | Test | Result | Details |
|---|------|--------|---------|
| 16 | matrix.lukacsi.org/_matrix/client/versions | PASS | Returns versions r0.0.1 through v1.11, unstable_features present |
| 17 | matrix.lukacsi.org/_matrix/federation/v1/version | PASS | `{"server":{"name":"Synapse","version":"1.121.1"}}` |
| 18 | livekit.lukacsi.org | PASS | Returns "OK" |
| 19 | element.lukacsi.org | PASS | Returns full Element Web HTML page with proper meta tags |
| 20 | lk-jwt.lukacsi.org/healthz | PASS | HTTP 200 (empty body, which is expected) |
| 21 | lukacsi.org/.well-known/matrix/client | PASS | `{"m.homeserver":{"base_url":"https://matrix.lukacsi.org"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://lk-jwt.lukacsi.org"}]}` |
| 22 | lukacsi.org/.well-known/matrix/server | PASS | `{"m.server":"matrix.lukacsi.org:443"}` |

## Layer 4: Status Aggregation

| # | Test | Result | Details |
|---|------|--------|---------|
| 23 | MatrixStack status | PASS | ready=true, message="Running", components.synapse: 1/1 replicas ready, host=matrix.lukacsi.org |
| 24 | LiveKitStack status | PASS | ready=true, message="Running", components: server 1/1, redis ready, networking.turnAddress=turn.lukacsi.org |
| 25 | MatrixRTCStack status | PASS | ready=true, message="Running", components.livekit (ready/Running), components.matrix (ready/Running) |

---

## Summary

| Metric | Count |
|--------|-------|
| **PASS** | **33** |
| **WARN** | **1** |
| **FAIL** | **0** |

### Issues Found

1. **WARN: LiveKit server deployment has no liveness/readiness probes.** The Synapse deployment has both configured, but livekit-server has neither. This means K8s cannot detect if the LiveKit process hangs or becomes unhealthy. Recommend adding HTTP probes on port 7880 (the root path returns "OK").

### Overall Assessment

**The matrix-rtc-operator is fully operational.** All four CRD layers (MatrixRTCStack -> MatrixStack/LiveKitStack -> Views -> K8s resources) decompose correctly. All 7 pods are running, all services are reachable externally via Gateway API HTTPRoutes, the STUNner UDPRoute for TURN/media is accepted and resolved, CNPG database is healthy, and the well-known endpoints correctly advertise both the homeserver and LiveKit RTC foci. Status aggregation rolls up correctly from individual components through to the top-level MatrixRTCStack.
