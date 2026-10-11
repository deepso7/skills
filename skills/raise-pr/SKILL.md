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

Run it from the repo root, in the background, and wait for it to finish (no `sleep`); a round takes a few minutes. The script reviews committed work in a throwaway worktree, pins the base on round 1 (rerunning round 1 starts over), and tells the reviewer the round number (and on round 3, that it is the last).

**In T3 Code** (`delegate_task` available), delegate instead, so the review is visible and wakes you:
- Pick the reviewer's model from `orchestrator_capabilities` (gpt-6.1-sol medium, or claude-opus-5-5); if it isn't listed, ask rather than substitute.
- Build the round's prompt once with `cross-review.sh --prompt-only <same args>`, note `git rev-parse HEAD`, and `delegate_task` the prompt (`mode: "async"`, one `clientRequestId` per round, reused on retries). End your turn; don't edit or commit until it completes.
- Read it with `task_status`. Accept it only if it completed with review text, and HEAD and a clean `git status` are unchanged; otherwise stop and investigate.

If a review fails (CLI missing, auth, rate limit, failed or empty task), ask the user whether to switch reviewer or skip; never treat it as `NO FINDINGS`. Before falling back from a delegated review to the CLI, make sure that task is finished or cancelled.

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
- **Cross-review:** reviewer and model (the script output's first line, or the delegated target); per round, fixed and declined (with reason). Mark fixes made after the last round you ran as "not re-reviewed".
- **Follow-ups:** leftover findings, or "none".

## 4. Baby-sit

Run the `baby-sit` skill on the new PR, then report its result with the PR URL.
