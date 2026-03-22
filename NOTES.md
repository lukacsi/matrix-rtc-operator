# Notes — matrix-rtc-operator

## 2026-03-21 — Patcher race condition workaround + e2e verified

**Context:** Status aggregation broken — multiple Patchers writing to the same object's status overwrite each other's fields.

**Analysis:** dcontroller's Patcher replaces the entire `status` object instead of deep-merging fields (filed as l7mp/dcontroller#9). In K8s, JSON merge patch preserves fields not mentioned in the patch — dcontroller doesn't. This makes decomposed status aggregation (the thesis pattern) unreliable whenever two controllers write to the same object.

**Decisions:**
- Workaround: single aggregate controller sourcing ALL raw resources (Deployment, StatefulSet, HTTPRoute, NetworkingView) and writing all status fields in one patch. Bypasses the race entirely.
- `@definedOr` only takes 2 args in dcontroller — nest them for 3+ fallbacks
- STUNner NodePort fixed at 30478 for predictable router port forwarding
- Garbage collection works correctly — delete CRs, all managed resources cleaned up, re-apply converges

**Done:**
- 4-source aggregate status controller working
- Clean e2e from scratch: apply CRs → Ready:true Running in ~30s
- LiveKit CLI verified: token generation, room join, room listing
- dcontroller#9 filed for Patcher merge behavior
- **Remaining:** commit all matrix-rtc-operator changes, external access (Cloudflare + router)

## 2026-03-21 — STUNner integration, health status, architectural decisions

**Context:** LiveKit pipelines working but status reporting was wrong — showed "Running" without STUNner deployed. Needed to fix health checks, deploy STUNner, and make several architectural decisions.

**Decisions:**
- **View CRDs are real** (not in-memory) — debuggable via kubectl, survive restarts, support status subresource and printer columns
- **Config generator doesn't block on TURN** — server starts immediately with `0.0.0.0` fallback, @hash triggers rolling restart when real TURN address arrives
- **Static TURN address** (`externalAddress`) needs separate status controller from Gateway LB discovery — same pattern at both infra and LiveKit levels
- **STUNner service type configurable** — `serviceType: NodePort|LoadBalancer` in RTCInfrastructure CRD, default LoadBalancer (cloud), NodePort for homelab
- **STUNner namespace** is `stunner` (separate from `stunner-system` where the operator lives) — config resources go here
- **Printer columns: industry standard** — Ready, Status, Age for user-facing CRDs. Details in `-o yaml`. Status is a condition string ("Running" / "Server not ready" / etc.), not data dump
- **Health check pattern**: managed STUNner checks Gateway+UDPRoute status; static `externalAddress` is trusted (ready=true when set). Separate controllers for each path.
- **STUNner chart skipCrds** — STUNner Helm chart ships Gateway API CRDs that conflict with existing Traefik CRDs. `skipCrds: true` in ArgoCD app.
- **TURN endpoint exposure** — grey cloud DNS record (`turn.lukacsi.org`) pointing to home IP, only UDP 3478 exposed. No SSH/TCP ports visible. TURN auth prevents relay abuse. Cloudflare tunnel handles all HTTPS.
- **dcontroller RBAC** — wildcard default, aggregated opt-in via `rbac.mode` Helm value. Tested both modes on minikube.

**Done:**
- STUNner gateway operator deployed via ArgoCD
- Operator creates GatewayConfig + GatewayClass + Gateway automatically from infra CR
- STUNner dataplane pod running, Gateway Accepted
- Static TURN address flowing to infra and LiveKit status
- All CRD printer columns cleaned up
- Full stack verified: `RTCInfrastructure ready:true`, `LiveKitStack Ready:true Running`

## 2026-03-21 — Phase 1: LiveKit pipelines working on homelab + dcontroller RBAC fixes

**Context:** Needed to adapt thesis LiveKit pipelines for gateway-agnostic operation and deploy on homelab workload cluster. Hit multiple dcontroller RBAC issues along the way.

**Analysis:** dcontroller published Helm chart (Jan 2026) has two RBAC bugs: (1) ClusterRole name mismatch from kustomize namePrefix (`dcontrollermanager-role` vs `dcontroller-role`), (2) missing `dcontroller.io/operators` permissions so controller can't watch its own CRDs. Root cause: kustomize pipeline generates explicit RBAC but doesn't include the operator's own API group. Old chart had wildcard `*/*` which masked both issues. Aggregated ClusterRole pattern (K8s native) is the enterprise solution — base chart provides core permissions, each operator chart adds its own via labeled ClusterRoles that K8s auto-merges.

**Decisions:**
- View CRDs are real (not in-memory) — debuggable via kubectl, survive restarts, support status subresource
- Config generator doesn't block on TURN address — server starts immediately with 0.0.0.0 fallback, updates via @hash rollout when TURN becomes available
- Static TURN address (`externalAddress`) supported for homelab/NAT — separate status controller from Gateway LB discovery
- Printer columns: industry standard (Ready, Status, Age) — details in `-o yaml`
- Status message: condition string ("Running" / "Server not ready" / "Redis not ready") not data dump
- dcontroller RBAC: wildcard default, aggregated opt-in via `rbac.mode` Helm value

**Done:**
- 4 LiveKit pipeline files adapted (livekit-to-views, views-to-k8s, status-writers, infra)
- 4 CRDs created (RTCInfrastructure, LiveKitStack, LiveKitServerView, LiveKitNetworkingView)
- Example CRs (infrastructure, secrets, livekit-stack-full)
- Deployed and verified on homelab workload cluster — `kubectl get livekitstack` shows `Ready: true, Status: Running`
- dcontroller RBAC fix: issue #7 + PR #8 on l7mp/dcontroller
- dcontroller fork with configurable RBAC (`chart/helm/templates/rbac.yaml`)
- CAPI workload cluster rebuilt, kubeconfig registered
- Runbook system + first runbook (kubeconfig CA mismatch)
- **Remaining:** commit matrix-rtc-operator changes, dcontroller aggregated RBAC PR, Matrix pipelines (Phase 2)

## 2026-03-18 — Phase 0: dcontroller assessment + repo scaffold + ticket system

**Context:** New project — declarative K8s operator for Matrix+LiveKit+STUNner built on dcontroller. Needed to assess whether dcontroller can handle the requirements before committing to implementation.

**Analysis:** Explored dcontroller source code and existing livekit-operator pipelines. Critical finding: FR-1 (Secret reading) which was documented as a CRITICAL blocker in the thesis is already solved — `DecodeSecretData()` auto-decodes base64, pipelines read plaintext via `$.Secret.data['key']`. The existing livekit-operator uses this extensively for api-key, api-secret, redis-password, stunner credentials. This eliminates the entire late-binding sed workaround pattern. @concat with `\n` generates valid multiline YAML configs (proven by livekit.yaml generation). Generic targets support any apiGroup/kind including CNPG Clusters.

**Decisions:**
- No critical dcontroller blockers — proceed to Phase 1 with high confidence
- FR-3 (pipeline testing) is only real gap — not a blocker, file as upstream issue
- Jira-style ticket system in docs/tickets/ with INDEX.md board view (41 tickets total)
- Ticket manager skill added to hub FUTURE.md for future automation

**Done:**
- Repo created at Projects/matrix-rtc-operator/ with 3 commits
- dcontroller assessment: docs/dcontroller-assessment.md
- 41 tickets across 7 phases + upstream + future in docs/tickets/
- CLAUDE.md with architecture, conventions, build commands
