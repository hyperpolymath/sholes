#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression tests for PR #242: sorting the Podman devcontainer's object keys
# must preserve its settings and array order. devcontainer.json is JSONC and
# is explicitly exempt from strict JCS serialization (see CLAUDE.md).
# Usage: bash tests/workflows/devcontainer_test.sh
# Requires Bun; runs offline without building or starting a container.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v bun >/dev/null 2>&1 || { echo 'FAIL: Bun is required' >&2; exit 1; }

bun run - "$REPO_DIR" <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const repo = process.argv[2];
const directory = resolve(repo, ".devcontainer");
const config = Bun.JSONC.parse(readFileSync(resolve(directory, "devcontainer.json"), "utf8"));

assert.ok(config !== null && typeof config === "object" && !Array.isArray(config),
  "devcontainer.json must parse as a JSONC object, including its comments");
console.log("PASS: commented devcontainer configuration parses");

// Check every object, including objects within arrays. Array order itself is
// significant and must not be sorted along with the object keys.
function assertSortedKeys(value, path = "devcontainer") {
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertSortedKeys(item, `${path}[${index}]`));
  } else if (value !== null && typeof value === "object") {
    const keys = Object.keys(value);
    assert.deepEqual(keys, [...keys].sort(), `${path}: object keys must be sorted`);
    for (const key of keys) assertSortedKeys(value[key], `${path}.${key}`);
  }
}
assertSortedKeys(config);
console.log("PASS: object keys are sorted recursively");

assert.equal(config.name, "sholes (Podman)", "retain the mintable Podman profile name");
assert.deepEqual(config.build, { context: "..", dockerfile: "Containerfile" });
assert.equal(resolve(directory, config.build.context), repo, "build context must be the repository root");
assert.ok(readFileSync(resolve(directory, config.build.dockerfile), "utf8").length > 0,
  "the configured Containerfile must exist and be nonempty");
console.log("PASS: profile name and build paths are preserved");

assert.equal(config.containerUser, "nonroot");
assert.equal(config.remoteUser, "nonroot");
// Absence must not pass: the default is to update the remote user's UID,
// which would conflict with the explicit keep-id mapping.
assert.equal(config.updateRemoteUserUID, false, "keep the nonroot UID fixed");
assert.deepEqual(config.runArgs, [
  "--userns=keep-id:uid=65532,gid=65532",
  "--security-opt=label=disable",
], "preserve Podman user mapping and SELinux workspace access in order");
console.log("PASS: rootless Podman identity and launch options are preserved");

assert.deepEqual(config.containerEnv, {
  EDITOR: "code --wait",
  HOME: "/home/nonroot",
  LANG: "C.UTF-8",
});
assert.equal(config.postCreateCommand, "just deps");
assert.equal(config.shutdownAction, "stopContainer");
console.log("PASS: environment and lifecycle commands are preserved");

const vscode = config.customizations.vscode;
assert.deepEqual(vscode.settings, {
  "[makefile]": { "editor.insertSpaces": false },
  "editor.formatOnSave": true,
  "editor.insertSpaces": true,
  "editor.tabSize": 2,
  "files.insertFinalNewline": true,
  "files.trimFinalNewlines": true,
  "files.trimTrailingWhitespace": true,
}, "retain formatting defaults and the Makefile tab override");
console.log("PASS: editor defaults and the Makefile tab exception are preserved");

assert.deepEqual(vscode.extensions, [
  "EditorConfig.EditorConfig",
  "eamodio.gitlens",
  "streetsidesoftware.code-spell-checker",
  "timonwong.shellcheck",
  "tamasfe.even-better-toml",
  "skellock.just",
  "redhat.vscode-yaml",
  "DavidAnson.vscode-markdownlint",
  "asciidoctor.asciidoctor-vscode",
  "usernamehw.errorlens",
], "key sorting must not reorder or drop extension array entries");
console.log("PASS: extension array contents and order are preserved");

// Omitting an empty forwardPorts list preserves the default: no explicit
// ports are forwarded. Permit both forms, but reject null or a nonempty list.
const { forwardPorts = [] } = config;
assert.deepEqual(forwardPorts, [], "no explicit forwarded ports");
console.log("PASS: omitted forwardPorts retains the empty-list behavior");
JS
