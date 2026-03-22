# GitHub Issue Draft: dcontroller RBAC naming mismatch in kustomize pipeline

**Repository:** github.com/l7mp/dcontroller
**Type:** Bug
**Status:** Not a known issue (no open issues on the repo)

---

## Title

RBAC naming mismatch in kustomize pipeline: `manager-role` vs `dcontroller-role` in role_binding.yaml

## Description

The kustomize RBAC source files have an inconsistency between the ClusterRole name and the ClusterRoleBinding roleRef that would produce broken RBAC when `make chart` regenerates `chart/helm/templates/all.yaml`.

### The problem

In `config/rbac/role.yaml`, controller-gen generates the ClusterRole with the standard kubebuilder name:

```yaml
kind: ClusterRole
metadata:
  name: manager-role
```

In `config/helm-base/kustomization.yaml`, `namePrefix: dcontroller` is applied. This transforms `manager-role` into `dcontrollermanager-role`.

However, `config/rbac/role_binding.yaml` hardcodes the roleRef name instead of using the unprefixed form:

```yaml
kind: ClusterRoleBinding
metadata:
  name: -rolebinding          # prefixed to dcontroller-rolebinding (correct)
roleRef:
  kind: ClusterRole
  name: dcontroller-role       # BUG: hardcoded, not matched by namePrefix transform
```

The roleRef should be `manager-role` (which kustomize would transform to `dcontrollermanager-role` and also update the roleRef reference automatically). Instead, `dcontroller-role` doesn't match any resource kustomize knows about, so it's left as-is.

The same issue exists in the leader_election_role_binding.yaml, where the roleRef hardcodes `dcontroller-leader-election-role` instead of using `leader-election-role`.

### Current state

The shipped Helm chart (`chart/helm/templates/all.yaml`) is currently **internally consistent** -- the ClusterRole is named `dcontroller-role` and the binding references `dcontroller-role`. This means the `all.yaml` was likely hand-edited after kustomize generation to fix the names, or was generated with a different kustomize config.

The bug will resurface any time `make chart` is run to regenerate the Helm templates, producing:
- ClusterRole: `dcontrollermanager-role`
- ClusterRoleBinding roleRef: `dcontroller-role` (unchanged by kustomize)
- Result: `clusterrole.rbac.authorization.k8s.io "dcontroller-role" not found`

### Reproduction steps

1. Clone the repo: `git clone https://github.com/l7mp/dcontroller`
2. Run `make chart` (requires kustomize, helm, controller-gen)
3. Inspect `chart/helm/templates/all.yaml`
4. The ClusterRole name will be `dcontrollermanager-role`
5. The ClusterRoleBinding roleRef will still reference `dcontroller-role`
6. Deploy the chart: the controller will fail with RBAC errors

### Expected behavior

The kustomize source files should use unprefixed names that kustomize can properly transform:

**`config/rbac/role_binding.yaml`** should reference `manager-role` (not `dcontroller-role`):
```yaml
roleRef:
  kind: ClusterRole
  name: manager-role
```

**`config/rbac/leader_election_role_binding.yaml`** should reference `leader-election-role` (not `dcontroller-leader-election-role`):
```yaml
roleRef:
  kind: Role
  name: leader-election-role
```

Kustomize's `namePrefix` and built-in `nameReference` transformer will then consistently rename both the resource metadata.name and all roleRef references.

### Affected files

- `config/rbac/role_binding.yaml` — hardcoded `dcontroller-role` in roleRef
- `config/rbac/leader_election_role_binding.yaml` — hardcoded `dcontroller-leader-election-role` in roleRef

### Environment

- dcontroller master branch (commit 6803f35a)
- Kustomize pipeline: `config/helm-base/kustomization.yaml` with `namePrefix: dcontroller`
