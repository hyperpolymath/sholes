#!/usr/bin/env bun
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// governance-badge.js - render and publish the estate's per-lane Shields
// endpoint badges.
//
// WHAT THIS OWNS
//
// Every RSR repo publishes one small JSON file per validation lane on a
// generated ORPHAN branch called `governance-badges`:
//
//     badges/k9.json   <- written by .github/workflows/dogfood-gate.yml
//
// README badges read those files straight from raw.githubusercontent.com, so
// the files are a public interface with a stable URL. This script is the only
// thing in the template that renders or publishes them; before it existed the
// mapping lived in inline `jq` in the workflow (and mapped `skipped` to RED),
// and publication lived in inline `gh api` shell that never compared bytes and
// treated EVERY API error as "branch missing".
//
// THE THREE INVARIANTS
//
//   1. Never a false green. Only a lane result of `success` may render
//      brightgreen, and only when that lane's artifact is present, valid and
//      byte-identical to what this script renders for `success`.
//   2. Byte equality, not "looks the same". An unchanged badge produces NO
//      commit. Comparison is on exact bytes: the file is never re-serialised,
//      re-ordered or canonicalised to make a comparison succeed.
//   3. Fail closed, and say which failure it was. A 404 means "missing"; a
//      401/403/429/5xx or a network error means "we do not know" and the run
//      fails without writing anything. Only a 404 on both the file and the
//      branch is allowed to create a branch.
//
// STATE MAPPING (total; every value lands in the table)
//
//   lane result      badge message   badge colour
//   ---------------  --------------  ------------
//   success          success         brightgreen
//   failure          failure         red
//   skipped          skipped         lightgrey
//   cancelled        cancelled       lightgrey
//   unavailable      unavailable     lightgrey   (lane evidence unusable)
//   anything else    unknown         lightgrey   (e.g. timed_out, neutral)
//
// A lightgrey badge means "this run did not produce a trustworthy
// success/failure result". It is deliberately NOT "green with stale data".
//
// USAGE
//
//   governance-badge.js render --label K9 --state success [--out FILE]
//   governance-badge.js publish --label K9
//                              --lane-result <needs.<job>.result>
//                              --artifact <path to the lane's badge.json>
//                              --branch governance-badges
//                              --path badges/k9.json
//                              [--repo owner/name] [--source-sha SHA]
//                              [--commit-message TEXT]
//                              [--api-url URL] [--token TOKEN]
//
//   --repo defaults to GITHUB_REPOSITORY, --token to GITHUB_TOKEN/GH_TOKEN,
//   --api-url to GITHUB_API_URL (set by Actions), else https://api.github.com.
//   GOVERNANCE_BADGE_REQUEST_TIMEOUT_MS bounds each request, including reading
//   its response body (default 30000 ms; positive integer up to 2147483647).
//
// EXIT CODES
//
//   0  published, or byte-identical so no commit was made
//   1  refused or failed: nothing was written, or the outcome is unknown
//      (API/auth/network failure, malformed existing file, branch guard)
//   2  usage or configuration error (bad flag, missing token, unsafe branch)
//   3  a GREY badge was published because the lane's evidence was missing or
//      malformed - the badge is honest, but the run must be looked at
//
// Runtime: Bun (estate first choice) or Node >= 18. Plain CommonJS and only
// node: builtins, so both run it unchanged; no dependencies, no third-party
// action is needed to use it.

"use strict";

const { existsSync, readFileSync, statSync, writeFileSync, appendFileSync } = require("node:fs");

// ---------------------------------------------------------------------------
// Exit codes
// ---------------------------------------------------------------------------

const EXIT_OK = 0;
const EXIT_REFUSED = 1;
const EXIT_USAGE = 2;
const EXIT_GREY_FAULT = 3;

// ---------------------------------------------------------------------------
// The single state -> badge table
// ---------------------------------------------------------------------------

const STATE_TABLE = Object.freeze({
    success: { message: "success", color: "brightgreen" },
    failure: { message: "failure", color: "red" },
    skipped: { message: "skipped", color: "lightgrey" },
    cancelled: { message: "cancelled", color: "lightgrey" },
    unavailable: { message: "unavailable", color: "lightgrey" },
    unknown: { message: "unknown", color: "lightgrey" },
});

const MESSAGES = new Set(Object.values(STATE_TABLE).map((s) => s.message));

// oneLine - anything that reaches a log line is flattened first. The step log
// is evidence, and a value that comes from an argument, an artifact path or an
// API response must not be able to forge a line in it or to terminate a
// `::error::` workflow command early.
function oneLine(value) {
    return String(value).replace(/[\r\n\u0000-\u001f\u007f]/g, " ");
}

// normaliseState - anything not in the table becomes `unknown`, never success.
function normaliseState(raw) {
    const key = String(raw === undefined || raw === null ? "" : raw).trim().toLowerCase();
    return Object.hasOwn(STATE_TABLE, key) ? key : "unknown";
}

// renderBadge - the canonical bytes. Key order and spacing are fixed here and
// nowhere else, so "did this change?" is a byte comparison. The trailing
// newline matches what the previous jq renderer emitted, which keeps the
// first run after an upgrade a no-op whenever the state has not changed.
function renderBadge(label, state) {
    const entry = STATE_TABLE[normaliseState(state)];
    return (
        `{"schemaVersion":1,"label":${JSON.stringify(label)},` +
        `"message":${JSON.stringify(entry.message)},` +
        `"color":${JSON.stringify(entry.color)}}\n`
    );
}

// inspectBadge - is this text a shield-endpoint object?
//
//   pairing: "strict"  message must be one of STATE_TABLE's, with exactly the
//                      colour this table pairs it with. Used for the lane
//                      artifact, which this script renders: anything else has
//                      been tampered with or came from a different renderer.
//   pairing: "loose"   a structurally valid shield badge of any shape (any
//                      non-empty message/colour). Used for the file already on
//                      the branch, which may predate this helper - e.g. the old
//                      inline jq wrote `skipped` in RED. Such a file is valid-
//                      but-different, so it is replaced rather than refused.
//
// Returns { ok, badge, errors }; never throws on bad input.
function inspectBadge(text, label, { pairing = "strict" } = {}) {
    const errors = [];
    let badge;
    try {
        badge = JSON.parse(text);
    } catch (err) {
        return { ok: false, badge: null, errors: [`not valid JSON (${err.message})`] };
    }
    if (badge === null || typeof badge !== "object" || Array.isArray(badge)) {
        return { ok: false, badge: null, errors: ["not a JSON object"] };
    }
    if (badge.schemaVersion !== 1) {
        errors.push(`schemaVersion is ${JSON.stringify(badge.schemaVersion)}, expected 1`);
    }
    if (label !== undefined && badge.label !== label) {
        errors.push(`label is ${JSON.stringify(badge.label)}, expected ${JSON.stringify(label)}`);
    }
    if (typeof badge.message !== "string" || badge.message.length === 0) {
        errors.push("message is missing or not a non-empty string");
    } else if (typeof badge.color !== "string" || badge.color.length === 0) {
        errors.push("color is missing or not a non-empty string");
    } else if (pairing === "strict" && !MESSAGES.has(badge.message)) {
        errors.push(
            `message ${JSON.stringify(badge.message)} is not one of ${[...MESSAGES].join(", ")}`,
        );
    } else if (pairing === "strict" && badge.color !== STATE_TABLE[badge.message].color) {
        errors.push(
            `message ${JSON.stringify(badge.message)} pairs with colour ` +
                `${JSON.stringify(STATE_TABLE[badge.message].color)}, not ${JSON.stringify(badge.color)}`,
        );
    }
    return { ok: errors.length === 0, badge, errors };
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

class UsageError extends Error {}

class RefusedError extends Error {}

class ApiError extends Error {
    /** Record an HTTP status (0 when unavailable) and a failure classification. */
    constructor(message, { status = 0, kind = "unexpected" } = {}) {
        super(message);
        this.status = status;
        this.kind = kind;
    }

    /** Whether this is a network or transient API failure eligible for retry. */
    get transient() {
        return this.kind === "transient" || this.kind === "network";
    }
}

/**
 * Classify 401/403 as auth, 404 as missing, 409/422 as conflict, and 429/5xx
 * as transient; all other statuses, including successful ones, are unexpected.
 */
function classifyStatus(status) {
    if (status === 401 || status === 403) return "auth";
    if (status === 404) return "missing";
    if (status === 409 || status === 422) return "conflict";
    if (status === 429 || (status >= 500 && status <= 599)) return "transient";
    return "unexpected";
}

const KIND_ADVICE = {
    auth: "the token cannot read/write this repository (401/403) - check the job's permissions",
    missing: "the API reported the resource as missing (404)",
    conflict: "the ref or file moved under us (409/422)",
    transient: "the GitHub API is failing or rate-limiting (429/5xx)",
    network: "the GitHub API could not be reached",
    unexpected: "the GitHub API returned an unexpected response",
};

// ---------------------------------------------------------------------------
// GitHub REST client (fetch; no gh CLI, no checkout, no extra action)
// ---------------------------------------------------------------------------

const MAX_RETRIES = 3;
const RETRY_DELAY_MS = Number(process.env.GOVERNANCE_BADGE_RETRY_DELAY_MS || 1000);
const MAX_CONFLICT_ATTEMPTS = 3;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Return the string value with all trailing slashes removed. */
function trimTrailingSlashes(value) {
    let base = String(value);
    while (base.endsWith("/")) base = base.slice(0, -1);
    return base;
}

/**
 * Send an authenticated request to apiUrl + apiPath, encoding a supplied body
 * as JSON. Resolve to { status, ok, text }, including for HTTP error statuses.
 * timeoutMs bounds the request and response-body read; no retries occur here.
 * @throws {ApiError} If serialization, fetch, or reading the response body fails.
 */
async function request(method, apiPath, { token, apiUrl, body, timeoutMs = 30000 } = {}) {
    const url = `${trimTrailingSlashes(apiUrl)}${apiPath}`;
    const headers = {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "hyperpolymath-governance-badge",
    };
    if (body !== undefined) headers["Content-Type"] = "application/json";

    let response;
    try {
        response = await fetch(url, {
            method,
            headers,
            body: body === undefined ? undefined : JSON.stringify(body),
            signal: AbortSignal.timeout(timeoutMs),
        });
    } catch (err) {
        throw new ApiError(`${method} ${apiPath} failed: ${err.message}`, { kind: "network" });
    }
    let text = "";
    try {
        text = await response.text();
    } catch (err) {
        throw new ApiError(`${method} ${apiPath}: response body unreadable: ${err.message}`, {
            status: response.status,
            kind: "network",
        });
    }
    return { status: response.status, ok: response.ok, text };
}

/**
 * Build an ApiError from an HTTP response, preferring its JSON message over
 * a shortened text body. Invalid JSON falls back to the text body.
 */
function apiError(method, apiPath, response) {
    const kind = classifyStatus(response.status);
    let detail = response.text.slice(0, 300).replace(/\s+/g, " ").trim();
    try {
        const parsed = JSON.parse(response.text);
        if (parsed && typeof parsed.message === "string") detail = parsed.message;
    } catch {
        /* not JSON; keep the raw head */
    }
    return new ApiError(
        `${method} ${apiPath} -> HTTP ${response.status} (${KIND_ADVICE[kind] || "error"}): ${detail}`,
        { status: response.status, kind },
    );
}

/**
 * GET and parse a 200 response as JSON, with up to three attempts for
 * network failures and 429/5xx only. A 404 is neither retried nor swallowed.
 * @throws {ApiError} For other statuses or exhausted network/transient retries.
 * @throws {SyntaxError} If a 200 response is not valid JSON; parsing is not retried.
 */
async function getJSON(apiPath, http) {
    let lastError;
    for (let attempt = 1; attempt <= MAX_RETRIES; attempt += 1) {
        try {
            const response = await request("GET", apiPath, http);
            if (response.status === 200) return JSON.parse(response.text);
            throw apiError("GET", apiPath, response);
        } catch (err) {
            if (!(err instanceof ApiError) || !err.transient) throw err;
            lastError = err;
            if (attempt < MAX_RETRIES) await sleep(RETRY_DELAY_MS * attempt);
        }
    }
    throw lastError;
}

// getWithRetry - GET returning the raw response, with bounded retries for
// NETWORK failures and 429/5xx only. A 404 (or 401/403) is an answer, not a
// transport failure, so it is returned immediately: the caller decides what
// "missing" means at its own endpoint. Retrying reads is what keeps a single
// blip from stranding a stale (possibly green) badge until the next push.
async function getWithRetry(apiPath, http) {
    let lastError = null;
    for (let attempt = 1; attempt <= MAX_RETRIES; attempt += 1) {
        let response = null;
        try {
            response = await request("GET", apiPath, http);
        } catch (err) {
            if (!(err instanceof ApiError) || !err.transient) throw err;
            lastError = err;
        }
        if (response) {
            if (classifyStatus(response.status) !== "transient") return response;
            lastError = apiError("GET", apiPath, response);
        }
        if (attempt < MAX_RETRIES) await sleep(RETRY_DELAY_MS * attempt);
    }
    throw lastError;
}

/**
 * POST JSON and return the parsed 200/201 response without retrying.
 * Transient failures are surfaced so the publication loop can re-read and
 * converge; every other status is fatal.
 * @throws {ApiError} For network failures, other statuses, or invalid response JSON.
 */
async function postJSON(apiPath, body, http) {
    const response = await request("POST", apiPath, { ...http, body });
    if (response.status === 200 || response.status === 201) {
        try {
            return JSON.parse(response.text);
        } catch (err) {
            throw new ApiError(`POST ${apiPath}: unreadable JSON response (${err.message})`, {
                status: response.status,
                kind: "unexpected",
            });
        }
    }
    throw apiError("POST", apiPath, response);
}

// ---------------------------------------------------------------------------
// Argument handling and guards
// ---------------------------------------------------------------------------

/**
 * Parse --key=value and --key value options, plus a bare --help flag.
 * Return an option map with the last duplicate winning; names are not validated.
 * @throws {UsageError} For positional arguments or options missing a value.
 */
function parseArgs(argv) {
    const opts = {};
    for (let i = 0; i < argv.length; i += 1) {
        const arg = argv[i];
        if (!arg.startsWith("--")) throw new UsageError(`unexpected argument: ${arg}`);
        const eq = arg.indexOf("=");
        if (eq !== -1) {
            opts[arg.slice(2, eq)] = arg.slice(eq + 1);
            continue;
        }
        const key = arg.slice(2);
        if (key === "help") {
            opts.help = true;
            continue;
        }
        const value = argv[i + 1];
        if (value === undefined || value.startsWith("--")) {
            throw new UsageError(`--${key} needs a value`);
        }
        opts[key] = value;
        i += 1;
    }
    return opts;
}

/**
 * Return a trimmed label of 1-32 ASCII letters, digits, spaces, dots, underscores,
 * or hyphens, starting with a letter or digit.
 * @throws {UsageError} If the label does not match these restrictions.
 */
function requireLabel(raw) {
    const label = String(raw || "").trim();
    if (!/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,31}$/.test(label)) {
        throw new UsageError(`--label must be 1-32 safe characters, got ${JSON.stringify(raw)}`);
    }
    return label;
}

// The badge branch is generated output. It may never be a default/main branch:
// that is the difference between a badge refresh and a merge into source.
const FORBIDDEN_BRANCHES = new Set(["main", "master", "head"]);

/**
 * Return a trimmed branch name of 1-80 ASCII letters, digits, dots, underscores,
 * or hyphens. The repository's default branch is checked separately by cmdPublish.
 * @throws {UsageError} For other names or main/master/HEAD, ignoring case.
 */
function requireBranch(raw) {
    const branch = String(raw || "").trim();
    if (!/^[A-Za-z0-9._-]{1,80}$/.test(branch)) {
        throw new UsageError(
            `--branch must be a simple branch name (letters, digits, . _ -), got ${JSON.stringify(raw)}`,
        );
    }
    if (FORBIDDEN_BRANCHES.has(branch.toLowerCase())) {
        throw new UsageError(
            `--branch ${branch} is a source branch; generated badges belong on an orphan branch such as governance-badges`,
        );
    }
    return branch;
}

/**
 * Return a trimmed badges/<name>.json path, where name has 1-80 ASCII letters,
 * digits, dots, underscores, or hyphens and contains no directory separators.
 * @throws {UsageError} If the destination does not match this shape.
 */
function requireDest(raw) {
    const dest = String(raw || "").trim();
    if (!/^badges\/[A-Za-z0-9._-]{1,80}\.json$/.test(dest)) {
        throw new UsageError(
            `--path must look like badges/<lane>.json (no traversal, no other directory), got ${JSON.stringify(raw)}`,
        );
    }
    return dest;
}

/** Encode each path segment for a URL while preserving directory separators. */
function encodePath(p) {
    return p.split("/").map(encodeURIComponent).join("/");
}

// ---------------------------------------------------------------------------
// render
// ---------------------------------------------------------------------------

/**
 * Write the canonical badge to opts.out (overwriting it) or stdout and return 0.
 * Unknown states become unknown/lightgrey; output directories are not created.
 * @throws {UsageError} For an invalid label or missing state.
 * @throws {Error} Propagates filesystem errors when writing opts.out.
 */
function cmdRender(opts) {
    const label = requireLabel(opts.label);
    if (opts.state === undefined) throw new UsageError("render needs --state");
    const state = normaliseState(opts.state);
    const text = renderBadge(label, state);
    if (opts.out) {
        writeFileSync(opts.out, text);
        console.log(`governance-badge: rendered ${oneLine(opts.out)} state=${state}`);
    } else {
        process.stdout.write(text);
    }
    return EXIT_OK;
}

// ---------------------------------------------------------------------------
// Intent: what badge SHOULD this run publish?
// ---------------------------------------------------------------------------

/**
 * Resolve the lane result to { state, bytes, faults }, with canonical UTF-8
 * badge bytes. Only success reads artifact, a local file that must contain the
 * canonical success badge for label; an artifact cannot turn a failed lane green.
 * Missing/non-file, invalid, noncanonical, or contradictory evidence returns
 * unavailable with a fault. Other lane states return no faults.
 * @throws {Error} Propagates filesystem inspection and read errors.
 */
function resolveIntent({ label, laneResult, artifact }) {
    const laneState = normaliseState(laneResult);
    const faults = [];

    if (laneState !== "success") {
        const state = laneState;
        return { state, bytes: Buffer.from(renderBadge(label, state), "utf8"), faults };
    }

    const grey = (reason) => {
        faults.push(reason);
        return {
            state: "unavailable",
            bytes: Buffer.from(renderBadge(label, "unavailable"), "utf8"),
            faults,
        };
    };

    if (!existsSync(artifact) || !statSync(artifact).isFile()) {
        return grey(`the lane artifact ${artifact} is missing, so a "success" lane cannot be trusted`);
    }

    // A file that exists, is regular, and still cannot be read (EACCES, a
    // TOCTOU deletion between the stat above and here, an I/O error) is not a
    // crash: it is evidence that cannot be checked, so the badge goes grey and
    // the errno is named. Throwing here would exit 1 with a stack trace and no
    // badge, which reads as "the publisher is broken" rather than "the lane
    // evidence is unreadable" - and grey is the honest state either way.
    let text;
    try {
        text = readFileSync(artifact, "utf8");
    } catch (err) {
        return grey(
            `the lane artifact ${artifact} could not be read (${err && err.code ? err.code : String(err)}),` +
                ` so a "success" lane cannot be trusted`,
        );
    }
    const verdict = inspectBadge(text, label);
    if (!verdict.ok) {
        return grey(`the lane artifact ${artifact} is not a valid shield badge: ${verdict.errors.join("; ")}`);
    }
    if (text !== renderBadge(label, verdict.badge.message)) {
        return grey(`the lane artifact ${artifact} is not byte-identical to the canonical render`);
    }
    if (verdict.badge.message !== "success") {
        return grey(
            `the lane job reports "success" but its artifact records ` +
                `${JSON.stringify(verdict.badge.message)} - refusing to publish a green badge`,
        );
    }
    return { state: "success", bytes: Buffer.from(renderBadge(label, "success"), "utf8"), faults };
}

// ---------------------------------------------------------------------------
// Remote state: present / file absent / branch absent - and nothing else
// ---------------------------------------------------------------------------

/**
 * Read the published badge as { kind: "present", bytes, text, sha }, or return
 * kind absent-file/absent-branch after a contents 404 and a ref 200/404.
 * repo is owner/name; dest is the repository-relative badge path.
 * @throws {ApiError} For failed reads, other statuses, invalid contents JSON,
 * or missing encoding/content/sha fields.
 * @throws {TypeError} If the decoded contents payload is null.
 */
async function readRemote({ repo, branch, dest, http }) {
    const contentsPath = `/repos/${repo}/contents/${encodePath(dest)}?ref=${encodeURIComponent(branch)}`;
    const response = await getWithRetry(contentsPath, http);

    if (response.status === 200) {
        let payload;
        try {
            payload = JSON.parse(response.text);
        } catch (err) {
            throw new ApiError(`GET ${contentsPath}: unreadable JSON (${err.message})`, {
                status: 200,
                kind: "unexpected",
            });
        }
        if (payload.encoding !== "base64" || typeof payload.content !== "string" || !payload.sha) {
            throw new ApiError(
                `GET ${contentsPath}: unexpected contents payload ` +
                    `(encoding=${JSON.stringify(payload.encoding)}) - refusing to guess`,
                { status: 200, kind: "unexpected" },
            );
        }
        const bytes = Buffer.from(payload.content, "base64");
        return { kind: "present", bytes, text: bytes.toString("utf8"), sha: payload.sha };
    }

    if (response.status !== 404) {
        // 401/403/429/5xx/anything else: we do NOT know. Never "missing".
        throw apiError("GET", contentsPath, response);
    }

    // The file is absent. That means "branch exists, file missing" ONLY if the
    // branch is really there; a 404 on the ref means the branch is absent. Any
    // other ref status is an outage and must not create a branch.
    const refPath = `/repos/${repo}/git/ref/heads/${branch}`;
    const refResponse = await getWithRetry(refPath, http);
    if (refResponse.status === 200) return { kind: "absent-file" };
    if (refResponse.status === 404) return { kind: "absent-branch" };
    throw apiError("GET", refPath, refResponse);
}

// ---------------------------------------------------------------------------
// Publishing
// ---------------------------------------------------------------------------

/** Build the Contents API path for an owner/name repo and relative destination. */
function contentsPathFor(repo, dest) {
    return `/repos/${repo}/contents/${encodePath(dest)}`;
}

/**
 * Create or replace the badge through the Contents API. Supply the previously
 * read blob sha for an update; omit it to create a file. A write may make a commit.
 * Return the raw response without status validation or retries.
 * @throws {ApiError} Propagates request failures, including unreadable responses.
 */
async function putFile({ repo, branch, dest, message, bytes, sha, http }) {
    const body = {
        message,
        content: bytes.toString("base64"),
        branch,
    };
    if (sha) body.sha = sha;
    return request("PUT", contentsPathFor(repo, dest), { ...http, body });
}

/**
 * Create a branch containing only the badge, with no parent commits or base tree.
 * Return { conflict: false, sha } on success, or { conflict: true } for a ref
 * creation 409/422. Earlier Git objects are not rolled back on conflict or error.
 * @throws {ApiError} For request failures, unexpected responses, or missing SHAs.
 * @throws {RefusedError} If the returned commit explicitly has nonempty parents.
 */
async function createOrphanBranch({ repo, branch, dest, message, bytes, http }) {
    const blob = await postJSON(`/repos/${repo}/git/blobs`, {
        content: bytes.toString("base64"),
        encoding: "base64",
    }, http);
    if (!blob || typeof blob.sha !== "string") {
        throw new ApiError("POST /git/blobs returned no sha", { kind: "unexpected" });
    }

    const tree = await postJSON(`/repos/${repo}/git/trees`, {
        tree: [{ path: dest, mode: "100644", type: "blob", sha: blob.sha }],
    }, http);
    if (!tree || typeof tree.sha !== "string") {
        throw new ApiError("POST /git/trees returned no sha", { kind: "unexpected" });
    }

    const commit = await postJSON(`/repos/${repo}/git/commits`, {
        message,
        tree: tree.sha,
        parents: [],
    }, http);
    if (!commit || typeof commit.sha !== "string") {
        throw new ApiError("POST /git/commits returned no sha", { kind: "unexpected" });
    }
    if (Array.isArray(commit.parents) && commit.parents.length !== 0) {
        throw new RefusedError(
            "the API returned a commit WITH parents for an orphan branch - refusing to publish " +
                "a governance-badges branch that shares history with a source branch",
        );
    }

    const ref = await request("POST", `/repos/${repo}/git/refs`, {
        ...http,
        body: { ref: `refs/heads/${branch}`, sha: commit.sha },
    });
    if (ref.status === 201 || ref.status === 200) return { conflict: false, sha: commit.sha };
    if (classifyStatus(ref.status) === "conflict") return { conflict: true };
    throw apiError("POST", `/repos/${repo}/git/refs`, ref);
}

/**
 * Append lines and a trailing newline to GITHUB_STEP_SUMMARY when set.
 * Ignore an unset target and catch append errors without failing publication.
 */
function stepSummary(lines) {
    const target = process.env.GITHUB_STEP_SUMMARY;
    if (!target) return;
    try {
        appendFileSync(target, lines.join("\n") + "\n");
    } catch (err) {
        console.log(`governance-badge: could not write the step summary: ${err.message}`);
    }
}

/**
 * Append a key=value line to GITHUB_OUTPUT when set. Catch append errors
 * without failing publication; an unset target is a no-op.
 */
function setOutput(key, value) {
    const target = process.env.GITHUB_OUTPUT;
    if (!target) return;
    try {
        appendFileSync(target, `${key}=${value}\n`);
    } catch (err) {
        console.log(`governance-badge: could not write $GITHUB_OUTPUT: ${err.message}`);
    }
}

/**
 * Record a publication decision in the Actions summary and state/action/colour/
 * label outputs. Return 3 when faults is nonempty, even for unchanged content;
 * otherwise return 0. This function does not publish or change the remote badge.
 */
function finish({ label, dest, branch, intent, action, commit, faults }) {
    const entry = STATE_TABLE[intent.state];
    const where = oneLine(`${dest} on ${branch}`);
    const commitId = oneLine(commit || "");

    if (action === "unchanged") {
        console.log(
            `governance-badge: ${where} is byte-identical to the new badge ` +
                `(state=${intent.state}, message=${entry.message}, colour=${entry.color}); ` +
                `unchanged - no commit made`,
        );
    } else {
        const commitNote = commitId ? `, commit=${commitId}` : "";
        console.log(
            `governance-badge: published ${where} ` +
                `(state=${intent.state}, message=${entry.message}, colour=${entry.color}, ` +
                `action=${action}${commitNote})`,
        );
    }

    for (const fault of faults) {
        console.log(`::error::${oneLine(fault)}`);
    }

    stepSummary([
        "",
        "### Governance badge",
        "",
        "| file | branch | state | message | colour | action |",
        "|---|---|---|---|---|---|",
        `| \`${dest}\` | \`${branch}\` | ${intent.state} | ${entry.message} | ${entry.color} | ${action}${commitId ? ` (\`${oneLine(String(commitId).slice(0, 12))}\`)` : ""} |`,
        "",
        action === "unchanged"
            ? "The published badge already carried these exact bytes, so no commit was made."
            : "The `governance-badges` branch is generated output: an orphan branch with no common ancestor with `main`. It must never be merged.",
        faults.length ? `\n**Lane evidence was unusable:** ${faults.join("; ")}` : "",
        "",
    ]);

    setOutput("state", intent.state);
    setOutput("action", action);
    setOutput("colour", entry.color);
    setOutput("label", label);

    if (faults.length) {
        console.log(
            `governance-badge: published a grey "${intent.state}" badge because this run's lane ` +
                `evidence was unusable; failing the step so the fault is visible`,
        );
        return EXIT_GREY_FAULT;
    }
    return EXIT_OK;
}

/**
 * Publish the lane's intended badge, leaving identical bytes unchanged and
 * refusing invalid existing badges. Repository, token, and API URL options fall
 * back to the environment; --source-sha contributes at most 12 characters to
 * the default commit message. Missing branches are created without parents.
 * Retry contents-write HTTP 409/422/429/5xx, ref-creation 409/422, and network/
 * transient failures during orphan creation by re-reading remote state, for
 * at most three publication attempts.
 * Return 0 on publication/no-op, or 3 for unusable lane evidence, even on no-op.
 * @throws {UsageError} For missing configuration, invalid arguments, or targeting
 * main/master/HEAD (ignoring case) or the repository's default branch.
 * @throws {RefusedError} For metadata read failures, invalid existing badges,
 * non-orphan commits, or exhausted publication attempts.
 * @throws {ApiError} Propagates other API failures, including PUT network errors.
 * @throws {Error} Propagates artifact filesystem and unexpected payload errors.
 */
async function cmdPublish(opts) {
    const label = requireLabel(opts.label);
    const branch = requireBranch(opts.branch);
    const dest = requireDest(opts.path);
    const laneResult = opts["lane-result"];
    if (laneResult === undefined) throw new UsageError("publish needs --lane-result");
    if (!opts.artifact) {
        throw new UsageError(
            "publish needs --artifact: the lane's badge.json is the evidence that a " +
                '"success" result is real',
        );
    }
    const repo = opts.repo || process.env.GITHUB_REPOSITORY;
    if (!repo) throw new UsageError("--repo (or GITHUB_REPOSITORY) is required");
    const token = opts.token || process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
    if (!token) throw new UsageError("GITHUB_TOKEN (or GH_TOKEN) is required");
    const apiUrl = opts["api-url"] || process.env.GITHUB_API_URL || "https://api.github.com";
    const timeoutMs = Number(process.env.GOVERNANCE_BADGE_REQUEST_TIMEOUT_MS ?? 30000);
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > 2147483647) {
        throw new UsageError("GOVERNANCE_BADGE_REQUEST_TIMEOUT_MS must be an integer from 1 to 2147483647");
    }
    const http = { token, apiUrl, timeoutMs };

    const intent = resolveIntent({ label, laneResult, artifact: opts.artifact });
    const sourceRevision = String(opts["source-sha"] || "");
    if (sourceRevision && !/^[a-f0-9]{40}$/.test(sourceRevision)) {
        throw new UsageError("--source-sha must be a complete 40-character Git commit SHA");
    }
    const sourceSha = sourceRevision.slice(0, 12);
    const message =
        opts["commit-message"] ||
        `badges: ${label} lane ${intent.state}${sourceSha ? ` (source ${sourceSha})` : ""}`;

    // Refuse to touch a source branch, whatever --branch said and whatever the
    // repository's default branch happens to be called.
    const repoInfo = await getJSON(`/repos/${repo}`, http).catch((err) => {
        throw new RefusedError(
            `cannot read repository metadata for ${repo}: ${err.message} - not treating this as "the branch is missing"`,
        );
    });
    const defaultBranch = String((repoInfo && repoInfo.default_branch) || "");
    if (defaultBranch && defaultBranch === branch) {
        throw new UsageError(
            `--branch ${branch} is this repository's default branch; generated badges belong ` +
                "on an orphan branch such as governance-badges",
        );
    }

    // Badge content belongs to one source revision, not merely one runner.
    // Older push jobs can finish after newer ones despite concurrency and
    // cannot overwrite the current revision's published badge.
    const assertSourceCurrent = async () => {
        if (!sourceRevision) return;
        if (!defaultBranch) {
            throw new RefusedError("repository does not identify its default branch; cannot establish source freshness");
        }
        let head;
        try {
            head = await getJSON(`/repos/${repo}/git/ref/heads/${encodeURIComponent(defaultBranch)}`, http);
        } catch (err) {
            throw new RefusedError(`cannot establish current ${defaultBranch} head: ${err.message}`);
        }
        const currentSha = head?.object?.sha;
        if (currentSha !== sourceRevision) {
            throw new RefusedError(
                `superseded source commit ${sourceRevision.slice(0, 12)}: ${defaultBranch} is at ${String(currentSha || "<unknown>").slice(0, 12)}; refusing stale badge publication`,
            );
        }
    };

    let lastConflict = null;
    for (let attempt = 1; attempt <= MAX_CONFLICT_ATTEMPTS; attempt += 1) {
        await assertSourceCurrent();
        const remote = await readRemote({ repo, branch, dest, http });

        if (remote.kind === "present") {
            const verdict = inspectBadge(remote.text, label, { pairing: "loose" });
            if (!verdict.ok) {
                throw new RefusedError(
                    `the existing ${dest} on ${branch} is not a valid shield badge ` +
                        `(${verdict.errors.join("; ")}); refusing to overwrite generated output ` +
                        "this tool did not produce. Repair or delete the file by hand, then re-run.",
                );
            }
            if (remote.bytes.equals(intent.bytes)) {
                return finish({ label, dest, branch, intent, action: "unchanged", commit: null, faults: intent.faults });
            }
            await assertSourceCurrent();
            let response;
            try {
                response = await putFile({
                    repo, branch, dest, message, bytes: intent.bytes, sha: remote.sha, http,
                });
            } catch (err) {
                // A lost response is not proof that the PUT failed. Re-read
                // remote bytes before another write, exactly as for HTTP 409.
                if (err instanceof ApiError && err.transient) {
                    lastConflict = err;
                    await sleep(RETRY_DELAY_MS * attempt);
                    continue;
                }
                throw err;
            }
            if (response.status === 200 || response.status === 201) {
                const sha = readJsonPath(response.text, "commit.sha");
                return finish({ label, dest, branch, intent, action: "updated", commit: sha, faults: intent.faults });
            }
            const kind = classifyStatus(response.status);
            if (kind === "conflict" || kind === "transient") {
                lastConflict = apiError("PUT", contentsPathFor(repo, dest), response);
                await sleep(RETRY_DELAY_MS * attempt);
                continue;
            }
            throw apiError("PUT", contentsPathFor(repo, dest), response);
        }

        if (remote.kind === "absent-file") {
            await assertSourceCurrent();
            let response;
            try {
                response = await putFile({ repo, branch, dest, message, bytes: intent.bytes, http });
            } catch (err) {
                if (err instanceof ApiError && err.transient) {
                    lastConflict = err;
                    await sleep(RETRY_DELAY_MS * attempt);
                    continue;
                }
                throw err;
            }
            if (response.status === 200 || response.status === 201) {
                const sha = readJsonPath(response.text, "commit.sha");
                return finish({ label, dest, branch, intent, action: "created", commit: sha, faults: intent.faults });
            }
            const kind = classifyStatus(response.status);
            if (kind === "conflict" || kind === "transient") {
                lastConflict = apiError("PUT", contentsPathFor(repo, dest), response);
                await sleep(RETRY_DELAY_MS * attempt);
                continue;
            }
            throw apiError("PUT", contentsPathFor(repo, dest), response);
        }

        // remote.kind === "absent-branch": create an orphan branch.
        let created;
        try {
            await assertSourceCurrent();
            created = await createOrphanBranch({ repo, branch, dest, message, bytes: intent.bytes, http });
        } catch (err) {
            if (err instanceof ApiError && err.transient) {
                lastConflict = err;
                await sleep(RETRY_DELAY_MS * attempt);
                continue;
            }
            throw err;
        }
        if (created.conflict) {
            // Another run created the branch between our read and our write.
            // Re-read and compare instead of forcing our ref over theirs.
            lastConflict = new RefusedError(
                `another run created ${branch} while this one was publishing; re-reading`,
            );
            await sleep(RETRY_DELAY_MS * attempt);
            continue;
        }
        return finish({ label, dest, branch, intent, action: "created-orphan-branch", commit: created.sha, faults: intent.faults });
    }

    throw new RefusedError(
        `gave up after ${MAX_CONFLICT_ATTEMPTS} attempts without a trustworthy publication` +
            (lastConflict ? `: ${lastConflict.message}` : ""),
    );
}

/**
 * Return the string at a dot-separated JSON path, or an empty string for invalid
 * JSON, a missing path, or a non-string value.
 */
function readJsonPath(text, path) {
    try {
        const parsed = JSON.parse(text);
        const parts = path.split(".");
        let cursor = parsed;
        for (const part of parts) cursor = cursor?.[part];
        return typeof cursor === "string" ? cursor : "";
    } catch {
        return "";
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/** Print command usage, supported states, and exit codes to stdout. */
function usage() {
    console.log(
        [
            "usage:",
            "  governance-badge.js render --label K9 --state success [--out FILE]",
            "  governance-badge.js publish --label K9 --lane-result success \\",
            "        --artifact FILE --branch governance-badges --path badges/k9.json \\",
            "        [--repo owner/name] [--source-sha SHA] [--commit-message TEXT]",
            "",
            "States: success | failure | skipped | cancelled | unavailable | unknown.",
            "Exit: 0 ok/unchanged, 1 refused/failed, 2 usage, 3 grey published (lane evidence unusable).",
        ].join("\n"),
    );
}

/**
 * Dispatch command-line arguments (excluding the runtime and script paths),
 * returning 0 for help or the selected command's exit code.
 * @throws {UsageError} For malformed options or an unknown command.
 * @throws {Error} Propagates render/publication errors to the entry point's handler.
 */
async function main(argv) {
    const command = argv[0];
    const opts = parseArgs(argv.slice(1));
    if (!command || command === "help" || opts.help || command === "--help" || command === "-h") {
        usage();
        return EXIT_OK;
    }
    if (command === "render") return cmdRender(opts);
    if (command === "publish") return cmdPublish(opts);
    throw new UsageError(`unknown command: ${command}`);
}

// process.exit() can truncate pending writes when stdout is a pipe (which is
// how Actions captures a step's log, and how the "unchanged" notice reaches the
// run page). Set the code and let the process drain and exit instead.
main(process.argv.slice(2))
    .then((code) => {
        process.exitCode = code;
    })
    .catch((err) => {
        if (err instanceof UsageError) {
            console.error(`governance-badge: ${oneLine(err.message)}`);
            usage();
            process.exitCode = EXIT_USAGE;
            return;
        }
        if (err instanceof RefusedError) {
            console.error(`governance-badge: refused: ${oneLine(err.message)}`);
            process.exitCode = EXIT_REFUSED;
            return;
        }
        if (err instanceof ApiError) {
            console.error(`governance-badge: ${oneLine(err.message)}`);
            console.error(
                "governance-badge: no write was attempted for an unknown remote state; " +
                    "an API error is never treated as a missing branch or file",
            );
            process.exitCode = EXIT_REFUSED;
            return;
        }
        console.error(`governance-badge: ${oneLine((err && err.stack) || err)}`);
        process.exitCode = EXIT_REFUSED;
    });
