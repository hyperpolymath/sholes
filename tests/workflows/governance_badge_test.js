#!/usr/bin/env node
"use strict";
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Hermetic tests for scripts/governance-badge.js: the state -> badge table, the
// byte-equality no-op, the publication decisions, and the API-error
// classification. Nothing here talks to github.com.
//
// The GitHub REST API is replaced by an in-process mock (node:http) whose state
// is a branch name, an optional file, and a per-route script of injected HTTP
// statuses, explicit responses, or stalls. The helper runs as a child process against
// `--api-url`, exactly as it does in the workflow, so tests exercise the real
// fetch/status paths rather than a stubbed function.
//
// Runtime-agnostic on purpose: CommonJS + node: builtins only, so it runs under
// the estate's first-choice runtime (Bun) and under Node, which is what makes
// the suite runnable outside CI. Spawn as: bun <this file> | node <this file>.

const { spawn, spawnSync } = require("node:child_process");
const { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const http = require("node:http");
const { tmpdir } = require("node:os");
const { join, resolve } = require("node:path");

const REPO_DIR = resolve(__dirname, "..", "..");
const HELPER = join(REPO_DIR, "scripts", "governance-badge.js");
const RUNTIME = process.execPath;
const LABEL = "K9";
const BRANCH = "governance-badges";
const DEST = "badges/k9.json";
const SOURCE_SHA = "0123456789abcdef0123456789abcdef01234567";

const SUCCESS_BADGE = '{"schemaVersion":1,"label":"K9","message":"success","color":"brightgreen"}\n';
const FAILURE_BADGE = '{"schemaVersion":1,"label":"K9","message":"failure","color":"red"}\n';
const SKIPPED_BADGE = '{"schemaVersion":1,"label":"K9","message":"skipped","color":"lightgrey"}\n';
const GREY_BADGE = '{"schemaVersion":1,"label":"K9","message":"unavailable","color":"lightgrey"}\n';

// Structural failures are invalid both as lane evidence and as existing
// output. Keep the expected policy independent of the helper's validator.
const INVALID_BADGES = [
    ["JSON null", "null\n"],
    ["JSON string", '"success"\n'],
    ["string schemaVersion", '{"schemaVersion":"1","label":"K9","message":"success","color":"brightgreen"}\n'],
    ["unsupported schemaVersion", '{"schemaVersion":2,"label":"K9","message":"success","color":"brightgreen"}\n'],
    ["another lane's label", '{"schemaVersion":1,"label":"OTHER","message":"success","color":"brightgreen"}\n'],
    ["missing label", '{"schemaVersion":1,"message":"success","color":"brightgreen"}\n'],
    ["empty message", '{"schemaVersion":1,"label":"K9","message":"","color":"brightgreen"}\n'],
    ["numeric message", '{"schemaVersion":1,"label":"K9","message":1,"color":"brightgreen"}\n'],
    ["missing color", '{"schemaVersion":1,"label":"K9","message":"success"}\n'],
    ["empty color", '{"schemaVersion":1,"label":"K9","message":"success","color":""}\n'],
    ["numeric color", '{"schemaVersion":1,"label":"K9","message":"success","color":1}\n'],
];

// ---------------------------------------------------------------------------
// Tiny test runner (the estate's Silence + Firing + Setup-error convention)
// ---------------------------------------------------------------------------

let passed = 0;
let failed = 0;
const failures = [];

async function test(name, fn) {
    try {
        await fn();
        passed += 1;
        console.log(`  PASS: ${name}`);
    } catch (err) {
        failed += 1;
        failures.push({ name, err });
        const detail = String(err && err.message ? err.message : err)
            .replace(/[\r\n]+/g, " ")
            .slice(0, 400);
        console.log(`  FAIL: ${name}`);
        console.log(`        ${String(err && err.message ? err.message : err).replace(/\n/g, "\n        ")}`);
        // Surface the failing check through the run's annotations: the log
        // itself can be awkward to reach, and a bare "exit code 1" is not a
        // report.
        // Workflow commands are only interpreted on stdout.  // NOSONAR
        console.log(`::error::governance-badge test failed: ${name} - ${detail}`);
    }
}

function section(title) {
    console.log(`\n=== ${title} ===`);
}

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function equal(actual, expected, message) {
    if (actual !== expected) {
        throw new Error(`${message}\n  wanted: ${JSON.stringify(expected)}\n  got:    ${JSON.stringify(actual)}`);
    }
}

// ---------------------------------------------------------------------------
// Mock GitHub REST API
// ---------------------------------------------------------------------------

function wrapBase64(buffer) {
    // GitHub wraps base64 payloads at 60 characters with newlines; decoding must
    // tolerate that, so the mock reproduces it.
    const encoded = buffer.toString("base64");
    const lines = [];
    for (let i = 0; i < encoded.length; i += 60) lines.push(encoded.slice(i, i + 60));
    return lines.join("\n");
}

function createApi(options = {}) {
    const state = {
        repo: options.repo || "example/template",
        defaultBranch: options.defaultBranch || "main",
        sourceHead: options.sourceHead || SOURCE_SHA,
        branchExists: Boolean(options.branchExists),
        file: options.fileBytes === undefined
            ? null
            : { sha: "sha-initial", bytes: Buffer.from(options.fileBytes, "utf8") },
        requests: [],
        script: new Map(),
        commitParents: options.commitParents || null,
        blobs: new Map(),
        trees: new Map(),
        commits: new Map(),
        counter: 0,
        hook: options.hook || null,
    };

    function nextSha(prefix) {
        state.counter += 1;
        return `${prefix}-${state.counter}`;
    }

    function routeOf(method, pathname) {
        if (pathname === `/repos/${state.repo}`) return "repo";
        if (pathname.includes("/contents/")) return method === "PUT" ? "contents-put" : "contents-get";
        if (pathname === `/repos/${state.repo}/git/ref/heads/${state.defaultBranch}`) return "source-ref-get";
        if (/\/git\/ref\/heads\//.test(pathname)) return "ref-get";
        if (/\/git\/refs$/.test(pathname)) return "refs-post";
        if (/\/git\/blobs$/.test(pathname)) return "blobs-post";
        if (/\/git\/trees$/.test(pathname)) return "trees-post";
        if (/\/git\/commits$/.test(pathname)) return "commits-post";
        return "unknown";
    }

    function send(res, status, payload) {
        const body = JSON.stringify(payload);
        res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
        res.end(body);
    }

    function bytesForTree(treeSha) {
        const blobSha = state.trees.get(treeSha);
        return blobSha === undefined ? null : state.blobs.get(blobSha);
    }

    async function handle(req, res) {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const raw = Buffer.concat(chunks).toString("utf8");
        const url = new URL(req.url, "http://127.0.0.1");
        const route = routeOf(req.method, url.pathname);
        let body = null;
        if (raw) {
            try {
                body = JSON.parse(raw);
            } catch {
                body = raw;
            }
        }
        const entry = {
            method: req.method,
            route,
            path: url.pathname,
            query: url.search,
            body,
        };
        state.requests.push(entry);

        if (state.hook) state.hook(entry, state);

        const scripted = state.script.get(route);
        if (scripted && scripted.length) {
            const response = scripted.shift();
            if (response === "stall-headers") return;
            if (response === "stall-body") {
                res.writeHead(200, { "Content-Type": "application/json" });
                res.write('{"incomplete":');
                return;
            }
            if (typeof response === "object") {
                res.writeHead(response.status, { "Content-Type": "application/json" });
                return res.end(response.text === undefined ? JSON.stringify(response.body) : response.text);
            }
            if (response >= 400) return send(res, response, { message: `injected ${response}` });
        }

        switch (route) {
            case "repo":
                return send(res, 200, { full_name: state.repo, default_branch: state.defaultBranch });

            case "contents-get": {
                if (!state.branchExists) return send(res, 404, { message: "Not Found" });
                if (!state.file) return send(res, 404, { message: "Not Found" });
                return send(res, 200, {
                    name: DEST.split("/").pop(),
                    path: DEST,
                    sha: state.file.sha,
                    size: state.file.bytes.length,
                    encoding: "base64",
                    content: wrapBase64(state.file.bytes),
                });
            }

            case "source-ref-get":
                return send(res, 200, {
                    ref: `refs/heads/${state.defaultBranch}`,
                    object: { sha: state.sourceHead, type: "commit" },
                });

            case "ref-get": {
                if (!state.branchExists) return send(res, 404, { message: "Not Found" });
                return send(res, 200, {
                    ref: `refs/heads/${BRANCH}`,
                    object: { sha: state.file ? state.file.sha : "ref-only", type: "commit" },
                });
            }

            case "contents-put": {
                if (!state.branchExists) return send(res, 404, { message: "Not Found" });
                if (state.file && !body.sha) {
                    return send(res, 422, { message: "sha wasn't supplied" });
                }
                if (state.file && body.sha !== state.file.sha) {
                    return send(res, 409, { message: "sha does not match" });
                }
                const created = !state.file;
                state.file = { sha: nextSha("sha"), bytes: Buffer.from(body.content, "base64") };
                return send(res, created ? 201 : 200, {
                    content: { sha: state.file.sha },
                    commit: { sha: nextSha("commit") },
                });
            }

            case "blobs-post": {
                const sha = nextSha("blob");
                state.blobs.set(sha, Buffer.from(body.content, "base64"));
                return send(res, 201, { sha });
            }

            case "trees-post": {
                const sha = nextSha("tree");
                state.trees.set(sha, body.tree[0].sha);
                return send(res, 201, { sha, tree: body.tree });
            }

            case "commits-post": {
                const sha = nextSha("commit");
                state.commits.set(sha, body.tree);
                const parents = state.commitParents === null ? body.parents : state.commitParents;
                return send(res, 201, { sha, tree: { sha: body.tree }, parents });
            }

            case "refs-post": {
                if (body.ref !== `refs/heads/${BRANCH}`) {
                    return send(res, 422, { message: `unexpected ref ${body.ref}` });
                }
                if (state.branchExists) return send(res, 422, { message: "Reference already exists" });
                const bytes = bytesForTree(state.commits.get(body.sha));
                state.branchExists = true;
                state.file = { sha: nextSha("sha"), bytes: bytes || Buffer.alloc(0) };
                return send(res, 201, { ref: body.ref, object: { sha: body.sha } });
            }

            default:
                return send(res, 500, { message: `unmapped route for ${req.method} ${url.pathname}` });
        }
    }

    const server = http.createServer((req, res) => {
        handle(req, res).catch((err) => send(res, 500, { message: String(err && err.message) }));
    });

    return {
        state,
        listen: () => new Promise((r) => server.listen(0, "127.0.0.1", () => r(`http://127.0.0.1:${server.address().port}`))),
        close: () => new Promise((r) => server.close(() => r())),
        server,
        writes: () => state.requests.filter((r) => r.method !== "GET"),
        posts: () => state.requests.filter((r) => r.method === "POST"),
        puts: () => state.requests.filter((r) => r.route === "contents-put"),
    };
}

// ---------------------------------------------------------------------------
// Running the helper
// ---------------------------------------------------------------------------

function baseEnv(extra = {}) {
    const env = {
        ...process.env,
        NO_COLOR: "1",
        GOVERNANCE_BADGE_RETRY_DELAY_MS: "0",
        GOVERNANCE_BADGE_REQUEST_TIMEOUT_MS: "30000",
    };
    // Never inherit a real credential or API endpoint. The suite passed on a
    // developer machine that had GH_TOKEN exported and failed in CI, where it
    // does not: tests must not depend on, or be able to use, either.
    delete env.GITHUB_API_URL;
    delete env.GITHUB_TOKEN;
    delete env.GH_TOKEN;
    // Test children must not append to the surrounding Actions job's files.
    delete env.GITHUB_OUTPUT;
    delete env.GITHUB_STEP_SUMMARY;
    Object.assign(env, extra);
    if (!("GITHUB_TOKEN" in env) && !("GH_TOKEN" in env)) {
        env.GITHUB_TOKEN = "governance-badge-test-token";
    }
    return env;
}

function runSync(args, extraEnv = {}) {
    const result = spawnSync(RUNTIME, [HELPER, ...args], {
        env: baseEnv(extraEnv),
        encoding: "utf8",
        timeout: 60000,
    });
    return { code: result.status, stdout: result.stdout || "", stderr: result.stderr || "" };
}

function runAsync(args, extraEnv = {}, timeoutMs = 60000) {
    return new Promise((resolvePromise) => {
        const child = spawn(RUNTIME, [HELPER, ...args], { env: baseEnv(extraEnv) });
        let stdout = "";
        let stderr = "";
        // A hung helper must fail the test, not hang CI.
        const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
        child.stdout.on("data", (d) => (stdout += d.toString()));
        child.stderr.on("data", (d) => (stderr += d.toString()));
        child.on("close", (code) => {
            clearTimeout(timer);
            resolvePromise({ code, stdout, stderr });
        });
    });
}

function publishArgs(apiUrl, artifact, extra = []) {
    return [
        "publish",
        "--label", LABEL,
        "--lane-result", "success",
        "--artifact", artifact,
        "--branch", BRANCH,
        "--path", DEST,
        "--repo", "example/template",
        "--api-url", apiUrl,
        "--source-sha", SOURCE_SHA,
        ...extra,
    ];
}

// Keep new cases isolated, including when an assertion or child process fails.
async function testWithApi(name, options, fn) {
    await test(name, async () => {
        const api = createApi(options);
        const url = await api.listen();
        try {
            await fn(api, url);
        } finally {
            await api.close();
        }
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

async function main() {
    const runtimeLabel = process.versions.bun ? `bun ${process.versions.bun}` : `node ${process.versions.node}`;
    console.log(`runtime: ${runtimeLabel} (${RUNTIME})`);
    console.log(`helper:  ${HELPER}`);
    const work = mkdtempSync(join(tmpdir(), "governance-badge-test-"));
    const artifactDir = join(work, "artifacts");
    mkdirSync(artifactDir, { recursive: true });

    const artifact = (name, text) => {
        const file = join(artifactDir, name);
        writeFileSync(file, text);
        return file;
    };
    const missingArtifact = join(artifactDir, "does-not-exist.json");
    const goodArtifact = artifact("success.json", SUCCESS_BADGE);
    const failureArtifact = artifact("failure.json", FAILURE_BADGE);

    try {
        // ---------------------------------------------------------------- 1
        section("1. State -> badge rendering is deterministic and total");

        await test("success renders brightgreen with the canonical bytes", () => {
            const out = runSync(["render", "--label", LABEL, "--state", "success"]);
            equal(out.code, 0, "render must exit 0");
            equal(out.stdout, SUCCESS_BADGE, "success badge bytes");
        });

        await test("failure renders red with the canonical bytes", () => {
            const out = runSync(["render", "--label", LABEL, "--state", "failure"]);
            equal(out.code, 0, "render must exit 0");
            equal(out.stdout, FAILURE_BADGE, "failure badge bytes");
        });

        for (const state of ["skipped", "cancelled", "unavailable", "unknown"]) {
            await test(`${state} renders lightgrey`, () => {
                const out = runSync(["render", "--label", LABEL, "--state", state]);
                equal(out.code, 0, "render must exit 0");
                const badge = JSON.parse(out.stdout);
                equal(badge.message, state, "message echoes the state");
                equal(badge.color, "lightgrey", `${state} must be lightgrey`);
                equal(badge.schemaVersion, 1, "schemaVersion is preserved");
                equal(badge.label, LABEL, "label is preserved");
            });
        }

        for (const raw of ["timed_out", "neutral", "action_required", "", "SUCCEEDED", "green", "__proto__", "constructor", "toString"]) {
            await test(`unrecognised lane result ${JSON.stringify(raw)} becomes unknown/lightgrey`, () => {
                const out = runSync(["render", "--label", LABEL, "--state", raw]);
                equal(out.code, 0, "render must exit 0");
                const badge = JSON.parse(out.stdout);
                equal(badge.message, "unknown", "unrecognised states are never echoed as success");
                equal(badge.color, "lightgrey", "unrecognised states are grey");
            });
        }

        await test("rendering is byte-stable across invocations", () => {
            const a = runSync(["render", "--label", LABEL, "--state", "skipped"]);
            const b = runSync(["render", "--label", LABEL, "--state", "skipped"]);
            equal(a.stdout, b.stdout, "same input must produce the same bytes");
            equal(a.stdout, SKIPPED_BADGE, "skipped badge bytes");
        });

        for (const [raw, expected] of [[" SUCCESS \t", SUCCESS_BADGE], ["\nFaIlUrE\r", FAILURE_BADGE]]) {
            await test(`render normalises surrounding whitespace and case in ${JSON.stringify(raw)}`, () => {
                const out = runSync(["render", "--label", LABEL, "--state", raw]);
                equal(out.code, 0, out.stderr);
                equal(out.stdout, expected, "normalised states retain canonical bytes");
            });
        }

        await test("render --out writes canonical bytes without mixing in its log", () => {
            const target = join(work, "rendered.json");
            const out = runSync(["render", "--label=K9", "--state=success", "--out", target]);
            equal(out.code, 0, out.stderr);
            equal(readFileSync(target, "utf8"), SUCCESS_BADGE, "file contains only the canonical badge");
            check(out.stdout.includes("rendered"), "the log reports the file write");
        });

        for (const label of ["A", "A".repeat(32)]) {
            await test(`render accepts the ${label.length}-character label boundary`, () => {
                const out = runSync(["render", "--label", label, "--state", "success"]);
                equal(out.code, 0, out.stderr);
                equal(JSON.parse(out.stdout).label, label, "the label is preserved");
            });
        }

        for (const label of ["", "A".repeat(33), "-K9", "K9\n::error::forged"]) {
            await test(`render rejects unsafe label ${JSON.stringify(label)}`, () => {
                const out = runSync(["render", "--label", label, "--state", "success"]);
                equal(out.code, 2, "invalid labels are usage errors");
                check(!out.stderr.split("\n").some((line) => line.startsWith("::error::")), "input cannot forge a diagnostic line");
            });
        }

        // ---------------------------------------------------------------- 2
        section("2. Identical bytes publish nothing");

        for (const [state, color] of [
            ["failure", "red"], ["skipped", "lightgrey"], ["cancelled", "lightgrey"],
            ["unavailable", "lightgrey"], ["unknown", "lightgrey"],
        ]) {
            const bytes = `{"schemaVersion":1,"label":"K9","message":"${state}","color":"${color}"}\n`;
            await testWithApi(`unchanged ${state} needs no success artifact or commit`, {
                branchExists: true, fileBytes: bytes,
            }, async (api, url) => {
                const out = await runAsync(publishArgs(url, missingArtifact, ["--lane-result", state]));
                equal(out.code, 0, out.stderr);
                equal(api.writes().length, 0, "unchanged non-success states never write");
                equal(api.state.file.bytes.toString(), bytes, "the existing bytes are preserved");
                check(out.stdout.includes("unchanged"), "the no-op decision is reported");
                check(!out.stdout.includes("::error::"), "non-success states need no witness");
            });
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test("byte-identical badge makes no commit", async () => {
                const summary = join(work, "summary-noop.md");
                writeFileSync(summary, "");
                const out = await runAsync(publishArgs(url, goodArtifact), { GITHUB_STEP_SUMMARY: summary });
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                check(/unchanged/i.test(out.stdout), `stdout must say unchanged: ${out.stdout}`);
                equal(api.writes().length, 0, "no write request may be made");
                equal(api.state.file.bytes.toString(), SUCCESS_BADGE, "the file must be untouched");
                const text = readFileSync(summary, "utf8");
                check(text.includes("### Governance badge"), "step summary must record the decision");
                check(text.includes("unchanged"), "step summary must say unchanged");
            });
            await api.close();
        }

        await testWithApi("unusable evidence still fails when unavailable is already published", {
            branchExists: true, fileBytes: GREY_BADGE,
        }, async (api, url) => {
            const output = join(work, "grey-noop-output");
            const out = await runAsync(publishArgs(url, missingArtifact), { GITHUB_OUTPUT: output });
            equal(out.code, 3, `an unchanged grey badge must retain the evidence fault: ${out.stderr}`);
            equal(api.writes().length, 0, "a grey fault must not create a no-op commit");
            check(out.stdout.includes("::error::"), "the evidence fault remains visible");
            equal(readFileSync(output, "utf8"), "state=unavailable\naction=unchanged\ncolour=lightgrey\nlabel=K9\n", "Actions outputs describe the no-op honestly");
        });

        // ---------------------------------------------------------------- 3
        section("3. Changed bytes publish exactly once");

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test("a failure replaces a green badge with a red one", async () => {
                const out = await runAsync([
                    "publish",
                    "--label", LABEL,
                    "--lane-result", "failure",
                    "--artifact", failureArtifact,
                    "--branch", BRANCH,
                    "--path", DEST,
                    "--repo", "example/template",
                    "--api-url", url,
                ]);
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                const puts = api.puts();
                equal(puts.length, 1, "exactly one contents PUT");
                equal(puts[0].body.sha, "sha-initial", "the PUT carries the sha it compared against");
                equal(puts[0].body.branch, BRANCH, "the PUT targets the orphan branch");
                equal(Buffer.from(puts[0].body.content, "base64").toString(), FAILURE_BADGE, "the published bytes are the red badge");
                equal(api.state.file.bytes.toString(), FAILURE_BADGE, "the branch now carries the red badge");
                check(/published/.test(out.stdout), "stdout must report publication");
                check(/commit=commit-/.test(out.stdout), "stdout must report the commit");
            });
            await api.close();
        }

        {
            // Same JSON semantics, different key order: a byte comparison must
            // see a difference, because "do not canonicalise JSON to compare".
            const api = createApi({
                branchExists: true,
                fileBytes: '{"label":"K9","schemaVersion":1,"message":"success","color":"brightgreen"}\n',
            });
            const url = await api.listen();
            await test("a reordered but semantically equal file is REPLACED, not treated as a no-op", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                equal(api.puts().length, 1, "byte differences must publish even when the JSON means the same");
            });
            await api.close();
        }

        for (const [name, bytes, laneResult, expected] of [
            ["pretty-printed JSON", JSON.stringify(JSON.parse(SUCCESS_BADGE), null, 2) + "\n", "success", SUCCESS_BADGE],
            ["missing final newline", SUCCESS_BADGE.trimEnd(), "success", SUCCESS_BADGE],
            ["legacy red skipped badge", '{"schemaVersion":1,"label":"K9","message":"skipped","color":"red"}\n', "skipped", SKIPPED_BADGE],
            ["legacy unrecognised message", '{"schemaVersion":1,"label":"K9","message":"pending","color":"blue"}\n', "success", SUCCESS_BADGE],
        ]) {
            await testWithApi(`existing ${name} is updated to canonical bytes`, {
                branchExists: true, fileBytes: bytes,
            }, async (api, url) => {
                const out = await runAsync(publishArgs(url, goodArtifact, ["--lane-result", laneResult]));
                equal(out.code, 0, out.stderr);
                equal(api.puts().length, 1, "different but valid bytes require exactly one update");
                equal(api.puts()[0].body.sha, "sha-initial", "the update is sha-checked");
                equal(api.state.file.bytes.toString(), expected, "the updated file is canonical");
            });
        }

        // ---------------------------------------------------------------- 4
        section("4. A missing branch is created as an orphan");

        {
            const api = createApi({ branchExists: false });
            const url = await api.listen();
            await test("first publication creates the branch with no parents", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                const posts = api.posts();
                equal(posts.map((p) => p.route).join(","), "blobs-post,trees-post,commits-post,refs-post", "blob -> tree -> commit -> ref");
                const commit = posts.find((p) => p.route === "commits-post");
                check(Array.isArray(commit.body.parents), "the commit body must carry a parents array");
                equal(commit.body.parents.length, 0, "the orphan commit must have NO parents (no main ancestry)");
                const ref = posts.find((p) => p.route === "refs-post");
                equal(ref.body.ref, `refs/heads/${BRANCH}`, "the ref is the badge branch, never main");
                const tree = posts.find((p) => p.route === "trees-post");
                check(!("base_tree" in tree.body), "the tree must not be based on another tree");
                equal(tree.body.tree[0].path, DEST, "the tree carries the badge file");
                equal(api.state.file.bytes.toString(), SUCCESS_BADGE, "the new branch carries the green badge");
                check(/created-orphan-branch/.test(out.stdout), "stdout must name the orphan creation");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: undefined });
            const url = await api.listen();
            await test("a branch without the file gets the file, not a new branch", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                equal(api.posts().length, 0, "no blob/tree/commit/ref may be created");
                const puts = api.puts();
                equal(puts.length, 1, "one contents PUT creates the file");
                check(!puts[0].body.sha, "a create carries no sha");
                equal(api.state.file.bytes.toString(), SUCCESS_BADGE, "the file exists after the run");
            });
            await api.close();
        }

        // ---------------------------------------------------------------- 5
        section("5. Grey states for untrustworthy lanes");

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test("a missing lane artifact publishes grey and fails the step", async () => {
                const out = await runAsync(publishArgs(url, missingArtifact));
                equal(out.code, 3, `expected exit 3 (grey published, lane evidence unusable), got ${out.code}: ${out.stderr}`);
                equal(api.puts().length, 1, "the grey badge must still be published");
                equal(api.state.file.bytes.toString(), GREY_BADGE, "a green badge must never survive a missing artifact");
                check(/::error::/.test(out.stdout), "the fault must be annotated");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test("a malformed artifact publishes grey and fails the step", async () => {
                const broken = artifact("broken.json", '{"schemaVersion":1,"label":"K9",');
                const out = await runAsync(publishArgs(url, broken));
                equal(out.code, 3, `expected exit 3, got ${out.code}: ${out.stderr}`);
                equal(api.state.file.bytes.toString(), GREY_BADGE, "malformed evidence cannot become green");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test("an artifact whose colour contradicts its message publishes grey", async () => {
                const tampered = artifact(
                    "tampered.json",
                    '{"schemaVersion":1,"label":"K9","message":"success","color":"red"}\n',
                );
                const out = await runAsync(publishArgs(url, tampered));
                equal(out.code, 3, `expected exit 3, got ${out.code}: ${out.stderr}`);
                equal(api.state.file.bytes.toString(), GREY_BADGE, "a contradictory artifact cannot become green");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test("a success job whose artifact records another state publishes grey", async () => {
                const out = await runAsync(publishArgs(url, artifact("skipped.json", SKIPPED_BADGE)));
                equal(out.code, 3, `expected exit 3, got ${out.code}: ${out.stderr}`);
                equal(api.state.file.bytes.toString(), GREY_BADGE, "inconsistent evidence cannot become green");
            });
            await api.close();
        }

        for (const [name, bytes] of [
            ...INVALID_BADGES,
            ["reordered keys", '{"label":"K9","schemaVersion":1,"message":"success","color":"brightgreen"}\n'],
            ["pretty-printed JSON", JSON.stringify(JSON.parse(SUCCESS_BADGE), null, 2) + "\n"],
            ["missing final newline", SUCCESS_BADGE.trimEnd()],
            ["CRLF newline", SUCCESS_BADGE.replace(/\n$/, "\r\n")],
            ["UTF-8 byte order mark", "\uFEFF" + SUCCESS_BADGE],
            ["extra field", SUCCESS_BADGE.replace('"schemaVersion":1,', '"schemaVersion":1,"extra":true,')],
            ["duplicate key", SUCCESS_BADGE.replace('"message":"success"', '"message":"failure","message":"success"')],
            ["unknown state", '{"schemaVersion":1,"label":"K9","message":"pending","color":"brightgreen"}\n'],
        ]) {
            await testWithApi(`success with ${name} evidence publishes unavailable`, {
                branchExists: true, fileBytes: SUCCESS_BADGE,
            }, async (api, url) => {
                const out = await runAsync(publishArgs(url, artifact("invalid.json", bytes)));
                equal(out.code, 3, `untrustworthy evidence must fail visibly: ${out.stderr}`);
                equal(api.puts().length, 1, "the stale green must be replaced");
                equal(api.state.file.bytes.toString(), GREY_BADGE, "invalid evidence never publishes green");
                check(out.stdout.includes("::error::"), "the evidence fault is annotated");
            });
        }

        await testWithApi("a directory is not accepted as success evidence", {
            branchExists: true, fileBytes: SUCCESS_BADGE,
        }, async (api, url) => {
            const out = await runAsync(publishArgs(url, artifactDir));
            equal(out.code, 3, out.stderr);
            equal(api.state.file.bytes.toString(), GREY_BADGE, "a non-file artifact produces unavailable");
        });

        // A present, regular, unreadable artifact is evidence that cannot be
        // checked: grey and exit 3, not an uncaught EACCES with a stack trace.
        // chmod 000 does not deny root, and a supervisor that runs CI as root
        // would turn this assertion into a false failure, so the case is
        // reported as skipped with the reason rather than silently passing.
        if (typeof process.getuid === "function" && process.getuid() === 0) {
            console.log("  SKIP: an unreadable artifact is grey (running as root, chmod cannot deny)");
        } else {
            await testWithApi("an unreadable artifact is grey, not a crash", {
                branchExists: true, fileBytes: SUCCESS_BADGE,
            }, async (api, url) => {
                const file = artifact("unreadable.json", SUCCESS_BADGE);
                chmodSync(file, 0o000);
                try {
                    const out = await runAsync(publishArgs(url, file));
                    equal(out.code, 3, out.stderr);
                    check(!/\n\s+at .*\(node:/.test(`${out.stdout}${out.stderr}`), "an unreadable artifact must not produce a stack trace");
                    check(/could not be read \(EACCES\)/.test(out.stdout), `the errno is named: ${out.stdout}`);
                    equal(api.state.file.bytes.toString(), GREY_BADGE, "unreadable evidence never publishes green");
                } finally {
                    chmodSync(file, 0o600);
                }
            });
        }

        for (const [laneResult, message, color] of [
            ["failure", "failure", "red"],
            ["skipped", "skipped", "lightgrey"],
            ["cancelled", "cancelled", "lightgrey"],
            ["timed_out", "unknown", "lightgrey"],
        ]) {
            await testWithApi(`a green artifact cannot override lane result ${laneResult}`, {
                branchExists: true, fileBytes: SUCCESS_BADGE,
            }, async (api, url) => {
                const out = await runAsync(publishArgs(url, goodArtifact, ["--lane-result", laneResult]));
                equal(out.code, 0, out.stderr);
                equal(api.puts().length, 1, "the lane result must replace the stale green");
                const badge = JSON.parse(api.state.file.bytes.toString());
                equal(badge.message, message, "the lane job remains authoritative");
                equal(badge.color, color, "the artifact cannot make the badge green");
                check(!out.stdout.includes("::error::"), "a non-success lane needs no success witness");
            });
        }

        for (const laneResult of ["skipped", "cancelled", "timed_out", ""]) {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const url = await api.listen();
            await test(`lane result ${JSON.stringify(laneResult)} replaces a green badge with grey`, async () => {
                const out = await runAsync(publishArgs(url, missingArtifact, ["--lane-result", laneResult]));
                equal(out.code, 0, `expected exit 0 (a known non-success state is not a fault), got ${out.code}: ${out.stderr}`);
                const bytes = api.state.file.bytes.toString();
                check(bytes.includes('"color":"lightgrey"'), `expected a grey badge, got ${bytes}`);
                check(!bytes.includes("brightgreen"), "a stale green must never survive");
            });
            await api.close();
        }

        // ---------------------------------------------------------------- 6
        section("6. Malformed existing content is refused, not overwritten");

        for (const [name, text] of [
            ["not JSON", "this is not json\n"],
            ["JSON array", "[]\n"],
            ["missing schemaVersion", '{"label":"K9","message":"failure","color":"red"}\n'],
            ["null message", '{"schemaVersion":1,"label":"K9","message":null,"color":"red"}\n'],
            ...INVALID_BADGES,
        ]) {
            const api = createApi({ branchExists: true, fileBytes: text });
            const url = await api.listen();
            await test(`existing file that is ${name} is rejected`, async () => {
                const out = await runAsync([
                    "publish",
                    "--label", LABEL,
                    "--lane-result", "failure",
                    "--artifact", failureArtifact,
                    "--branch", BRANCH,
                    "--path", DEST,
                    "--repo", "example/template",
                    "--api-url", url,
                ]);
                equal(out.code, 1, `expected exit 1, got ${out.code}: ${out.stderr}`);
                equal(api.writes().length, 0, "malformed existing content must not be overwritten");
                check(/refused/i.test(out.stderr), `stderr must say refused: ${out.stderr}`);
            });
            await api.close();
        }

        // ---------------------------------------------------------------- 7
        section("7. Missing is not the same as broken");

        {
            const api = createApi({ branchExists: false });
            api.state.script.set("contents-get", [503, 503, 503]);
            const url = await api.listen();
            await test("a 5xx contents read fails the run and creates nothing", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 1, `expected exit 1, got ${out.code}: ${out.stdout}`);
                equal(api.writes().length, 0, "an outage must never be treated as a missing branch");
                check(/503/.test(out.stderr), `stderr must name the status: ${out.stderr}`);
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: false });
            api.state.script.set("contents-get", [404]);
            api.state.script.set("ref-get", [500, 500, 500]);
            const url = await api.listen();
            await test("a 404 file with an unreadable ref fails the run and creates nothing", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 1, `expected exit 1, got ${out.code}: ${out.stdout}`);
                equal(api.posts().length, 0, "the branch must not be created when existence is unknown");
                check(/500/.test(out.stderr), `stderr must name the status: ${out.stderr}`);
            });
            await api.close();
        }

        {
            // A transient blip must not be read as "missing": retry, then honour
            // the definitive 404 that follows.
            const api = createApi({ branchExists: false });
            api.state.script.set("contents-get", [503]);
            const url = await api.listen();
            await test("a transient blip before a 404 is retried, not acted on", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                equal(api.state.branchExists, true, "the retry sees the real 404 and creates the orphan branch");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            api.state.script.set("contents-get", [403]);
            const url = await api.listen();
            await test("a 403 fails the run without writing", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 1, `expected exit 1, got ${out.code}: ${out.stdout}`);
                equal(api.writes().length, 0, "an auth failure must not write");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            const deadUrl = await api.listen();
            await api.close(); // nothing is listening on that port any more
            await test("an unreachable API fails the run without writing", async () => {
                const out = await runAsync(publishArgs(deadUrl, goodArtifact));
                equal(out.code, 1, `expected exit 1, got ${out.code}: ${out.stdout}`);
                check(/could not be reached|failed:/.test(out.stderr), `stderr must name the network failure: ${out.stderr}`);
            });
        }

        for (const phase of ["headers", "body"]) {
            for (const route of ["repo", "contents-get", "ref-get", "contents-put", "blobs-post", "trees-post", "commits-post", "refs-post"]) {
                const isPut = route === "contents-put";
                const api = createApi(isPut ? { branchExists: true, fileBytes: FAILURE_BADGE } : {});
                // PUT transport failures now reconcile against remote state.
                // Three consecutive timeouts are needed to prove exhaustion.
                const attempts = 3;
                api.state.script.set(route, Array(attempts).fill(`stall-${phase}`));
                const url = await api.listen();
                try {
                    await test(`${route} with stalled ${phase} times out and fails closed`, async () => {
                        const out = await runAsync(publishArgs(url, goodArtifact), {
                            GOVERNANCE_BADGE_REQUEST_TIMEOUT_MS: "200",
                        }, 5000);
                        equal(out.code, 1, `expected timeout failure, got ${out.code}: ${out.stderr}`);
                        equal(api.state.requests.filter((r) => r.route === route).length, attempts,
                            "GET, orphan and PUT transport failures exhaust three bounded attempts");
                        check(/failed:|response body unreadable:/.test(out.stderr),
                            `stderr must name the transport failure: ${out.stderr}`);
                        if (isPut) {
                            equal(api.state.file.bytes.toString(), FAILURE_BADGE, "no badge was changed");
                        } else {
                            equal(api.state.branchExists, false, "no branch was created");
                        }
                        if (route === "repo" || route === "contents-get") {
                            equal(api.writes().length, 0, "an unreadable remote state must not cause writes");
                        }
                    });
                } finally {
                    await api.close();
                }
            }

            for (const route of ["repo", "contents-get"]) {
                const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
                api.state.script.set(route, [`stall-${phase}`]);
                const url = await api.listen();
                try {
                    await test(`${route} recovers after a ${phase} timeout`, async () => {
                        const out = await runAsync(publishArgs(url, goodArtifact), {
                            GOVERNANCE_BADGE_REQUEST_TIMEOUT_MS: "200",
                        }, 5000);
                        equal(out.code, 0, `expected successful GET retry, got ${out.code}: ${out.stderr}`);
                        equal(api.state.requests.filter((r) => r.route === route).length, 2, "the GET was retried");
                        equal(api.writes().length, 0, "identical bytes still produce no writes");
                        check(/unchanged/.test(out.stdout), "the retry sees the existing badge");
                    });
                } finally {
                    await api.close();
                }
            }
        }

        for (const timeout of ["", "0", "-1", "1.5", "invalid", "2147483648"]) {
            await test(`invalid request timeout ${JSON.stringify(timeout)} is a usage error`, () => {
                const out = runSync(publishArgs("http://127.0.0.1:1", goodArtifact), {
                    GOVERNANCE_BADGE_REQUEST_TIMEOUT_MS: timeout,
                });
                equal(out.code, 2, `expected usage error, got ${out.code}: ${out.stderr}`);
                check(/GOVERNANCE_BADGE_REQUEST_TIMEOUT_MS/.test(out.stderr), "stderr must name the setting");
            });
        }

        await testWithApi("the maximum supported request timeout permits a no-op publication", {
            branchExists: true, fileBytes: SUCCESS_BADGE,
        }, async (api, url) => {
            const out = await runAsync(publishArgs(url, goodArtifact), {
                GOVERNANCE_BADGE_REQUEST_TIMEOUT_MS: "2147483647",
            });
            equal(out.code, 0, out.stderr);
            equal(api.state.requests.map((r) => r.route).join(","), "repo,source-ref-get,contents-get", "the upper boundary verifies the current source ref before the ordinary read path");
            equal(api.writes().length, 0, "the timeout setting cannot cause a no-op write");
            check(out.stdout.includes("unchanged"), "the unchanged decision is preserved");
        });

        for (const route of ["repo", "contents-get", "ref-get"]) {
            for (const status of [401, 403, 429, 502, 400]) {
                await testWithApi(`${route} HTTP ${status} fails closed with bounded reads`, {
                    branchExists: false,
                }, async (api, url) => {
                    const transient = status === 429 || status === 502;
                    const attempts = transient ? 3 : 1;
                    // Leave extra failures queued: the test must observe the
                    // limit, rather than accidentally succeed on the mock's default.
                    api.state.script.set(route, Array(4).fill(status));
                    const out = await runAsync(publishArgs(url, goodArtifact));
                    equal(out.code, 1, `HTTP ${status} must fail: ${out.stderr}`);
                    equal(api.state.requests.filter((r) => r.route === route).length, attempts, "only transient failures are retried, at most three times");
                    equal(api.writes().length, 0, "unknown remote state never permits any writes");
                    equal(api.state.branchExists, false, "API errors cannot create the branch");
                    check(out.stderr.includes(String(status)), "the diagnostic identifies the HTTP status");
                    if (route === "repo") {
                        equal(api.state.requests.length, attempts, "metadata failure stops before reading contents");
                    } else if (route === "contents-get") {
                        equal(api.state.requests.filter((r) => r.route === "ref-get").length, 0, "only a definitive file 404 permits a ref lookup");
                    }
                });
            }
        }

        for (const route of ["repo", "contents-get", "ref-get"]) {
            await testWithApi(`${route} recovers on its last allowed transient retry`, {
                branchExists: false,
            }, async (api, url) => {
                api.state.script.set(route, [429, 503]);
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 0, out.stderr);
                equal(api.state.requests.filter((r) => r.route === route).length, 3, "the third read is authoritative");
                equal(api.state.file.bytes.toString(), SUCCESS_BADGE, "recovery publishes the intended bytes");
                equal(api.posts().filter((r) => r.route === "refs-post").length, 1, "only the confirmed absence creates a branch");
            });
        }

        const contentsPayload = {
            sha: "sha-initial", encoding: "base64", content: Buffer.from(SUCCESS_BADGE).toString("base64"),
        };
        for (const [name, response] of [
            ["invalid response JSON", { status: 200, text: "{" }],
            ["wrong encoding", { status: 200, body: { ...contentsPayload, encoding: "utf-8" } }],
            ["missing sha", { status: 200, body: { ...contentsPayload, sha: undefined } }],
            ["missing content", { status: 200, body: { ...contentsPayload, content: undefined } }],
            ["non-string content", { status: 200, body: { ...contentsPayload, content: [] } }],
        ]) {
            await testWithApi(`contents API with ${name} is refused without writing`, {
                branchExists: true, fileBytes: SUCCESS_BADGE,
            }, async (api, url) => {
                api.state.script.set("contents-get", [response]);
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 1, out.stderr);
                equal(api.writes().length, 0, "an unreadable contents payload cannot authorise writes");
                equal(api.state.file.bytes.toString(), SUCCESS_BADGE, "existing bytes remain intact");
                equal(api.state.requests.filter((r) => r.route === "contents-get").length, 1, "malformed successful responses are not transient");
                equal(api.state.requests.filter((r) => r.route === "ref-get").length, 0, "bad payloads are never interpreted as absence");
            });
        }

        for (const route of ["blobs-post", "trees-post", "commits-post"]) {
            for (const [name, response] of [
                ["invalid JSON", { status: 201, text: "not JSON" }],
                ["missing sha", { status: 201, body: {} }],
                ["non-string sha", { status: 201, body: { sha: 123 } }],
            ]) {
                await testWithApi(`orphan creation stops at ${route} with ${name}`, {
                    branchExists: false,
                }, async (api, url) => {
                    api.state.script.set(route, [response]);
                    const out = await runAsync(publishArgs(url, goodArtifact));
                    equal(out.code, 1, out.stderr);
                    equal(api.posts().at(-1).route, route, "no later creation step is attempted");
                    equal(api.state.requests.filter((r) => r.route === route).length, 1, "invalid creation responses are not retried");
                    equal(api.state.branchExists, false, "no ref can expose an unverified commit");
                    equal(api.puts().length, 0, "an invalid orphan response cannot fall back to a contents write");
                });
            }
        }

        // ---------------------------------------------------------------- 8
        section("8. Concurrent publications reconcile instead of overwriting");

        for (const deleted of ["file", "branch"]) {
            await testWithApi(`an update conflict re-creates a concurrently deleted ${deleted}`, {
                branchExists: true, fileBytes: FAILURE_BADGE,
            }, async (api, url) => {
                let injected = false;
                api.state.hook = (request, state) => {
                    if (request.route === "contents-put" && !injected) {
                        injected = true;
                        state.file = null;
                        state.branchExists = deleted !== "branch";
                        state.script.set("contents-put", [409]);
                    }
                };
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 0, out.stderr);
                equal(api.state.file.bytes.toString(), SUCCESS_BADGE, "recovery publishes intended bytes");
                equal(api.puts()[0].body.sha, "sha-initial", "initial update uses the read sha");
                equal(api.state.requests.filter((r) => r.route === "ref-get").length, 1, "deletion is confirmed by a new ref read");
                if (deleted === "file") {
                    equal(api.puts().length, 2, "a missing file is created once after the conflict");
                    check(!("sha" in api.puts()[1].body), "recreation cannot reuse the deleted file's sha");
                    equal(api.posts().length, 0, "the existing branch needs no Git objects");
                } else {
                    equal(api.puts().length, 1, "a missing branch cannot use a contents create");
                    equal(api.posts().map((r) => r.route).join(","), "blobs-post,trees-post,commits-post,refs-post", "only confirmed branch absence permits orphan creation");
                    equal(api.posts().find((r) => r.route === "commits-post").body.parents.length, 0, "recovery still creates an orphan");
                }
            });
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            let injected = false;
            api.state.hook = (request, state) => {
                if (request.route === "contents-put" && !injected) {
                    injected = true;
                    // Another run wins the race and writes the same badge we want.
                    state.file = { sha: "sha-other", bytes: Buffer.from(FAILURE_BADGE, "utf8") };
                    state.script.set("contents-put", [409]);
                }
            };
            const url = await api.listen();
            await test("a lost race that already published the same bytes ends unchanged", async () => {
                const out = await runAsync([
                    "publish",
                    "--label", LABEL,
                    "--lane-result", "failure",
                    "--artifact", failureArtifact,
                    "--branch", BRANCH,
                    "--path", DEST,
                    "--repo", "example/template",
                    "--api-url", url,
                ]);
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                equal(api.puts().length, 1, "the second read shows identical bytes, so no second PUT");
                check(/unchanged/i.test(out.stdout), `stdout must say unchanged: ${out.stdout}`);
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: true, fileBytes: SUCCESS_BADGE });
            let injected = false;
            api.state.hook = (request, state) => {
                if (request.route === "contents-put" && !injected) {
                    injected = true;
                    state.file = { sha: "sha-other", bytes: Buffer.from(SKIPPED_BADGE, "utf8") };
                    state.script.set("contents-put", [409]);
                }
            };
            const url = await api.listen();
            await test("a lost race with different bytes re-reads and publishes against the new sha", async () => {
                const out = await runAsync([
                    "publish",
                    "--label", LABEL,
                    "--lane-result", "failure",
                    "--artifact", failureArtifact,
                    "--branch", BRANCH,
                    "--path", DEST,
                    "--repo", "example/template",
                    "--api-url", url,
                ]);
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                const puts = api.puts();
                equal(puts.length, 2, "conflict, re-read, publish");
                equal(puts[1].body.sha, "sha-other", "the retry uses the sha it re-read");
                equal(api.state.file.bytes.toString(), FAILURE_BADGE, "the final content is this run's badge");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: false });
            api.state.hook = (request, state) => {
                if (request.route === "refs-post" && !state.script.get("refs-post")) {
                    // Another run creates the branch first.
                    state.branchExists = true;
                    state.file = { sha: "sha-other", bytes: Buffer.from(SUCCESS_BADGE, "utf8") };
                    state.script.set("refs-post", [422]);
                }
            };
            const url = await api.listen();
            await test("a lost race creating the branch re-reads instead of forcing the ref", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 0, `expected exit 0, got ${out.code}: ${out.stderr}`);
                equal(api.posts().filter((p) => p.route === "refs-post").length, 1, "the ref is attempted once");
                equal(api.puts().length, 0, "the winner already published our bytes");
                check(/unchanged/i.test(out.stdout), `stdout must say unchanged: ${out.stdout}`);
            });
            await api.close();
        }

        for (const fileBytes of [undefined, SUCCESS_BADGE]) {
            for (const status of [409, 422, 429, 503]) {
                await testWithApi(`HTTP ${status} during ${fileBytes === undefined ? "file creation" : "file update"} exhausts bounded reconciliation`, {
                    branchExists: true, fileBytes,
                }, async (api, url) => {
                    api.state.script.set("contents-put", Array(4).fill(status));
                    const out = await runAsync(publishArgs(url, failureArtifact, ["--lane-result", "failure"]));
                    equal(out.code, 1, out.stderr);
                    equal(api.puts().length, 3, "publication stops after three failed writes");
                    equal(api.state.requests.filter((r) => r.route === "contents-get").length, 3, "every write attempt re-reads current contents");
                    equal(api.posts().length, 0, "contents conflicts never create an orphan branch");
                    equal(api.state.file && api.state.file.bytes.toString(), fileBytes === undefined ? null : fileBytes, "failed writes preserve the original file state");
                    check(out.stderr.includes("gave up after 3 attempts"), "exhaustion is diagnosed explicitly");
                    for (const put of api.puts()) {
                        equal(put.body.sha, fileBytes === undefined ? undefined : "sha-initial", "only an existing file supplies a sha");
                    }
                });
            }
        }

        for (const status of [401, 403, 404]) {
            await testWithApi(`a PUT returning ${status} is fatal without retries or branch creation`, {
                branchExists: true, fileBytes: SUCCESS_BADGE,
            }, async (api, url) => {
                api.state.script.set("contents-put", [status]);
                const out = await runAsync(publishArgs(url, failureArtifact, ["--lane-result", "failure"]));
                equal(out.code, 1, out.stderr);
                equal(api.writes().length, 1, "a fatal write response is not retried");
                equal(api.state.file.bytes.toString(), SUCCESS_BADGE, "the original bytes are preserved");
            });
        }

        await testWithApi("a creation race with different bytes re-reads and updates the winner's sha", {
            branchExists: true,
        }, async (api, url) => {
            let injected = false;
            api.state.hook = (request, state) => {
                if (request.route === "contents-put" && !injected) {
                    injected = true;
                    state.file = { sha: "sha-winner", bytes: Buffer.from(SKIPPED_BADGE) };
                    state.script.set("contents-put", [422]);
                }
            };
            const out = await runAsync(publishArgs(url, goodArtifact));
            equal(out.code, 0, out.stderr);
            equal(api.puts().length, 2, "the creation conflict is followed by one update");
            check(!("sha" in api.puts()[0].body), "the initial create has no sha");
            equal(api.puts()[1].body.sha, "sha-winner", "the update uses the competing file's sha");
            equal(api.state.file.bytes.toString(), SUCCESS_BADGE, "the final content matches this run");
        });

        await testWithApi("an update conflict cannot overwrite a newly malformed remote file", {
            branchExists: true, fileBytes: SUCCESS_BADGE,
        }, async (api, url) => {
            api.state.hook = (request, state) => {
                if (request.route === "contents-put") {
                    state.file = { sha: "sha-hand-edit", bytes: Buffer.from("hand edit\n") };
                    state.script.set("contents-put", [409]);
                }
            };
            const out = await runAsync(publishArgs(url, failureArtifact, ["--lane-result", "failure"]));
            equal(out.code, 1, out.stderr);
            equal(api.puts().length, 1, "the malformed re-read must prevent a second write");
            equal(api.state.file.bytes.toString(), "hand edit\n", "the competing hand edit remains intact");
            check(out.stderr.includes("refusing to overwrite"), "the refusal explains the invalid remote content");
        });

        for (const route of ["blobs-post", "trees-post", "commits-post", "refs-post"]) {
            await testWithApi(`a transient ${route} failure restarts orphan creation safely`, {
                branchExists: false,
            }, async (api, url) => {
                api.state.script.set(route, [503]);
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 0, out.stderr);
                equal(api.state.requests.filter((r) => r.route === "contents-get").length, 2, "retry first verifies remote state again");
                equal(api.posts().filter((r) => r.route === route).length, 2, "the transient step is retried once");
                for (const commit of api.posts().filter((r) => r.route === "commits-post")) {
                    equal(JSON.stringify(commit.body.parents), "[]", "each attempted commit remains an orphan");
                }
                equal(api.state.file.bytes.toString(), SUCCESS_BADGE, "recovery publishes canonical bytes");
            });
        }

        // A dropped response body after an applied PUT is indeterminate.
        // Reconciliation must read the new file instead of issuing a second
        // blind write or leaving a stale green badge behind.
        for (const fileBytes of [undefined, SUCCESS_BADGE]) {
            await testWithApi(`a committed ${fileBytes ? "update" : "creation"} with a lost response is not duplicated`, {
                branchExists: true, fileBytes,
            }, async (api, url) => {
                api.state.hook = (request, state) => {
                    if (request.route === "contents-put") {
                        state.file = { sha: "sha-network-applied", bytes: Buffer.from(FAILURE_BADGE) };
                        state.script.set("contents-put", ["stall-body"]);
                    }
                };
                const out = await runAsync(
                    publishArgs(url, failureArtifact, ["--lane-result", "failure"]),
                    { GOVERNANCE_BADGE_REQUEST_TIMEOUT_MS: "250" },
                );
                equal(out.code, 0, `applied PUT with lost response should reconcile: ${out.stderr}`);
                equal(api.puts().length, 1, "a lost response cannot cause a second commit when bytes already match");
                equal(api.state.requests.filter((r) => r.route === "contents-get").length, 2, "uncertain write is re-read");
                equal(api.state.file.bytes.toString(), FAILURE_BADGE, "reconciliation retains the applied badge");
            });
        }

        // A write can land before the API returns an error. Reconciliation
        // must inspect the resulting bytes before attempting another commit.
        for (const fileBytes of [undefined, SUCCESS_BADGE]) {
            const operation = fileBytes === undefined ? "creation" : "update";
            await testWithApi(`a committed file ${operation} followed by HTTP 503 is not written twice`, {
                branchExists: true, fileBytes,
            }, async (api, url) => {
                api.state.hook = (request, state) => {
                    if (request.route === "contents-put") {
                        state.file = { sha: "sha-applied", bytes: Buffer.from(FAILURE_BADGE) };
                        state.script.set("contents-put", [503]);
                    }
                };
                const out = await runAsync(publishArgs(url, failureArtifact, ["--lane-result", "failure"]));
                equal(out.code, 0, out.stderr);
                equal(api.puts().length, 1, "the applied write is never repeated");
                equal(api.state.requests.filter((r) => r.route === "contents-get").length, 2, "the retry re-reads the applied content");
                equal(api.posts().length, 0, "reconciliation cannot create another branch");
                equal(api.state.file.sha, "sha-applied", "the committed file is left untouched");
                equal(api.state.file.bytes.toString(), FAILURE_BADGE, "the applied bytes match the intended badge");
                check(out.stdout.includes("unchanged"), "the second read reports no further change");
            });

            await testWithApi(`file ${operation} recovers after a conflict and a transient error`, {
                branchExists: true, fileBytes,
            }, async (api, url) => {
                api.state.script.set("contents-put", [422, 503]);
                const out = await runAsync(publishArgs(url, failureArtifact, ["--lane-result", "failure"]));
                equal(out.code, 0, out.stderr);
                equal(api.puts().length, 3, "the last allowed attempt succeeds");
                equal(api.state.requests.filter((r) => r.route === "contents-get").length, 3, "each attempt starts with a fresh contents read");
                equal(api.posts().length, 0, "file writes never fall back to orphan creation");
                for (const put of api.puts()) {
                    equal(put.body.sha, fileBytes === undefined ? undefined : "sha-initial", "each write uses the sha from its read, when present");
                }
                equal(api.state.file.bytes.toString(), FAILURE_BADGE, "recovery publishes the intended content");
                check(out.stdout.includes(`action=${fileBytes === undefined ? "created" : "updated"}`), "the final action reflects the successful write");
            });
        }

        await testWithApi("an applied orphan ref followed by HTTP 503 is not created twice", {
            branchExists: false,
        }, async (api, url) => {
            api.state.hook = (request, state) => {
                if (request.route === "refs-post") {
                    state.branchExists = true;
                    state.file = { sha: "sha-applied-ref", bytes: Buffer.from(SUCCESS_BADGE) };
                    state.script.set("refs-post", [503]);
                }
            };
            const out = await runAsync(publishArgs(url, goodArtifact));
            equal(out.code, 0, out.stderr);
            equal(api.posts().map((r) => r.route).join(","), "blobs-post,trees-post,commits-post,refs-post", "no orphan objects or refs are retried after the ref lands");
            equal(api.state.requests.filter((r) => r.route === "contents-get").length, 2, "the uncertain ref creation is resolved by reading contents");
            equal(api.puts().length, 0, "identical content requires no follow-up write");
            equal(api.state.file.sha, "sha-applied-ref", "the applied ref's file is preserved");
            check(out.stdout.includes("unchanged"), "the existing applied content is acknowledged");
        });

        await testWithApi("a branch creation conflict with different bytes updates the winner's file sha", {
            branchExists: false,
        }, async (api, url) => {
            api.state.hook = (request, state) => {
                if (request.route === "refs-post") {
                    state.branchExists = true;
                    state.file = { sha: "sha-branch-winner", bytes: Buffer.from(SKIPPED_BADGE) };
                    state.script.set("refs-post", [409]);
                }
            };
            const out = await runAsync(publishArgs(url, goodArtifact));
            equal(out.code, 0, out.stderr);
            equal(api.posts().filter((r) => r.route === "refs-post").length, 1, "the winner's ref is never forced or recreated");
            equal(api.puts().length, 1, "one contents update replaces the competing badge");
            equal(api.puts()[0].body.sha, "sha-branch-winner", "the update is checked against the winner's actual blob sha");
            equal(api.state.file.bytes.toString(), SUCCESS_BADGE, "this run's intended content is published");
        });

        const orphanRoutes = ["blobs-post", "trees-post", "commits-post", "refs-post"];
        for (const [index, route] of orphanRoutes.entries()) {
            for (const status of [401, 403, 503]) {
                await testWithApi(`orphan ${route} HTTP ${status} cannot continue past the failed stage`, {
                    branchExists: false,
                }, async (api, url) => {
                    const attempts = status === 503 ? 3 : 1;
                    api.state.script.set(route, Array(4).fill(status));
                    const out = await runAsync(publishArgs(url, goodArtifact));
                    equal(out.code, 1, out.stderr);
                    const expectedRoutes = Array(attempts).fill(orphanRoutes.slice(0, index + 1).join(",")).join(",");
                    equal(api.posts().map((r) => r.route).join(","), expectedRoutes, "only transient failures may restart the orphan sequence, at most three times");
                    equal(api.state.requests.filter((r) => r.route === "contents-get").length, attempts, "every restart must establish remote absence again");
                    equal(api.state.requests.filter((r) => r.route === "ref-get").length, attempts, "every restart must confirm branch absence");
                    equal(api.state.branchExists, false, "no failed stage may expose an orphan branch");
                    equal(api.puts().length, 0, "a failed orphan stage cannot fall back to a contents write");
                    check(out.stderr.includes(String(status)), "the failing status is diagnosed");
                    check(!out.stdout.includes("governance-badge: published"), "failed publication is never reported as success");
                });
            }
        }

        // ---------------------------------------------------------------- 9
        section("9. Guards: the badge never touches a source branch");

        await testWithApi("superseded source run cannot overwrite the latest badge", {
            branchExists: true, fileBytes: FAILURE_BADGE,
            sourceHead: "ffffffffffffffffffffffffffffffffffffffff",
        }, async (api, url) => {
            const out = await runAsync(publishArgs(url, goodArtifact));
            equal(out.code, 1, `stale source must refuse publication: ${out.stderr}`);
            check(/superseded source commit/.test(out.stderr), "stale revision is identified");
            equal(api.writes().length, 0, "stale run never writes badge or source");
        });

        await testWithApi("head changing after reading badge still refuses a stale PUT", {
            branchExists: true, fileBytes: FAILURE_BADGE,
            hook: (entry, state) => {
                if (entry.route === "contents-get") {
                    state.sourceHead = "ffffffffffffffffffffffffffffffffffffffff";
                }
            },
        }, async (api, url) => {
            const out = await runAsync(publishArgs(url, goodArtifact));
            equal(out.code, 1, `race must refuse publication: ${out.stderr}`);
            equal(api.puts().length, 0, "freshness is rechecked immediately before PUT");
        });


        for (const sha of [SOURCE_SHA.slice(1), `${SOURCE_SHA}0`, SOURCE_SHA.toUpperCase(), "g".repeat(40), `${SOURCE_SHA}\n`]) {
            await testWithApi(`invalid source revision ${JSON.stringify(sha)} is refused before contacting the API`, {}, async (api, url) => {
                const out = await runAsync(publishArgs(url, goodArtifact, ["--source-sha", sha]));
                equal(out.code, 2, out.stderr);
                check(out.stderr.includes("complete 40-character Git commit SHA"), "the diagnostic explains the required revision identity");
                equal(api.state.requests.length, 0, "invalid revision identities cannot authorise remote reads or writes");
            });
        }

        await testWithApi("source freshness requires the repository to identify its default branch", {
            branchExists: true, fileBytes: FAILURE_BADGE,
        }, async (api, url) => {
            api.state.script.set("repo", [{ status: 200, body: { full_name: "example/template" } }]);
            const out = await runAsync(publishArgs(url, goodArtifact));
            equal(out.code, 1, out.stderr);
            check(out.stderr.includes("cannot establish source freshness"), "missing metadata is diagnosed");
            equal(api.state.requests.map((r) => r.route).join(","), "repo", "no badge access is allowed without a source branch identity");
        });

        for (const body of [{}, { object: {} }, { object: { sha: SOURCE_SHA.slice(0, 12) } }]) {
            await testWithApi(`an incomplete source ref ${JSON.stringify(body)} cannot prove freshness`, {
                branchExists: true, fileBytes: FAILURE_BADGE,
            }, async (api, url) => {
                api.state.script.set("source-ref-get", [{ status: 200, body }]);
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 1, out.stderr);
                equal(api.state.requests.map((r) => r.route).join(","), "repo,source-ref-get", "a partial ref never permits a badge read or write");
                check(out.stderr.includes("refusing stale badge publication"), "the unverifiable revision is refused explicitly");
            });
        }

        for (const status of [403, 404, 429, 503]) {
            await testWithApi(`source-head HTTP ${status} cannot authorise badge publication`, {
                branchExists: true, fileBytes: FAILURE_BADGE,
            }, async (api, url) => {
                api.state.script.set("source-ref-get", Array(4).fill(status));
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 1, out.stderr);
                equal(api.state.requests.filter((r) => r.route === "source-ref-get").length, status >= 429 ? 3 : 1, "only transient source-ref failures are retried");
                equal(api.writes().length, 0, "an unavailable source ref never permits writes");
                equal(api.state.requests.filter((r) => r.route === "contents-get").length, 0, "freshness failure stops before reading badges");
                check(out.stderr.includes("cannot establish current main head"), "the failing prerequisite is named");
            });
        }

        await testWithApi("source freshness can recover on the final allowed read", {
            branchExists: true, fileBytes: SUCCESS_BADGE,
        }, async (api, url) => {
            api.state.script.set("source-ref-get", [429, 503]);
            const out = await runAsync(publishArgs(url, goodArtifact));
            equal(out.code, 0, out.stderr);
            equal(api.state.requests.filter((r) => r.route === "source-ref-get").length, 3, "the last read confirms the full source revision");
            equal(api.writes().length, 0, "recovery preserves the byte-identical no-op");
            check(out.stdout.includes("unchanged"), "a verified source may finish unchanged");
        });

        for (const branchExists of [true, false]) {
            await testWithApi(`a source change after confirming ${branchExists ? "file" : "branch"} absence prevents creation`, {
                branchExists,
                hook: (entry, state) => {
                    if (entry.route === "ref-get") state.sourceHead = "f".repeat(40);
                },
            }, async (api, url) => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 1, out.stderr);
                equal(api.state.requests.filter((r) => r.route === "source-ref-get").length, 2, "freshness is checked again after establishing absence");
                equal(api.writes().length, 0, "a stale run cannot create a file, Git objects or a ref");
                equal(api.state.branchExists, branchExists, "the generated branch remains as it was");
                equal(api.state.file, null, "the stale run publishes no file");
            });
        }

        await testWithApi("a source change during a PUT conflict stops reconciliation before another write", {
            branchExists: true, fileBytes: FAILURE_BADGE,
            hook: (entry, state) => {
                if (entry.route === "contents-put") {
                    state.sourceHead = "f".repeat(40);
                    state.script.set("contents-put", [409]);
                }
            },
        }, async (api, url) => {
            const out = await runAsync(publishArgs(url, goodArtifact));
            equal(out.code, 1, out.stderr);
            equal(api.puts().length, 1, "the initial conflict is the only attempted write");
            equal(api.state.requests.filter((r) => r.route === "contents-get").length, 1, "reconciliation checks source freshness before another badge read");
            equal(api.state.file.bytes.toString(), FAILURE_BADGE, "the original badge remains intact");
            check(out.stderr.includes("superseded source commit"), "the newer source revision explains the refusal");
        });

        await testWithApi("an API error cannot forge workflow commands through its message", {}, async (api, url) => {
            api.state.script.set("repo", [{ status: 403, body: { message: "denied\r\n::error::forged\u0000\tend" } }]);
            const out = await runAsync(publishArgs(url, goodArtifact));
            equal(out.code, 1, out.stderr);
            check(out.stderr.includes("denied  ::error::forged  end"), "control characters are flattened while preserving the error detail");
            check(!out.stderr.split("\n").some((line) => line.startsWith("::error::")), "remote text cannot start a new workflow command");
            equal(api.writes().length, 0, "the permission failure never attempts a write");
        });

        for (const branch of ["main", "master", "HEAD"]) {
            await test(`--branch ${branch} is refused before any API call`, () => {
                const out = runSync(publishArgs("http://127.0.0.1:1", goodArtifact, ["--branch", branch]));
                equal(out.code, 2, `expected exit 2, got ${out.code}: ${out.stderr}`);
                check(/orphan branch/i.test(out.stderr), `stderr must explain why: ${out.stderr}`);
            });
        }

        await test("--path outside badges/ is refused", () => {
            const out = runSync(publishArgs("http://127.0.0.1:1", goodArtifact, ["--path", "src/k9.json"]));
            equal(out.code, 2, `expected exit 2, got ${out.code}: ${out.stderr}`);
        });

        await test("--path with traversal is refused", () => {
            const out = runSync(publishArgs("http://127.0.0.1:1", goodArtifact, ["--path", "badges/../k9.json"]));
            equal(out.code, 2, `expected exit 2, got ${out.code}: ${out.stderr}`);
        });

        {
            const api = createApi({ branchExists: false, defaultBranch: BRANCH });
            const url = await api.listen();
            await test("a repository whose default branch is the badge branch is refused", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 2, `expected exit 2, got ${out.code}: ${out.stderr}`);
                equal(api.writes().length, 0, "nothing may be written to a default branch");
            });
            await api.close();
        }

        {
            const api = createApi({ branchExists: false, commitParents: ["1111111111111111111111111111111111111111"] });
            const url = await api.listen();
            await test("a commit that comes back with a parent is refused", async () => {
                const out = await runAsync(publishArgs(url, goodArtifact));
                equal(out.code, 1, `expected exit 1, got ${out.code}: ${out.stderr}`);
                equal(api.posts().filter((p) => p.route === "refs-post").length, 0, "no ref may point at a non-orphan commit");
                check(/parents/i.test(out.stderr), `stderr must explain: ${out.stderr}`);
            });
            await api.close();
        }

        await test("publish refuses to run without a token, and writes nothing", () => {
            const result = spawnSync(RUNTIME, [HELPER, ...publishArgs("http://127.0.0.1:1", goodArtifact)], {
                env: { PATH: process.env.PATH, GOVERNANCE_BADGE_RETRY_DELAY_MS: "0" },
                encoding: "utf8",
                timeout: 60000,
            });
            equal(result.status, 2, `expected exit 2, got ${result.status}: ${result.stderr}`);
            check(/token/i.test(result.stderr), `stderr must name the missing token: ${result.stderr}`);
        });

        await test("a missing --artifact is a usage error, not a silent success", () => {
            const out = runSync([
                "publish",
                "--label", LABEL,
                "--lane-result", "success",
                "--branch", BRANCH,
                "--path", DEST,
                "--repo", "example/template",
                "--api-url", "http://127.0.0.1:1",
            ]);
            equal(out.code, 2, `expected exit 2, got ${out.code}: ${out.stderr}`);
        });

        // --------------------------------------------------------------- 10
        section("10. Actions outputs, summaries and shared rendering");

        for (const [action, options, evidence, state, color, code] of [
            ["updated", { branchExists: true, fileBytes: FAILURE_BADGE }, goodArtifact, "success", "brightgreen", 0],
            ["created", { branchExists: true }, goodArtifact, "success", "brightgreen", 0],
            ["created-orphan-branch", { branchExists: false }, goodArtifact, "success", "brightgreen", 0],
            ["updated", { branchExists: true, fileBytes: SUCCESS_BADGE }, missingArtifact, "unavailable", "lightgrey", 3],
            ["created", { branchExists: true }, missingArtifact, "unavailable", "lightgrey", 3],
            ["created-orphan-branch", { branchExists: false }, missingArtifact, "unavailable", "lightgrey", 3],
        ]) {
            await testWithApi(`${action}/${state} appends truthful Actions outputs and a summary`, options, async (api, url) => {
                const output = join(work, "actions-output");
                const summary = join(work, "actions-summary");
                writeFileSync(output, "existing=value\n");
                writeFileSync(summary, "Earlier step\n");
                const out = await runAsync(publishArgs(url, evidence), {
                    GITHUB_OUTPUT: output, GITHUB_STEP_SUMMARY: summary,
                });
                equal(out.code, code, out.stderr);
                equal(readFileSync(output, "utf8"), `existing=value\nstate=${state}\naction=${action}\ncolour=${color}\nlabel=K9\n`, "outputs append the actual publication decision");
                const text = readFileSync(summary, "utf8");
                check(text.startsWith("Earlier step\n"), "summary preserves previous step content");
                check(text.includes(`| ${state} | ${state} | ${color} | ${action}`), "summary records the actual state, color and action");
                equal(text.includes("**Lane evidence was unusable:**"), code === 3, "only unusable evidence adds the fault explanation");
                equal(JSON.parse(api.state.file.bytes.toString()).message, state, "outputs agree with the published file");
            });
        }

        for (const [name, fileBytes, evidence, code] of [
            ["update", FAILURE_BADGE, goodArtifact, 0],
            ["no-op", SUCCESS_BADGE, goodArtifact, 0],
            ["unusable evidence", SUCCESS_BADGE, missingArtifact, 3],
        ]) {
            await testWithApi(`Actions reporting errors preserve the ${name} publication result`, {
                branchExists: true, fileBytes,
            }, async (api, url) => {
                // Opening a directory for append fails even when tests run as
                // root; permission bits alone would not be a reliable fixture.
                const out = await runAsync(publishArgs(url, evidence), {
                    GITHUB_OUTPUT: artifactDir, GITHUB_STEP_SUMMARY: artifactDir,
                });
                equal(out.code, code, "reporting failures cannot change the publication/evidence exit code");
                equal(api.puts().length, name === "no-op" ? 0 : 1, "reporting cannot cause duplicate writes");
                equal(api.state.file.bytes.toString(), code === 3 ? GREY_BADGE : SUCCESS_BADGE, "reporting errors preserve the correct remote badge");
                check(out.stdout.includes("could not write the step summary"), "the summary failure is visible");
                check(out.stdout.includes("could not write $GITHUB_OUTPUT"), "the output failure is visible");
            });
        }

        await test("the workflow's artifact producer would render the same bytes", () => {
            const out = runSync(["render", "--label", "K9", "--state", "success"]);
            equal(out.stdout, SUCCESS_BADGE, "artifact bytes and publisher bytes must agree");
        });

        await test("the previous jq renderer's success bytes are reproduced exactly", () => {
            // The rollout must not create a commit just because the renderer
            // changed. This is the jq output the workflow used to produce.
            const legacy = '{"schemaVersion":1,"label":"K9","message":"success","color":"brightgreen"}\n';
            equal(runSync(["render", "--label", LABEL, "--state", "success"]).stdout, legacy, "legacy green bytes");
        });
    } finally {
        rmSync(work, { recursive: true, force: true });
    }

    console.log("");
    console.log(`${passed} passed, ${failed} failed`);
    if (failed > 0) {
        for (const failure of failures) console.log(`  failed: ${failure.name}`);
        process.exit(1);
    }
}

main().catch((err) => {
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
});
