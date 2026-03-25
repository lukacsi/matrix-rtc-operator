# dcontroller Improvement Proposals: Deep Dive

Based on real experience building the matrix-rtc-operator, this document analyzes 8 improvement proposals against the dcontroller source code at `/home/oger/AI/Projects/dcontroller`.

---

## Issue 5: Pipeline Testing Framework

### Current State

Pipelines are extensively tested in Go using Ginkgo/Gomega:
- `pkg/pipeline/aggregation_test.go` (39KB) — unit tests for individual pipeline operations (@select, @project, @unwind, @gather)
- `pkg/pipeline/join_test.go` (15KB) — multi-source join tests including delete propagation
- `pkg/pipeline/pipeline_test.go` (27KB) — end-to-end pipeline evaluation tests
- `pkg/pipeline/misc_test.go` (4KB) — helper function tests
- `pkg/expression/expression_test.go` — expression evaluator unit tests
- `test/` directory — integration tests using `envtest` (real API server)

All tests use the same pattern: construct a pipeline from JSON/YAML, feed it `object.Delta` values, and assert on output deltas. The `pipeline.New()` function and `pipeline.Evaluate()` work entirely in-memory — no live cluster needed for unit tests.

### Infrastructure Reusable for `dctl test`

The `dctl` CLI already uses Cobra and has subcommands: `start`, `generate-keys`, `generate-config`, `get-config`, `visualize`. Adding a `test` subcommand fits naturally.

Key reusable components:
1. **`pipeline.New(operator, targetGVK, sourceGVKs, config, logger)`** — creates a pipeline from an Operator CR spec, runs entirely standalone
2. **`pipeline.Evaluate(delta)`** — processes a single delta, returns output deltas
3. **`pipeline.Sync()`** — state-of-the-world re-evaluation
4. **`manager.NewFakeManager()`** — already exists in `pkg/manager/`, used extensively in tests, provides a fake client and cache
5. **Expression evaluator** — `expression.Expression.Evaluate(ctx)` runs standalone with just an `EvalCtx{Object, Subject, Log}`
6. **`dctl visualize`** — already parses Operator YAML from files, so file-loading infrastructure exists

### Feasibility: Offline Evaluation

Yes, pipelines can be evaluated offline. The expression evaluator operates on `map[string]any` (unstructured content) with no cluster dependencies. The pipeline's DBSP executor is purely computational. The only cluster dependency is in the reconciler layer (source watches, target writes), which sits above the pipeline.

### Proposed Approach

Add a `dctl test` subcommand:

```bash
# Basic: evaluate pipeline against sample inputs
dctl test --pipeline operator.yaml --input samples/

# With expected outputs for CI
dctl test --pipeline operator.yaml --input samples/ --expect expected/

# Single expression evaluation
dctl test --expr '{"@concat": ["$.metadata.name", "-svc"]}' --input obj.yaml
```

Implementation sketch:
1. Parse Operator YAML (reuse from `visualize` command)
2. For each controller in the Operator:
   a. Create pipeline via `pipeline.New()` with fake GVKs
   b. Load input YAML files, convert to `object.Delta` (Added type)
   c. Call `pipeline.Evaluate()` for each input
   d. Print output deltas as YAML
   e. If `--expect` given, diff against expected output

The `samples/` directory would contain files named by source kind (e.g., `Secret-my-secret.yaml`, `ConfigMap-my-cm.yaml`). For multi-source join pipelines, all source objects would be loaded and fed sequentially.

### Estimated Difficulty: Medium
- File parsing infrastructure exists (visualize command)
- Pipeline evaluation works standalone
- Main work: CLI plumbing, input file loading/matching to sources, output formatting
- ~300-500 lines of new code

### Priority: High
This is the single most impactful developer experience improvement. Currently the only way to test a pipeline is to deploy it to a cluster and watch logs. A local test command would dramatically speed up iteration.

---

## Issue 6: No Re-evaluation on Operator CR Change

### Current State

The Operator CR reconciler lives in `main.go` (`runStartServer`). When the dcontroller process starts, it creates an operator controller that watches Operator CRDs:

```go
// Create an operator controller to watch and reconcile Operator CRDs
config := ctrl.GetConfigOrDie()
api, err := cache.NewAPI(config, cache.APIOptions{...})
```

The `DeclarativeController` in `pkg/controller/declarative.go` is created once per controller spec within an Operator CR. It calls `NewDeclarative()` which:
1. Creates sources and targets
2. Creates a controller-runtime controller with watches
3. Creates the pipeline
4. Returns — the controller is now running

**The problem:** If you update the Operator CR (e.g., change a pipeline expression), the existing controllers are NOT torn down and recreated. The operator controller reconciler would need to detect the change, stop old controllers, and start new ones.

### Should Controllers Auto-Restart?

Yes, but with careful design. The current architecture creates controllers at startup time. Controller-runtime controllers cannot be stopped once started (this is a known limitation of the controller-runtime library). The options are:

1. **Process restart** (current workaround): Delete and recreate the dcontroller pod. Works but defeats the purpose of a declarative system.
2. **Hot-reload via generation tracking**: Track `metadata.generation` on the Operator CR. On generation change, create new controllers with updated pipelines. Old controllers would need to be drained (stop processing new events).
3. **Pipeline hot-swap**: Keep the controller shell (sources, watches) but replace the pipeline evaluator inside the reconciler. This is the cleanest approach since sources/targets rarely change — it's usually the pipeline logic that gets updated.

### Proposed Approach: Pipeline Hot-Swap

The `DeclarativeController` stores `pipeline pipeline.Evaluator` as a field. The reconciler in `pkg/controller/reconcilers.go` calls `c.pipeline.Evaluate(delta)`. A hot-swap would:

1. Operator controller detects generation change on Operator CR
2. For each controller in the spec, compare with running controller
3. If only pipeline changed: create new `pipeline.New()`, atomically swap `c.pipeline` (behind a mutex)
4. If sources/targets changed: log a warning, require pod restart (or implement full teardown)
5. Trigger a `Sync()` on the new pipeline to rebuild state

This avoids the controller-runtime limitation of not being able to stop controllers, while still enabling the most common update path (pipeline expression changes).

### Estimated Difficulty: Hard
- Controller-runtime doesn't support stopping controllers
- Need generation tracking, diffing, and atomic swap
- State migration (pipeline caches) is tricky
- Risk of race conditions during swap

### Priority: Medium
Important for production UX but has a workable workaround (pod restart). The pipeline hot-swap approach limits scope.

---

## Issue 7: Memory Defaults and Sizing

### Current State

The Helm chart at `chart/helm/templates/deployment.yaml` sets:

```yaml
resources:
  limits:
    cpu: 500m
    memory: 128Mi
  requests:
    cpu: 10m
    memory: 64Mi
```

The `values.yaml` is minimal — just image configuration. No resource overrides are exposed.

### Informer Count Analysis

Each source in a controller creates one informer:
- **Watcher source** (`pkg/reconciler/source.go`): Creates a `controller-runtime` source that registers a watch via the manager's cache, which creates one informer per GVK
- **View source**: Uses the ViewCache's internal informer system (`pkg/cache/view_cache.go`), one `ViewCacheInformer` per GVK
- **Controller-runtime caches are shared**: If two controllers watch the same GVK, they share the same informer (controller-runtime deduplicates)

For the matrix-rtc-operator with ~10 Operator CRs and ~5 controllers each:
- **Native K8s informers**: Secrets, ConfigMaps, Services, Deployments, StatefulSets, HTTPRoutes, Gateways, etc. — roughly 8-12 unique GVKs, so 8-12 shared informers
- **View informers**: Each view kind gets its own ViewCacheInformer. With ~20-30 view types across all operators, that's 20-30 view informers
- **Total**: ~30-40 informers

### Memory Estimation

Each informer caches all objects matching its watch scope:
- **Cluster-scoped Secret informer**: Caches ALL Secrets in the cluster. In a typical homelab with 50-100 secrets, ~1-5MB. In production with thousands of secrets: 50-200MB.
- **Namespace-scoped informer**: Much cheaper — only objects in that namespace
- **View informers**: Lightweight, in-memory only, typically small (10s-100s of objects)
- **Per-informer overhead**: ~50-100KB for the watch connection and internal structures

**Estimate for 10 operators, 50 controllers, homelab scale:**
- Native informers (12 GVKs, moderate cluster): ~20-50MB
- View informers (30 views, small datasets): ~5-10MB
- Pipeline DBSP state (caches per pipeline): ~10-20MB
- Go runtime overhead: ~30-50MB
- **Total: ~80-130MB** — the 128Mi limit is dangerously tight

**At production scale with cluster-wide Secret watching:**
- Could easily exceed 512MB

### Proposed Approach

1. **Expose resource limits in values.yaml** (immediate fix):
```yaml
resources:
  limits:
    cpu: "1"
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 256Mi
```

2. **Per-source memory budget documentation**: Document the memory impact of each source type:
   - Cluster-scoped native resource: `(avg_object_size * object_count) + 100KB overhead`
   - Namespace-scoped native resource: Same formula but scoped
   - View: Negligible unless aggregating large datasets

3. **Lazy informer sharing** (longer term): The ViewCache already supports `DelegatingViewCache` for cross-operator view sharing. A similar pattern could be used for native resources — defer informer creation until the first reconcile event, and share informers across operators watching the same GVK.

4. **Namespace scoping for sources** (already supported): The Source spec has a `namespace` field. Document that using `namespace` on Secret/ConfigMap sources dramatically reduces memory vs. cluster-wide watches.

### Estimated Difficulty: Easy (values.yaml fix), Medium (documentation), Hard (lazy sharing)
### Priority: High
The 128Mi default will cause OOMKills in any non-trivial deployment. This is a production blocker.

---

## Issue 8: RBAC Auto-Generation

### Current State

The Helm chart at `chart/helm/templates/rbac.yaml` already implements two RBAC modes:

1. **Wildcard mode** (default): Grants `*/*` access to all resources. Simple but overly permissive.
```yaml
rbac:
  mode: wildcard
```

2. **Aggregated mode**: Uses Kubernetes ClusterRole aggregation. The base chart provides core permissions (Operator CRD access, leader election), and each operator chart adds its own ClusterRole with label `dcontroller.io/aggregate-to-manager: "true"`. Kubernetes auto-merges these.

The base ClusterRole in aggregated mode includes:
- `dcontroller.io` operators, operators/status, operators/finalizers
- Events (create, patch)
- Coordination leases

Operator charts are expected to ship their own ClusterRole like:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    dcontroller.io/aggregate-to-manager: "true"
rules:
  - apiGroups: [""]
    resources: [secrets, configmaps]
    verbs: [get, list, watch]
```

### Could RBAC Be Auto-Generated from Operator CRs?

Yes. Each Operator CR declares:
- **Sources**: `apiGroup` + `kind` -> needs `get`, `list`, `watch` permissions
- **Targets with type Updater**: `apiGroup` + `kind` -> needs `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`
- **Targets with type Patcher**: `apiGroup` + `kind` -> needs `get`, `list`, `watch`, `update`, `patch`

A controller or CLI tool could:
1. Scan all Operator CRs in the cluster (or from files)
2. Extract all source and target resource references
3. Generate a ClusterRole with minimum required permissions
4. Apply it with the aggregation label

### Proposed Approaches

**Option A: `dctl generate-rbac` CLI command** (recommended)
```bash
# Generate RBAC from operator YAML files
dctl generate-rbac operators/*.yaml > rbac.yaml

# Or from a running cluster
dctl generate-rbac --from-cluster --namespace=my-ns > rbac.yaml
```

This fits the existing `dctl` pattern (generate-keys, generate-config) and produces a static YAML that can be reviewed and committed to git. No runtime magic.

**Option B: Admission webhook validation**
A validating webhook could check at deploy time whether the dcontroller ServiceAccount has permissions for all resources referenced in an Operator CR. This would catch permission errors early but doesn't generate the RBAC — it only validates.

**Option C: Dynamic ClusterRole controller**
A controller within dcontroller that watches Operator CRs and maintains a ClusterRole. Powerful but creates a chicken-and-egg problem (needs permission to create ClusterRoles) and is harder to audit.

### Recommended: Option A + aggregated mode

The `generate-rbac` command produces a ClusterRole YAML per operator chart. Combined with the already-implemented aggregated mode, this gives:
- Predictable, auditable RBAC (static YAML in git)
- Automatic aggregation at deploy time
- No runtime privilege escalation

### Estimated Difficulty: Easy (Option A), Medium (Option B), Hard (Option C)
### Priority: Medium
The wildcard default works for development. Aggregated mode already exists for production. The generator just smooths the DX for creating operator-specific ClusterRoles.

---

## Issue 9: @definedOr Variadic

### Current State

The `@definedOr` implementation in `pkg/expression/expression.go` (line 292-317):

```go
case "@definedOr": // useful for setting defaults
    args, err := AsExpOrExpList(e.Arg)
    if err != nil {
        return nil, NewExpressionError(e, err)
    }

    if len(args) != 2 {
        return nil, NewExpressionError(e,
            errors.New("invalid arguments: expected 2 arguments"))
    }

    // conditional
    v, err := args[0].Evaluate(ctx)
    if err != nil {
        return nil, err
    }

    if v == nil {
        v, err = args[1].Evaluate(ctx)
        if err != nil {
            return nil, err
        }
    }
```

**It is hardcoded to exactly 2 arguments.** The check `len(args) != 2` rejects any other arity. The logic is: evaluate args[0], if nil, evaluate args[1].

Tests in `expression_test.go` (lines 1286-1345) confirm only 2-arg usage:
```json
{"@definedOr": [1, 2]}
{"@definedOr": ["$.dummy", 2]}
{"@definedOr": ["$.metadata.namespace", 2]}
{"@definedOr": ["$.dummy", "$.metadata.namespace"]}
```

### How Hard Is the Fix?

Trivial. Replace the 2-arg check with a loop:

```go
case "@definedOr":
    args, err := AsExpOrExpList(e.Arg)
    if err != nil {
        return nil, NewExpressionError(e, err)
    }

    if len(args) < 2 {
        return nil, NewExpressionError(e,
            errors.New("invalid arguments: expected at least 2 arguments"))
    }

    var v any
    for _, arg := range args {
        v, err = arg.Evaluate(ctx)
        if err != nil {
            return nil, err
        }
        if v != nil {
            break
        }
    }
```

This is a fully backward-compatible change — existing 2-arg usage works identically.

### Use Case from matrix-rtc-operator

Currently we write nested `@definedOr` for multi-level defaults:
```yaml
image: {"@definedOr": ["$.spec.livekit.image", {"@definedOr": ["$.spec.defaults.image", "livekit/livekit-server:latest"]}]}
```

With variadic support:
```yaml
image: {"@definedOr": ["$.spec.livekit.image", "$.spec.defaults.image", "livekit/livekit-server:latest"]}
```

### Estimated Difficulty: Easy
- ~10 lines of code change in `expression.go`
- Add 2-3 test cases for 3+ args
- Fully backward compatible

### Priority: High
Small change, high impact on pipeline readability. The nested workaround is ugly and error-prone.

---

## Issue 10: Source Type/Label Filtering for Core Resources

### Current State

The Source spec in `pkg/api/operator/v1alpha1/types.go` supports:

```go
type Source struct {
    Resource      `json:",inline"`
    Type          SourceType             `json:"type,omitempty"`          // Watcher, Periodic, OneShot
    Namespace     *string                `json:"namespace,omitempty"`     // namespace scoping
    LabelSelector *metav1.LabelSelector  `json:"labelSelector,omitempty"` // label filtering
    Predicate     *predicate.Predicate   `json:"predicate,omitempty"`    // event predicates
    Parameters    *apiextensionsv1.JSON  `json:"parameters,omitempty"`   // virtual source params
}
```

**LabelSelector is supported.** It's converted to a controller-runtime predicate in `pkg/reconciler/source.go`:

```go
// From predicate package:
func FromLabelSelector(labelSelector metav1.LabelSelector) (predicate.TypedPredicate[client.Object], error) {
    return predicate.LabelSelectorPredicate(labelSelector)
}
```

**FieldSelector is NOT directly supported** in the Source spec. However, the ViewCache (`pkg/cache/view_cache.go`) does support field selectors internally for List and Watch operations — it checks `client.MatchingFields` and `client.MatchingFieldsSelector` options.

**No typeSelector exists.** For Secrets, the Kubernetes API supports `type` as a field selector (`field.selector=type=kubernetes.io/tls`), but this would need to be exposed through the Source spec.

### The Problem

When watching Secrets cluster-wide, the informer caches ALL secrets — including service account tokens, Helm release secrets, TLS certs, etc. In a typical cluster, 80%+ of secrets are irrelevant to the operator. This wastes memory and generates unnecessary reconciliation events.

### Proposed Approaches

**Option 1: Add fieldSelector to Source spec** (recommended)
```yaml
sources:
  - apiGroup: ""
    kind: Secret
    fieldSelector:
      matchFields:
        type: Opaque
```

This requires:
1. Add `FieldSelector` field to the Source struct
2. In `source.go`, pass it as a `cache.ByObject` option when setting up the informer
3. Controller-runtime supports field selectors on cache configuration via `cache.Options.ByObject[obj].Field`

**Important caveat:** Controller-runtime field selectors work at the cache level, not the API level. Only certain fields are indexable. For Secrets, `type` would need to be registered as an index. The alternative is to use the API server's native field selector by configuring the informer's ListWatch directly.

**Option 2: Informer transform functions**
Controller-runtime supports transform functions on informers that can strip unnecessary data from cached objects:

```go
cache.Options{
    ByObject: map[client.Object]cache.ByObject{
        &corev1.Secret{}: {
            Transform: func(obj interface{}) (interface{}, error) {
                secret := obj.(*corev1.Secret)
                if secret.Type != corev1.SecretTypeOpaque {
                    return nil, nil // exclude from cache
                }
                return secret, nil
            },
        },
    },
}
```

This reduces memory usage but doesn't eliminate the API watch traffic.

**Option 3: Namespace scoping (already works)**
```yaml
sources:
  - apiGroup: ""
    kind: Secret
    namespace: my-namespace
```

This is the simplest approach and already supported. Combined with labelSelector, it covers most use cases.

### Recommended: Option 3 (document it) + Option 1 (longer term)

For most operators, namespace + label selector is sufficient. Document this pattern prominently. Add fieldSelector support as a follow-up for advanced use cases.

### Estimated Difficulty: Easy (documentation), Medium (fieldSelector), Hard (transform functions)
### Priority: Medium
Namespace scoping already solves the memory problem for most cases. fieldSelector is a nice-to-have.

---

## Issue 11: GC for Join-Based Pipelines

### Current State

**Join pipelines DO produce delete deltas.** The DBSP incremental join operator tracks state and correctly propagates deletes. From `pkg/pipeline/join_test.go`:

```go
// Delete pod3 after it was added and joined with dep2
deltas, err = j.Evaluate(object.Delta{Type: object.Deleted, Object: pod3})
Expect(deltas).To(HaveLen(1))
Expect(deltas[0].Type).To(Equal(object.Deleted))
```

When a source object is deleted, the join operator:
1. Looks up the object in its internal cache
2. Finds all matching pairs from the other source(s)
3. Produces `Deleted` deltas for each pair that no longer exists

**The Updater target** (`pkg/reconciler/target.go`) handles delete deltas by calling `c.Delete(ctx, delta.Object)`, which removes the target resource from the cluster.

**The Patcher target** handles delete deltas by applying a "delete patch" — removing the fields specified in the delta from the target object (using RFC 7386 merge-patch semantics with nil values).

### So Where's the GC Problem?

The GC issue is specifically about **Updater targets writing to native Kubernetes resources** (not views). When a pipeline creates a Deployment or ConfigMap as a target, and then the source objects change such that the pipeline no longer produces that output — the old target resource is orphaned.

**The key insight:** The pipeline's DBSP engine correctly produces `Deleted` deltas when join pairs break. The target's `Write()` method correctly processes those deltas. **The GC works for the common case.**

The edge cases where GC fails:
1. **dcontroller pod restart**: Pipeline state (DBSP caches) is lost. The `Sync()` method rebuilds state, but only for objects still matching — it doesn't know about previously-created targets that are no longer produced.
2. **Operator CR change**: If a pipeline is modified, old targets created by the previous pipeline version are orphaned.
3. **Race conditions**: If the dcontroller crashes between creating a target and caching the source state, the target is orphaned.

### Proposed Approach: Owner References

The most Kubernetes-native solution:

1. When the Updater target creates an object, set an `ownerReference` pointing to the Operator CR (or a dedicated "controller state" object)
2. On startup/sync, list all objects with that owner reference
3. Compare with current pipeline output
4. Delete orphans

Implementation in `target.go`:
```go
case object.Added, object.Upserted:
    // Set owner reference to the Operator CR
    delta.Object.SetOwnerReferences([]metav1.OwnerReference{{
        APIVersion: "dcontroller.io/v1alpha1",
        Kind:       "Operator",
        Name:       t.operatorName,
        UID:        t.operatorUID,
    }})
```

**Alternative: Finalizer-based approach**
Add a finalizer to each created target. On pipeline re-evaluation, if an object is no longer produced, the finalizer handler deletes it. This is more complex but handles cross-namespace targets (owner references require same-namespace).

**Alternative: Label-based GC**
Label each created target with `dcontroller.io/operator=<name>` and `dcontroller.io/controller=<name>`. On sync, list by label and diff against current output. Simpler than owner references and works cross-namespace.

### Estimated Difficulty: Medium (label-based), Hard (owner references with proper lifecycle)
### Priority: Medium-High
The happy path works. The restart/upgrade path orphans resources. For production operators managing real infrastructure (Deployments, Services), this is a data integrity issue.

---

## Issue 12: Developer Documentation

### Current State

The `doc/` directory contains a comprehensive documentation set:

**Concepts:**
- `what-is-delta-controller.md` — overview, strengths, limitations
- `concepts-operator-controller-object.md` — Operator, Controller, Object model
- `concepts-source-target.md` — Sources (Watcher, OneShot, Periodic) and Targets (Updater, Patcher)
- `concepts-view.md` — View system explanation
- `concepts-pipeline.md` — Pipeline operations and data flow
- `concepts-expression.md` — Expression language
- `concepts-API-server.md` — Extension API Server, authentication

**Reference:**
- `reference-operator.md` — Operator CR spec
- `reference-pipeline.md` — Pipeline operations reference
- `reference-expression.md` — Expression language reference

**Tutorials (3):**
1. `examples/configmap-deployment-controller/` — basic CRD + join + patch
2. `examples/service-health-monitor/` — two-stage pipeline with views
3. `examples/endpointslice-controller/` — hybrid declarative + imperative

**Other:**
- `getting-started.md`
- `further-reading.md`
- `INDEX.md` — table of contents

### What's Missing

Based on building matrix-rtc-operator (10 Operator CRs, 50+ controllers, 3-tier CRD hierarchy):

1. **Multi-source join patterns tutorial**: The existing ConfigMap-Deployment tutorial shows a basic 2-source join. Missing:
   - 3+ source joins (proven to work but undocumented)
   - Join + @gather patterns (aggregate across multiple matches)
   - Join key design (how to structure metadata.name and labels for efficient joins)

2. **Config generation patterns**: The matrix-rtc-operator's most powerful pattern — using `@project` to generate ConfigMaps/Secrets from CRD fields — is completely undocumented. This includes:
   - Generating YAML/JSON config files via string concatenation and @concat
   - Using @hash for rollout-on-config-change patterns
   - Multi-level CRD decomposition (top-level CRD -> intermediate views -> concrete resources)

3. **Status aggregation patterns**: Collecting status from child resources and writing it back to parent CRDs. The matrix-rtc-operator's status pipeline pattern (watch Deployments/StatefulSets -> aggregate readiness -> patch parent status) is a key use case with no documentation.

4. **View chaining best practices**: When to use views vs. direct source-to-target. The matrix-rtc-operator uses a 3-tier architecture (L0: decompose, L1: generate, L2: deploy) that's a powerful pattern worth documenting.

5. **RBAC setup guide**: The wildcard vs. aggregated mode is documented in the Helm chart README but not in the main docs. Especially the gotchas (missing `dcontroller.io/operators` permissions, name prefix mismatches).

6. **Troubleshooting guide**: Common errors and their solutions:
   - "no source for GVK" — wrong apiGroup
   - "pipeline evaluation failed" — expression errors, missing fields
   - RBAC 403 errors — which permissions are needed for which operations
   - View CRD not found — extension API server not ready

7. **Performance tuning**: Memory impact of cluster-wide watches, namespace scoping, labelSelector benefits, pipeline cache sizing.

### Key Patterns from matrix-rtc-operator Worth Documenting

| Pattern | Description | MRO Example |
|---------|-------------|-------------|
| CRD Decomposition | Split a top-level CRD into sub-CRDs via @project | MatrixRTCStack -> LiveKitStack + MatrixStack |
| Config Generation | Generate ConfigMaps from CRD fields | LiveKit config.yaml from LiveKitStack spec |
| Status Rollup | Aggregate child readiness into parent status | Deployment/StatefulSet ready -> Stack status |
| Hash-based Rollout | Use @hash to trigger pod restarts on config change | ConfigMap hash annotation on Deployments |
| Default Cascading | Multi-level defaults with @definedOr | Infra defaults -> Stack defaults -> Component spec |
| Cross-namespace Ref | Use infraRef to reference shared infrastructure | RTCInfrastructure referenced by multiple stacks |

### Estimated Difficulty: Medium (each tutorial/guide is 1-2 days of writing)
### Priority: High
Documentation is the #1 adoption blocker. The existing concepts and reference docs are good, but practical tutorials for real-world patterns are what developers need to go from "interesting" to "I can build my operator with this."

---

## Summary Table

| Issue | Current State | Difficulty | Priority | Quick Win? |
|-------|--------------|------------|----------|------------|
| 5: Pipeline testing | Tests exist in Go, no CLI | Medium | High | No |
| 6: Operator CR re-eval | No hot-reload, requires pod restart | Hard | Medium | No |
| 7: Memory defaults | 128Mi limit, no values.yaml override | Easy-Hard | **High** | **Yes** |
| 8: RBAC auto-gen | Aggregated mode exists, no generator | Easy-Medium | Medium | Partial |
| 9: @definedOr variadic | Hardcoded to 2 args | **Easy** | **High** | **Yes** |
| 10: Source filtering | labelSelector + namespace work, no fieldSelector | Easy-Medium | Medium | Partial |
| 11: Join GC | Works for happy path, fails on restart | Medium-Hard | Medium-High | No |
| 12: Documentation | Good concepts/ref, missing tutorials | Medium | **High** | Partial |

### Recommended Execution Order

1. **Issue 9** (@definedOr variadic) — 1 hour, immediate value
2. **Issue 7** (memory defaults) — values.yaml fix in 30 minutes, documentation in a day
3. **Issue 12** (documentation) — ongoing, start with config generation pattern
4. **Issue 5** (pipeline testing CLI) — 2-3 days, transforms development workflow
5. **Issue 8** (RBAC generator) — 1-2 days, pairs with aggregated mode
6. **Issue 11** (join GC) — 3-5 days, important for production
7. **Issue 10** (source filtering) — 2-3 days, nice-to-have
8. **Issue 6** (Operator CR hot-reload) — 1-2 weeks, complex but valuable
