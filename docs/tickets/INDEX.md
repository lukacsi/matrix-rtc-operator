# Ticket Index — matrix-rtc-operator

## Status Legend
- `BACKLOG` — Not started
- `READY` — Requirements clear, ready to pick up
- `IN_PROGRESS` — Actively being worked on
- `BLOCKED` — Waiting on dependency
- `DONE` — Completed
- `DROPPED` — Won't do (with reason)

## Priority Legend
- `P0` — Critical blocker
- `P1` — High — needed for current phase
- `P2` — Medium — needed for completeness
- `P3` — Low — nice to have
- `P4` — Future — not needed for v1

---

## Phase 0: dcontroller Assessment

| ID | Title | Status | Priority | Assignee |
|----|-------|--------|----------|----------|
| MRO-001 | [Test CNPG Cluster CRD creation](MRO-001.md) | DONE | P0 | — |
| MRO-002 | [Test @concat for homeserver.yaml](MRO-002.md) | DONE | P0 | — |
| MRO-003 | [Document dcontroller FR workarounds](MRO-003.md) | DONE | P1 | — |
| MRO-004 | [File dcontroller improvement issues](MRO-004.md) | READY | P2 | — |

## Phase 1: Repo + Chart Skeleton + LiveKit Adaptation

| ID | Title | Status | Priority | Assignee |
|----|-------|--------|----------|----------|
| MRO-010 | [Enterprise values.yaml with @param comments](MRO-010.md) | BACKLOG | P1 | — |
| MRO-011 | [values.schema.json validation](MRO-011.md) | BACKLOG | P2 | — |
| MRO-012 | [CRD templates (MatrixRTCStack, LiveKitStack, MatrixStack, RTCInfra)](MRO-012.md) | DONE | P0 | — |
| MRO-013 | [RBAC templates — least privilege](MRO-013.md) | BACKLOG | P1 | — |
| MRO-014 | [Adapt LiveKit pipelines — gateway-agnostic](MRO-014.md) | DONE | P1 | — |
| MRO-015 | [Top-level decomposition pipeline (stack-decompose)](MRO-015.md) | DONE | P0 | — |
| MRO-016 | [NOTES.txt + .helmignore + CI values](MRO-016.md) | BACKLOG | P3 | — |
| MRO-017 | [GitHub Actions CI](MRO-017.md) | BACKLOG | P2 | — |

## Phase 2: Matrix Core — Synapse + CNPG

| ID | Title | Status | Priority | Assignee |
|----|-------|--------|----------|----------|
| MRO-020 | [matrix-to-views.yaml — server + networking views](MRO-020.md) | DONE | P0 | — |
| MRO-021 | [Synapse deployment pipeline](MRO-021.md) | DONE | P0 | — |
| MRO-022 | [homeserver.yaml generation via @concat](MRO-022.md) | DONE | P0 | — |
| MRO-023 | [CNPG Cluster pipeline (conditional)](MRO-023.md) | DONE | P1 | — |
| MRO-024 | [Synapse service + HTTPRoute](MRO-024.md) | DONE | P1 | — |
| MRO-025 | [Example CR — minimal MatrixStack](MRO-025.md) | DONE | P2 | — |

## Phase 3: Clients — Element Web + Cinny

| ID | Title | Status | Priority | Assignee |
|----|-------|--------|----------|----------|
| MRO-030 | [matrix-to-client-views controller (@unwind)](MRO-030.md) | DROPPED | P1 | — |
| MRO-031 | [Client deployment + config pipelines](MRO-031.md) | DONE | P1 | — |
| MRO-032 | [Security contexts for client pods](MRO-032.md) | BACKLOG | P2 | — |

## Phase 4: LiveKit Bridge — lk-jwt-service + .well-known

| ID | Title | Status | Priority | Assignee |
|----|-------|--------|----------|----------|
| MRO-040 | [lk-jwt-service deployment pipeline](MRO-040.md) | DONE | P1 | — |
| MRO-041 | [.well-known via nginx + cross-CRD bridge pipeline](MRO-041.md) | DONE | P0 | — |
| MRO-042 | [End-to-end call verification](MRO-042.md) | BACKLOG | P1 | — |

## Phase 5: Status Aggregation + Enterprise Polish

| ID | Title | Status | Priority | Assignee |
|----|-------|--------|----------|----------|
| MRO-050 | [Matrix status writers (fan-in)](MRO-050.md) | BACKLOG | P1 | — |
| MRO-051 | [Probes for all components](MRO-051.md) | BACKLOG | P1 | — |
| MRO-052 | [NetworkPolicy templates](MRO-052.md) | BACKLOG | P2 | — |
| MRO-053 | [ServiceMonitor templates](MRO-053.md) | BACKLOG | P2 | — |
| MRO-054 | [PodDisruptionBudget templates](MRO-054.md) | BACKLOG | P2 | — |

## Phase 6: Testing + Docs + Homelab Deploy

| ID | Title | Status | Priority | Assignee |
|----|-------|--------|----------|----------|
| MRO-060 | [Evaluation test cases (8 cases)](MRO-060.md) | BACKLOG | P1 | — |
| MRO-061 | [Documentation (architecture, quickstart, CRD ref)](MRO-061.md) | BACKLOG | P1 | — |
| MRO-062 | [README with parameter tables](MRO-062.md) | BACKLOG | P2 | — |
| MRO-063 | [Example CRs (minimal, full, external-db, livekit-only)](MRO-063.md) | BACKLOG | P2 | — |
| MRO-064 | [Homelab deployment via ArgoCD](MRO-064.md) | BACKLOG | P1 | — |

## dcontroller Upstream

| ID | Title | Status | Priority | Blocked by |
|----|-------|--------|----------|------------|
| MRO-100 | [FR-2: Auto-generate RBAC from Operator CR](MRO-100.md) | BACKLOG | P2 | — |
| MRO-101 | [FR-3: Pipeline testing framework — dctl test](MRO-101.md) | BACKLOG | P1 | — |
| MRO-102 | [FR-4: Auto-generate ValidatingWebhookConfiguration](MRO-102.md) | BACKLOG | P2 | — |
| MRO-103 | [FR-6: Developer experience — tutorials, cookbook, dctl init](MRO-103.md) | BACKLOG | P1 | — |
| MRO-104 | [FR-7: dcontroller-common Helm library chart](MRO-104.md) | BACKLOG | P2 | — |

## Future (Post-v1)

| ID | Title | Status | Priority |
|----|-------|--------|----------|
| MRO-200 | [Tiered media storage (SSD→HDD archival)](MRO-200.md) | BACKLOG | P4 |
| MRO-201 | [CNPG backup integration (ScheduledBackup)](MRO-201.md) | BACKLOG | P4 |
| MRO-202 | [Matrix federation support](MRO-202.md) | BACKLOG | P4 |
| MRO-203 | [Standalone LiveKit chart extraction](MRO-203.md) | BACKLOG | P4 |
| MRO-204 | [Matrix bridges (Discord, Telegram, Signal)](MRO-204.md) | BACKLOG | P4 |
