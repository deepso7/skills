---
name: raise-pr
description: Implement the agreed plan or discussed change, commit, get up to 3 rounds of cross-review from another agent (Codex gpt-6.1-sol or Claude Opus 5.5), fix findings, open a PR, then baby-sit it until green. Use when the user says "raise a PR", "implement and raise PR", "do it e2e", or "lets do it" after a plan is agreed.
---

# Raise PR

## 1. Implement

- Source of truth: the plan file or what was agreed in this conversation. If unclear or conflicting, ask first.
- On the base branch? Create a feature branch with a short name, no agent prefix (`codex/`, `claude/`).
- Implement in logical commits. Before each commit run lint, format, typecheck and relevant tests.
- Never amend or force push.

## 2. Cross-review (up to 3 rounds)

Reviewer is the other agent: `codex` if you are Claude, `claude` if you are Codex, unless the user named one.

```bash
SETUP_CMD="<install deps, e.g. pnpm install --frozen-lockfile --prefer-offline>" TEST_CMD="<repo test command>" \
  <this skill's dir>/scripts/cross-review.sh <round> <codex|claude> <prompt-file> [base-branch]
```

Run it from the repo root, in the background; a round takes a few minutes. The script reviews committed work in a throwaway worktree and pins the base on round 1. If it fails (CLI missing, auth, rate limit), ask the user whether to switch reviewer or skip.

Round 1 prompt:

```
Goal: <one paragraph>. Plan: <path or "none">.
Review for correctness bugs, missed plan requirements, security issues, broken edge cases,
missing tests for real behavior, and needless complexity. Skip lint-level nits.
Output: `N. [high|medium|low] file:line - what breaks - suggested fix`, or exactly NO FINDINGS.
```

Rounds 2 and 3 use the same prompt plus:

```
Previous findings and how they were handled:
<N. finding - fixed in <sha> / declined: reason>
Verify each fix, then look for new issues, especially in the fix commits.
```

After each round:
1. Check each finding against the code; reviewers can be wrong. Fix valid ones at the root cause and commit (`fix: address review findings (round N)`).
2. Run another round only if you just fixed a valid high or medium finding. Stop at `NO FINDINGS`, low-only findings, or after round 3.

## 3. Open the PR

Push, then `gh pr create --base <base>` (`--draft` only if asked). Body:
- **Summary:** what and why, 2-4 bullets.
- **Plan:** path or link, if any.
- **Testing:** commands run and what you verified.
- **Cross-review:** reviewer and model; per round, fixed and declined (with reason).
- **Follow-ups:** leftover findings, or "none".

## 4. Baby-sit

Run the `baby-sit` skill on the new PR, then report its result with the PR URL.
