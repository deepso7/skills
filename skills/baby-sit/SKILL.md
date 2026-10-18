---
name: baby-sit
description: Watch one or more GitHub PRs and keep fixing them until green and ready to merge - CI, review-bot comments (CodeRabbit, Greptile, cubic, Copilot), nested thread replies, and human comments. Use whenever the user says "babysit", "watch the PR", "until PR is green", "CI is failing", "address the review comments", "fix and push to the PR", "merge when green", "is it merge ready", or "are the bot comments sorted", including as the last step of a bigger request, for several PRs at once, or for existing PRs you review and fix one by one; after any push to a PR you opened; and at the end of raise-pr.
---

# Baby-sit a PR

Never merge or close the PR, rebase, or force push unless the user asked. Merging the base branch into the PR branch is fine.

`<this skill's dir>/scripts/pr-status.sh N`, run from the repo root, checks PR `N` once and prints JSON with a `nextAction`. If that file is missing (the skill was loaded without its files), ask the user to install the skills; don't improvise the checks.

## Setup

Pin the PR number `N` and pass it last to every command (`pr-status.sh --record round N`). Several PRs: one baby-sit per PR. `gh pr checkout N`; if tracked files have changes you didn't make, stop and ask. Pick a waiting mode (below) and run the first check.

## Each check

| `nextAction` | Do |
|---|---|
| `fix` | Handle every item in `blockers.agent` (below), then check again |
| `wait` | Wait (see **Waiting**). Report `blockers.human` only once `nextAction` changes |
| `ask-user` | Read `botComments` and `botRepliesOnResolved` first; if you reopened a thread, check again. Otherwise stop and report `blockers.human` |
| `done` | Same reads as `ask-user`, then the final report |
| `stop` | PR merged or closed; report |
| `error` | Read `error`. Wait and check once more; if it fails again, stop and report |

`done` means no blockers on the head commit: CI passed (or none registered), and every review bot in `reviewBots` reviewed that commit. Only `pr-status.sh` is a check: a watch notification, `gh pr checks` or `gh pr view` is not, and may be about an older commit. If you filter its JSON, keep `nextAction`, `wakeOnEvent` and `tellUserNow`. Asked whether a PR is ready? Run one check and answer from it.

## Waiting

Use the first mode your environment supports and name it in your first progress line:

1. **A PR watch tool** (T3 Code's `watch_pull_request`): call it once, and `unwatch_pull_request` before the final report. On each wake, run one check.
2. **Background commands wake you** (Claude Code): run `pr-status.sh --wait N` with the tool's background option (not `&`); on `waitResult: still-waiting`, start it again.
3. **Neither** (Codex, plain CLI): run `pr-status.sh --wait N` in the foreground (returns within 9 minutes), at most 6 times in a row; then stop, report, and tell the user to ask again later.

In mode 1, end your turn on a `wait` only if the latest check says `wakeOnEvent: true`; otherwise also wait as in mode 2 (or 3). Never end a turn while babysitting unless something will wake you, and never write your own `sleep`, `gh run watch` or `gh pr checks --watch` loops. If `tellUserNow` is not empty, tell the user in one line in your next message, not at the final report, and keep going.

After a resume, compaction or server restart, earlier watches and background commands may be gone: call `watch_pull_request` again and restart `--wait`. Any push to the PR, even after the final report, means babysitting again.

## Handling blockers

- **Failed checks:** `kind: actions`: `gh run view <runId> --log-failed` and fix the cause; for an obvious infra flake, `gh run rerun <runId> --failed` once. `kind: external` (listed in `blockers.human`): open its `url`; fix it if the code caused it, otherwise report it. Never approve `checksAwaitingApproval` unless the user asks.
- **Feedback** (`threadsToAddress`, `newReviews`, `newComments`): read whole threads; later replies can change the ask. Fetch `truncated` bodies in full: `gh api repos/{owner}/{repo}/{issues/comments|pulls/comments}/<id>` or `.../pulls/N/reviews/<id>`. Verify each item against the code; fix valid ones at the root cause, decline the rest with a one-line reason.
- **Bot output that doesn't block** (`botComments`, `botRepliesOnResolved`): read it every check; a few carry real findings, handle those like feedback. If a bot reply on a resolved thread pushes back, reopen it (`gh api graphql -f query='mutation($id:ID!){unresolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<threadId>`) and `--record reopen <threadId>`, unless it is in `session.reopenedThreads`: then leave it and report it under `Bot follow-ups`.
- **Never reply to a bot acknowledgement** ("thanks", "confirmed", "LGTM"); bots answer replies and that loops. Put its id, and the ids of bot output and review summaries you read, in the marker of your next thread reply or PR comment; never post a comment just to carry a marker.
- **Review bot behind** (`reviewedHead: false`): wait while it is in `blockers.wait`. Once it is in `blockers.human`, you may ask it once per head commit (`@coderabbitai review`, `@greptileai review`, `@cubic-dev-ai review`) and `--record rereview <bot-login>`, unless `rereviewRequested` is true or its `skipReason` is a quota, plan or rate limit. Each request can use up the bot's quota.
- **Local checkout:** follow the blocker text; if it is `diverged` or has changes you didn't make, stop and ask.
- **Conflicts / behind base:** `git fetch <local.baseRemote> <base> && git merge <local.baseRemote>/<base>`.

If you changed code: run lint, typecheck and tests, commit (`fix: address review feedback (round N)`), push, and `--record round` (only for commits that fix feedback or CI). If the fix changes something the PR body describes, update it (`gh pr edit N --body-file`). Then reply.

### Replying: the marker rule

Write each body to a fresh `mktemp` file (shared names like `/tmp/pr-body.md` collide with other sessions). End **everything** you post with a marker as its very last line, or the item is never counted as handled:
- **Threads:** `gh api repos/{owner}/{repo}/pulls/N/comments/<replyTo>/replies -F body=@<file>`, the file holding what you did, then the thread's `marker`.
- **Reviews and comments:** one `gh pr comment N --body-file <file>` for all of them, ending with `summaryMarker` plus any ids from above (`handled:<ids>,<more ids>`).
- **Anything else:** `<!-- baby-sit -->`.

Resolve each bot thread right after replying in it (bots edit answered comments, and an open thread would pick that up), plus `threadsToResolve` and human threads you fixed. Leave human threads you declined open:
`gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<thread-id>`

## Stop and ask when

- a comment needs a product decision or contradicts the user
- the same check fails 3 rounds in a row
- a human disagrees with your reply
- `session.rounds` reaches 8 (it survives new sessions)

Keep progress updates to 1-2 lines per check.

## Final report

Run a check right before it, and after every later push. A check awaiting approval means WAITING ON, never READY.

```
PR:        <url>
Status:    READY / WAITING ON <human blockers> / STOPPED - <why>
Rounds:    N (commits: <shas>)
Fixed:     <one line each>
Declined:  <item - reason>
Bot follow-ups: <reopened / confirmations only / none>
Needs you: <approvals, decisions, or none>
```

If the only human blockers are review bots that skipped for a quota, plan or rate limit (or said no review was needed) and `mergeState` is not `BLOCKED`, the status is `READY (not reviewed by <bot>: <skipReason>)`.
