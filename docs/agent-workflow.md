# Agent Workflow — Quick Reference

This is the operational quick-reference for running sprints. For full details on coding standards, escalation rules, and branch conventions, see [CLAUDE.md](../CLAUDE.md).

## Sprint Lifecycle

1. **Spec** — Orchestrator writes the sprint spec (`docs/sprints/sprint-X.Y.md`)
2. **Approve** — User reviews and sets the Approved date
3. **Pre-flight** — Coding agent inventories existing state, checks for blockers, reports findings
4. **Implement** — Coding agent builds the spec, writes tests, commits to the sprint branch
5. **Validate** — Run acceptance criteria and the validation checklist from the sprint spec
6. **Fix** — Address any failures, re-validate
7. **Merge** — Orchestrator merges the sprint branch into the development branch

## Roles

| Role | Does | Does NOT |
|------|------|----------|
| **Orchestrator** | Writes specs, coordinates, reviews, merges | Write implementation code |
| **Coding agent** | Implements spec, writes tests, fixes defects | Merge branches, skip tests |

## Session Startup

Every session, the agent must:

1. Read `CLAUDE.md`
2. Verify environment (`busybox ash` available)
3. Read `docs/roadmap.md` — find the active sprint
4. Read the active sprint spec
5. Read the sprint summary if resuming

See CLAUDE.md "Session Startup Protocol" for the full checklist.

## When to Stop and Escalate

- Spec ambiguity requiring an architectural decision
- Missing files or dependencies not in the repo
- Implementation needs files outside the sprint's file table
- Pre-existing tests now fail
- Hardware-dependent test cannot be written

State: *what* you were doing, *which* criterion triggered the stop, *what decision* you need.

## Handoff Artifacts

After implementation, create `docs/sprints/sprint-X.Y-summary.md` with:

- Files created / modified
- Tests written
- Deviations from spec (if any)
- Open items

## Key References

- **Coding standards:** CLAUDE.md "Coding Standards" section
- **Branch conventions:** CLAUDE.md "Branch and Worktree Convention" section
- **Repo structure:** `docs/ideal_os_repo_structure_spec.md`
- **Testing:** `docs/testing.md`
