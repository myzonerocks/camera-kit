# Decisions

## 2026-08-14 Public repository, hosted gates, server-side protection

The owner made the repository public so hosted runners are unmetered. That
retires the visibility guard, restores hosted CI as the merge authority with
the local zig build ci as pre-flight, and unlocks server-side rules: main
now requires a pull request with the gates check green, allows only squash
merges, and blocks force pushes and deletion for everyone.

## 2026-08-14 Gates run locally

Hosted runners are not funded, so the gate suite is local and authoritative:
zig build ci runs the tests in both optimize modes, the source gate, the abi
surface check, the vendor verification, and the commit provenance scan. It
must be green before every push and every merge. The workflow files stay for
the day hosted runners return; until then they are advisory.

## 2026-08-14 Main branch protection

GitHub only enforces branch protection on private repositories under a paid
plan, and this repository stays private. So protection is procedural for
now. Squash is the only merge method the repository accepts, merged branches
delete automatically, a pre-push hook refuses direct pushes to main, and CI
runs the full gate suite on every PR and fails if the repository ever
reports public. Every change reaches main through a PR with green gates.

If the org moves to a paid plan, add a ruleset on main that requires PRs and
blocks force pushes, and delete this entry.
