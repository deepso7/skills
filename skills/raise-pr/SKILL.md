---
name: raise-pr
description: Implement the agreed plan or discussed change, commit, get up to 3 rounds of cross-review from another agent (Codex gpt-6.1-sol or Claude Opus 5.5), fix findings, open a PR, then baby-sit it until green. Use when the user says "raise a PR", "implement and raise PR", "do it e2e", or "lets do it" after a plan is agreed, including when a plan, issue, other command or longer request ends with "raise a PR" or "after finishing, raise a PR". Never open a PR with a bare `gh pr create` instead.
---

# Raise PR

## 1. Implement

- Source of truth (the **spec**): the plan file, the issue being worked on, or what was agreed in this conversation. If unclear or conflicting, ask first.
- On the base branch? Create a feature branch with a short name, no agent prefix (`codex/`, `claude/`).
- Implement in logical commits. Before each commit run lint, format, typecheck and relevant tests.
- Never amend or force push.

## 2. Cross-review (up to 3 rounds)

Reviewer is the other agent: `codex` if you are Claude, `claude` if you are Codex, unless the user named one.

```bash
SETUP_CMD="<install deps, e.g. pnpm install --frozen-lockfile --prefer-offline>" TEST_CMD="<repo test command>" \
  <this skill's dir>/scripts/cross-review.sh <round> <codex|claude> <prompt-file> [base-branch]
```

If `<this skill's dir>/scripts` is missing, ask the user to install the skills. Run it from the repo root, in the background, and wait for it to finish (no `sleep`); a round takes a few minutes. The script reviews committed work in a throwaway worktree, pins the base on round 1 (rerunning round 1 starts over), and tells the reviewer the round number (and on round 3, that it is the last).

**In T3 Code** (`delegate_task` available), delegate instead, so the review is visible and wakes you:
- Pick the reviewer's model from `orchestrator_capabilities` (gpt-6.1-sol medium, or claude-opus-5-5); if it isn't listed, ask rather than substitute.
- Build every round's prompt with `cross-review.sh --prompt-only <same args>` and pass that text itself as the task: tool arguments aren't shell-expanded, so `$(cat …)` or placeholders arrive literally. Use `mode: "async"` and one `clientRequestId` per round, reused on retries. End your turn; don't edit or commit until it completes.
- Read it with `task_status`. Accept it only if it completed with review text and `cross-review.sh --verify <round>` passes; otherwise stop and investigate.

If a review fails (CLI missing, auth, rate limit, failed or empty task), ask the user whether to switch reviewer or skip; never treat it as `NO FINDINGS`. Before falling back from a delegated review to the CLI, make sure that task is finished or cancelled.

Round 1 prompt:

```
Goal: <one paragraph>.
Spec: <plan path; or the issue's number, title and requirements pasted in; or "none">.
Review two axes separately:
- Spec: does the change do what the spec asks, correctly? Missing or partial requirements,
  behavior nobody asked for, correctness bugs, security issues, broken edge cases,
  missing tests for real behavior.
- Standards: does it follow this repo's documented rules? Read AGENTS.md, CLAUDE.md,
  CODING_STANDARDS.md and CONTRIBUTING.md where present and cite the file and rule.
  Also flag needless complexity.
Skip lint-level nits and anything tooling already enforces.
Output: under `## Spec` and `## Standards`, numbered across both,
`N. [high|medium|low] file:line - what breaks - suggested fix`; write `none` under an empty heading.
If both are empty, output exactly NO FINDINGS.
```

Paste the issue's requirements rather than only its number: the reviewer runs without network or `gh`.

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

Only after cross-review: push, then `gh pr create --base <base> --body-file <a fresh mktemp file>` (`--draft` only if asked). Body:
- **Summary:** what and why in a line or two, then the smallest visual that makes the change clear: a diff sketch, call tree, file tree, pseudocode, or Mermaid diagram. Skip the visual for a trivial change.
- **Spec:** plan path or issue link (`Closes #N` when the PR resolves it), if any.
- **Evidence:** before and after: the test or command that failed and now passes, its output, or a screenshot for a visual change. List the commands run.
- **Merge danger:** one-way or two-way door (can it be rolled back cheaply?), and blast radius (what could break, and for whom).
- **Cross-review:** reviewer and model (the script output's first line, or the delegated target); per round, fixed and declined (with reason). Mark fixes made after the last round you ran as "not re-reviewed".
- **Follow-ups:** leftover findings, or "none".

## 4. Baby-sit

Run the `baby-sit` skill on the new PR, then report its result with the PR URL.
