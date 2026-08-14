# ADR 0001: main protection without server-side rulesets

Date: 2026-08-14. Status: accepted.

## Context

`main` must be PR-only: squash merges with all gates green, no direct
commits, no force-push. GitHub enforces this server-side via branch
protection or rulesets, but both require a paid plan for private
repositories, and this repository is private on a free-plan org. Making the
repository public to unlock the feature is not an option; private is a hard
requirement.

## Decision

Enforce the same invariants at the layers available:

- Repository settings (server-side, plan-independent): squash is the only
  enabled merge method; head branches auto-delete on merge.
- `.githooks/pre-push` refuses any direct push to `refs/heads/main`.
  Legitimate merges happen server-side through the PR squash button or
  `gh pr merge --squash`, which the hook never sees.
- CI runs the full gate suite on every PR and on every push to `main`; the
  visibility guard fails the build if the repository ever reports public.
- Process: every merge goes through a PR with gates green, verified locally
  before push as well, since local gates are a superset of CI.

## Consequences

Protection is procedural, not physical: a hostile or hookless clone could
push to `main`. Acceptable while the committer set is one person. If the org
moves to a paid plan, add the `main` ruleset (require PR, block force-push,
block deletion, required status checks, no bypass actors) and retire this
ADR.
