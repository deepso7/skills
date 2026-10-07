#!/usr/bin/env bash
# Usage: cross-review.sh <round 1-3> <codex|claude> <prompt-file> [base-branch]
#
# Runs a read-only review of committed work by another agent, in a throwaway worktree.
# Prints the review to stdout. The base commit is pinned on round 1 and reused after,
# so every round reviews the same diff: `git diff <base>...HEAD`.
#
# Env: SETUP_CMD  run in the worktree before the review, e.g. "pnpm install --frozen-lockfile --prefer-offline"
#                 (worktrees start without node_modules; the sandboxed reviewer can't install them)
#      TEST_CMD   test runner the Claude reviewer may run (e.g. "pnpm test")
#      CODEX_MODEL / CLAUDE_MODEL / EFFORT   override gpt-6.1-sol / claude-opus-5-5 / medium
set -euo pipefail

ROUND="${1:?round}"; REVIEWER="${2:?codex|claude}"; PROMPT="$(cd "$(dirname "${3:?prompt file}")" && pwd)/$(basename "$3")"
BASE="${4:-}"
EFFORT="${EFFORT:-medium}"

[[ -z "$(git status --porcelain)" ]] || { echo "commit your work first: the reviewer only sees commits" >&2; exit 1; }

STATE="$(git rev-parse --absolute-git-dir)/cross-review/$(git rev-parse --abbrev-ref HEAD | tr '/' '_')"
mkdir -p "$STATE"

if [[ "$ROUND" == 1 || ! -f "$STATE/base.sha" ]]; then
  # base comes from the repository the PR targets; in a fork that is "upstream", not "origin"
  TARGET="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [[ -n "$BASE" ]] || BASE="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)"
  REMOTE="$( [[ -n "$TARGET" ]] && git remote -v | grep -iE "[:/]$TARGET(\.git)?[[:space:]]" | head -1 | cut -f1 || true)"
  git fetch -q "${REMOTE:-origin}" "$BASE"
  git rev-parse FETCH_HEAD > "$STATE/base.sha"
fi
BASE_SHA="$(cat "$STATE/base.sha")"

# fresh worktree per round, outside .git (Codex's sandbox protects .git), with its own TMPDIR
WT="$(mktemp -d "${TMPDIR:-/tmp}/cross-review.XXXXXX")/wt"
git worktree add -q --detach "$WT" HEAD
trap 'git worktree remove --force "$WT" 2>/dev/null || true; rm -rf "$(dirname "$WT")"' EXIT
mkdir -p "$WT/.tmp"
if [[ -n "${SETUP_CMD:-}" ]]; then
  (cd "$WT" && bash -c "$SETUP_CMD") > "$STATE/setup-$ROUND.log" 2>&1 || { echo "SETUP_CMD failed, see $STATE/setup-$ROUND.log" >&2; exit 4; }
fi

{ echo "Base commit: $BASE_SHA. Review \`git diff $BASE_SHA...HEAD\`. Do not edit any files."
  # the claude reviewer may only run commands that start with TEST_CMD; pipes, cd, or env prefixes get denied
  [[ -n "${TEST_CMD:-}" ]] && echo "To run tests, use \`$TEST_CMD\` (optionally followed by paths or flags) as a plain command: no pipes, redirects, cd, or env prefixes."
  echo; cat "$PROMPT"; } > "$STATE/prompt-$ROUND.md"
OUT="$STATE/review-$ROUND.md"

LOG="$STATE/$REVIEWER-$ROUND.log"
rm -f "$OUT"
rc=0
case "$REVIEWER" in
  codex)
    # writes allowed only inside the throwaway worktree (tests need temp files); no /tmp, no network
    TMPDIR="$WT/.tmp" codex exec -C "$WT" -m "${CODEX_MODEL:-gpt-6.1-sol}" -c model_reasoning_effort="$EFFORT" \
      -s workspace-write -c sandbox_workspace_write.exclude_slash_tmp=true \
      -c sandbox_workspace_write.exclude_tmpdir_env_var=true \
      -c 'sandbox_workspace_write.writable_roots=[]' -c sandbox_workspace_write.network_access=false --ephemeral \
      -o "$OUT" - < "$STATE/prompt-$ROUND.md" > "$LOG" 2>&1 || rc=$? ;;
  claude)
    # --tools: only these built-ins exist; --setting-sources "": ignore the user's allow rules;
    # --strict-mcp-config: no MCP servers; dontAsk: deny any Bash not in --allowedTools.
    # Not --bare: it skips OAuth login.
    allowed=("Read" "Grep" "Glob" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)")
    [[ -n "${TEST_CMD:-}" ]] && allowed+=("Bash($TEST_CMD:*)")
    (
      # --setting-sources "" also drops the `env` block of user settings, where auth such as
      # ANTHROPIC_AUTH_TOKEN / ANTHROPIC_BASE_URL may live; load just that block (never printed)
      settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
      if [[ -f "$settings" ]]; then
        envfile="$(mktemp)"   # mode 600, removed right after reading
        if ! jq -j '(.env // {}) | to_entries[] | "\(.key)=\(.value)\u0000"' "$settings" > "$envfile"; then
          rm -f "$envfile"; echo "could not read the env block of $settings" >&2; exit 6
        fi
        while IFS= read -r -d '' kv; do export "$kv"; done < "$envfile"
        rm -f "$envfile"
      fi
      cd "$WT" && claude -p --model "${CLAUDE_MODEL:-claude-opus-5-5}" --effort "$EFFORT" \
        --permission-mode dontAsk --setting-sources "" --strict-mcp-config \
        --tools "Read" "Grep" "Glob" "Bash" --allowedTools "${allowed[@]}" \
        < "$STATE/prompt-$ROUND.md" > "$OUT" 2> "$LOG"
    ) || rc=$? ;;
  *) echo "reviewer must be codex or claude" >&2; exit 2 ;;
esac

# a failed or empty review must never look like a clean one
if (( rc != 0 )) || [[ ! -s "$OUT" ]]; then
  echo "reviewer $REVIEWER failed (exit $rc). Output:" >&2
  for f in "$OUT" "$LOG"; do [[ -s "$f" ]] && tail -n 20 "$f" >&2; done
  [[ -s "$OUT" || -s "$LOG" || $rc == 6 ]] || echo "(no output; check that '$REVIEWER' is logged in on this machine)" >&2
  exit 5
fi

[[ -z "$(git status --porcelain)" ]] || { echo "WARNING: your checkout changed during review; not touching it" >&2; exit 3; }
cat "$OUT"
