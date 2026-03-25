# dcontroller Issues Deep Dive

Source code analysis of four dcontroller framework issues discovered while building the matrix-rtc-operator. All references point to the dcontroller repo at `~/AI/Projects/dcontroller/`.

---

## Issue 1: Patcher Merge Race (#9)

### Root Cause

The Patcher target mode (`pkg/reconciler/target.go:179-315`) uses a **read-modify-write** pattern without field ownership:

1. **Read**: Fetches the current object from the API server (or uses the original snapshot from the reconcile request) (`target.go:197-213`)
2. **Modify**: Applies delta changes via `object.Patch()` which implements RFC 7386 JSON Merge Patch semantics (`target.go:217`)
3. **Write**: Calls the custom `Update()` function (`target.go:230`) which does `client.Update()` followed by `client.Status().Update()` for native resources (`pkg/reconciler/ctrlutils.go:96-144`)

The `Update()` function in `ctrlutils.go:96-144` uses `retry.RetryOnConflict`, but on retry it only re-fetches the `resourceVersion` (`ctrlutils.go:119`), not the full object. The desired state was already computed against a potentially stale snapshot. So:

- **Controller A** reads object, computes patch with `status.controllerA: {...}`
- **Controller B** reads the same object, computes patch with `status.controllerB: {...}`
- Controller A writes -- object now has both original fields + controllerA
- Controller B writes -- object now has original fields + controllerB (controllerA's changes are **overwritten** because Controller B's desired state was computed from the pre-A snapshot)

The conflict retry only updates `resourceVersion` to make the write succeed, but the desired state still reflects the stale snapshot. This is a classic **lost update** problem.

The `object.Patch()` function itself (`pkg/object/patch.go:13-93`) implements a recursive merge that handles nested maps and arrays, but it operates on a **local copy** -- it has no awareness of what other controllers may have written between read and write.

### Impact Severity: **HIGH**

Any operator with 2+ controllers writing to the same target object (very common pattern -- e.g., one controller manages `.spec`, another manages `.status` subfields) will silently lose fields. The matrix-rtc-operator hit this with multiple controllers patching the same ConfigMap status.

### Proposed Fix

**Option A: Server-Side Apply with field ownership (recommended)**

Replace the read-modify-write pattern with Kubernetes Server-Side Apply (SSA). Each controller would use its own field manager name (e.g., `dcontroller:<operator>:<controller>`). SSA tracks which fields are owned by which manager and merges non-conflicting writes automatically.

```go
// In target.go patch(), replace Update() with:
err := c.Patch(ctx, obj, client.Apply, client.FieldOwner(fieldManager), client.ForceFieldOwnership)
```

This requires:
- Building the apply configuration (the "desired state" patch) rather than the full object
- Handling the status subresource separately with `client.Status().Patch()` using SSA
- Each controller must declare a unique field manager

**Option B: Re-read on retry with re-merge**

On conflict retry in `Update()`, re-fetch the full object AND re-apply the delta patch against the fresh state. This would require threading the original delta through the retry loop, which is a more invasive change.

### Difficulty: **Medium** (Option A) / **Easy** (Option B)

Option A is the correct long-term fix but requires reworking the target write path. Option B is a targeted fix that prevents data loss but doesn't solve the fundamental ownership problem (two controllers can still fight over the same field).

### Classification: **Framework design issue**

The read-modify-write pattern without field ownership is fundamentally racy when multiple writers target the same object. This is a known Kubernetes anti-pattern that SSA was designed to solve.

---

## Issue 2: Silent Data Loss After OOM / DBSP State Recovery

### Root Cause

All DBSP state is **purely in-memory** with no persistence or recovery mechanism. The stateful operators are:

1. **IntegratorOp** (`pkg/dbsp/op_misc.go:~60-80`): Accumulates deltas into snapshots via `state = state + delta`. The `state` field is a `*DocumentZSet` that grows unboundedly.

2. **DifferentiatorOp** (`pkg/dbsp/op_misc.go:~90-120`): Tracks `prevState` to compute `delta = snapshot - prevState`.

3. **IncrementalBinaryJoinOp** (`pkg/dbsp/op_bilinear.go`): Maintains `prevLeft` and `prevRight` `*DocumentZSet` fields representing accumulated snapshots of each join input. The incremental join computes `deltaL join deltaR + prevL join deltaR + deltaL join prevR`.

4. **IncrementalJoinOp** (N-ary) (`pkg/dbsp/op_bilinear.go`): Maintains `prevStates []*DocumentZSet` for N inputs.

5. **DelayOp** (`pkg/dbsp/op_misc.go:~160-190`): Buffers one timestep of data.

6. **Pipeline source/target caches** (`pkg/pipeline/pipeline.go:66-68`): `sourceCache map[GVK]*cache.Store` and `targetCache *cache.Store` track what's been seen and what's been written.

On process restart (OOM kill, pod eviction, upgrade):
- All integrator/differentiator/join state is **zeroed out**
- Source and target caches are **empty**
- controller-runtime informers re-list all watched resources, delivering **Added** events for every existing object

The recovery sequence fails because:

1. **Join state is empty**: When the first source (e.g., ConfigMap) re-lists, the join's `prevRight` (for the other source, e.g., Secret) is empty. The join produces `deltaL join empty = nothing`. Events from the first source are effectively **dropped**.

2. **Source cache is empty**: `ConvertDeltaToZSet()` (`pkg/pipeline/zset_adaptor.go`) treats all re-listed objects as `Added` (multiplicity +1). But if the join produces nothing (because the other side hasn't re-listed yet), the target cache never gets populated.

3. **Race between re-list streams**: There's no synchronization to ensure all sources have completed their initial list before processing begins. Whichever source completes first will have its events processed against empty join state for the other sources.

4. **The `Executor.Reset()` method exists** (`pkg/dbsp/executor.go:98-123`) and correctly resets all stateful operators, but it is **never called during normal restart recovery**. It's only used in tests.

### Impact Severity: **HIGH**

Every pod restart (OOM, upgrade, node drain) can leave the operator in an inconsistent state where some join combinations are missing from the output. The operator appears healthy (no errors) but silently produces incomplete results. The only recovery is to delete and recreate the source objects to force re-processing -- which users don't know to do.

### Proposed Fix

**Option A: Full re-evaluation on startup (recommended, medium effort)**

After all informer caches have synced (controller-runtime provides `cache.WaitForCacheSync()`), run a Sync() pass for every controller:

1. Add a startup hook in `DeclarativeController` that waits for all source informers to sync
2. Collect all objects from each source informer
3. Call `Pipeline.Sync()` which already implements state-of-the-world reconciliation (`pkg/pipeline/pipeline.go:~240-330`) -- it converts source caches to ZSets, runs a snapshot executor, and diffs against the target cache
4. This correctly handles the "all sources at once" case because the snapshot executor doesn't use incremental join state

The `Sync()` method already exists and works correctly for periodic sources. The fix is to also run it once at startup for incremental sources.

**Option B: Persistent DBSP state (hard, not recommended)**

Persist integrator/join state to a sidecar database (e.g., SQLite, etcd). This is complex, adds operational overhead, and the state can still become stale if the source objects changed while the operator was down.

### Difficulty: **Medium** (Option A) / **Hard** (Option B)

Option A leverages the existing `Sync()` mechanism. The main challenge is hooking into the startup sequence at the right point (after informer sync, before incremental processing begins) and ensuring thread safety.

### Classification: **Framework design issue**

The DBSP model assumes a continuous stream of deltas from time zero. There's no mechanism to handle the "cold start" case where accumulated state is lost. This is inherent to the in-memory incremental computation model.

---

## Issue 3: No Error Visibility

### Root Cause

Errors during pipeline expression evaluation **propagate up as Go errors** and are surfaced in two places, but neither is easily discoverable by operators:

**Error propagation path:**

1. Expression evaluation (`pkg/expression/expression.go:60`) returns `(any, error)`. Errors include type mismatches, invalid arguments (`pkg/expression/error.go`), etc.

2. Pipeline operators wrap these: `SelectionOp.Evaluate()` returns `fmt.Errorf("failed to evaluate expression %s: %w", ...)` (`pkg/pipeline/op.go:~30`). Same for `ProjectionOp`, `UnwindOp`, `GatherOp`.

3. DBSP operators propagate: `ProjectionOp.Process()` (`pkg/dbsp/op_linear.go:37`) returns the error from `eval.Evaluate()` directly with no wrapping.

4. The Executor propagates: `executor.Process()` wraps with `fmt.Errorf("operation %s (step %d) failed: %w", ...)` (`pkg/dbsp/executor.go:85`).

5. Pipeline.Evaluate wraps: `NewPipelineError(fmt.Errorf("failed to evaluate the DBSP graph: %w", err))` (`pkg/pipeline/pipeline.go:217`).

6. The reconciler logs and pushes to errorReporter: `r.log.Error(r.controller.Push(err), "error", ...)` (`pkg/controller/reconcilers.go:~65`).

7. The errorReporter (`pkg/controller/status_reporter.go`) maintains a LIFO stack of 10 errors and rate-limits status updates (3 per 2 seconds). Errors are forwarded to the OpController via channel.

8. The OpController calls `updateStatus()` (`pkg/kubernetes/controllers/*.go`) which writes to the Operator CR's `.status.controllers[].conditions`.

**The critical issue -- silent `nil` returns from JSONPath:**

`GetJSONPathRaw()` (`pkg/expression/jsonpath.go:~100-112`) returns `(nil, nil)` when a JSONPath expression matches zero values:

```go
values := je.Get(object)
if len(values) == 0 {
    return nil, nil  // <-- SILENT: no error, just nil
}
```

This means accessing a non-existent field like `$.spec.nonExistentField` returns `nil` with no error. Downstream, this `nil` propagates through expressions and can cause:
- `@eq` comparisons against nil silently returning false
- `@concat` with nil producing unexpected strings
- `@project` setting fields to nil, which are then stripped by JSON serialization
- The entire pipeline producing "correct" but **empty/wrong** output with no indication of why

Errors that DO occur (type mismatches, etc.) are surfaced via the Operator CR status conditions, but:
- Users must know to check `.status.controllers[].conditions`
- Error messages are truncated to 120 chars prefix + suffix (`TrimPrefixSuffixLen` in `status_reporter.go`)
- Rate limiting means rapid errors can be dropped
- No Kubernetes Events are emitted (the standard discovery mechanism for operator errors)

### Impact Severity: **HIGH**

The silent `nil` return is the most dangerous part. A typo in a JSONPath expression (`$.spec.replcias` instead of `$.spec.replicas`) produces no error -- the pipeline just silently outputs wrong data. Users have no way to discover this except by manually inspecting the output and noticing missing fields.

### Proposed Fix

**Step 1: Emit K8s Events on expression errors (easy)**

In `IncrementalReconciler.Reconcile()` and `StateOfTheWorldReconciler.Reconcile()`, after `Push(err)`, also emit a Kubernetes Event on the Operator CR:

```go
r.manager.GetEventRecorderFor("dcontroller").Eventf(
    operatorCR, corev1.EventTypeWarning, "PipelineError",
    "controller %s: %s", r.controller.name, err.Error())
```

This makes errors visible via `kubectl describe operator <name>` and `kubectl get events`.

**Step 2: Add a strict mode for JSONPath (medium)**

Add an `@strict` or `@required` expression wrapper that converts nil JSONPath results to errors:

```yaml
# Current (silent nil):
"@project": {"replicas": "$.spec.replicas"}
# Strict mode (errors on nil):
"@project": {"replicas": {"@required": "$.spec.replicas"}}
```

Or better: add a pipeline-level `strict: true` option that makes ALL JSONPath lookups error on nil.

**Step 3: Pipeline validation mode (medium)**

Add a dry-run validation that takes a sample object and traces the pipeline, reporting which expressions produced nil and which fields were dropped.

### Difficulty: **Easy** (Step 1) / **Medium** (Steps 2-3)

Step 1 is a straightforward addition of event recording. Steps 2-3 require expression language changes.

### Classification: **Framework design issue** (silent nil) + **Implementation gap** (no K8s Events)

The silent nil return in JSONPath is a design choice that prioritizes flexibility over safety. The lack of K8s Events is a missing feature that should be easy to add.

---

## Issue 4: No Re-evaluation on Operator CR Change

### Root Cause

When an Operator CR is updated (e.g., pipeline expressions changed), the `OpController.Reconcile()` method (`pkg/kubernetes/controllers/*.go`) calls `UpsertOperator()`:

```go
func (c *OpController) UpsertOperator(name string, spec *opv1a1.OperatorSpec) (*operator.Operator, error) {
    // If this is a modification event, first remove old operator and create a new one
    if c.GetOperator(name) != nil {
        c.DeleteOperator(name)
    }
    return c.AddOperatorFromSpec(name, spec)
}
```

`DeleteOperator()` cancels the operator's context and unregisters GVKs:

```go
func (c *OpController) DeleteOperator(name string) {
    // ...
    e.op.UnregisterGVKs()
    e.cancel()  // Cancels the operator context, stopping its manager
}
```

`AddOperatorFromSpec()` creates a **completely new** operator with a fresh manager, fresh controllers, fresh pipelines, and fresh DBSP state:

```go
func (c *OpController) AddOperatorFromSpec(name string, spec *opv1a1.OperatorSpec) (*operator.Operator, error) {
    op, err := operator.New(name, c.config, operator.Options{...})
    op.AddSpec(spec)   // Creates new controllers with fresh pipelines
    c.AddOperator(op)  // Starts the operator
    return op, nil
}
```

The problem sequence:

1. Old operator is destroyed (context cancelled, manager stops, all controller-runtime informers stop)
2. New operator is created with fresh empty state (empty DBSP integrators, empty join caches, empty source/target caches)
3. New operator starts, informers begin re-listing resources
4. **Same Issue 2 race condition**: re-listed events hit empty join state, producing incomplete output

But it's actually **worse** than Issue 2 because:

- The old operator's target objects (e.g., ConfigMaps it created) **still exist** in the cluster
- The new operator has an empty target cache, so it doesn't know those objects exist
- If the pipeline logic changed (which is why the user updated the CR), the new pipeline may produce **different** objects
- Old target objects that the new pipeline no longer produces are **orphaned** -- never cleaned up

The `Operator.Start()` method (`pkg/operator/operator.go:211-215`) simply delegates to `mgr.Start()` which starts the controller-runtime manager. There's no post-start hook to run a full reconciliation pass.

### Impact Severity: **MEDIUM-HIGH**

Users expect that editing the Operator CR re-evaluates all existing data with the new pipeline. Instead:
- Stale target objects from the old pipeline are orphaned
- The new pipeline may produce incomplete results due to the join race (Issue 2)
- The operator appears healthy but the output doesn't match the new pipeline definition
- Manual workaround: delete all target objects and restart the pod

### Proposed Fix

**Option A: Full Sync after operator recreation (recommended)**

After `UpsertOperator()` creates and starts the new operator, wait for informer caches to sync, then trigger a `Pipeline.Sync()` on every controller. This:
- Correctly handles the fresh join state (Sync uses snapshot executor, not incremental)
- Cleans up orphaned target objects (Sync computes required state and diffs against actual state)

```go
func (c *OpController) UpsertOperator(name string, spec *opv1a1.OperatorSpec) (*operator.Operator, error) {
    if c.GetOperator(name) != nil {
        c.DeleteOperator(name)
    }
    op, err := c.AddOperatorFromSpec(name, spec)
    if err != nil {
        return nil, err
    }
    // After informers sync, trigger full reconciliation
    go func() {
        // Wait for cache sync...
        for _, ctrl := range op.ListControllers() {
            ctrl.TriggerFullSync()
        }
    }()
    return op, nil
}
```

**Option B: Owner references for cleanup (complementary)**

Set the Operator CR as the owner of all target objects. When the operator is deleted/recreated, Kubernetes GC handles cleanup. This doesn't solve the re-evaluation problem but prevents orphaned objects.

### Difficulty: **Medium**

The main challenge is the same as Issue 2: hooking into the startup sequence at the right point. The `Sync()` method already does the right thing -- the work is in orchestrating when it runs.

### Classification: **Framework design issue**

The destroy-and-recreate pattern is correct for handling schema changes (new sources, different GVKs), but it needs a post-creation full-sync pass to ensure the new pipeline's output is consistent with the current cluster state.

---

## Summary Table

| Issue | Root Cause | Severity | Difficulty | Type |
|-------|-----------|----------|------------|------|
| #1 Patcher merge race | Read-modify-write without field ownership; retry only updates resourceVersion, not desired state | HIGH | Medium | Design |
| #2 Silent data loss on restart | In-memory DBSP state (integrators, join caches) lost on restart; no full-sync on startup; join race between re-listing sources | HIGH | Medium | Design |
| #3 No error visibility | JSONPath returns `(nil, nil)` for missing fields; no K8s Events emitted; errors only in CR status conditions (truncated, rate-limited) | HIGH | Easy-Medium | Design + Gap |
| #4 No re-eval on CR change | Destroy-recreate drops all state; no full-sync after recreation; orphaned target objects | MEDIUM-HIGH | Medium | Design |

### Recommended Priority Order

1. **Issue 3** (error visibility) -- Easiest win, biggest debugging impact. The K8s Events addition is a few lines of code.
2. **Issue 2** (restart recovery) -- Fixes a critical data integrity problem. The `Sync()` mechanism already exists.
3. **Issue 4** (CR change re-eval) -- Same underlying fix as Issue 2 (full sync after startup), applied to the upsert path.
4. **Issue 1** (patcher race) -- Requires the most architectural change (SSA migration) but affects fewer users (only those with multi-controller targets).

### Cross-cutting Theme

Issues 2 and 4 share the same root cause: **no full-sync pass after state reset**. A single "startup sync" mechanism that runs `Pipeline.Sync()` after informer caches have synced would fix both issues. This is the highest-leverage fix to pursue.
