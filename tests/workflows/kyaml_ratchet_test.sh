#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Unit tests of the actual KYAML workflow step bodies, with downloads and
# checksum commands replaced at the process boundary. No network is used.
# Usage: bash tests/workflows/kyaml_ratchet_test.sh
# Requires Mike Farah yq v4; all fixtures are deleted on exit.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
workflow="$repo/.github/workflows/estate-rules.yml"
fail() { echo "FAIL: $*" >&2; exit 1; }

install_name='Install verified yq 4.53.3 and kyaml-format.sh (standards 8e48b1c)'
gate_name='Converted YAML stays KYAML'
export install_name gate_name
for step_name in "$install_name" "$gate_name"; do
    export step_name
    count=$(yq '[.jobs.estate-rules.steps[] | select(.name == strenv(step_name))] | length' "$workflow")
    [[ "$count" = 1 ]] || fail "expected exactly one $step_name step"
    metadata=$(yq -o json -I 0 '.jobs.estate-rules.steps[] | select(.name == strenv(step_name)) | [.if, .continue-on-error]' "$workflow")
    [[ "$metadata" = '[null,null]' ]] || fail "$step_name may be skipped or allowed to fail"
done
indices=$(yq -o json -I 0 '.jobs.estate-rules.steps | to_entries | [.[] | select(.value.name == strenv(install_name) or .value.name == strenv(gate_name)) | .value.name]' "$workflow")
[[ "$indices" = "[\"$install_name\",\"$gate_name\"]" ]] || fail 'formatter installation must precede the ratchet'
yq -r '.jobs.estate-rules.steps[] | select(.name == strenv(install_name)) | .run' "$workflow" > "$scratch/install.sh"
yq -r '.jobs.estate-rules.steps[] | select(.name == strenv(gate_name)) | .run' "$workflow" > "$scratch/gate.sh"

mkdir -p "$scratch/bin" "$scratch/assets"
cat > "$scratch/assets/yq" <<'YQ'
#!/usr/bin/env bash
exit 0
YQ
cat > "$scratch/assets/kyaml-format.sh" <<'FORMATTER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$FORMATTER_ARGS"
exit "${FORMATTER_STATUS:-0}"
FORMATTER

# These mocks reject unexpected endpoints/flags and inspect the pinned digest
# manifests. Failure injection tests the runner's handling of both downloads
# and both checksum failures, independently of the upstream formatter.
cat > "$scratch/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
proto= redir= fail= silent= show= location= url= output=
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --proto) proto=$2; shift 2 ;;
        --proto-redir) redir=$2; shift 2 ;;
        --fail) fail=yes; shift ;;
        --silent) silent=yes; shift ;;
        --show-error) show=yes; shift ;;
        --location) location=yes; shift ;;
        --output) output=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) echo "unexpected curl argument: $1" >&2; exit 90 ;;
    esac
done
[[ "$proto/$redir/$fail/$silent/$show/$location" = '=https/=https/yes/yes/yes/yes' ]] || exit 91
case "$url" in
    https://github.com/mikefarah/yq/releases/download/v4.53.3/yq_linux_amd64)
        asset=yq
        [[ "$output" = "$RUNNER_TEMP/yq-bin/yq" ]] || exit 92 ;;
    https://raw.githubusercontent.com/metadatastician/standards/f0b3cd4c464d33e1584f8528c17bce104555e256/scripts/kyaml-format.sh)
        asset=kyaml-format.sh
        [[ "$output" = "$RUNNER_TEMP/kyaml-format.sh" ]] || exit 92 ;;
    *) echo "unexpected download: $url" >&2; exit 93 ;;
esac
echo "curl:$asset" >> "$EVENTS"
[[ "${FAIL_AT:-}" != "curl:$asset" ]] || exit 22
cp "$ASSETS/$asset" "$output"
CURL
cat > "$scratch/bin/sha256sum" <<'CHECKSUM'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 2 ]] && [[ "$1" = --check ]] && [[ "$2" = --strict ]] || exit 94
IFS= read -r manifest
case "$manifest" in
    "fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4  $RUNNER_TEMP/yq-bin/yq")
        asset=yq
        downloaded="$RUNNER_TEMP/yq-bin/yq"
        [[ ! -x "$RUNNER_TEMP/yq-bin/yq" ]] || exit 95 ;;
    "5fddd58fc8cbd2b68766ef5b4b5ba39f299da3f27252ae6cdcff0a641bbaef18  $RUNNER_TEMP/kyaml-format.sh")
        asset=kyaml-format.sh
        downloaded="$RUNNER_TEMP/kyaml-format.sh" ;;
    *) echo "unexpected checksum manifest: $manifest" >&2; exit 96 ;;
esac
echo "sha256:$asset" >> "$EVENTS"
[[ -f "$downloaded" ]] || exit 97
[[ "${FAIL_AT:-}" != "sha256:$asset" ]] || exit 1
CHECKSUM
chmod +x "$scratch/bin/curl" "$scratch/bin/sha256sum"

original_path=$PATH
export ASSETS="$scratch/assets"
export FORMATTER_ARGS="$scratch/formatter-args"
existing_path_entry='/existing runner/bin'
run_install() {
    local scenario=$1 expected_status=$2 expected_events=$3 status=0
    # Spaces in GitHub runner paths must survive every invocation/manifest.
    export RUNNER_TEMP="$scratch/$scenario/runner temp"
    export GITHUB_PATH="$scratch/$scenario/github path"
    export EVENTS="$scratch/$scenario/events"
    mkdir -p "$RUNNER_TEMP"
    printf '%s\n' "$existing_path_entry" > "$GITHUB_PATH"
    : > "$EVENTS"
    FAIL_AT="$scenario" PATH="$scratch/bin:$original_path" \
        bash --noprofile --norc -e "$scratch/install.sh" > "$scratch/install.log" 2>&1 || status=$?
    [[ "$status" -eq "$expected_status" ]] || { cat "$scratch/install.log" >&2; fail "$scenario: expected exit $expected_status, got $status"; }
    [[ "$(cat "$EVENTS")" = "$expected_events" ]] || fail "$scenario: wrong download/verification sequence: $(cat "$EVENTS")"
}

all_events=$'curl:yq\nsha256:yq\ncurl:kyaml-format.sh\nsha256:kyaml-format.sh'
run_install success 0 "$all_events"
[[ -x "$RUNNER_TEMP/yq-bin/yq" ]] || fail 'verified yq was not made executable'
[[ "$(cat "$GITHUB_PATH")" = "$existing_path_entry"$'\n'"$RUNNER_TEMP/yq-bin" ]] || fail 'verified yq directory must be appended without losing existing runner paths'
cmp -s "$ASSETS/yq" "$RUNNER_TEMP/yq-bin/yq" || fail 'yq downloaded to the wrong path'
cmp -s "$ASSETS/kyaml-format.sh" "$RUNNER_TEMP/kyaml-format.sh" || fail 'formatter downloaded to the wrong path'

compose=build/container/compose.yaml
example=build/container/compose.example.yaml
policy=build/container/stapeln/.gatekeeper.yaml
# make_tree NAME ENTRY...: a fixture tree holding only the named files, plus
# archetypes/ (the template marker) when an entry is "archetypes".
make_tree() {
    local tree="$scratch/trees/$1" entry
    shift
    mkdir -p "$tree"
    for entry in "$@"; do
        if [[ "$entry" = archetypes ]]; then
            mkdir -p "$tree/archetypes"
        else
            mkdir -p "$tree/$(dirname "$entry")"
            : > "$tree/$entry"
        fi
    done
    printf '%s\n' "$tree"
}
# run_gate TREE FORMATTER_STATUS: sets gate_status and leaves the step's output
# in $scratch/gate.log. Always run the extracted body as a separate process:
# testing it in a shell conditional would suppress errexit inside it.
run_gate() {
    rm -f "$FORMATTER_ARGS"
    gate_status=0
    (cd "$1"; FORMATTER_STATUS=$2 bash --noprofile --norc -e "$scratch/gate.sh") > "$scratch/gate.log" 2>&1 || gate_status=$?
}
expect_args() {
    local expected
    expected=$(printf '%s\n' --check "$@")
    [[ -f "$FORMATTER_ARGS" ]] || fail "$label: formatter did not run"
    [[ "$(cat "$FORMATTER_ARGS")" = "$expected" ]] \
        || fail "$label: ratchet must check exactly the converted files present, with no workflow or bot-owned configs"
}
expect_log() { grep -Fq -- "$1" "$scratch/gate.log" || fail "$label: missing '$1' in: $(cat "$scratch/gate.log")"; }

label='template'
tree=$(make_tree template archetypes "$compose" "$example" "$policy")
for expected_status in 0 1 2; do
    run_gate "$tree" "$expected_status"
    [[ "$gate_status" -eq "$expected_status" ]] || fail "ratchet swallowed formatter exit $expected_status (got $gate_status)"
    expect_args "$compose" "$example" "$policy"
done
echo 'PASS: pinned HTTPS downloads are verified in order, runner paths with spaces work, and the ratchet propagates clean/drift/refusal statuses'

# Exercise all eight subsets, including the full/no-stapeln/not-portable/
# no-container mint paths and a missing file in every position of the list.
# Unconverted files must never be passed to the formatter, even when they
# are the only YAML left in a minted repository.
converted_files=("$compose" "$example" "$policy")
for mask in {0..7}; do
    kept=() missing=()
    for index in "${!converted_files[@]}"; do
        if ((mask & (1 << index))); then
            kept+=("${converted_files[index]}")
        else
            missing+=("${converted_files[index]}")
        fi
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        label="template subset $mask"
        tree=$(make_tree "template-$mask" archetypes "${kept[@]}")
        run_gate "$tree" 0
        [[ "$gate_status" -eq 1 ]] || fail "$label: expected exit 1, got $gate_status"
        [[ ! -f "$FORMATTER_ARGS" ]] || fail "$label: formatter ran with a required file missing"
        expect_log "::error::${missing[0]} is missing from the template"
        ! grep -Fq '::notice::' "$scratch/gate.log" || fail "$label: template loss was treated as mint narrowing"
    fi

    label="minted subset $mask"
    tree=$(make_tree "minted-$mask" "${kept[@]}" .github/workflows/example.yml .github/dependabot.yml .coderabbit.yaml)
    for formatter_status in 0 1 2 17; do
        run_gate "$tree" "$formatter_status"
        expected_status=$formatter_status
        if [[ "${#kept[@]}" -eq 0 ]]; then
            expected_status=0
            [[ ! -f "$FORMATTER_ARGS" ]] || fail "$label: formatter ran with no converted files"
            expect_log 'nothing to check'
        else
            expect_args "${kept[@]}"
        fi
        [[ "$gate_status" -eq "$expected_status" ]] || fail "$label: expected exit $expected_status, got $gate_status"
        for file in "${missing[@]}"; do
            expect_log "::notice::$file was removed at mint by container narrowing; not checked"
        done
        for file in "${kept[@]}"; do
            ! grep -Fq "::notice::$file " "$scratch/gate.log" || fail "$label: present file reported as removed"
        done
        ! grep -Fq '::error::' "$scratch/gate.log" || fail "$label: narrowing reported as a template error"
    done
done
echo 'PASS: every template/mint file subset checks exactly the retained files and propagates formatter failures'

# A directory or broken symlink with a converted filename is not a config.
for file in "${converted_files[@]}"; do
    label="template non-file $file"
    tree=$(make_tree "non-file-$file" archetypes "$compose" "$example" "$policy")
    rm "$tree/$file"
    mkdir "$tree/$file"
    for kind in directory broken-symlink; do
        run_gate "$tree" 0
        [[ "$gate_status" -eq 1 ]] || fail "$label ($kind): expected exit 1, got $gate_status"
        [[ ! -f "$FORMATTER_ARGS" ]] || fail "$label ($kind): formatter ran with a required file missing"
        expect_log "::error::$file is missing from the template"
        if [[ "$kind" = directory ]]; then
            rmdir "$tree/$file"
            ln -s missing-config.yaml "$tree/$file"
        fi
    done
done
echo 'PASS: directories and broken symlinks cannot stand in for required template configs'

label='missing formatter'
tree=$(make_tree missing-formatter "$compose")
mv "$RUNNER_TEMP/kyaml-format.sh" "$RUNNER_TEMP/kyaml-format.saved"
run_gate "$tree" 0
[[ "$gate_status" -eq 127 ]] || fail "$label: expected exit 127, got $gate_status"
[[ ! -f "$FORMATTER_ARGS" ]] || fail "$label: unexpected formatter invocation"
expect_log 'kyaml-format.sh'
mv "$RUNNER_TEMP/kyaml-format.saved" "$RUNNER_TEMP/kyaml-format.sh"
echo 'PASS: a missing formatter cannot silently pass a repository with converted files'

run_install curl:yq 22 'curl:yq'
[[ "$(cat "$GITHUB_PATH")" = "$existing_path_entry" ]] || fail 'failed yq download changed the runner path'
run_install sha256:yq 1 $'curl:yq\nsha256:yq'
[[ ! -x "$RUNNER_TEMP/yq-bin/yq" ]] || fail 'unverified yq became executable'
[[ "$(cat "$GITHUB_PATH")" = "$existing_path_entry" ]] || fail 'unverified yq changed the runner path'
run_install curl:kyaml-format.sh 22 $'curl:yq\nsha256:yq\ncurl:kyaml-format.sh'
run_install sha256:kyaml-format.sh 1 "$all_events"
echo 'PASS: each failed download or checksum stops installation and cannot report success'

# The local formatter is part of PR #253's ratchet; exercise its byte/data
# preservation controls as well as the workflow download/dispatch controls.
bash "$repo/tests/workflows/kyaml_format_test.sh"
