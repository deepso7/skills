// Runs baby-sit/scripts/pr-status.sh against a fake `gh` that serves crafted GraphQL responses.
import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, chmodSync } from "fs";
import { tmpdir } from "os";
import { dirname, join } from "path";

const SCRIPT = join(import.meta.dir, "../skills/baby-sit/scripts/pr-status.sh");
const HEAD = "a".repeat(40);
const ME = "me";

type Author = { login: string; __typename: "User" | "Bot" };
const user = (login: string): Author => ({ login, __typename: "User" });
const bot = (login: string): Author => ({ login, __typename: "Bot" });
const cm = (id: number, author: Author, body: string, day: number) => ({
  databaseId: id, author, body, createdAt: `2026-01-${String(day).padStart(2, "0")}T00:00:00Z`,
});
const thread = (id: string, resolved: boolean, comments: ReturnType<typeof cm>[], total = comments.length) => ({
  id, isResolved: resolved, isOutdated: false, path: "a.ts", line: 1, originalLine: 1,
  comments: { totalCount: total, nodes: comments.slice(0, 100) },
});

function pr(over: Record<string, unknown> = {}) {
  return {
    number: 7, url: "u", state: "OPEN", isDraft: false, headRefName: "feat", headRefOid: HEAD,
    baseRefName: "main", isCrossRepository: false, mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
    reviewDecision: "APPROVED",
    commits: { nodes: [{ commit: { oid: HEAD, committedDate: "2026-01-05T00:00:00Z", statusCheckRollup: {
      state: "SUCCESS", contexts: { nodes: [{ __typename: "CheckRun", name: "ci", status: "COMPLETED", conclusion: "SUCCESS", detailsUrl: "https://github.com/o/r/actions/runs/111/job/1" }] } } } }] },
    reviewThreads: { totalCount: 0, nodes: [] as unknown[] },
    reviews: { nodes: [] as unknown[] },
    comments: { nodes: [] as unknown[] },
    ...over,
  };
}

// merged-PR history for the repo-level review-bot check: one entry per PR, listing who reviewed it
const history = (...prs: Author[][]) => ({ data: { repository: { pullRequests: { nodes:
  prs.map((authors) => ({ reviews: { nodes: authors.map((author) => ({ author })) } })) } } } });

// fixtures: one response, or a list served in order (last one repeats)
// a fixture that makes that gh call fail
const FAIL = {};
type RunOpts = { args?: string[]; env?: Record<string, string>; cwd?: string; history?: object; state?: string; now?: number;
                 // on GitHub a bot's inline comments always come with a review; by default every bot that
                 // commented gets an empty review of the head commit, so it counts as a current reviewer
                 rawBots?: boolean };

function withBotReviews(p: any) {
  if (p === FAIL || !p.reviewThreads) return p;
  const commenters = [...p.reviewThreads.nodes.flatMap((t: any) => t.comments.nodes), ...p.comments.nodes]
    .map((c: any) => c.author).filter((a: Author) => a.__typename === "Bot");
  const reviewed = new Set(p.reviews.nodes.filter((r: any) => r.commit?.oid === p.headRefOid).map((r: any) => r.author.login));
  const extra = [...new Map(commenters.map((a: Author) => [a.login, a])).values()].filter((a) => !reviewed.has(a.login))
    .map((author, i) => ({ databaseId: 80000 + i, author, state: "COMMENTED", body: "", submittedAt: "2026-01-01T00:00:00Z", commit: { oid: p.headRefOid } }));
  return { ...p, reviews: { ...p.reviews, nodes: [...p.reviews.nodes, ...extra] } };
}
// seconds since epoch for the fixture clock; heads are first seen at whatever `now` the first run uses
const T0 = Date.parse("2026-01-10T00:00:00Z") / 1000;
const stateDir = () => mkdtempSync(join(tmpdir(), "prs-state-"));

function run(fixtures: object | object[], opts: RunOpts = {}) {
  const r = exec(fixtures, opts);
  if (r.exitCode !== 0) throw new Error(r.stderr.toString() || r.stdout.toString());
  return JSON.parse(r.stdout.toString());
}

function exec(fixtures: object | object[], opts: RunOpts = {}) {
  const dir = mkdtempSync(join(tmpdir(), "prs-"));
  const list = (Array.isArray(fixtures) ? fixtures : [fixtures])
    .map((p) => p === FAIL ? FAIL : ({ data: { viewer: { login: ME }, repository: { pullRequest: opts.rawBots ? p : withBotReviews(p) } } }));
  list.forEach((f, i) => writeFileSync(join(dir, `f${i}.json`), f === FAIL ? "FAIL\n" : JSON.stringify(f)));
  writeFileSync(join(dir, "history.json"), opts.history === FAIL ? "FAIL\n" : JSON.stringify(opts.history ?? history()));
  writeFileSync(join(dir, "gh"), `#!/bin/sh
case "$*" in *recentBotCheck*) [ "$(cat "${dir}/history.json")" = FAIL ] && { echo "HTTP 502" >&2; exit 1; }; cat "${dir}/history.json"; exit;; esac
n=$(cat "${dir}/count" 2>/dev/null || echo 0); echo $((n+1)) > "${dir}/count"
i=$n; [ $i -ge ${list.length} ] && i=${list.length - 1}
if [ "$(cat "${dir}/f$i.json")" = FAIL ]; then echo "HTTP 502" >&2; exit 1; fi
cat "${dir}/f$i.json"\n`);
  chmodSync(join(dir, "gh"), 0o755);
  return Bun.spawnSync(["bash", SCRIPT, ...(opts.args ?? ["7"])], {
    cwd: opts.cwd ?? dir,
    // stop git from finding an enclosing repo when TMPDIR itself lives inside one
    env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, GH_REPO: "o/r", GIT_CEILING_DIRECTORIES: dirname(opts.cwd ?? dir),
           BABYSIT_STATE_DIR: opts.state ?? join(dir, "state"), BABYSIT_NOW: String(opts.now ?? T0), ...opts.env },
  });
}

describe("baseline", () => {
  test("clean approved PR is done", () => {
    const s = run(pr());
    expect(s.nextAction).toBe("done");
    expect(s.ready).toBe(true);
  });
});

describe("threads", () => {
  test("#9 thread comment authors carry bot flag; answered bot threads get resolved, human ones wait", () => {
    const s = run(pr({ reviewThreads: { totalCount: 2, nodes: [
      thread("TB", false, [cm(1, bot("coderabbitai"), "bug", 1), cm(2, user(ME), "Fixed\n<!-- baby-sit handled:1 -->", 2)]),
      thread("TH", false, [cm(3, user("alice"), "rename?", 1), cm(4, user(ME), "Declined: ...\n<!-- baby-sit handled:3 -->", 2)]),
    ] } }));
    expect(s.threadsToResolve.map((t: any) => t.id)).toEqual(["TB"]);
    expect(s.threadsAwaitingHumans.map((t: any) => t.id)).toEqual(["TH"]);
    expect(s.threadsToAddress).toEqual([]);
    expect(s.nextAction).toBe("fix"); // resolving the bot thread is agent work
  });

  test("nested reply after our answer in an open thread needs a response, with a ready-made marker", () => {
    const s = run(pr({ reviewThreads: { totalCount: 1, nodes: [
      thread("T", false, [cm(1, user("alice"), "ask", 1), cm(2, user(ME), "done\n<!-- baby-sit handled:1 -->", 2), cm(3, user("alice"), "still wrong", 3)]),
    ] } }));
    expect(s.threadsToAddress[0].unhandled).toEqual([3]);
    expect(s.threadsToAddress[0].marker).toBe("<!-- baby-sit handled:3 -->");
  });

  test("#7 resolved thread: new reply after our answer is caught; thread resolved by others with no answer from us is ignored", () => {
    const s = run(pr({ reviewThreads: { totalCount: 2, nodes: [
      thread("R1", true, [cm(1, bot("greptile-apps"), "race", 1), cm(2, user(ME), "fixed\n<!-- baby-sit handled:1 -->", 2), cm(3, user(ME), "no, still racy", 3)]),
      thread("R2", true, [cm(4, user("alice"), "nit", 1), cm(5, user("bob"), "agreed", 2)]),
    ] } }));
    expect(s.threadsToAddress.map((t: any) => t.id)).toEqual(["R1"]);
    expect(s.threadsToAddress[0].unhandled).toEqual([3]);
  });

  test("r3#2 a deep reply in a long thread is seen; threads over 100 replies block as incomplete", () => {
    const comments = Array.from({ length: 60 }, (_, i) => cm(100 + i, user(i % 2 ? ME : "alice"), i % 2 ? `ok\n<!-- baby-sit handled:${99 + i} -->` : `reply ${i}`, 2));
    comments.push(cm(999, user("alice"), "still wrong", 9));
    const s = run(pr({ reviewThreads: { totalCount: 1, nodes: [thread("L", false, comments)] } }));
    expect(s.threadsToAddress[0].unhandled).toEqual([999]);
    const big = run(pr({ reviewThreads: { totalCount: 1, nodes: [thread("B", false, comments, 150)] } }));
    expect(big.incomplete).toEqual(["1 threads have over 100 replies; only the first 100 were read"]);
    expect(big.blockers.human).toContain("1 threads have over 100 replies; only the first 100 were read");
  });

  test("r3#1 resolved thread: a human comment edited after we handled it comes back", () => {
    const edited = { ...cm(1, user("alice"), "race (updated: also on retry)", 1), lastEditedAt: "2026-01-05T00:00:00Z" };
    const s = run(pr({ reviewThreads: { totalCount: 1, nodes: [
      thread("R", true, [edited, cm(2, user(ME), "fixed\n<!-- baby-sit handled:1 -->", 2)]),
    ] } }));
    expect(s.threadsToAddress[0]?.unhandled).toEqual([1]);
  });

  // kanshi#6: CodeRabbit confirms the fix in a reply, then edits its root comment with
  // "✅ Confirmed as addressed" seconds after every answer. That must not loop.
  test("bot confirmation reply and bot edit on a resolved thread do not reopen it", () => {
    const root = { ...cm(1, bot("coderabbitai"), "Keep applied migrations frozen", 1), lastEditedAt: "2026-01-05T00:00:00Z" };
    const s = run(pr({ reviewThreads: { totalCount: 1, nodes: [
      thread("K", true, [
        root,
        cm(2, user(ME), "Fixed in 0030cb6\n<!-- baby-sit handled:1 -->", 2),
        cm(3, bot("coderabbitai"), "confirmed, thread already resolved", 3),
        cm(4, user(ME), "Thanks for confirming.\n<!-- baby-sit handled:1,3 -->", 4),
      ]),
    ] } }));
    expect(s.threadsToAddress).toEqual([]);
    expect(s.nextAction).toBe("done");
  });

  test("a bot confirming the fix in a resolved thread needs no reply", () => {
    const s = run(pr({ reviewThreads: { totalCount: 1, nodes: [
      thread("K", true, [
        cm(1, bot("coderabbitai"), "Keep applied migrations frozen", 1),
        cm(2, user(ME), "Fixed in 0030cb6\n<!-- baby-sit handled:1 -->", 2),
        cm(3, bot("coderabbitai"), "confirmed, thread already resolved", 3),
      ]),
    ] } }));
    expect(s.threadsToAddress).toEqual([]);
    expect(s.nextAction).toBe("done");
    // still surfaced, without blocking, so real pushback is never lost
    expect(s.botRepliesOnResolved).toEqual([{ threadId: "K", path: "a.ts", line: 1,
      replies: [{ id: 3, by: "coderabbitai", at: "2026-01-03T00:00:00Z", truncated: false, body: "confirmed, thread already resolved" }] }]);
  });

  test("bot pushback between two agent replies stays listed when the later marker does not cover it", () => {
    const s = run(pr({ reviewThreads: { totalCount: 1, nodes: [
      thread("P", true, [
        cm(1, bot("coderabbitai"), "bug", 1),
        cm(2, user(ME), "fixed\n<!-- baby-sit handled:1 -->", 2),
        cm(3, bot("coderabbitai"), "still broken on retry", 3),
        cm(4, user("alice"), "unrelated question", 4),
        cm(5, user(ME), "answered alice\n<!-- baby-sit handled:4 -->", 5),
      ]),
    ] } }));
    expect(s.botRepliesOnResolved[0].replies.map((r: any) => r.id)).toEqual([3]);
  });

  test("a handled bot comment the bot edits later is not relisted on a resolved thread", () => {
    const root = { ...cm(1, bot("coderabbitai"), "bug\n\n✅ Addressed in abc123", 3), lastEditedAt: "2026-01-05T00:00:00Z" };
    const s = run(pr({
      reviewThreads: { totalCount: 1, nodes: [thread("E", true, [root, cm(2, user(ME), "fixed\n<!-- baby-sit handled:1 -->", 4)])] },
      comments: { nodes: [cm(90, user(ME), "status\n<!-- baby-sit -->", 2)] },
    }));
    expect(s.botRepliesOnResolved).toEqual([]);
    expect(s.nextAction).toBe("done");
  });

  test("bot reply on a thread resolved by someone else is listed once baby-sit has started", () => {
    const s = run(pr({
      reviewThreads: { totalCount: 1, nodes: [
        thread("X", true, [cm(1, user("alice"), "nit", 1), cm(2, bot("coderabbitai"), "this also leaks the handle", 6)]),
      ] },
      comments: { nodes: [cm(90, user(ME), "status\n<!-- baby-sit -->", 4)] },
    }));
    expect(s.botRepliesOnResolved[0].replies.map((r: any) => r.id)).toEqual([2]);
  });

  test("bot pushback after the agent resolved a declined bot thread is listed, not dropped", () => {
    const s = run(pr({ reviewThreads: { totalCount: 1, nodes: [
      thread("D", true, [
        cm(1, bot("cubic-dev-ai"), "race on retry", 1),
        cm(2, user(ME), "Declined: retries are serialized\n<!-- baby-sit handled:1 -->", 2),
        cm(3, bot("cubic-dev-ai"), "disagree: the retry path is not serialized", 3),
      ]),
    ] } }));
    expect(s.botRepliesOnResolved[0].replies.map((r: any) => r.id)).toEqual([3]);
  });

  test("bot replies that a marker already covers are not listed again", () => {
    const s = run(pr({ reviewThreads: { totalCount: 1, nodes: [
      thread("K", true, [
        cm(1, bot("coderabbitai"), "bug", 1),
        cm(2, user(ME), "fixed\n<!-- baby-sit handled:1 -->", 2),
        cm(3, bot("coderabbitai"), "confirmed", 3),
      ]),
    ] }, comments: { nodes: [cm(9, user(ME), "noted\n<!-- baby-sit handled:3 -->", 4)] } }));
    expect(s.botRepliesOnResolved).toEqual([]);
  });

  test("a human reply in a resolved thread that has bot comments still needs a response", () => {
    const s = run(pr({ reviewThreads: { totalCount: 1, nodes: [
      thread("M", true, [
        cm(1, bot("coderabbitai"), "bug", 1),
        cm(2, user(ME), "fixed\n<!-- baby-sit handled:1 -->", 2),
        cm(3, bot("coderabbitai"), "confirmed", 3),
        cm(4, user("alice"), "this fix broke the CLI", 4),
      ]),
    ] } }));
    expect(s.threadsToAddress[0].unhandled).toEqual([4]);
  });

  test("open thread: a bot edit after handling and a new bot reply both count", () => {
    const root = { ...cm(1, bot("coderabbitai"), "bug (also applies to retry)", 1), lastEditedAt: "2026-01-05T00:00:00Z" };
    const answered = [root, cm(2, user(ME), "fixed\n<!-- baby-sit handled:1 -->", 2)];
    expect(run(pr({ reviewThreads: { totalCount: 1, nodes: [thread("O", false, answered)] } })).threadsToAddress[0].unhandled).toEqual([1]);
    const pushback = run(pr({ reviewThreads: { totalCount: 1, nodes: [thread("O", false, [cm(1, bot("coderabbitai"), "bug", 1), answered[1]!, cm(3, bot("coderabbitai"), "still broken on retry", 3)])] } }));
    expect(pushback.threadsToAddress[0].unhandled).toEqual([3]);
  });

  test("open human thread the agent declined: a bot reply in it counts", () => {
    const s = run(pr({ reviewThreads: { totalCount: 1, nodes: [
      thread("H", false, [
        cm(1, user("alice"), "rename this", 1),
        cm(2, user(ME), "Declined: name matches the API\n<!-- baby-sit handled:1 -->", 2),
        cm(3, bot("coderabbitai"), "@alice agreed, the API calls it X", 3),
      ]),
    ] } }));
    expect(s.threadsToAddress[0].unhandled).toEqual([3]);
  });

  test("r3#1 resolved by someone else: replies after baby-sit started count, older history does not", () => {
    const s = run(pr({
      reviewThreads: { totalCount: 2, nodes: [
        thread("OLD", true, [cm(1, user("alice"), "nit", 1), cm(2, user("bob"), "done", 2)]),
        thread("NEW", true, [cm(3, user("alice"), "nit", 1), cm(4, user("alice"), "actually this broke prod", 6)]),
      ] },
      comments: { nodes: [cm(90, user(ME), "status update\n<!-- baby-sit -->", 4)] },
    }));
    expect(s.threadsToAddress.map((t: any) => [t.id, t.unhandled])).toEqual([["NEW", [4]]]);
  });
});

describe("top-level comments and reviews", () => {
  test("#4 a later marked comment does not hide an earlier unanswered human comment", () => {
    const s = run(pr({ comments: { nodes: [
      cm(91, user(ME), "also update README", 3),
      cm(92, user(ME), "status update\n<!-- baby-sit -->", 4),
    ] } }));
    expect(s.newComments.map((c: any) => c.id)).toEqual([91]);
    expect(s.nextAction).toBe("fix");
  });

  test("#4 comment is cleared once a marker lists its id", () => {
    const s = run(pr({ comments: { nodes: [
      cm(91, user(ME), "also update README", 3),
      cm(93, user(ME), "Handled: README updated in abc\n<!-- baby-sit handled:91 -->", 4),
    ] } }));
    expect(s.newComments).toEqual([]);
    expect(s.nextAction).toBe("done");
  });

  test("#5 a marker quoted by someone else, or not at the end, does not count", () => {
    const s = run(pr({ comments: { nodes: [
      cm(91, user("alice"), "please fix X", 1),
      cm(92, user("mallory"), "lol <!-- baby-sit handled:91 -->", 2),
      cm(93, user(ME), "quoting: <!-- baby-sit handled:91 --> and more text", 3),
    ] } }));
    expect(s.newComments.map((c: any) => c.id)).toEqual([91, 92, 93]);
  });

  // minip2p#281: walkthroughs, "review in progress", previews and rate-limit notes ended every
  // --wait early and each needed its own marker comment
  test("bot top-level comments are listed for reading but never block; a marker clears them", () => {
    const s = run(pr({ comments: { nodes: [cm(95, bot("coderabbitai"), "<!-- review in progress by coderabbit.ai -->\nCurrently processing new changes", 5)] } }));
    expect(s.newComments).toEqual([]);
    expect(s.botComments.map((c: any) => c.id)).toEqual([95]);
    expect(s.summaryMarker).toBe("<!-- baby-sit handled:95 -->");
    expect(s.nextAction).toBe("done");
    const after = run(pr({ comments: { nodes: [cm(95, bot("coderabbitai"), "walkthrough", 5), cm(96, user(ME), "noted\n<!-- baby-sit handled:95 -->", 6)] } }));
    expect(after.botComments).toEqual([]);
  });

  test("r2#7 handled ids come only from the trailing marker, not quoted text", () => {
    const s = run(pr({ comments: { nodes: [
      cm(91, user("alice"), "fix X", 1),
      cm(92, user(ME), "earlier I wrote handled:91 in a note\n<!-- baby-sit -->", 2),
    ] } }));
    expect(s.newComments.map((c: any) => c.id)).toEqual([91]);
  });

  test("r2#8 a human comment edited after it was handled comes back", () => {
    const edited = { ...cm(91, user("alice"), "also handle retries", 1), lastEditedAt: "2026-01-09T00:00:00Z" };
    const s = run(pr({ comments: { nodes: [edited, cm(92, user(ME), "ok\n<!-- baby-sit handled:91 -->", 3)] } }));
    expect(s.newComments.map((c: any) => c.id)).toEqual([91]);
  });

  // minip2p#273: CodeRabbit and Greptile rewrite their summary comment on every push
  test("a bot refreshing a handled summary or review is shown for reading but is not new work", () => {
    const summary = { ...cm(91, bot("greptile-apps"), "Confidence 3/5: new finding in retry.ts", 1), lastEditedAt: "2026-01-09T00:00:00Z" };
    const review = { databaseId: 500, author: bot("coderabbitai"), state: "COMMENTED", body: "Actionable comments posted: 0 (edited)", submittedAt: "2026-01-02T00:00:00Z", lastEditedAt: "2026-01-09T00:00:00Z", commit: { oid: HEAD } };
    const s = run(pr({ reviews: { nodes: [review] }, comments: { nodes: [summary, cm(92, user(ME), "ok\n<!-- baby-sit handled:91,500 -->", 3)] } }));
    expect([s.newReviews, s.nextAction]).toEqual([[], "done"]);
    expect(s.botComments.map((c: any) => [c.id, c.editedSinceHandled])).toEqual([[91, true], [500, true]]);
    expect(s.summaryMarker).toBe("<!-- baby-sit handled:91,500 -->");
  });

  test("r2#5 a long reply keeps its marker; long feedback is flagged truncated", () => {
    const long = "x".repeat(300);
    const s = run(pr({ reviewThreads: { totalCount: 1, nodes: [
      thread("T", false, [cm(1, bot("coderabbitai"), long, 1), cm(2, user(ME), long + "\n<!-- baby-sit handled:1 -->", 2)]),
    ] }, comments: { nodes: [cm(9, user("alice"), long, 3)] } }), { env: { MAX_BODY: "100" } });
    expect(s.threadsToAddress).toEqual([]);
    expect(s.threadsToResolve.map((t: any) => t.id)).toEqual(["T"]);
    expect(s.newComments[0].truncated).toBe(true);
  });

  test("r2#14 reviews written from the viewer account (the user) are not skipped", () => {
    const s = run(pr({ reviews: { nodes: [{ databaseId: 700, author: user(ME), state: "COMMENTED", body: "please split this file", submittedAt: "2026-01-04T00:00:00Z", commit: { oid: HEAD } }] } }));
    expect(s.newReviews.map((r: any) => r.id)).toEqual([700]);
  });

  test("#8 an unhandled review on an older commit is still surfaced; handled one is not", () => {
    const rv = (id: number, oid: string) => ({ databaseId: id, author: bot("coderabbitai"), state: "COMMENTED", body: "Outside diff range comments (1)", submittedAt: "2026-01-04T00:00:00Z", commit: { oid } });
    const s = run(pr({
      reviews: { nodes: [rv(501, "old"), rv(502, HEAD)] },
      comments: { nodes: [cm(96, user(ME), "handled\n<!-- baby-sit handled:502 -->", 5)] },
    }));
    expect(s.newReviews.map((r: any) => [r.id, r.onHead])).toEqual([[501, false]]);
    expect(s.summaryMarker).toBe("<!-- baby-sit handled:501 -->");
  });

  test("r4#1 a bot thread with over 100 replies is never auto-resolved", () => {
    const comments = [cm(1, bot("coderabbitai"), "bug", 1), cm(2, user(ME), "fixed\n<!-- baby-sit handled:1 -->", 2)];
    const s = run(pr({ reviewThreads: { totalCount: 1, nodes: [thread("B", false, comments, 150)] } }));
    expect(s.threadsToResolve).toEqual([]);
    expect(s.nextAction).toBe("ask-user");
  });

});

describe("merge state", () => {
  test("#1 approval still required is not ready; asks the user", () => {
    const s = run(pr({ reviewDecision: "REVIEW_REQUIRED", mergeStateStatus: "BLOCKED" }));
    expect(s.ready).toBe(false);
    expect(s.nextAction).toBe("ask-user");
    expect(s.blockers.human).toContain("awaiting required approval");
  });

  test("#1 BLOCKED with no other reason is reported as branch protection", () => {
    const s = run(pr({ mergeStateStatus: "BLOCKED" }));
    expect(s.nextAction).toBe("ask-user");
    expect(s.blockers.human[0]).toStartWith("blocked by branch protection");
  });

  // useaspen#475: right after a push no checks exist yet, and that was reported as done
  test("#10 no checks on a fresh head is a wait; a repo without CI is not blocked forever", () => {
    const p = pr();
    (p.commits.nodes[0]!.commit as any).statusCheckRollup = null;
    const state = stateDir();
    const fresh = run(p, { state });
    expect([fresh.ci, fresh.nextAction, fresh.blockers.wait]).toEqual(["NONE", "wait", ["no checks reported on aaaaaaa yet"]]);
    expect(run(p, { state, now: T0 + 149 }).nextAction).toBe("wait");
    expect(run(p, { state, now: T0 + 150 }).nextAction).toBe("done");
  });

  test("#11 merged or closed PR stops the loop", () => {
    expect(run(pr({ state: "MERGED" })).nextAction).toBe("stop");
    expect(run(pr({ state: "CLOSED" })).nextAction).toBe("stop");
  });

  test("conflicts and behind-base are agent work; unknown mergeability is a wait", () => {
    expect(run(pr({ mergeable: "CONFLICTING", mergeStateStatus: "DIRTY" })).blockers.agent).toContain("merge conflicts with main");
    expect(run(pr({ mergeStateStatus: "BEHIND" })).nextAction).toBe("fix");
    expect(run(pr({ mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN" })).nextAction).toBe("wait");
  });
});

describe("checks", () => {
  test("#14 actions checks expose runId; external checks are marked external", () => {
    const p = pr();
    (p.commits.nodes[0]!.commit as any).statusCheckRollup = { state: "FAILURE", contexts: { nodes: [
      { __typename: "CheckRun", name: "test", status: "COMPLETED", conclusion: "FAILURE", detailsUrl: "https://github.com/o/r/actions/runs/4242/job/9" },
      { __typename: "StatusContext", context: "Vercel", state: "FAILURE", targetUrl: "https://vercel.com/x" },
    ] } };
    const s = run(p);
    expect(s.checksFailed).toEqual([
      { name: "test", url: "https://github.com/o/r/actions/runs/4242/job/9", kind: "actions", runId: "4242" },
      { name: "Vercel", url: "https://vercel.com/x", kind: "external", runId: null },
    ]);
    expect(s.nextAction).toBe("fix");
  });

  test("r2#6 CI rollup failure/pending is respected even when the check is not listed", () => {
    const withRollup = (state: string) => { const p = pr(); (p.commits.nodes[0]!.commit as any).statusCheckRollup = { state, contexts: { totalCount: 150, nodes: [] } }; return p; };
    const f = run(withRollup("FAILURE"));
    expect(f.nextAction).toBe("fix");
    expect(f.incomplete).toEqual(["only the first 100 checks were listed"]);
    expect(run(withRollup("PENDING")).nextAction).toBe("wait");
  });

  test("pending checks mean wait", () => {
    const p = pr();
    (p.commits.nodes[0]!.commit as any).statusCheckRollup = { state: "PENDING", contexts: { nodes: [{ __typename: "CheckRun", name: "ci", status: "IN_PROGRESS", conclusion: null, detailsUrl: "" }] } };
    expect(run(p).nextAction).toBe("wait");
  });
});

describe("#2 / r2#9 local checkout", () => {
  const repo = (setup: string) => {
    const dir = mkdtempSync(join(tmpdir(), "prs-git-"));
    const r = Bun.spawnSync(["sh", "-c", `git init -q -b feat && git remote add origin git@github.com:o/r.git
      c() { git -c user.email=a@b -c user.name=a commit -q --allow-empty -m "$1"; }
      c base && git rev-parse HEAD > .head && echo .head > .git/info/exclude
      ${setup}`], { cwd: dir });
    if (r.exitCode !== 0) throw new Error(r.stderr.toString());
    return { dir, head: require("fs").readFileSync(join(dir, ".head"), "utf8").trim() };
  };
  const at = (r: { dir: string; head: string }) => run(pr({ headRefOid: r.head }), { cwd: r.dir });

  test("in sync", () => expect(at(repo("")).local.relation).toBe("same"));
  test("wrong branch", () => expect(at(repo("git checkout -q -b other")).blockers.agent[0]).toBe("local checkout is on other, not feat"));
  test("unpushed commits block done", () => {
    const s = at(repo("c fix1; c fix2"));
    expect(s.blockers.agent[0]).toBe("2 unpushed local commits");
    expect(s.nextAction).toBe("fix");
  });
  test("stale checkout", () => expect(at(repo("c next; git rev-parse HEAD > .head; git reset -q --hard HEAD~1")).local.relation).toBe("behind"));
  test("diverged", () => expect(at(repo("c theirs; git rev-parse HEAD > .head; git reset -q --hard HEAD~1; c mine")).local.relation).toBe("diverged"));
  test("changes to tracked files block", () => expect(at(repo("echo x > t.txt && git add t.txt")).blockers.agent).toContain("1 uncommitted local changes"));
  // useaspen#460: a stray build file made --wait return "fix" at once
  test("untracked files are reported but do not block", () => {
    const s = at(repo("echo x > build.log"));
    expect([s.local.dirty, s.local.untracked, s.nextAction]).toEqual([0, 1, "done"]);
  });
  test("r3#5 fork: base remote is the one pointing at the PR repo, not origin", () => {
    const s = at(repo("git remote set-url origin git@github.com:me/r.git && git remote add upstream https://github.com/o/r.git"));
    expect(s.local.baseRemote).toBe("upstream");
    expect(s.local.repoMatches).toBe(true);
  });
  test("different repo", () => expect(at(repo("git remote set-url origin git@github.com:x/other.git")).blockers.agent[0]).toBe("local checkout is not a clone of o/r"));
});

describe("checks that need a person", () => {
  const withRollup = (state: string, ...nodes: object[]) => { const p = pr(); (p.commits.nodes[0]!.commit as any).statusCheckRollup = { state, contexts: { nodes } }; return p; };
  const withChecks = (...nodes: object[]) => withRollup("PENDING", ...nodes);
  const ci = { __typename: "CheckRun", name: "ci", status: "COMPLETED", conclusion: "SUCCESS", detailsUrl: "" };

  // minip2p#281/#295: aws-bench waits for a deployment approval; --wait sat 31 minutes on it
  test("a job waiting for approval asks the user at once instead of waiting", () => {
    const s = run(withChecks(ci, { __typename: "CheckRun", name: "aws-bench", status: "WAITING", conclusion: null, detailsUrl: "u" }));
    expect(s.checksPending).toEqual([]);
    expect(s.nextAction).toBe("ask-user");
    expect(s.blockers.human).toContain("check aws-bench is waiting for someone to approve it");
  });

  test("an approval-held job is reported at once while other checks keep running", () => {
    const s = run(withChecks({ __typename: "CheckRun", name: "aws-bench", status: "WAITING", conclusion: null, detailsUrl: "u" },
                             { __typename: "CheckRun", name: "test", status: "IN_PROGRESS", conclusion: null, detailsUrl: "" }));
    expect([s.nextAction, s.tellUserNow]).toEqual(["wait", ["check aws-bench is waiting for someone to approve it"]]);
  });

  test("action_required is a question for the user, not a failure to fix", () => {
    const s = run(withRollup("FAILURE", { __typename: "CheckRun", name: "deploy", status: "COMPLETED", conclusion: "ACTION_REQUIRED", detailsUrl: "u" }));
    expect([s.checksFailed, s.nextAction]).toEqual([[], "ask-user"]);
  });

  test("a check re-run on an old head gets its own hour", () => {
    const running = withChecks({ __typename: "CheckRun", name: "e2e", status: "IN_PROGRESS", conclusion: null, detailsUrl: "" });
    const finished = withRollup("SUCCESS", { __typename: "CheckRun", name: "e2e", status: "COMPLETED", conclusion: "SUCCESS", detailsUrl: "" });
    const state = stateDir();
    run(finished, { state });
    const rerun = run(running, { state, now: T0 + 7200 });
    expect([rerun.nextAction, rerun.blockers.wait]).toEqual(["wait", ["1 checks running"]]);
    expect(run(running, { state, now: T0 + 7200 + 3601 }).nextAction).toBe("ask-user");
  });

  test("a check still running long after the push is reported, not waited on forever", () => {
    const p = withChecks({ __typename: "CheckRun", name: "e2e", status: "IN_PROGRESS", conclusion: null, detailsUrl: "" });
    const state = stateDir();
    expect(run(p, { state }).nextAction).toBe("wait");
    const late = run(p, { state, now: T0 + 3601 });
    expect(late.nextAction).toBe("ask-user");
    expect(late.blockers.human).toContain("1 checks still running after 60m: e2e");
  });
});

describe("review bots on the head commit", () => {
  const review = (id: number, login: string, oid: string, body = "Looks good") =>
    ({ databaseId: id, author: bot(login), state: "COMMENTED", body, submittedAt: "2026-01-04T00:00:00Z", commit: { oid } });
  const handled = (...ids: number[]) => cm(900, user(ME), `ok\n<!-- baby-sit handled:${ids.join(",")} -->`, 8);
  const withCheck = (p: any, node: object) => { p.commits.nodes[0].commit.statusCheckRollup.contexts.nodes.push(node); return p; };

  // baibai#16/#18: "Cubic: all reported issues addressed" quoted a review of the previous commit
  test("a bot whose last review is on an older commit is waited for, then asked about", () => {
    const p = pr({ reviews: { nodes: [review(501, "cubic-dev-ai", "old")] }, comments: { nodes: [handled(501)] } });
    const state = stateDir();
    const s = run(p, { state });
    expect(s.nextAction).toBe("wait");
    expect(s.blockers.wait).toEqual(["waiting for cubic-dev-ai to review aaaaaaa"]);
    expect(s.reviewBots).toEqual([{ bot: "cubic-dev-ai", reviewedHead: false, skippedHead: false, checksRunning: [], rereviewRequested: false, waitedSecs: 0 }]);
    const late = run(p, { state, now: T0 + 900 });
    expect(late.nextAction).toBe("ask-user");
    expect(late.blockers.human).toEqual(["cubic-dev-ai has not reviewed aaaaaaa after 15m (skipped, out of quota, or needs a trigger)"]);
  });

  test("a review on the head commit counts", () => {
    const s = run(pr({ reviews: { nodes: [review(501, "cubic-dev-ai", "old"), review(502, "cubic-dev-ai", HEAD)] }, comments: { nodes: [handled(501, 502)] } }));
    expect([s.reviewBots[0].reviewedHead, s.nextAction]).toEqual([true, "done"]);
  });

  test("a passed bot check on the head counts (CodeRabbit posts 'Review completed' as a status)", () => {
    const p = withCheck(pr({ reviews: { nodes: [review(501, "coderabbitai", "old")] }, comments: { nodes: [handled(501)] } }),
      { __typename: "StatusContext", context: "CodeRabbit", state: "SUCCESS", targetUrl: "", creator: { login: "coderabbitai" } });
    expect(run(p).nextAction).toBe("done");
  });

  test("a CI job named after the bot is not the bot's review", () => {
    const p = withCheck(pr({ reviews: { nodes: [review(501, "coderabbitai", "old")] }, comments: { nodes: [handled(501)] } }),
      { __typename: "CheckRun", name: "CodeRabbit integration tests", status: "COMPLETED", conclusion: "SUCCESS", detailsUrl: "", checkSuite: { app: { slug: "github-actions" } } });
    expect(run(p).reviewBots[0].reviewedHead).toBe(false);
  });

  test("a bot reply in a thread is not a review of the head (a 'thanks' says nothing about new commits)", () => {
    const p = pr({ reviews: { nodes: [review(501, "greptile-apps", "old")] }, comments: { nodes: [handled(501)] },
      reviewThreads: { totalCount: 1, nodes: [thread("G", true, [cm(7, bot("greptile-apps"), "thanks!", 11)])] } });
    expect(run(p, { rawBots: true }).reviewBots[0].reviewedHead).toBe(false);
  });

  test("a pending (unsubmitted) review of the head does not count", () => {
    const p = pr({ reviews: { nodes: [{ ...review(501, "cubic-dev-ai", HEAD), state: "PENDING" }] } });
    expect(run(p, { rawBots: true }).reviewBots[0].reviewedHead).toBe(false);
  });

  test("a known AI reviewer that has only posted 'review in progress' is expected", () => {
    const s = run(pr({ comments: { nodes: [cm(95, bot("coderabbitai"), "Currently processing new changes", 11)] } }), { rawBots: true });
    expect(s.blockers.wait).toEqual(["waiting for coderabbitai to review aaaaaaa"]);
  });

  test("other commenting bots (previews, deploys) are not reviewers", () => {
    const s = run(pr({ comments: { nodes: [cm(95, bot("vercel"), "Preview ready", 11)] } }), { rawBots: true });
    expect([s.reviewBots, s.nextAction]).toEqual([[], "done"]);
  });

  test("if the repo's bot history can't be read, an older cached list is used", () => {
    const state = stateDir();
    run(pr(), { state, history: history([bot("cubic-dev-ai")]) });
    const s = run(pr(), { state, now: T0 + 2 * 86400, history: FAIL, env: { RETRY_DELAY: "0" } });
    expect(s.reviewBots.map((b: any) => b.bot)).toEqual(["cubic-dev-ai"]);
  });

  test("if the repo's bot history can't be read and nothing is cached, the check fails instead of assuming no bots", () => {
    const r = exec(pr(), { history: FAIL, env: { RETRY_DELAY: "0" } });
    expect([r.exitCode, JSON.parse(r.stdout.toString()).nextAction]).toEqual([1, "error"]);
  });

  test("wakeOnEvent: a PR watcher wakes for running checks, not for a silent bot", () => {
    const running = pr({ reviews: { nodes: [review(501, "cubic-dev-ai", "old")] }, comments: { nodes: [handled(501)] } });
    expect(run(running).wakeOnEvent).toBe(false);
    (running.commits.nodes[0]!.commit as any).statusCheckRollup = { state: "PENDING", contexts: { nodes: [{ __typename: "CheckRun", name: "ci", status: "IN_PROGRESS", conclusion: null, detailsUrl: "" }] } };
    expect(run(running).wakeOnEvent).toBe(true);
  });

  // minip2p#73/#76: cubic showed "skipping" and was read as a pass
  test("a skipped bot check is not a review, and the report says it was skipped", () => {
    const p = withCheck(pr({ reviews: { nodes: [review(501, "cubic-dev-ai", "old")] }, comments: { nodes: [handled(501)] } }),
      { __typename: "CheckRun", name: "cubic · AI code reviewer", status: "COMPLETED", conclusion: "SKIPPED", detailsUrl: "", checkSuite: { app: { slug: "cubic-dev-ai" } } });
    const state = stateDir();
    run(p, { state });
    const s = run(p, { state, now: T0 + 900 });
    expect(s.checksSkipped).toEqual(["cubic · AI code reviewer"]);
    expect(s.blockers.human).toEqual(["cubic-dev-ai has not reviewed aaaaaaa after 15m (its check was skipped)"]);
  });

  // minipaw#3: Greptile's check ran 24m; it was reported as "out of quota" at 15m, 5m before it posted
  test("a bot whose own check is still running is waited on past the grace period", () => {
    const p = withCheck(pr({ reviews: { nodes: [review(501, "greptile-apps", "old")] }, comments: { nodes: [handled(501)] } }),
      { __typename: "CheckRun", name: "Greptile Review", status: "IN_PROGRESS", conclusion: null, detailsUrl: "", checkSuite: { app: { slug: "greptile-apps" } } });
    const state = stateDir();
    run(p, { state });
    const s = run(p, { state, now: T0 + 1500 });
    expect([s.nextAction, s.wakeOnEvent, s.blockers.human]).toEqual(["wait", true, []]);
    expect(s.blockers.wait).toContain("greptile-apps is reviewing aaaaaaa (its check is running)");
    const stuck = run(p, { state, now: T0 + 3601 });
    expect([stuck.nextAction, stuck.blockers.wait]).toEqual(["ask-user", []]);
    expect(stuck.blockers.human).toEqual(["1 checks still running after 60m: Greptile Review"]);
  });

  test("on a new PR, bots that review this repo's merged PRs are expected before they post", () => {
    const s = run(pr(), { history: history([bot("coderabbitai"), user("alice")], [user("bob")]) });
    expect(s.blockers.wait).toEqual(["waiting for coderabbitai to review aaaaaaa"]);
  });

  test("a repo without review bots is done as soon as CI is", () => {
    expect(run(pr(), { history: history([user("alice")], []) }).nextAction).toBe("done");
  });

  test("BABYSIT_IGNORE_BOTS drops a bot from the expected reviewers", () => {
    const s = run(pr(), { history: history([bot("coderabbitai")]), env: { BABYSIT_IGNORE_BOTS: "coderabbitai" } });
    expect([s.reviewBots, s.nextAction]).toEqual([[], "done"]);
  });

  test("a recorded re-review request restarts that bot's grace period", () => {
    const p = pr({ reviews: { nodes: [review(501, "greptile-apps", "old")] }, comments: { nodes: [handled(501)] } });
    const state = stateDir();
    run(p, { state });
    expect(run(p, { state, now: T0 + 900 }).nextAction).toBe("ask-user");
    run([], { state, now: T0 + 1000, args: ["--record", "rereview", "greptile-apps", "7"] });
    const s = run(p, { state, now: T0 + 1100 });
    expect([s.nextAction, s.reviewBots[0].rereviewRequested, s.reviewBots[0].waitedSecs]).toEqual(["wait", true, 100]);
  });
});

describe("--record", () => {
  test("concurrent records from several agents are all kept", async () => {
    const state = stateDir();
    const dir = mkdtempSync(join(tmpdir(), "prs-"));
    const procs = Array.from({ length: 8 }, () => Bun.spawn(["bash", SCRIPT, "--record", "round", "7"],
      { env: { ...process.env, GH_REPO: "o/r", BABYSIT_STATE_DIR: state, BABYSIT_NOW: String(T0) }, cwd: dir, stdout: "ignore" }));
    await Promise.all(procs.map((p) => p.exited));
    expect(run(pr(), { state }).session.rounds).toBe(8);
  });

  test("rounds and reopened threads are remembered and reported", () => {
    const state = stateDir();
    run([], { state, args: ["--record", "round", "7"] });
    run([], { state, args: ["--record", "round", "7"] });
    run([], { state, args: ["--record", "reopen", "T1", "7"] });
    expect(run(pr(), { state }).session).toEqual({ rounds: 2, reopenedThreads: ["T1"] });
  });

  test("a re-review before any status run fails without wiping the state", () => {
    const state = stateDir();
    run([], { state, args: ["--record", "round", "7"] });
    expect(exec([], { state, args: ["--record", "rereview", "greptile-apps", "7"] }).exitCode).not.toBe(0);
    expect(run(pr(), { state }).session.rounds).toBe(1);
  });
});

describe("GitHub errors", () => {
  const fast = { RETRY_DELAY: "0" };

  test("a transient failure is retried", () => {
    expect(run([FAIL, FAIL, pr()], { env: fast }).nextAction).toBe("done");
  });

  test("failing to find the PR or the repo still prints the error JSON", () => {
    for (const opts of [{ args: [] as string[] }, { args: ["7"], env: { GH_REPO: "" } }]) {
      const r = exec([FAIL], { ...opts, env: { ...fast, ...opts.env } });
      expect([r.exitCode, JSON.parse(r.stdout.toString()).nextAction]).toEqual([1, "error"]);
    }
  });

  test("an unwritable state dir fails the check quickly instead of hanging", () => {
    const file = join(stateDir(), "not-a-dir");
    writeFileSync(file, "");
    const started = Date.now();
    const r = exec(pr(), { state: file, env: fast });
    expect([r.exitCode, JSON.parse(r.stdout.toString()).nextAction]).toEqual([1, "error"]);
    expect(Date.now() - started).toBeLessThan(5000);
  });

  test("several agents recovering the same stale lock lose no updates", async () => {
    const state = stateDir();
    writeFileSync(join(state, "o_r-7.json.lock"), "999999");
    const dir = mkdtempSync(join(tmpdir(), "prs-"));
    const procs = Array.from({ length: 8 }, () => Bun.spawn(["bash", SCRIPT, "--record", "round", "7"],
      { env: { ...process.env, GH_REPO: "o/r", BABYSIT_STATE_DIR: state, BABYSIT_NOW: String(T0) }, cwd: dir, stdout: "ignore" }));
    await Promise.all(procs.map((p) => p.exited));
    expect(run(pr(), { state }).session.rounds).toBe(8);
  });

  test("a lock directory left by the previous version is cleared after 10s", () => {
    const state = stateDir();
    require("fs").mkdirSync(join(state, "o_r-7.json.lock"));
    expect(run(pr(), { state }).nextAction).toBe("done");
  }, 20_000);

  test("a lock left by a dead process is taken over", () => {
    const state = stateDir();
    writeFileSync(join(state, "o_r-7.json.lock"), "999999");
    expect(run(pr(), { state }).nextAction).toBe("done");
  });

  test("three failures give nextAction error and exit 1, with JSON on stdout", () => {
    const r = exec([FAIL], { env: fast });
    expect(r.exitCode).toBe(1);
    expect(JSON.parse(r.stdout.toString()).nextAction).toBe("error");
  });
});

describe("#12 --wait", () => {
  test("a new approval notice ends the wait; the next wait does not return for it again", () => {
    const running = { __typename: "CheckRun", name: "test", status: "IN_PROGRESS", conclusion: null, detailsUrl: "" };
    const both = pr();
    (both.commits.nodes[0]!.commit as any).statusCheckRollup = { state: "PENDING", contexts: { nodes: [running,
      { __typename: "CheckRun", name: "aws-bench", status: "WAITING", conclusion: null, detailsUrl: "" }] } };
    const onlyTest = pr();
    (onlyTest.commits.nodes[0]!.commit as any).statusCheckRollup = { state: "PENDING", contexts: { nodes: [running] } };
    const state = stateDir();
    const first = run([onlyTest, both], { state, args: ["--wait", "7"], env: { POLL_SECS: "0", WAIT_SECS: "60" } });
    expect([first.nextAction, first.waitResult, first.newNotices]).toEqual(["wait", "changed", ["check aws-bench is waiting for someone to approve it"]]);
    const again = run([both], { state, args: ["--wait", "7"], env: { POLL_SECS: "1", WAIT_SECS: "2" } });
    expect([again.waitResult, again.newNotices, again.tellUserNow.length]).toEqual(["still-waiting", [], 1]);
    // approved, then needed again (a re-run): that is news again
    run(onlyTest, { state });
    expect(run(both, { state }).newNotices).toEqual(["check aws-bench is waiting for someone to approve it"]);
  });

  const pending = () => {
    const p = pr();
    (p.commits.nodes[0]!.commit as any).statusCheckRollup = { state: "PENDING", contexts: { nodes: [{ __typename: "CheckRun", name: "ci", status: "QUEUED", conclusion: null, detailsUrl: "" }] } };
    return p;
  };
  const fast = { POLL_SECS: "0", RETRY_DELAY: "0" };

  test("polls until there is something to do, then reports", () => {
    const s = run([pending(), pending(), pr()], { args: ["--wait", "7"], env: { ...fast, WAIT_SECS: "60" } });
    expect([s.nextAction, s.waitResult]).toEqual(["done", "changed"]);
  });

  test("r2#11 work arriving while CI still runs returns at once", () => {
    const busy = pending();
    busy.comments = { nodes: [cm(91, user("alice"), "one more thing", 5)] };
    const s = run([pending(), busy], { args: ["--wait", "7"], env: { ...fast, WAIT_SECS: "60" } });
    expect([s.nextAction, s.waitResult, s.checksPending]).toEqual(["fix", "changed", ["ci"]]);
  });

  test("returns still-waiting after WAIT_SECS so one call fits in a tool timeout", () => {
    const s = run([pending()], { args: ["--wait", "7"], env: { POLL_SECS: "1", WAIT_SECS: "2" } });
    expect([s.nextAction, s.waitResult]).toEqual(["wait", "still-waiting"]);
  });

  test("a failed poll is retried on the next poll instead of ending the wait", () => {
    const s = run([pending(), FAIL, FAIL, FAIL, pr()], { args: ["--wait", "7"], env: { ...fast, WAIT_SECS: "60" } });
    expect([s.nextAction, s.waitResult]).toEqual(["done", "changed"]);
  });
});
