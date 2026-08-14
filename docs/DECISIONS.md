# Decisions

## 2026-08-14 Main branch protection

GitHub only enforces branch protection on private repositories under a paid
plan, and this repository stays private. So protection is procedural for
now. Squash is the only merge method the repository accepts, merged branches
delete automatically, a pre-push hook refuses direct pushes to main, and CI
runs the full gate suite on every PR and fails if the repository ever
reports public. Every change reaches main through a PR with green gates.

If the org moves to a paid plan, add a ruleset on main that requires PRs and
blocks force pushes, and delete this entry.
