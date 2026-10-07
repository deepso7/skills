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
#     (cached for a day), plus known AI reviewers (CodeRabbit, Greptile, cubic, Copilot, ...) that
#     posted anything on this PR. BABYSIT_IGNORE_BOTS=login,login skips some. A bot is current when
#     it submitted a review of the head commit or its own check passed on the head. A bot that is
#     not current is a wait while its own check runs on the head (up to CHECK_STUCK_SECS), otherwise
#     for BOT_GRACE (default 900s) after the head appeared or a re-review was recorded; then it is a
#     question for the user.
#   - wakeOnEvent says whether the wait ends on a PR event (checks finishing) that a PR watcher
#     would report, or only on a timer. tellUserNow lists things a person must do right away.
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

GH_FAILED='GitHub API calls failed 3 times; check `gh auth status` and try again'
failed() { jq -n --arg pr "${PR:-}" --arg msg "$1" '{pr:($pr | tonumber? // $pr), nextAction:"error", error:$msg}'; }

PR="${1:-}"
if [[ -z $PR ]] && ! PR="$(retry gh pr view --json number -q .number)"; then
  failed "no PR found for the current branch, or $GH_FAILED"; exit 1
fi
if [[ -n ${GH_REPO:-} ]]; then REPO="$GH_REPO"
elif ! REPO="$(retry gh repo view --json nameWithOwner -q .nameWithOwner)"; then
  failed "could not tell which GitHub repo this is (set GH_REPO=owner/repo), or $GH_FAILED"; exit 1
fi
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
  local tmp
  tmp="$(mktemp "$STATE_DIR/.tmp.XXXXXX")" && cat > "$tmp" && mv "$tmp" "$1"
}
# take_lock <file>: creates it holding our pid, or fails if it exists. bash's noclobber opens it
# with O_EXCL, which is atomic on every platform. mkdir is not: uutils mkdir (Ubuntu 26.04) lets
# several racing processes all "create" the same directory. macOS has no flock.
take_lock() { ( set -C; echo $$ > "$1" ) 2>/dev/null; }
# break_lock <lock> <stale-owner>: removes a stale lock. Only one process may do it at a time, and
# only if the lock still has the owner it saw, so a lock someone else just took is never removed.
break_lock() {
  local lock="$1" seen="$2"
  if take_lock "$lock.break"; then
    # -r: a lock directory left by an older version of this script
    [[ "$(cat "$lock" 2>/dev/null || true)" == "$seen" ]] && rm -rf "$lock"
    rm -f "$lock.break"
  fi
  return 0
}
# update_state <file> <jq args...> <filter>: read, transform and write one state file while holding
# its lock, so concurrent agents and polls don't lose each other's updates. Prints the new state.
update_state() {
  local f="$1" lock="$1.lock" tries=0 owner next rc=0; shift
  if ! mkdir -p "$STATE_DIR" 2>/dev/null || [[ ! -w $STATE_DIR ]]; then
    echo "baby-sit: state dir $STATE_DIR is not writable" >&2; return 1
  fi
  # The lock file holds its owner's pid; if that process is gone, or no pid shows up within 10s,
  # the lock is stale. A live owner holding it for 20s is an error.
  until take_lock "$lock"; do
    owner="$(cat "$lock" 2>/dev/null || true)"
    if [[ -n $owner ]] && ! kill -0 "$owner" 2>/dev/null; then break_lock "$lock" "$owner"
    elif (( tries > 100 )) && [[ -z $owner ]]; then break_lock "$lock" ""
    fi
    if (( ++tries > 100 )); then
      # a breaker that died mid-way leaves $lock.break behind; a live one holds it for milliseconds
      (( tries == 101 )) && rm -f "$lock.break"
      if (( tries > 200 )); then echo "baby-sit: could not take $lock (held by ${owner:-no pid})" >&2; return 1; fi
    fi
    sleep 0.1
  done
  next="$(read_state "$f" | jq -c "$@")" || rc=$?
  if (( rc == 0 )); then write_state "$f" <<<"$next" || rc=$?; fi
  rm -f "$lock"
  if (( rc == 0 )); then echo "$next"; fi
  return $rc
}

if [[ $MODE == record ]]; then
  update_state "$PR_STATE" --arg e "$EVENT" --arg v "$VALUE" --argjson now "$(now)" '
    if $e == "round" then .rounds = ((.rounds // 0) + 1)
    elif $e == "reopen" then .reopened = ((.reopened // []) + [$v] | unique)
    elif .lastHead == null then error("run pr-status.sh once before recording a re-review")
    else .rereview[.lastHead][$v] = $now end'
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
          ... on CheckRun{__typename name status conclusion detailsUrl checkSuite{app{slug}}}
          ... on StatusContext{__typename context state targetUrl creator{login}}
        }}}}}}
      reviewThreads(first:100){totalCount nodes{id isResolved isOutdated path line originalLine
        comments(first:100){totalCount nodes{databaseId author{login __typename} body createdAt lastEditedAt}}}}
      reviews(last:100){totalCount nodes{databaseId author{login __typename} state body submittedAt lastEditedAt commit{oid}}}
      comments(last:100){totalCount nodes{databaseId author{login __typename} body createdAt lastEditedAt}}
    }}}'

# logins of bots that reviewed one of the repo's last 10 merged PRs, cached for a day.
# If GitHub fails, an older cached list is used; with none, the check fails rather than assume no bots.
repo_bots() {
  local cached out
  cached="$(read_state "$REPO_STATE" | jq -c --argjson now "$(now)" 'select(.botsAt != null and $now - .botsAt < 86400) | .bots')"
  if [[ -n "$cached" ]]; then echo "$cached"; return; fi
  if out="$(retry gh api graphql -F owner="$OWNER" -F name="$NAME" -f query='
      query recentBotCheck($owner:String!,$name:String!){
        repository(owner:$owner,name:$name){
          pullRequests(last:10, states:MERGED){nodes{reviews(first:50){nodes{author{login __typename}}}}}}}' 2>/dev/null)" &&
     out="$(jq -c '[.data.repository.pullRequests.nodes[].reviews.nodes[].author | select(.__typename == "Bot") | .login] | unique' <<<"$out")"; then
    update_state "$REPO_STATE" --argjson b "$out" --argjson now "$(now)" '.bots = $b | .botsAt = $now' >/dev/null
    echo "$out"
  else
    read_state "$REPO_STATE" | jq -ce '.bots // empty'
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
  local raw head t state bots pending out new
  raw="$(retry gh api graphql -F owner="$OWNER" -F name="$NAME" -F pr="$PR" -f query="$QUERY")" || return 1
  head="$(jq -er .data.repository.pullRequest.headRefOid <<<"$raw")" || return 1
  t="$(now)"
  # remember when each head commit first showed up; grace periods count from there
  # names of running checks; same rule as `pending` in the main filter below
  pending="$(jq -c '[.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
    | select((.__typename == "CheckRun" and .status != "COMPLETED" and .status != "WAITING") or .state == "PENDING" or .state == "EXPECTED")
    | .name // .context]' <<<"$raw")" || return 1
  # when each running check was first seen running; a check that finished and was re-run starts over
  state="$(update_state "$PR_STATE" --arg h "$head" --argjson now "$t" --argjson pending "$pending" '
    .heads[$h] //= $now | .lastHead = $h
    | (.pendingSince // {}) as $old
    | .pendingSince = (reduce $pending[] as $n ({}; .["\($h) \($n)"] = ($old["\($h) \($n)"] // $now)))')" || return 1
  bots="$(repo_bots)" || return 1
  out="$(jq --argjson max "$MAX_BODY" --arg repo "$REPO" --argjson now "$t" --argjson state "$state" \
     --argjson repoBots "$bots" --arg ignoreBots "${BABYSIT_IGNORE_BOTS:-}" \
     --argjson noChecksGrace "$NO_CHECKS_GRACE" --argjson botGrace "$BOT_GRACE" --argjson stuck "$CHECK_STUCK_SECS" \
     --argjson local "$(local_state "$head")" '
  .data.viewer.login as $viewer
  | .data.repository.pullRequest as $p
  | $p.commits.nodes[0].commit as $head
  | ($state.heads[$p.headRefOid]) as $headSince
  | ($now - $headSince) as $headAge
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
    # time; outside open review threads, a bot edit to something already handled is shown in
    # botComments for reading, but is not new work
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
       owner:(.checkSuite.app.slug // .creator.login // null),
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

  # "coderabbitai" -> "coderabbit", "cubic-dev-ai" -> "cubic", "greptile-apps" -> "greptile"; matches check names
  | def botKey: ascii_downcase | sub("\\[bot\\]$"; "") | split("-")[0] | sub("ai$"; "");
  # review bots: bots that reviewed this PR or recent merged PRs, plus known AI reviewers that
  # posted anything on this PR (their first act is often a "review in progress" comment).
  # Other commenting bots (previews, deploys) are not reviewers.
    ["coderabbit","greptile","cubic","copilot","sourcery","ellipsis","qodo","gemini","codeant","cursor","bugbot","graphite","korbit"] as $knownReviewers
  | ($ignoreBots | split(",") | map(select(length > 0))) as $ignored
  | ([ ($p.reviews.nodes[] | select(.author.__typename == "Bot") | .author.login),
       ([$p.comments.nodes[], $p.reviewThreads.nodes[].comments.nodes[]][]
        | select(.author.__typename == "Bot") | .author.login | select(botKey as $k | $knownReviewers | index($k)))
     ] + $repoBots | unique - $ignored) as $reviewBots
  # the check the bot itself posted ("CodeRabbit" status, "cubic · AI code reviewer" run), matched
  # by the app or account that created it; a CI job named after the bot is not it
  | def botCheck($b): ($b | botKey) as $k | [$checks[] | select(.owner != null and (.owner | botKey) == $k)];
    def rereviewAt($b): $state.rereview[$p.headRefOid][$b] // 0;
    [ $reviewBots[] as $b
      | (botCheck($b)) as $bc
      # a submitted review of the head commit, or the bot check passing on it. Replies and
      # comments do not count: a "thanks" on an old thread says nothing about the new commit.
      | {bot:$b,
         reviewedHead:(
           any($p.reviews.nodes[]; .author.login == $b and .commit.oid == $p.headRefOid and .state != "PENDING")
           or any($bc[]; .passed)),
         skippedHead:any($bc[]; .skipped),
         # its own check still running on the head: it is reviewing now, however long that takes
         checksRunning:[$bc[] | select(.pending) | .name],
         rereviewRequested:(rereviewAt($b) > 0),
         waitedSecs:($now - ([$headSince, rereviewAt($b)] | max))} ] as $bots
  | [ $bots[] | select(.reviewedHead | not) ] as $botsBehind

  | [ $p.reviews.nodes[] | select(.state != "PENDING")
      | select((.body // "") != "" or .state == "CHANGES_REQUESTED")
      | (c + {state, onHead:(.commit.oid == $head.oid)}) | select(unhandled) ] as $reviews
  | [ $reviews[] | select(newToUs) ] as $newReviews
  | [ $p.comments.nodes[] | c | select(unhandled) ] as $topLevel
  | [ $topLevel[] | select(.bot | not) ] as $newComments
  # walkthroughs, "review in progress", previews, rate-limit notes, and bot edits to summaries
  # and reviews already handled: read each, never blocking
  | [ ($topLevel[] | select(.bot)), ($reviews[] | select(newToUs | not))
      | . + {editedSinceHandled:editedAfterHandled} ] as $botComments

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
  | [.checksPending[] | select($now - ($state.pendingSince["\($p.headRefOid) \(.)"] // $now) > $stuck)] as $stuckChecks
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
        ((.checksPending - $stuckChecks | length) as $n | if $n > 0 then "\($n) checks running" else empty end),
        (if (.checksPending | length) == 0 and (.checksAwaitingApproval | length) == 0 and ($ci == "PENDING" or $ci == "EXPECTED") then "CI is pending" else empty end),
        (if $ci == "NONE" and $headAge < $noChecksGrace then "no checks reported on \(.head[0:7]) yet" else empty end),
        ($botsBehind[] | select((.checksRunning - $stuckChecks | length) > 0) | "\(.bot) is reviewing \($p.headRefOid[0:7]) (its check is running)"),
        ($botsBehind[] | select(.waitedSecs < $botGrace and (.checksRunning | length) == 0) | "waiting for \(.bot) to review \($p.headRefOid[0:7])"),
        (if .mergeable == "UNKNOWN" or .mergeState == "UNKNOWN" then "GitHub is still computing mergeability" else empty end)
      ],
      human: ([
        (.checksAwaitingApproval[] | "check \(.name) is waiting for someone to approve it"),
        (if ($stuckChecks | length) > 0 then "\($stuckChecks | length) checks still running after \($stuck | mins): \($stuckChecks | join(", "))" else empty end),
        ($botsBehind[] | select(.waitedSecs >= $botGrace and (.checksRunning | length) == 0)
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
  # a PR watcher (T3 Code) wakes on check results, comments and reviews. It never wakes for a
  # grace period running out: CI that never registers, or a review bot that stays silent.
  | .wakeOnEvent = ((.checksPending - $stuckChecks | length) > 0 or (.blockers.wait | any(test("^CI is pending|^GitHub is still computing"))))
  # needs a person even though the rest is still running; say so now, keep watching the rest
  | .tellUserNow = [.checksAwaitingApproval[] | "check \(.name) is waiting for someone to approve it"]
  | .nextAction = (if .state != "OPEN" then "stop"
                   elif (.blockers.agent | length) > 0 then "fix"
                   elif (.blockers.wait | length) > 0 then "wait"
                   elif (.blockers.human | length) > 0 then "ask-user"
                   else "done" end)' <<<"$raw")" || return 1
  # notices not reported by an earlier check of this head end a --wait, so the user hears about
  # them now. Only the current notices are remembered: one that clears and comes back is new again.
  local told notices
  told="$(jq -c --arg h "$head" 'if .told.head == $h then .told.notices else [] end' <<<"$state")" || return 1
  notices="$(jq -c '.tellUserNow' <<<"$out")" || return 1
  new="$(jq -nc --argjson n "$notices" --argjson t "$told" '$n - $t')" || return 1
  if [[ $notices != "$told" ]]; then
    update_state "$PR_STATE" --arg h "$head" --argjson n "$notices" '.told = {head:$h, notices:$n}' >/dev/null || return 1
  fi
  jq --argjson new "$new" '. + {newNotices:$new}' <<<"$out"
}

if [[ $MODE == status ]]; then
  if out="$(status)"; then echo "$out"; else failed "$GH_FAILED"; exit 1; fi
  exit
fi

# --wait: an error is retried like a wait until the time runs out
start=$SECONDS
while :; do
  out="$(status)" || out="$(failed "$GH_FAILED")"
  next="$(jq -r .nextAction <<<"$out")"
  [[ $next == wait || $next == error ]] && [[ "$(jq -c '.newNotices // []' <<<"$out")" == '[]' ]] &&
    (( SECONDS - start + POLL_SECS < WAIT_SECS )) || break
  sleep "$POLL_SECS"
done
if [[ $next == wait || $next == error ]] && [[ "$(jq -c '.newNotices // []' <<<"$out")" == '[]' ]]; then
  result=still-waiting
else
  result=changed
fi
jq --arg r "$result" --argjson s $((SECONDS - start)) '. + {waitResult:$r, waitedSecs:$s}' <<<"$out"
[[ $next != error ]]
