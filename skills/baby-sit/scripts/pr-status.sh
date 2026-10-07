#!/usr/bin/env bash
# Usage: pr-status.sh [pr-number]                       one check, prints JSON (pr defaults to the current branch's PR)
#        pr-status.sh --wait [pr-number]                polls until nextAction is no longer "wait", at most WAIT_SECS
#        pr-status.sh --record <event> [value] [pr]     remembers a decision across turns and sessions:
#                                                       round | rereview <bot-login> | reopen <thread-id>
#
# Prints one JSON object describing everything between the PR and merge, and a
# `nextAction`: fix | wait | ask-user | done | stop | error.
#
# "done" needs CI and every review bot to have finished on the current head commit:
#   - no checks on a head first seen under NO_CHECKS_GRACE (default 150s) ago is a wait, since
#     CI may not have registered yet; after that a repo without CI is fine.
#   - review bots are the bots that reviewed this PR or one of the repo's last 10 merged PRs
#     (cached for a day; BABYSIT_IGNORE_BOTS=login,login skips some). A bot is current when it
#     reviewed the head commit, commented in a thread since the head appeared, or its check run
#     passed on the head. A bot that is not current is a wait for BOT_GRACE (default 900s) after
#     the head appeared or a re-review was recorded, then a question for the user.
#   - checks waiting for a manual approval, or running over CHECK_STUCK_SECS (default 3600s),
#     are questions for the user.
#
# --wait  POLL_SECS (default 45) between checks, WAIT_SECS (default 540) in total so it fits in
#         one tool call. Adds waitResult: changed | still-waiting. Run it again on still-waiting.
#
# GitHub calls are retried 3 times. If they still fail, nextAction is "error" (exit 1).
#
# State lives in BABYSIT_STATE_DIR (default ~/.local/state/baby-sit), shared by every agent.
# Env: GH_REPO=owner/repo to run outside a clone. MAX_BODY (default 6000) caps comment text;
#      clipped items have truncated=true and must be fetched in full before handling.
#
# Everything the baby-sit skill posts ends with one marker, from the viewer's own account:
#   <!-- baby-sit handled:<ids> -->   answered these comment/review ids
#   <!-- baby-sit -->                 anything else
# An item counts as handled when a later marker lists its id and it hasn't been edited since.
set -euo pipefail

MODE=status EVENT="" VALUE=""
case "${1:-}" in
  --wait) MODE=wait; shift ;;
  --record)
    MODE=record; EVENT="${2:?usage: --record round|rereview <bot>|reopen <thread-id> [pr]}"; shift 2
    case "$EVENT" in
      round) ;;
      rereview|reopen) VALUE="${1:?--record $EVENT needs a value}"; shift ;;
      *) echo "unknown event: $EVENT" >&2; exit 2 ;;
    esac ;;
esac

# runs a command up to 3 times; GitHub's API has transient 502s and secondary rate limits
retry() {
  local i
  for i in 1 2 3; do
    if "$@"; then return 0; fi
    (( i < 3 )) && sleep $((i * ${RETRY_DELAY:-3}))
  done
  return 1
}

PR="${1:-$(retry gh pr view --json number -q .number)}"
REPO="${GH_REPO:-$(retry gh repo view --json nameWithOwner -q .nameWithOwner)}"
OWNER="${REPO%/*}"; NAME="${REPO#*/}"
MAX_BODY="${MAX_BODY:-6000}"
WAIT_SECS="${WAIT_SECS:-540}"
POLL_SECS="${POLL_SECS:-45}"
NO_CHECKS_GRACE="${NO_CHECKS_GRACE:-150}"
BOT_GRACE="${BOT_GRACE:-900}"
CHECK_STUCK_SECS="${CHECK_STUCK_SECS:-3600}"
STATE_DIR="${BABYSIT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/baby-sit}"
PR_STATE="$STATE_DIR/${REPO//\//_}-$PR.json"
REPO_STATE="$STATE_DIR/${REPO//\//_}.json"

now() { echo "${BABYSIT_NOW:-$(date +%s)}"; }
read_state() { jq -c 'if type == "object" then . else {} end' "$1" 2>/dev/null || echo '{}'; }
write_state() {  # stdin -> $1, atomically
  mkdir -p "$STATE_DIR"
  local tmp; tmp="$(mktemp "$STATE_DIR/.tmp.XXXXXX")"
  cat > "$tmp" && mv "$tmp" "$1"
}

if [[ $MODE == record ]]; then
  next="$(read_state "$PR_STATE" | jq --arg e "$EVENT" --arg v "$VALUE" --argjson now "$(now)" '
    if $e == "round" then .rounds = ((.rounds // 0) + 1)
    elif $e == "reopen" then .reopened = ((.reopened // []) + [$v] | unique)
    elif .lastHead == null then error("run pr-status.sh once before recording a re-review")
    else .rereview[.lastHead][$v] = $now end')"
  write_state "$PR_STATE" <<<"$next"
  echo "$next"
  exit
fi

QUERY='
query($owner:String!,$name:String!,$pr:Int!){
  viewer{login}
  repository(owner:$owner,name:$name){
    pullRequest(number:$pr){
      number url state isDraft headRefName headRefOid baseRefName isCrossRepository
      mergeable mergeStateStatus reviewDecision
      commits(last:1){nodes{commit{oid statusCheckRollup{state
        contexts(first:100){totalCount nodes{
          ... on CheckRun{__typename name status conclusion detailsUrl}
          ... on StatusContext{__typename context state targetUrl}
        }}}}}}
      reviewThreads(first:100){totalCount nodes{id isResolved isOutdated path line originalLine
        comments(first:100){totalCount nodes{databaseId author{login __typename} body createdAt lastEditedAt}}}}
      reviews(last:100){totalCount nodes{databaseId author{login __typename} state body submittedAt lastEditedAt commit{oid}}}
      comments(last:100){totalCount nodes{databaseId author{login __typename} body createdAt lastEditedAt}}
    }}}'

# logins of bots that reviewed one of the repo's last 10 merged PRs, cached for a day
repo_bots() {
  local cached out
  cached="$(read_state "$REPO_STATE" | jq -c --argjson now "$(now)" 'select(.botsAt != null and $now - .botsAt < 86400) | .bots')"
  if [[ -n "$cached" ]]; then echo "$cached"; return; fi
  if out="$(retry gh api graphql -F owner="$OWNER" -F name="$NAME" -f query='
      query recentBotCheck($owner:String!,$name:String!){
        repository(owner:$owner,name:$name){
          pullRequests(last:10, states:MERGED){nodes{reviews(first:50){nodes{author{login __typename}}}}}}}' 2>/dev/null)" &&
     out="$(jq -c '[.data.repository.pullRequests.nodes[].reviews.nodes[].author | select(.__typename == "Bot") | .login] | unique' <<<"$out")"; then
    read_state "$REPO_STATE" | jq --argjson b "$out" --argjson now "$(now)" '.bots = $b | .botsAt = $now' | write_state "$REPO_STATE"
    echo "$out"
  else
    echo '[]'  # not cached, so the next call tries again
  fi
}

# How the local checkout relates to the PR head: same | ahead | behind | diverged | missing
local_state() {
  local head="$1"
  if ! git rev-parse --git-dir >/dev/null 2>&1; then echo null; return; fi
  local sha rel ahead=0 base_remote
  sha="$(git rev-parse HEAD)"
  if [[ "$sha" == "$head" ]]; then rel=same
  elif ! git cat-file -e "$head^{commit}" 2>/dev/null; then rel=missing
  elif git merge-base --is-ancestor "$head" HEAD; then rel=ahead; ahead="$(git rev-list --count "$head..HEAD")"
  elif git merge-base --is-ancestor HEAD "$head"; then rel=behind
  else rel=diverged; fi
  # the local remote that points at the PR's repository (for forks this is usually "upstream")
  base_remote="$(git remote -v | grep -iE "[:/]${REPO}(\.git)?[[:space:]]" | head -1 | cut -f1 || true)"
  # untracked files (build output, scratch notes) are reported but do not block
  jq -n --arg branch "$(git rev-parse --abbrev-ref HEAD)" --arg sha "$sha" --arg rel "$rel" \
    --argjson ahead "$ahead" \
    --argjson dirty "$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" \
    --argjson untracked "$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')" \
    --arg baseRemote "$base_remote" \
    '{branch:$branch, sha:$sha, relation:$rel, unpushed:$ahead, dirty:$dirty, untracked:$untracked,
      repoMatches:($baseRemote != ""), baseRemote:(if $baseRemote == "" then null else $baseRemote end)}'
}

status() {
  local raw head t state bots
  raw="$(retry gh api graphql -F owner="$OWNER" -F name="$NAME" -F pr="$PR" -f query="$QUERY")" || return 1
  head="$(jq -er .data.repository.pullRequest.headRefOid <<<"$raw")" || return 1
  t="$(now)"
  # remember when each head commit first showed up; grace periods count from there
  state="$(read_state "$PR_STATE" | jq -c --arg h "$head" --argjson now "$t" '.heads[$h] //= $now | .lastHead = $h')"
  write_state "$PR_STATE" <<<"$state"
  bots="$(repo_bots)"
  jq --argjson max "$MAX_BODY" --arg repo "$REPO" --argjson now "$t" --argjson state "$state" \
     --argjson repoBots "$bots" --arg ignoreBots "${BABYSIT_IGNORE_BOTS:-}" \
     --argjson noChecksGrace "$NO_CHECKS_GRACE" --argjson botGrace "$BOT_GRACE" --argjson stuck "$CHECK_STUCK_SECS" \
     --argjson local "$(local_state "$head")" '
  .data.viewer.login as $viewer
  | .data.repository.pullRequest as $p
  | $p.commits.nodes[0].commit as $head
  | ($state.heads[$p.headRefOid]) as $headSince
  | ($now - $headSince) as $headAge
  | ($headSince | todate) as $headSinceIso
  | "<!-- baby-sit(?: handled:(?<ids>[0-9,]+))? -->\\s*$" as $re
  | def mine: ((.author.login // "") == $viewer) and ((.body // "") | test($re));
    def marker: (.body | capture($re));
    def mins: (. / 60 | floor | tostring) + "m";
    # normalized item; `mine` is computed from the full, unclipped body
    def c: {id:.databaseId, by:(.author.login // "ghost"), bot:(.author.__typename == "Bot"),
            at:(.createdAt // .submittedAt), edited:(.lastEditedAt // .createdAt // .submittedAt), mine:mine,
            truncated:((.body // "") | length > $max),
            body:((.body // "") | if length > $max then .[0:$max] + " …[truncated]" else . end)};

    # id -> time of the latest marker (from the raw, unclipped bodies) that handled it
    ([$p.reviewThreads.nodes[].comments.nodes[]] + $p.comments.nodes | map(select(mine))) as $oursRaw
  | (reduce ($oursRaw[] | .createdAt as $at | (marker.ids // "") | split(",")[] | select(length > 0) | {k:., at:$at}) as $h
       ({}; .[$h.k] = ([.[$h.k] // "", $h.at] | max))) as $handledAt
  | def unhandled: (.mine | not) and ((.id | tostring) as $k | ($handledAt[$k] == null) or (.edited > $handledAt[$k]));
    def editedAfterHandled: (.id | tostring) as $k | $handledAt[$k] != null and .edited > $handledAt[$k];
    # bots rewrite summaries and answered comments ("✅ addressed", a refreshed walkthrough) all the
    # time; outside open review threads, a bot edit to something already handled is never new work
    def newToUs: unhandled and ((.bot and editedAfterHandled) | not);
    # when baby-sit first posted on this PR; resolved-thread activity before it is history
    ([$oursRaw[].createdAt] | min) as $since

  | [ $p.reviewThreads.nodes[]
      | .isResolved as $resolved
      | (.comments.nodes | sort_by(.createdAt) | map(c)) as $cs
      | ([$cs | to_entries[] | select(.value.mine) | .key] | max) as $lastOurs
      | {id, resolved:$resolved, outdated:.isOutdated, path, line:(.line // .originalLine),
         total:.comments.totalCount, replyTo:$cs[0].id, botThread:$cs[0].bot, comments:$cs,
         # on resolved threads bots edit their comments ("✅ addressed") and reply to confirm
         # fixes; counting those would loop forever. So there, bot edits and bot replies do
         # not block; new bot replies are listed in botRepliesOnResolved for the agent to read.
         # On open threads a bot edit can be a rewritten finding, so it still counts.
         # resolved threads count only: human replies after our last answer, human edits to
         # handled items, and anything humans posted after baby-sit started on this PR
         unhandled:[ $cs | to_entries[]
                     | select(.value | unhandled and (($resolved and .bot and editedAfterHandled) | not))
                     | select(($resolved and .value.bot) | not)
                     | select(($resolved | not)
                              or ($lastOurs != null and .key > $lastOurs)
                              or (.value | editedAfterHandled)
                              or ($since != null and .value.at > $since))
                     | .value.id ],
         # same window as unhandled above, for the bot comments it leaves out; only comments
         # no marker ever covered, so a bot editing a handled comment does not resurface it
         botReplies:[ if $resolved then
                        $cs | to_entries[]
                        | select(.value.bot and (.value.mine | not) and $handledAt[.value.id | tostring] == null
                                 and (($lastOurs != null and .key > $lastOurs) or ($since != null and .value.at > $since)))
                        | .value
                      else empty end ]}
    ] as $threads

  | ($head.statusCheckRollup.contexts.nodes // [] | map(
      {name:(.name // .context), url:(.detailsUrl // .targetUrl),
       kind:(if ((.detailsUrl // "") | test("/actions/runs/")) then "actions" else "external" end),
       runId:((.detailsUrl // "") | capture("/actions/runs/(?<id>[0-9]+)").id // null),
       # a job held by an environment protection rule, or a run that needs someone to approve it
       approval:(.status == "WAITING" or .conclusion == "ACTION_REQUIRED"),
       passed:(.conclusion == "SUCCESS" or .state == "SUCCESS"),
       skipped:(.conclusion == "SKIPPED" or .conclusion == "NEUTRAL"),
       pending:((.__typename == "CheckRun" and .status != "COMPLETED" and .status != "WAITING") or .state == "PENDING" or .state == "EXPECTED"),
       failed:((.conclusion as $x | ["FAILURE","TIMED_OUT","CANCELLED","STARTUP_FAILURE"] | index($x) != null)
               or .state == "FAILURE" or .state == "ERROR")})) as $checks
  | ($head.statusCheckRollup.state // "NONE") as $ci

  # review bots: bots that reviewed this PR or recent merged PRs
  | ($ignoreBots | split(",") | map(select(length > 0))) as $ignored
  | ([$p.reviews.nodes[] | select(.author.__typename == "Bot") | .author.login] + $repoBots | unique - $ignored) as $reviewBots
  # "coderabbitai" -> "coderabbit", "cubic-dev-ai" -> "cubic", "greptile-apps" -> "greptile"; matches check names
  | def botKey: ascii_downcase | sub("\\[bot\\]$"; "") | split("-")[0] | sub("ai$"; "");
    def botCheck($b): ($b | botKey) as $k | if ($k | length) < 4 then [] else [$checks[] | select(.name | ascii_downcase | contains($k))] end;
    def rereviewAt($b): $state.rereview[$p.headRefOid][$b] // 0;
    [ $reviewBots[] as $b
      | (botCheck($b)) as $bc
      | {bot:$b,
         reviewedHead:(
           any($p.reviews.nodes[]; .author.login == $b and .commit.oid == $p.headRefOid)
           or any($p.reviewThreads.nodes[].comments.nodes[]; .author.login == $b and .createdAt > $headSinceIso)
           or any($bc[]; .passed)),
         skippedHead:any($bc[]; .skipped),
         rereviewRequested:(rereviewAt($b) > 0),
         waitedSecs:($now - ([$headSince, rereviewAt($b)] | max))} ] as $bots
  | [ $bots[] | select(.reviewedHead | not) ] as $botsBehind

  | [ $p.reviews.nodes[] | select(.state != "PENDING")
      | select((.body // "") != "" or .state == "CHANGES_REQUESTED")
      | (c + {state, onHead:(.commit.oid == $head.oid)}) | select(newToUs) ] as $newReviews
  | [ $p.comments.nodes[] | c | select(newToUs) ] as $topLevel
  | [ $topLevel[] | select(.bot | not) ] as $newComments
  # walkthroughs, "review in progress", previews, rate-limit notes: read, never blocking
  | [ $topLevel[] | select(.bot) ] as $botComments

  | {
      pr: $p.number, url: $p.url, state: $p.state, draft: $p.isDraft,
      base: $p.baseRefName, branch: $p.headRefName, head: $p.headRefOid, crossRepo: $p.isCrossRepository,
      headAgeSecs: $headAge,
      local: (if $local == null then null else $local + {branchMatches:($local.branch == $p.headRefName)} end),
      mergeable: $p.mergeable, mergeState: $p.mergeStateStatus, reviewDecision: $p.reviewDecision,
      ci: $ci,
      checksPending: [$checks[] | select(.pending) | .name],
      checksFailed: [$checks[] | select(.failed) | {name, url, kind, runId}],
      checksAwaitingApproval: [$checks[] | select(.approval) | {name, url}],
      checksSkipped: [$checks[] | select(.skipped) | .name],
      reviewBots: $bots,
      threadsToAddress: [$threads[] | select(.unhandled | length > 0)
                         | . + {marker:"<!-- baby-sit handled:\(.unhandled | map(tostring) | join(",")) -->"}],
      # never auto-resolve a thread with replies we could not read
      threadsToResolve: [$threads[] | select((.resolved | not) and (.unhandled | length == 0) and .botThread and .total <= 100) | {id, path, line}],
      threadsAwaitingHumans: [$threads[] | select((.resolved | not) and (.unhandled | length == 0) and (.botThread | not)) | {id, path, line, lastBy:.comments[-1].by}],
      newReviews: $newReviews,
      newComments: $newComments,
      botComments: $botComments,
      botsSeen: ([$threads[].comments[], ($p.comments.nodes[] | c), ($p.reviews.nodes[] | c)] | any(.bot)),
      summaryMarker: ([$newReviews[].id, $newComments[].id, $botComments[].id]
                      | if length > 0 then "<!-- baby-sit handled:\(map(tostring) | join(",")) -->" else null end),
      # not blocking: read each; reopen the thread if it is pushback, ignore confirmations
      botRepliesOnResolved: [$threads[] | select(.botReplies | length > 0)
                             | {threadId:.id, path, line, replies:[.botReplies[] | {id, by, at, truncated, body}]}],
      session: {rounds:($state.rounds // 0), reopenedThreads:($state.reopened // [])},
      incomplete: [
        (([$threads[] | select(.total > 100)] | length) as $n | if $n > 0 then "\($n) threads have over 100 replies; only the first 100 were read" else empty end),
        (if $p.reviewThreads.totalCount > 100 then "only the first 100 of \($p.reviewThreads.totalCount) threads were checked" else empty end),
        (if $p.reviews.totalCount > 100 then "only the last 100 of \($p.reviews.totalCount) reviews were checked" else empty end),
        (if $p.comments.totalCount > 100 then "only the last 100 of \($p.comments.totalCount) comments were checked" else empty end),
        (if ($head.statusCheckRollup.contexts.totalCount // 0) > 100 then "only the first 100 checks were listed" else empty end)
      ]
    }
  | ($headAge > $stuck and (.checksPending | length) > 0) as $stuckChecks
  | .blockers = {
      agent: [
        (if .local == null then empty
         elif (.local.repoMatches | not) then "local checkout is not a clone of \($repo)"
         elif (.local.branchMatches | not) then "local checkout is on \(.local.branch), not \(.branch)"
         elif .local.relation == "ahead" then "\(.local.unpushed) unpushed local commits"
         elif .local.relation == "behind" then "local branch is behind the PR head; git pull"
         elif .local.relation == "diverged" then "local branch diverged from the PR head"
         elif .local.relation == "missing" then "PR head commit not in local repo; git fetch"
         else empty end),
        (if .local != null and .local.dirty > 0 then "\(.local.dirty) uncommitted local changes" else empty end),
        ((.checksFailed | length) as $n | if $n > 0 then "\($n) failed checks" else empty end),
        (if (.checksFailed | length) == 0 and (.checksAwaitingApproval | length) == 0 and ($ci == "FAILURE" or $ci == "ERROR") then "CI reports \($ci | ascii_downcase) but the failing check is not listed" else empty end),
        ((.threadsToAddress | length) as $n | if $n > 0 then "\($n) threads need a response" else empty end),
        ((.threadsToResolve | length) as $n | if $n > 0 then "\($n) answered bot threads to resolve" else empty end),
        ((.newReviews | length) as $n | if $n > 0 then "\($n) new or edited review summaries" else empty end),
        ((.newComments | length) as $n | if $n > 0 then "\($n) new or edited PR comments" else empty end),
        (if .mergeable == "CONFLICTING" or .mergeState == "DIRTY" then "merge conflicts with \(.base)" else empty end),
        (if .mergeState == "BEHIND" then "branch is behind \(.base) and must be updated" else empty end)
      ],
      wait: [
        (if $stuckChecks then empty else
          ((.checksPending | length) as $n | if $n > 0 then "\($n) checks running" else empty end),
          (if (.checksPending | length) == 0 and (.checksAwaitingApproval | length) == 0 and ($ci == "PENDING" or $ci == "EXPECTED") then "CI is pending" else empty end)
        end),
        (if $ci == "NONE" and $headAge < $noChecksGrace then "no checks reported on \(.head[0:7]) yet" else empty end),
        ($botsBehind[] | select(.waitedSecs < $botGrace) | "waiting for \(.bot) to review \($p.headRefOid[0:7])"),
        (if .mergeable == "UNKNOWN" or .mergeState == "UNKNOWN" then "GitHub is still computing mergeability" else empty end)
      ],
      human: ([
        (.checksAwaitingApproval[] | "check \(.name) is waiting for someone to approve it"),
        (if $stuckChecks then "\(.checksPending | length) checks still running after \($headAge | mins): \(.checksPending | join(", "))" else empty end),
        ($botsBehind[] | select(.waitedSecs >= $botGrace)
         | "\(.bot) has not reviewed \($p.headRefOid[0:7]) after \(.waitedSecs | mins)"
           + (if .skippedHead then " (its check was skipped)" else " (skipped, out of quota, or needs a trigger)" end)),
        (if .reviewDecision == "REVIEW_REQUIRED" then "awaiting required approval" else empty end),
        (if .reviewDecision == "CHANGES_REQUESTED" then "changes requested; reviewer must re-review or dismiss" else empty end),
        ((.threadsAwaitingHumans | length) as $n | if $n > 0 then "\($n) answered human threads still open" else empty end),
        (if .draft then "PR is a draft" else empty end)
      ] + .incomplete)
    }
  | if .mergeState == "BLOCKED" and ([.blockers[][]] | length) == 0
    then .blockers.human += ["blocked by branch protection (required checks, approvals, or signed commits)"] else . end
  | .ready = (.state == "OPEN" and ([.blockers[][]] | length) == 0)
  | .nextAction = (if .state != "OPEN" then "stop"
                   elif (.blockers.agent | length) > 0 then "fix"
                   elif (.blockers.wait | length) > 0 then "wait"
                   elif (.blockers.human | length) > 0 then "ask-user"
                   else "done" end)' <<<"$raw"
}

failed() { jq -n --arg pr "$PR" '{pr:($pr | tonumber? // $pr), nextAction:"error", error:"GitHub API calls failed 3 times; check `gh auth status` and try again"}'; }

if [[ $MODE == status ]]; then
  if out="$(status)"; then echo "$out"; else failed; exit 1; fi
  exit
fi

# --wait: an error is retried like a wait until the time runs out
start=$SECONDS
while :; do
  out="$(status)" || out="$(failed)"
  next="$(jq -r .nextAction <<<"$out")"
  [[ $next == wait || $next == error ]] && (( SECONDS - start + POLL_SECS < WAIT_SECS )) || break
  sleep "$POLL_SECS"
done
case "$next" in
  wait|error) result=still-waiting ;;
  *) result=changed ;;
esac
jq --arg r "$result" --argjson s $((SECONDS - start)) '. + {waitResult:$r, waitedSecs:$s}' <<<"$out"
[[ $next != error ]]
