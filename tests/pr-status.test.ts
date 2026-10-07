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

// merged-PR history for the repo-level bot check: one entry per PR, listing author types
// "more" marks a PR with more comments than the check fetches
const history = (...prs: ("Bot" | "User" | "more")[][]) => ({ data: { repository: { pullRequests: { nodes:
  prs.map((types) => ({
    comments: { pageInfo: { hasNextPage: types.includes("more") }, nodes: types.filter((t) => t !== "more").map((t) => ({ author: { __typename: t } })) },
    reviews: { pageInfo: { hasNextPage: false }, nodes: [] },
  })) } } } });

// fixtures: one response, or a list served in order (last one repeats)
function run(fixtures: object | object[], opts: { args?: string[]; env?: Record<string, string>; cwd?: string; history?: object } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "prs-"));
  const list = (Array.isArray(fixtures) ? fixtures : [fixtures]).map((p) => ({ data: { viewer: { login: ME }, repository: { pullRequest: p } } }));
  list.forEach((f, i) => writeFileSync(join(dir, `f${i}.json`), JSON.stringify(f)));
  writeFileSync(join(dir, "history.json"), JSON.stringify(opts.history ?? history()));
  writeFileSync(join(dir, "gh"), `#!/bin/sh
case "$*" in *recentBotCheck*) cat "${dir}/history.json"; exit;; esac
n=$(cat "${dir}/count" 2>/dev/null || echo 0); echo $((n+1)) > "${dir}/count"
i=$n; [ $i -ge ${list.length} ] && i=${list.length - 1}
cat "${dir}/f$i.json"\n`);
  chmodSync(join(dir, "gh"), 0o755);
  const r = Bun.spawnSync(["bash", SCRIPT, ...(opts.args ?? ["7"])], {
    cwd: opts.cwd ?? dir,
    // stop git from finding an enclosing repo when TMPDIR itself lives inside one
    env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, GH_REPO: "o/r", GIT_CEILING_DIRECTORIES: dirname(opts.cwd ?? dir), ...opts.env },
  });
  if (r.exitCode !== 0) throw new Error(r.stderr.toString());
  return JSON.parse(r.stdout.toString());
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

  test("r2#3 new bot top-level comments must be read (block) until a marker lists them", () => {
    const s = run(pr({ comments: { nodes: [cm(95, bot("cubic-dev-ai"), "P1: null deref in x.ts", 5)] } }));
    expect(s.newComments.map((c: any) => c.id)).toEqual([95]);
    expect(s.nextAction).toBe("fix");
    const after = run(pr({ comments: { nodes: [cm(95, bot("cubic-dev-ai"), "P1", 5), cm(96, user(ME), "fixed\n<!-- baby-sit handled:95 -->", 6)] } }));
    expect(after.nextAction).toBe("done");
  });

  test("r2#7 handled ids come only from the trailing marker, not quoted text", () => {
    const s = run(pr({ comments: { nodes: [
      cm(91, user("alice"), "fix X", 1),
      cm(92, user(ME), "earlier I wrote handled:91 in a note\n<!-- baby-sit -->", 2),
    ] } }));
    expect(s.newComments.map((c: any) => c.id)).toEqual([91]);
  });

  test("r2#8 an item edited after it was handled comes back", () => {
    const edited = { ...cm(91, bot("coderabbitai"), "summary v2 with new finding", 1), lastEditedAt: "2026-01-09T00:00:00Z" };
    const s = run(pr({ comments: { nodes: [edited, cm(92, user(ME), "ok\n<!-- baby-sit handled:91 -->", 3)] } }));
    expect(s.newComments.map((c: any) => c.id)).toEqual([91]);
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

  test("#10 repo with no checks is not blocked forever", () => {
    const p = pr();
    (p.commits.nodes[0]!.commit as any).statusCheckRollup = null;
    const s = run(p);
    expect(s.ci).toBe("NONE");
    expect(s.nextAction).toBe("done");
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
  test("dirty worktree blocks", () => expect(at(repo("echo x > f.txt")).blockers.agent).toContain("1 uncommitted local changes"));
  test("r3#5 fork: base remote is the one pointing at the PR repo, not origin", () => {
    const s = at(repo("git remote set-url origin git@github.com:me/r.git && git remote add upstream https://github.com/o/r.git"));
    expect(s.local.baseRemote).toBe("upstream");
    expect(s.local.repoMatches).toBe(true);
  });
  test("different repo", () => expect(at(repo("git remote set-url origin git@github.com:x/other.git")).blockers.agent[0]).toBe("local checkout is not a clone of o/r"));
});

describe("#12 --wait", () => {
  const pending = () => {
    const p = pr();
    (p.commits.nodes[0]!.commit as any).statusCheckRollup = { state: "PENDING", contexts: { nodes: [{ __typename: "CheckRun", name: "ci", status: "QUEUED", conclusion: null, detailsUrl: "" }] } };
    return p;
  };
  const fast = { POLL_SECS: "0", SETTLE_SECS: "0" };

  test("polls until checks finish, then reports", () => {
    const s = run([pending(), pending(), pr()], { args: ["--wait", "7"], env: { ...fast, WAIT_SECS: "60" } });
    expect(s.nextAction).toBe("done");
    expect(s.waitResult).toBe("settled");
  });

  test("r2#11 work arriving while CI still runs returns early as actionable, not as a finished wait", () => {
    const busy = pending();
    busy.comments = { nodes: [cm(91, user("alice"), "one more thing", 5)] };
    const s = run([pending(), busy], { args: ["--wait", "7"], env: { ...fast, WAIT_SECS: "60" } });
    expect(s.waitResult).toBe("actionable");
    expect(s.checksPending).toEqual(["ci"]);
  });

  test("gives up after WAIT_SECS on a stuck check", () => {
    const s = run([pending()], { args: ["--wait", "7"], env: { POLL_SECS: "1", SETTLE_SECS: "0", WAIT_SECS: "2" } });
    expect(s.waitResult).toBe("timed-out");
    expect(s.timedOut).toBe(true);
  });
});

describe("--wait bot settle skip", () => {
  // a clone in sync with the PR, so the local checkout doesn't block
  const clone = () => {
    const dir = mkdtempSync(join(tmpdir(), "prs-settle-"));
    Bun.spawnSync(["sh", "-c", `git init -q -b feat && git remote add origin git@github.com:o/r.git
      git -c user.email=a@b -c user.name=a commit -q --allow-empty -m x`], { cwd: dir });
    const head = Bun.spawnSync(["git", "rev-parse", "HEAD"], { cwd: dir }).stdout.toString().trim();
    return { dir, head };
  };
  const env = { POLL_SECS: "0", SETTLE_SECS: "2", WAIT_SECS: "60" };
  const wait = (p: object, cwd?: string) => run(p, { args: ["--wait", "7"], env, cwd });

  test("no bots: first wait settles, later waits skip", () => {
    const c = clone();
    const first = wait(pr({ headRefOid: c.head }), c.dir);
    expect([first.nextAction, first.settleSkipped, first.botsSeen]).toEqual(["done", false, false]);
    expect(first.waitedSecs).toBeGreaterThanOrEqual(2);
    const second = wait(pr({ headRefOid: c.head }), c.dir);
    expect(second.settleSkipped).toBe(true);
    expect(second.waitedSecs).toBeLessThan(2);
  }, 20_000);

  test("a bot has posted: never skips", () => {
    const c = clone();
    const withBot = pr({ headRefOid: c.head, comments: { nodes: [
      cm(95, bot("coderabbitai"), "summary", 1), cm(96, user(ME), "ok\n<!-- baby-sit handled:95 -->", 2)] } });
    wait(withBot, c.dir);
    const again = wait(withBot, c.dir);
    expect([again.botsSeen, again.settleSkipped]).toEqual([true, false]);
  }, 20_000);

  test("outside a clone: never skips on its own", () => {
    wait(pr());
    expect(wait(pr()).settleSkipped).toBe(false);
  }, 20_000);

  test("repo with no bots on recent merged PRs: skips even on the first wait", () => {
    const s = run(pr(), { args: ["--wait", "7"], env, history: history(["User"], ["User", "User"]) });
    expect(s.settleSkipped).toBe(true);
    expect(s.waitedSecs).toBeLessThan(2);
  }, 20_000);

  test("repo where a bot reviewed a recent PR: first wait still runs", () => {
    const s = run(pr(), { args: ["--wait", "7"], env, history: history(["User"], ["Bot"]) });
    expect(s.settleSkipped).toBe(false);
  }, 20_000);

  test("busy PR in history with more comments than fetched: first wait still runs", () => {
    expect(run(pr(), { args: ["--wait", "7"], env, history: history(["User"], ["User", "more"]) }).settleSkipped).toBe(false);
  }, 20_000);

  test("repo with no merged PRs: first wait still runs", () => {
    expect(run(pr(), { args: ["--wait", "7"], env, history: history() }).settleSkipped).toBe(false);
  }, 20_000);
});
