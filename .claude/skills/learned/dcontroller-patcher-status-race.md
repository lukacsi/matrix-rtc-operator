---
name: dcontroller-patcher-status-race
description: "dcontroller Patcher replaces entire status — use single multi-source aggregate controller"
user-invocable: false
origin: auto-extracted
---

# dcontroller Patcher Status Race Condition

**Extracted:** 2026-03-21
**Context:** Multiple dcontroller controllers writing to the same object's status via Patcher

## Problem
dcontroller's Patcher replaces the entire `status` object instead of deep-merging fields (issue #9). When two controllers patch the same object's status, the second overwrites fields written by the first.

Example: Controller A writes `status.replicas`, Controller B writes `status.redis.ready`. After both run, only one set of fields survives.

## Solution
Use a single aggregate controller that joins ALL sources and writes ALL status fields in one patch. Don't use separate Patchers for the same target object.

```yaml
# BAD — two controllers, race condition
- name: server-status   # writes status.replicas
  sources: [Deployment]
  target: {kind: MyView, type: Patcher}

- name: redis-status    # writes status.redis — OVERWRITES replicas
  sources: [StatefulSet]
  target: {kind: MyView, type: Patcher}

# GOOD — single controller, no race
- name: aggregate-status
  sources: [Deployment, StatefulSet, HTTPRoute, NetworkingView]
  pipeline:
    - "@join": ...  # join all sources
    - "@project":   # write ALL fields at once
        status:
          replicas: "$.Deployment.status.readyReplicas"
          redis: { ready: ... }
          httpRouteReady: ...
  target: {kind: MyStack, type: Patcher}
```

Also: `@definedOr` only takes 2 arguments. Nest for 3+ fallbacks:
```yaml
# BAD
"@definedOr": [a, b, c]  # error: expected 2 arguments

# GOOD
"@definedOr": [a, {"@definedOr": [b, c]}]
```

## When to Use
- Building dcontroller operators with status aggregation from multiple sources
- Any time two+ controllers Patch the same object's status
- Until dcontroller#9 is fixed
