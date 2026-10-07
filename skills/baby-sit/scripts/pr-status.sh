#!/usr/bin/env bash
# Usage: pr-status.sh [--wait] [pr-number]      (pr defaults to the current branch's PR)
#
# Prints one JSON object describing everything between the PR and merge, and a
# `nextAction`: fix | wait | ask-user | done | stop.
#
# --wait  sleeps POLL_SECS (default 60) so fresh checks can register, then polls every
#         POLL_SECS while nextAction is "wait", up to WAIT_SECS (default 1800). If CI
#         finished, waits SETTLE_SECS (default 300) for review bots, then re-checks.
#         That bot wait is skipped when no bot has posted on this PR and either no bot
#         posted on the repo's last 10 merged PRs, or the wait already ran once for this
#         PR (state in .git/baby-sit/).
#         Adds waitResult: settled | actionable (work showed up while waiting) | timed-out.
#
# Env: GH_REPO=owner/repo to run outside a clone. MAX_BODY (default 6000) caps comment text;
#      clipped items have truncated=true and must be fetched in full before handling.
#
# Everything the baby-sit skill posts ends with one marker, from the viewer's own account:
#   <!-- baby-sit handled:<ids> -->   answered these comment/review ids
#   <!-- baby-sit -->                 anything else
# An item counts as handled when a later marker lists its id and it hasn't been edited since.
set -euo pipefail

WAIT=0
if [[ "${1:-}" == "--wait" ]]; then WAIT=1; shift; fi
PR="${1:-$(gh pr view --json number -q .number)}"
REPO="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
OWNER="${REPO%/*}"; NAME="${REPO#*/}"
MAX_BODY="${MAX_BODY:-6000}"
WAIT_SECS="${WAIT_SECS:-1800}"
SETTLE_SECS="${SETTLE_SECS:-300}"
POLL_SECS="${POLL_SECS:-60}"

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

# true / false / unknown: did any bot comment on or review the repo's last 10 merged PRs?
repo_has_bots() {
  gh api graphql -F owner="$OWNER" -F name="$NAME" -f query='
    query recentBotCheck($owner:String!,$name:String!){
      repository(owner:$owner,name:$name){
        pullRequests(last:10, states:MERGED){nodes{
          comments(first:50){pageInfo{hasNextPage} nodes{author{__typename}}}
          reviews(first:50){pageInfo{hasNextPage} nodes{author{__typename}}}}}}}' 2>/dev/null |
  jq -r '.data.repository.pullRequests.nodes
         | if length == 0 then "unknown"
           elif [.[] | (.comments.nodes + .reviews.nodes)[] | .author.__typename] | any(. == "Bot") then "true"
           # a bot may be hiding past the first 50 items of a busy PR
           elif [.[] | .comments.pageInfo.hasNextPage, .reviews.pageInfo.hasNextPage] | any then "unknown"
           else "false" end' 2>/dev/null ||
  echo unknown
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
  jq -n --arg branch "$(git rev-parse --abbrev-ref HEAD)" --arg sha "$sha" --arg rel "$rel" \
    --argjson ahead "$ahead" --argjson dirty "$(git status --porcelain | wc -l | tr -d ' ')" \
    --arg baseRemote "$base_remote" \
    '{branch:$branch, sha:$sha, relation:$rel, unpushed:$ahead, dirty:$dirty,
      repoMatches:($baseRemote != ""), baseRemote:(if $baseRemote == "" then null else $baseRemote end)}'
}

status() {
  local raw
  raw="$(gh api graphql -F owner="$OWNER" -F name="$NAME" -F pr="$PR" -f query="$QUERY")"
  jq --argjson max "$MAX_BODY" --arg repo "$REPO" \
     --argjson local "$(local_state "$(jq -r .data.repository.pullRequest.headRefOid <<<"$raw")")" '
  .data.viewer.login as $viewer
  | .data.repository.pullRequest as $p
  | $p.commits.nodes[0].commit as $head
  | "<!-- baby-sit(?: handled:(?<ids>[0-9,]+))? -->\\s*$" as $re
  | def mine: ((.author.login // "") == $viewer) and ((.body // "") | test($re));
    def marker: (.body | capture($re));
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
    # when baby-sit first posted on this PR; resolved-thread activity before it is history
    ([$oursRaw[].createdAt] | min) as $since

  | [ $p.reviewThreads.nodes[]
      | .isResolved as $resolved
      | (.comments.nodes | sort_by(.createdAt) | map(c)) as $cs
      | ([$cs | to_entries[] | select(.value.mine) | .key] | max) as $lastOurs
      | {id, resolved:$resolved, outdated:.isOutdated, path, line:(.line // .originalLine),
         total:.comments.totalCount, replyTo:$cs[0].id, botThread:$cs[0].bot, comments:$cs,
         # bots edit their comments once answered ("✅ addressed") and reply to confirm fixes;
         # counting those would loop forever. So bot edits after handling never count, and on
         # resolved threads bot replies do not block either (listed in botRepliesOnResolved).
         # Bots post anything genuinely new as a new comment, which still counts.
         # resolved threads count only: human replies after our last answer, human edits to
         # handled items, and anything humans posted after baby-sit started on this PR
         unhandled:[ $cs | to_entries[]
                     | select(.value | unhandled and ((.bot and editedAfterHandled) | not))
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
       pending:((.__typename == "CheckRun" and .status != "COMPLETED") or .state == "PENDING" or .state == "EXPECTED"),
       failed:((.conclusion as $x | ["FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"] | index($x) != null)
               or .state == "FAILURE" or .state == "ERROR")})) as $checks
  | ($head.statusCheckRollup.state // "NONE") as $ci

  | [ $p.reviews.nodes[] | select(.state != "PENDING")
      | select((.body // "") != "" or .state == "CHANGES_REQUESTED")
      | (c + {state, onHead:(.commit.oid == $head.oid)}) | select(unhandled) ] as $newReviews
  | [ $p.comments.nodes[] | c | select(unhandled) ] as $newComments


  | {
      pr: $p.number, url: $p.url, state: $p.state, draft: $p.isDraft,
      base: $p.baseRefName, branch: $p.headRefName, head: $p.headRefOid, crossRepo: $p.isCrossRepository,
      local: (if $local == null then null else $local + {branchMatches:($local.branch == $p.headRefName)} end),
      mergeable: $p.mergeable, mergeState: $p.mergeStateStatus, reviewDecision: $p.reviewDecision,
      ci: $ci,
      checksPending: [$checks[] | select(.pending) | .name],
      checksFailed: [$checks[] | select(.failed) | del(.pending, .failed)],
      threadsToAddress: [$threads[] | select(.unhandled | length > 0)
                         | . + {marker:"<!-- baby-sit handled:\(.unhandled | map(tostring) | join(",")) -->"}],
      # never auto-resolve a thread with replies we could not read
      threadsToResolve: [$threads[] | select((.resolved | not) and (.unhandled | length == 0) and .botThread and .total <= 100) | {id, path, line}],
      threadsAwaitingHumans: [$threads[] | select((.resolved | not) and (.unhandled | length == 0) and (.botThread | not)) | {id, path, line, lastBy:.comments[-1].by}],
      newReviews: $newReviews,
      newComments: $newComments,
      botsSeen: ([$threads[].comments[], ($p.comments.nodes[] | c), ($p.reviews.nodes[] | c)] | any(.bot)),
      summaryMarker: ([$newReviews[].id, $newComments[].id] | if length > 0 then "<!-- baby-sit handled:\(map(tostring) | join(",")) -->" else null end),
      # not blocking: read each; reopen the thread if it is pushback, ignore confirmations
      botRepliesOnResolved: [$threads[] | select(.botReplies | length > 0)
                             | {threadId:.id, path, line, replies:[.botReplies[] | {id, by, at, truncated, body}]}],
      incomplete: [
        (([$threads[] | select(.total > 100)] | length) as $n | if $n > 0 then "\($n) threads have over 100 replies; only the first 100 were read" else empty end),
        (if $p.reviewThreads.totalCount > 100 then "only the first 100 of \($p.reviewThreads.totalCount) threads were checked" else empty end),
        (if $p.reviews.totalCount > 100 then "only the last 100 of \($p.reviews.totalCount) reviews were checked" else empty end),
        (if $p.comments.totalCount > 100 then "only the last 100 of \($p.comments.totalCount) comments were checked" else empty end),
        (if ($head.statusCheckRollup.contexts.totalCount // 0) > 100 then "only the first 100 checks were listed" else empty end)
      ]
    }
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
        (if (.checksFailed | length) == 0 and ($ci == "FAILURE" or $ci == "ERROR") then "CI reports \($ci | ascii_downcase) but the failing check is not listed" else empty end),
        ((.threadsToAddress | length) as $n | if $n > 0 then "\($n) threads need a response" else empty end),
        ((.threadsToResolve | length) as $n | if $n > 0 then "\($n) answered bot threads to resolve" else empty end),
        ((.newReviews | length) as $n | if $n > 0 then "\($n) new or edited review summaries" else empty end),
        ((.newComments | length) as $n | if $n > 0 then "\($n) new or edited PR comments" else empty end),
        (if .mergeable == "CONFLICTING" or .mergeState == "DIRTY" then "merge conflicts with \(.base)" else empty end),
        (if .mergeState == "BEHIND" then "branch is behind \(.base) and must be updated" else empty end)
      ],
      wait: [
        ((.checksPending | length) as $n | if $n > 0 then "\($n) checks running" else empty end),
        (if (.checksPending | length) == 0 and ($ci == "PENDING" or $ci == "EXPECTED") then "CI is pending" else empty end),
        (if .mergeable == "UNKNOWN" or .mergeState == "UNKNOWN" then "GitHub is still computing mergeability" else empty end)
      ],
      human: ([
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

if [[ $WAIT == 0 ]]; then status; exit; fi

start=$SECONDS
sleep "$POLL_SECS"
out="$(status)"
while [[ "$(jq -r .nextAction <<<"$out")" == "wait" ]] && (( SECONDS - start < WAIT_SECS )); do
  sleep "$POLL_SECS"
  out="$(status)"
done
case "$(jq -r .nextAction <<<"$out")" in
  wait)     result=timed-out ;;
  fix|stop) result=actionable ;;  # returned early: there is work (or the PR closed), CI may still be running
  *)
    # skip the bot wait on PRs no bot has posted on, if the repo has no bots or we already waited once
    marker="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
    [[ -n "$marker" ]] && marker="$marker/baby-sit/${REPO//\//_}-$PR.settled"
    skipped=false
    if [[ "$(jq -r .botsSeen <<<"$out")" == false ]]; then
      if [[ -n "$marker" && -f "$marker" ]] || [[ "$(repo_has_bots)" == false ]]; then skipped=true; fi
    fi
    if [[ $skipped == false ]]; then
      sleep "$SETTLE_SECS"; out="$(status)"
      [[ -n "$marker" ]] && mkdir -p "$(dirname "$marker")" && touch "$marker"
    fi
    result=settled ;;
esac
jq --arg r "$result" --argjson s $((SECONDS - start)) --argjson sk "${skipped:-false}" \
  '. + {waitResult:$r, timedOut:($r == "timed-out"), settleSkipped:$sk, waitedSecs:$s}' <<<"$out"
