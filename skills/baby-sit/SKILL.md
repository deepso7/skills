---
name: baby-sit
description: Watch a GitHub PR and keep fixing it until it is green and ready to merge - CI, review-bot comments (CodeRabbit, Greptile, cubic, Copilot), nested thread replies, and human comments. Use when the user says "babysit", "until PR is green", "CI is failing", or "address the review comments", and at the end of raise-pr.
---

# Baby-sit a PR

Never merge or close the PR, rebase, or force push unless the user asked. Merging the base branch into the PR branch (below) is fine.

`pr-status.sh` lives in this skill's `scripts/` directory; run it from the repo root.

## Setup

1. Pin the PR number `N` and pass it to every command.
2. `gh pr checkout N`. If the worktree isn't clean, stop and ask.
3. Start with `scripts/pr-status.sh --wait N` (run in the background).

## Loop

`scripts/pr-status.sh [--wait] N` returns JSON. Act on `nextAction`:

| `nextAction` | Do |
|---|---|
| `fix` | Handle every item in `blockers.agent` (below), then push, reply, and run `--wait` |
| `wait` | Run `--wait` |
| `ask-user` | Read `botRepliesOnResolved` first (below); if you reopened a thread, run status again instead. Otherwise stop and report `blockers.human` |
| `done` | Read `botRepliesOnResolved` first; if you reopened a thread, run status again instead. Otherwise final report |
| `stop` | PR merged or closed; report |

`--wait` returns `waitResult`: `settled` (CI done, bots had time to post; the 5-minute bot wait is skipped if no bot has posted on this PR and none posted on the repo's recent PRs), `actionable` (work arrived mid-CI; handle it now), or `timed-out` (stuck check; stop and ask).

### Handling blockers

- **Checks:** `kind: actions`: run `gh run view <runId> --log-failed` and fix the cause. For obvious infra flakes, run `gh run rerun <runId> --failed` once. `kind: external`: open its `url`.
- **Feedback:** `threadsToAddress`, `newReviews`, and `newComments`. Read whole threads, because later replies can change the ask. If `truncated`, fetch the full body: `gh api repos/{owner}/{repo}/{issues/comments|pulls/comments}/<id>` or `.../pulls/N/reviews/<id>`. Verify each item against the code. Fix the valid ones at the root cause; decline the rest with a one-line reason.
- **Bot replies on resolved threads** (`botRepliesOnResolved`, not blocking): read them every round (fetch `truncated` ones in full). If one pushes back or raises something new, reopen the thread so it moves to `threadsToAddress`: `gh api graphql -f query='mutation($id:ID!){unresolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<threadId>`. Reopen a thread for a bot at most once; if it pushes back again, leave it resolved, add its id to your PR comment's marker (so the decision survives a new session), and report it under `Bot follow-ups`. Confirmations need no reply; list their ids in your next PR comment's marker (below) so they stop showing up.
- **Bot acknowledgements anywhere** ("thanks", "confirmed", "LGTM"): never reply in the thread, since bots answer replies and that loops. Add their ids to your PR comment's marker instead.
- **Local checkout:** follow the blocker text. If it's `diverged` or has changes you didn't make, stop and ask.
- **Conflicts / behind base:** `git fetch <local.baseRemote> <base> && git merge <local.baseRemote>/<base>`.

Then run lint, typecheck and tests, commit (`fix: address review feedback (round N)`), and push.

### Replying: the marker rule

End **everything** you post with a marker as its very last line, or the item is never counted as handled:
- **Threads:** `gh api repos/{owner}/{repo}/pulls/N/comments/<replyTo>/replies -f body=$'<what you did>\n\n<marker>'`, using the thread's `marker`.
- **Reviews and comments:** one `gh pr comment N --body-file <file>` covering all of them, ending with `summaryMarker`. List noise (previews, walkthroughs) in it too, and add the ids of bot acknowledgements you skipped (`handled:<summary ids>,<ack ids>`).
- **Anything else:** `<!-- baby-sit -->`.

Resolve each bot thread **right after** replying in it (same round, not waiting for `threadsToResolve`), so later bot replies there don't block. Also resolve `threadsToResolve` and human threads you fixed. Leave human threads you declined open:
`gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<thread-id>`

## Stop and ask when

- a comment needs a product decision or contradicts the user
- the same check fails 3 rounds in a row
- a human disagrees with your reply
- you reach 8 rounds

Keep progress updates to 1-2 lines per round.

## Final report

```
PR:        <url>
Status:    READY / WAITING ON <human blockers> / STOPPED - <why>
Rounds:    N (commits: <shas>)
Fixed:     <one line each>
Declined:  <item - reason>
Bot follow-ups: <reopened / confirmations only / none>
Needs you: <approvals, decisions, or none>
```
