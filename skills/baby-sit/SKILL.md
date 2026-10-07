---
name: baby-sit
description: Watch a GitHub PR and keep fixing it until it is green and ready to merge - CI, review-bot comments (CodeRabbit, Greptile, cubic, Copilot), nested thread replies, and human comments. Use when the user says "babysit", "watch the PR", "until PR is green", "CI is failing", or "address the review comments", and at the end of raise-pr.
---

# Baby-sit a PR

Never merge or close the PR, rebase, or force push unless the user asked. Merging the base branch into the PR branch (below) is fine.

`pr-status.sh` lives in this skill's `scripts/` directory; run it from the repo root. It checks the PR once and prints JSON with a `nextAction`. It never decides how you wait; that depends on where you run (see **Waiting**).

## Setup

1. Pin the PR number `N` and pass it to every command.
2. `gh pr checkout N`. If tracked files have changes you didn't make, stop and ask.
3. Pick your waiting mode (below) and run the first check.

## Each check

Run `scripts/pr-status.sh N` and act on `nextAction`:

| `nextAction` | Do |
|---|---|
| `fix` | Handle every item in `blockers.agent` (below), push, reply, `--record round`, then wait |
| `wait` | Wait (see **Waiting**). `blockers.wait` says for what. Keep waiting even if `blockers.human` has items; report them when `nextAction` changes, not before |
| `ask-user` | Read `botComments` and `botRepliesOnResolved` first; if you reopened a thread, check again. Otherwise stop and report `blockers.human` |
| `done` | Same reads as `ask-user`, then the final report |
| `stop` | PR merged or closed; report |
| `error` | GitHub failed 3 times. Wait and check once more; if it fails again, stop and report |

`done` already means CI passed on the head commit and every review bot (`reviewBots`) reviewed that commit. Don't declare the PR green from `gh pr checks` or from a bot review on an older commit.

## Waiting

Use the first mode your environment supports, and say which one you're using in your first progress line.

1. **A PR watch tool exists** (T3 Code's `watch_pull_request`): call it once. On a `wait` with `wakeOnEvent: true`, end your turn; the watcher wakes you when checks finish, someone comments or reviews, or the branch conflicts. On each wake, run one check and act on it. Before the final report, call `unwatch_pull_request`.
   - `wakeOnEvent: false` means the wait may end on a timer, not on a PR event: CI that hasn't registered, a review bot that may stay silent, or a bot check that may never finish. The watcher can't wake you for that, so wait with mode 2 if your harness supports it, otherwise mode 3, while the watch stays on.
2. **Background commands wake you when they finish** (Claude Code): run `scripts/pr-status.sh --wait N` in the background and end your turn. On `waitResult: still-waiting`, start it again.
3. **Neither** (e.g. Codex or a plain CLI): run `scripts/pr-status.sh --wait N` in the foreground; it returns within 9 minutes. Repeat on `still-waiting`, at most 6 times in a row. Then stop and report the status, and tell the user to ask again later.

Never end a turn while saying you are babysitting unless mode 1 or 2 will wake you. Don't write your own `sleep` / `gh pr checks --watch` loops; `--wait` already polls cheaply and returns on anything new.

In every mode, if `tellUserNow` is not empty (e.g. a deployment waiting for approval), tell the user in one line right away and keep going with the rest.

## Handling blockers

- **Checks:** `kind: actions`: run `gh run view <runId> --log-failed` and fix the cause. For obvious infra flakes, run `gh run rerun <runId> --failed` once. `kind: external`: open its `url`. Checks in `checksAwaitingApproval` need a person; never approve them yourself.
- **Feedback:** `threadsToAddress`, `newReviews`, and `newComments`. Read whole threads, because later replies can change the ask. If `truncated`, fetch the full body: `gh api repos/{owner}/{repo}/{issues/comments|pulls/comments}/<id>` or `.../pulls/N/reviews/<id>`. Verify each item against the code. Fix the valid ones at the root cause; decline the rest with a one-line reason.
- **Bot top-level comments** (`botComments`, not blocking): walkthroughs, "review in progress", previews, rate-limit notes. Read them each check, since a few carry real findings; handle those like feedback. List all their ids in your next PR comment's marker so they stop showing up.
- **Bot replies on resolved threads** (`botRepliesOnResolved`, not blocking): read them every check (fetch `truncated` ones in full). If one pushes back or raises something new, reopen the thread so it moves to `threadsToAddress`, and run `--record reopen <threadId>`: `gh api graphql -f query='mutation($id:ID!){unresolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<threadId>`. Never reopen a thread listed in `session.reopenedThreads`; leave it resolved, add the reply's id to your PR comment's marker, and report it under `Bot follow-ups`. Confirmations need no reply; list their ids in your next PR comment's marker.
- **Bot acknowledgements anywhere** ("thanks", "confirmed", "LGTM"): never reply in the thread, since bots answer replies and that loops. Add their ids to your PR comment's marker instead.
- **Review bot behind** (`reviewBots[].reviewedHead` false): wait while it is in `blockers.wait`. When it moves to `blockers.human`, you may ask it to review once per head commit (`@coderabbitai review`, `@greptileai review`, `@cubic-dev-ai review`) and run `--record rereview <bot-login>`; skip this if `rereviewRequested` is already true. Each request can use up the bot's quota.
- **Local checkout:** follow the blocker text. If it's `diverged` or has changes you didn't make, stop and ask.
- **Conflicts / behind base:** `git fetch <local.baseRemote> <base> && git merge <local.baseRemote>/<base>`.

Then run lint, typecheck and tests, commit (`fix: address review feedback (round N)`), and push.

### Replying: the marker rule

End **everything** you post with a marker as its very last line, or the item is never counted as handled:
- **Threads:** `gh api repos/{owner}/{repo}/pulls/N/comments/<replyTo>/replies -f body=$'<what you did>\n\n<marker>'`, using the thread's `marker`.
- **Reviews and comments:** one `gh pr comment N --body-file <file>` covering all of them, ending with `summaryMarker` (it already includes `botComments`). Add the ids of bot acknowledgements you skipped (`handled:<summary ids>,<ack ids>`).
- **Anything else:** `<!-- baby-sit -->`.

Resolve each bot thread **right after** replying in it (same round, not waiting for `threadsToResolve`); bots edit their comments once answered, and an open thread would pick that up. Also resolve `threadsToResolve` and human threads you fixed. Leave human threads you declined open:
`gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<thread-id>`

## Stop and ask when

- a comment needs a product decision or contradicts the user
- the same check fails 3 rounds in a row
- a human disagrees with your reply
- `session.rounds` reaches 8 (it survives new sessions; it is not reset)

Keep progress updates to 1-2 lines per check.

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
