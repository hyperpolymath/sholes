#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-lock-sync.sh — verify .github/workflows/actions.lock is in sync with the
# workflow YAML, in BOTH directions (including job-level reusable-workflow refs),
# AND that the lockfile is TRANSITIVELY CLOSED.
#
# Validation clauses, each of which alone is insufficient:
#
#   1. every `uses:` in a workflow is locked under THAT workflow's own path;
#   2. every lockfile entry is still referenced by its workflow (no orphans);
#   3. every ref NAMED anywhere in the lockfile resolves to a top-level
#      `dependencies:` record — the lockfile has no dangling edges.
#   4. every workflow file has a lockfile entry, even when it uses no actions;
#   5. dependency ref metadata is a string naming a short branch/tag, never a
#      SHA or placeholder, and matches its key unless that key is a full SHA.
#      One measured exception: a record that is ONLY the target of job-level
#      reusable-workflow calls (`uses: o/r/.github/workflows/x.yml@<sha>`),
#      never a step action and never a nested `uses:` of another record, may
#      carry its own SHA as ref:. Such a reusable has no tag to name, and
#      GitHub runs it: hyperpolymath/secret-types main at d1d843b, Governance
#      run 41678782554 (2026-11-03), every job past "Set up job" with
#      metadatastician/standards@46ee183 recorded as ref: 46ee183... . The
#      action case stays refused (Protoctist.jl#18; metadatastician/lintel#15);
#   6. the lockfile version is the supported v0.0.3 format.
#
# Clause 3 is not decoration. It is the clause that catches the failure mode that
# clauses 1 and 2 are structurally blind to, and it was added only after that
# blindness was measured. On hyperpolymath/cicd-squabbler, 2026-09-22:
#
#   commit    dangling-edge class                              result
#   fe22bbc   workflows: -> dependencies: (ref listed, no record)   4 workflows startup_failure, jobs=0
#   cfadcf9   dependencies: -> dependencies: (record added, its
#             own nested uses: unrecorded)                          the same 4 still startup_failure
#   5286aa5   none - transitively closed                            0 startup_failure, all 17 runs create jobs
#
# At fe22bbc AND cfadcf9 this script exited 0, `gh actions-lock --verify-local`
# exited 0, and the Lock Sync Gate reported green - while GitHub was refusing to
# start four workflows. Every local gate was green on a fatal commit. That is the
# guard/consumer trap: the gate asked "is every uses: locked?" and GitHub asks
# "is every locked ref RESOLVABLE?".
#
# The asymmetry that makes clause 3 mandatory, and counter-intuitive:
#   * a job-level ref ABSENT from the lockfile entirely is HARMLESS;
#   * a ref PRESENT in the lockfile but unresolvable is FATAL.
# So adding entries without closing them is strictly worse than adding nothing.
# Clause 1 demands entries be added; only clause 3 makes that demand safe. Shipping
# clause 1 without clause 3 actively steers a developer into the fatal state:
# Dependabot bumps a job-level ref -> clause 1 reds -> `gh actions-lock` is blind to
# job-level refs and will not backfill -> the developer hand-adds the workflows:
# entry to get green -> no dependencies: record -> CI dies silently, gate green.
#
# Exit 0 only when all clauses hold. Any violation exits 1. There is no
# warn-only mode: a desync means GitHub refuses to start the run, so it must fail
# the job. A `::warning::` cannot fail a job and would be a vacuous gate.

set -euo pipefail

WF_DIR="${1:-.github/workflows}"
LOCK="$WF_DIR/actions.lock"

# Portable POSIX awk: avoids GNU gawk's 3-argument match() extension so the
# gate runs identically on Debian/Ubuntu minimal images (mawk) and gawk.
AWK=""
for cand in gawk mawk awk; do
  if command -v "$cand" >/dev/null 2>&1; then
    AWK="$cand"; break
  fi
done
if [ -z "$AWK" ]; then
  echo "check-lock-sync: FATAL: no awk found on PATH" >&2
  exit 1
fi

if [ ! -f "$LOCK" ]; then
  echo "check-lock-sync: FATAL: no lockfile at $LOCK" >&2
  exit 1
fi

shopt -s nullglob
mapfile -t WORKFLOWS < <(printf '%s\n' "$WF_DIR"/*.yml "$WF_DIR"/*.yaml | sort -u)
if [ "${#WORKFLOWS[@]}" -eq 0 ]; then
  echo "check-lock-sync: FATAL: no workflow files under $WF_DIR" >&2
  exit 1
fi

read -r -d '' PROG <<'AWK' || true
# owner/repo[/subpath...]@ref  ->  owner/repo@ref   ("" if not an external ref)
function norm(r,   at, path, ref, n, parts) {
  at = 0
  for (n = length(r); n > 0; n--) { if (substr(r, n, 1) == "@") { at = n; break } }
  if (at == 0) return ""
  path = substr(r, 1, at - 1); ref = substr(r, at + 1)
  if (path == "" || ref == "") return ""
  if (substr(path, 1, 2) == "./" || substr(path, 1, 2) == "$/") return ""   # local action
  if (split(path, parts, "/") < 2) return ""
  return parts[1] "/" parts[2] "@" ref
}

# Fold case on the OWNER/REPO segment only, for comparison keys. GitHub resolves
# owner and repository names case-insensitively, and this is measured, not assumed:
# metadatastician/pong-ping's lockfile records sonarsource/sonarqube-scan-action@v8.2.1
# while sonarqube.yml says SonarSource/..., and at commit cd5f90f that workflow ran
# SUCCESS while codeql.yml at the SAME commit was startup_failure. A same-commit
# control, so the case difference is provably not what kills a run.
# The REF is NOT folded: git tags and branch names are case-sensitive.
function ck(r,   at, s) {
  at = 0
  for (s = length(r); s > 0; s--) { if (substr(r, s, 1) == "@") { at = s; break } }
  if (at == 0) return tolower(r)
  return tolower(substr(r, 1, at - 1)) substr(r, at)
}

# Full commit identities supported by the upstream resolver (SHA-1/SHA-256).
# Keep the length checks separate from the regex for POSIX awk/mawk.
function fullsha(r) {
  return r ~ /^[0-9a-fA-F]+$/ && (length(r) == 40 || length(r) == 64)
}

# The v0.0.3 schema requires a string, not a YAML null, boolean, number or
# collection. Recognize plain single-line names without coercing those types
# into strings. Quoted names are handled separately, so e.g. "null" and
# "123" remain eligible literal refs. Tags/anchors/block scalars are outside
# the generated lockfile format; quote a literal name instead.
function plainstring(r,   n) {
  if (r == "" || r ~ /^(~|null|Null|NULL|true|True|TRUE|false|False|FALSE)$/) return 0
  if (r ~ /^[#&*!|>\[{]/ || substr(r, 1, 1) == "`" || substr(r, 1, 1) == "@") return 0
  n = r
  gsub(/_/, "", n)
  if (r ~ /^[-+0-9.]/ && (n ~ /^[-+]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?$/ ||
      n ~ /^[-+]?0[xX][0-9a-fA-F]+$/ ||
      n ~ /^[-+]?0[oO][0-7]+$/ ||
      n ~ /^[-+]?0[bB][01]+$/ ||
      n ~ /^[-+]?\.(inf|Inf|INF)$/ || n ~ /^\.(nan|NaN|NAN)$/)) return 0
  return 1
}

# Check short named-ref syntax without network access. Git allows one-level
# names for branches/tags, but lock metadata forbids the refs/ namespace
# prefix; see upstream lockfile.ValidEntryRef. Angle brackets
# are additionally rejected here because lock metadata must not be a template
# marker such as <sha-pinned>. Existence and commit resolution remain upstream
# checks; this gate does not claim to prove them from a name alone.
function namedref(r,   count, part, j) {
  if (index(r, "refs/") == 1) return 0
  if (r == "" || r == "@" || r ~ /[[:cntrl:] ]/ || r ~ /[~^:?*\\]/ || index(r, "[")) return 0
  if (index(r, "<") || index(r, ">") || index(r, "..") || index(r, "@{") || index(r, "//")) return 0
  if (r ~ /^\// || r ~ /\/$/ || r ~ /\.$/) return 0
  count = split(r, part, "/")
  for (j = 1; j <= count; j++)
    if (part[j] ~ /^\./ || part[j] ~ /\.lock$/) return 0
  return 1
}

# ---------- pass 1: the lockfile ----------
FILENAME == lockfile {
  if ($0 ~ /^version:[[:space:]]*/) {
    verline = $0
    sub(/^version:[[:space:]]*/, "", verline)
    sub(/[[:space:]]*$/, "", verline)
    has_version = 1
    lock_version = verline
    next
  }
  if ($0 ~ /^workflows:[[:space:]]*$/)    { inwf = 1; indep = 0; next }
  if ($0 ~ /^dependencies:[[:space:]]*$/) { inwf = 0; indep = 1; next }
  if ($0 ~ /^[a-z_]+:/)                   { inwf = 0; indep = 0; next }

  # --- the dependencies: section, for clause 3 & self-SHA ref guard ---
  if (indep) {
    # "    'owner/repo@ref':"  -- a top-level dependency record
    if ($0 ~ /^    \047[^\047]+\047:/) {
      depkey = $0
      sub(/^    \047/, "", depkey)
      sub(/\047:.*$/, "", depkey)
      haverec[ck(depkey)] = 1; disp[ck(depkey)] = depkey
      rawrec[depkey] = 1
      next
    }
    # "        ref: '...'" -- the record needs a real branch/tag name, even
    # when its dependency key and commit: are correctly pinned to a SHA.
    if ($0 ~ /^        ref:/ && depkey != "") {
      rval = $0
      # Preserve the separator before # until comments are stripped: a
      # comment-only value is YAML null, not a branch named #missing.
      sub(/[[:space:]]+#.*$/, "", rval)
      sub(/^        ref:[[:space:]]*/, "", rval)
      sub(/[[:space:]]*$/, "", rval)
      hasref[depkey] = 1
      quote = substr(rval, 1, 1)
      if (quote == "\047" || quote == "\042") {
        # Match one complete scalar: inner single quotes must be doubled,
        # and an unescaped double quote must end a double-quoted scalar.
        if ((quote == "\047" && rval !~ /^\047([^\047]|\047\047)*\047$/) ||
            (quote == "\042" && rval !~ /^\042([^\042\\]|\\.)*\042$/)) {
          invalidref[depkey] = rval
          next
        }
        rval = substr(rval, 2, length(rval) - 2)
        if (quote == "\047") gsub(/\047\047/, "\047", rval)
      } else if (!plainstring(rval)) {
        invalidscalar[depkey] = (rval == "" ? "<empty or comment-only>" : rval)
        next
      }
      keyref = substr(depkey, index(depkey, "@") + 1)
      if (fullsha(rval)) {
        selfsha[depkey] = rval
      } else if (!namedref(rval)) {
        invalidref[depkey] = (rval == "" ? "<empty>" : rval)
      } else if (!fullsha(keyref) && rval != keyref) {
        mismatchref[depkey] = rval
      }
      next
    }
    # "            - 'owner/repo@ref'"  -- a nested uses: of that record
    if ($0 ~ /^            - \047[^\047]+\047/ && depkey != "") {
      val = $0
      sub(/^            - \047/, "", val)
      sub(/\047.*$/, "", val)
      r = ck(val); disp[r] = val
      want[r] = 1
      wantsrc[r] = wantsrc[r] " dependencies:" depkey
      next
    }
    next
  }

  if (!inwf) next

  # "    '.github/workflows/x.yml':"  or  "... : []"
  if ($0 ~ /^    \047[^\047]+\047:/) {
    cur = $0
    sub(/^    \047/, "", cur)
    sub(/\047:.*$/, "", cur)
    seen_path[cur] = 1
    next
  }
  if ($0 ~ /^        - \047[^\047]+\047[[:space:]]*$/ && cur != "") {
    val = $0
    sub(/^        - \047/, "", val)
    sub(/\047[[:space:]]*$/, "", val)
    lr = ck(val); disp[lr] = val; lock[cur, lr] = 1
    lockcount[cur]++
    want[lr] = 1
    wantsrc[lr] = wantsrc[lr] " " cur
    next
  }
  next
}

# ---------- pass 2: the workflow YAML ----------
FNR == 1 { wf = FILENAME; stepind = -1 }
{
  line = $0
  sub(/[[:space:]]+#.*$/, "", line)              # strip trailing comment
  # Track whether this line sits inside a job's `steps:` block, by
  # indentation: a `uses:` there is a step action, whatever its path looks
  # like (an action directory may be named tool.yml). Only a `uses:` outside
  # every `steps:` block is a job-level reusable-workflow call.
  if (line ~ /[^[:space:]]/) {
    match(line, /^[[:space:]]*/); ind = RLENGTH
    if (stepind >= 0 && ind <= stepind) stepind = -1
    if (line ~ /^[[:space:]]*steps:/) stepind = ind
  }
  if (line ~ /^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*.+$/) {
    raw = line
    sub(/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*/, "", raw)
    gsub(/^["\047]|["\047]$/, "", raw)
    gsub(/[[:space:]]+$/, "", raw)
    if (raw ~ /^\$\//) { dollar[wf] = dollar[wf] " " raw; next }   # known corruption
    n = norm(raw)
    if (n != "") { uses[wf, ck(n)] = 1; useslist[wf] = useslist[wf] " " n }
    # Clause 5's exception needs to know HOW a ref is used: as the target of a
    # job-level reusable-workflow call, or as an action.
    if (n != "") {
      if (stepind < 0 && line !~ /^[[:space:]]*-/ && raw ~ /\/\.github\/workflows\/[^\/@]+\.ya?ml@/) reusetgt[ck(n)] = 1
      else actiontgt[ck(n)] = 1
    }
  }
}

END {
  bad = 0
  for (i = 1; i < ARGC; i++) {
    wf = ARGV[i]
    if (wf == lockfile) continue
    key = wf
    sub(/.*\//, "", key)
    key = ".github/workflows/" key          # the lockfile always uses this canonical path

    if (dollar[wf] != "") {
      printf "FAIL %s\n     invalid local-action rewrite (uses: $/...):%s\n", key, dollar[wf]
      bad = 1
    }

    # --- clause 1: every uses: must be locked under THIS path ---
    nu = split(useslist[wf], u, " ")
    delete uniq; missing = ""
    for (j = 1; j <= nu; j++) {
      if (u[j] == "" || (u[j] in uniq)) continue
      uniq[u[j]] = 1
      if (!((key SUBSEP ck(u[j])) in lock)) missing = missing " " u[j]
    }
    if (missing != "") {
      if (!(key in seen_path))
        printf "FAIL %s\n     not onboarded: no lockfile entry for this path\n     unlocked refs:%s\n", key, missing
      else
        printf "FAIL %s\n     refs missing from the lockfile:%s\n", key, missing
      bad = 1
    }

    # --- clause 2: every lock entry must be referenced by this workflow ---
    orphan = ""
    for (k in lock) {
      split(k, kp, SUBSEP)
      if (kp[1] != key) continue
      if (!((wf SUBSEP kp[2]) in uses)) orphan = orphan " " (kp[2] in disp ? disp[kp[2]] : kp[2])
    }
    if (orphan != "") {
      printf "FAIL %s\n     stale lockfile entries, no uses: references them:%s\n", key, orphan
      bad = 1
    }
  }

  # --- lockfile entries for workflow files that no longer exist ---
  for (p in seen_path) {
    found = 0
    for (i = 1; i < ARGC; i++) {
      q = ARGV[i]; if (q == lockfile) continue
      sub(/.*\//, "", q); q = ".github/workflows/" q
      if (q == p) { found = 1; break }
    }
    if (!found) { printf "FAIL %s\n     lockfile entry for a workflow file that does not exist\n", p; bad = 1 }
  }

  # --- clause 4: COVERAGE. Every workflow FILE must have a key in the lockfile,
  #     including one with no uses: at all - the value is then an empty list.
  #     MEASURED 2026-09-22, single-variable flip on two independent repos:
  #     hyperpolymath/verisimdb's lock-sync-gate.yml was startup_failure 7 times
  #     running with ZERO uses: refs, and adding
  #         '.github/workflows/lock-sync-gate.yml': []
  #     flipped it to success; reproduced on hyperpolymath/blocky-writer, 2 of 2.
  #     `gh actions-lock` already emits this empty-list form for other zero-uses:
  #     workflows (labels.yml), so it is the generator's own convention, not ours.
  #     Clauses 1-3 CANNOT catch this: they ask "is every uses: locked?", and a
  #     workflow with no uses: satisfies them vacuously while GitHub still refuses
  #     to start it. 13 repos passed clauses 1-3 with exactly this gap.
  nunlisted = 0; unlisted = ""
  for (i = 1; i < ARGC; i++) {
    q = ARGV[i]; if (q == lockfile) continue
    sub(/.*\//, "", q); q = ".github/workflows/" q
    if (q in seen_path) continue
    nunlisted++; unlisted = unlisted "\n       " q
  }
  if (nunlisted > 0) {
    printf "FAIL actions.lock: UNLISTED WORKFLOWS\n"
    printf "     %d workflow file(s) have no key in the lockfile. GitHub refuses such a\n", nunlisted
    printf "     run at startup (jobs=0) even when the workflow has no uses: at all.\n"
    printf "     The entry for a zero-uses: workflow is an empty list:%s\n", unlisted
    bad = 1
  }

  # --- clause 3: TRANSITIVE CLOSURE. Every ref named anywhere in the lockfile
  #     must resolve to a top-level dependencies: record. A dangling edge makes
  #     GitHub refuse the run at startup with jobs=0. ---
  ndang = 0; dang = ""
  for (r in want) {
    if (r !~ /^[^\/]+\/[^\/@]+@/) continue      # not an OWNER/REPO@REF pin; not ours to resolve
    if (r in haverec) continue
    ndang++
    dang = dang sprintf("\n       %s\n           named by:%s", (r in disp ? disp[r] : r), wantsrc[r])
  }
  if (ndang > 0) {
    printf "FAIL actions.lock: DANGLING EDGES\n"
    printf "     %d ref(s) are named in the lockfile but have no top-level dependencies: record.%s\n", ndang, dang
    bad = 1
  }

  # --- clause 5: GitHub requires string-valued short source refs, matching
  #     mutable keys, never 40/64-hex commit identities as ref metadata. ---
  nself = 0; selflist = ""
  for (s in selfsha) {
    k = ck(s)
    # Only the target of job-level reusable calls, never an action and never a
    # nested uses: of another record (see the header, clause 5).
    # The record's key must itself be pinned to that same SHA: a mutable key
    # (@v1) or a key at a different SHA is not "its own SHA".
    keyref = substr(s, index(s, "@") + 1)
    if (fullsha(keyref) && tolower(keyref) == tolower(selfsha[s]) &&
        (k in reusetgt) && !(k in actiontgt) && index(wantsrc[k], " dependencies:") == 0) continue
    nself++
    selflist = selflist sprintf("\n       %s (ref: %s)", s, selfsha[s])
  }
  if (nself > 0) {
    printf "FAIL actions.lock: SELF-SHA REFS\n"
    printf "     %d dependencies: record(s) use a 40/64-hex SHA as ref: (rejected by GitHub runner):%s\n", nself, selflist
    bad = 1
  }

  # Metadata belongs to each raw record, even when repository lookup folds
  # case and another spelling of the same pin has its own valid ref.
  for (d in rawrec)
    if (!(d in hasref)) invalidref[d] = "<missing ref>"
  ninvalid = 0; invalidlist = ""
  for (d in invalidref) {
    ninvalid++
    invalidlist = invalidlist sprintf("\n       %s (ref: %s)", d, invalidref[d])
  }
  if (ninvalid > 0) {
    printf "FAIL actions.lock: INVALID NAMED REFS\n"
    printf "     %d dependencies: record(s) have missing, placeholder or malformed ref: metadata:%s\n", ninvalid, invalidlist
    bad = 1
  }

  nscalar = 0; scalarlist = ""
  for (d in invalidscalar) {
    nscalar++
    scalarlist = scalarlist sprintf("\n       %s (ref: %s)", d, invalidscalar[d])
  }
  if (nscalar > 0) {
    printf "FAIL actions.lock: INVALID REF SCALARS\n"
    printf "     %d dependencies: record(s) have non-string or unsupported YAML ref: values; quote literal names:%s\n", nscalar, scalarlist
    bad = 1
  }

  nmismatch = 0; mismatchlist = ""
  for (d in mismatchref) {
    nmismatch++
    mismatchlist = mismatchlist sprintf("\n       %s (ref: %s)", d, mismatchref[d])
  }
  if (nmismatch > 0) {
    printf "FAIL actions.lock: MISMATCHED REFS\n"
    printf "     %d dependencies: record(s) disagree with their mutable key refs:%s\n", nmismatch, mismatchlist
    bad = 1
  }

  if (!has_version || lock_version != "\047v0.0.3\047") {
    printf "FAIL actions.lock: INVALID VERSION (%s; expected \047v0.0.3\047)\n", (has_version ? lock_version : "missing")
    bad = 1
  }

  # --- a dependencies: record nothing names is dead weight, not fatal: report only ---
  nunref = 0
  for (d in haverec) if (!(d in want)) nunref++

  if (bad) {
    print ""
    print "actions.lock is OUT OF SYNC, is not transitively closed, or has invalid pin metadata."
    print "GitHub refuses such a run at startup: zero jobs are created and the run"
    print "reports \"This run likely failed because of a workflow file issue.\""
    print ""
    print "Fix, in this order:"
    print "  0. After a Dependabot bump: `just lock-sync-fix` (scripts/lock-sync-fix.sh)"
    print "     resolves the new refs, rewrites the lock, and re-runs this check."
    print "  1. `gh actions-lock --no-migrate-local-actions`, then review the diff. It does"
    print "     NOT handle job-level reusable-workflow refs and it can de-pin bare SHAs to"
    print "     floating tags - both must be corrected by hand."
    print "  2. For any DANGLING EDGES above, add a top-level `dependencies:` record for each"
    print "     ref. A leaf record may legally omit the nested `uses:` key entirely, so adding"
    print "     leaves introduces no new dangling edges and closure terminates in one pass."
    print "     Keys are sorted with LC_ALL=C collation (ASCII '-' 0x2d sorts before '@' 0x40)."
    print "  3. Nested `uses:` entries must be bare OWNER/REPO@REF. A subpath pin such as"
    print "     github/codeql-action/upload-sarif@<sha> is REJECTED by the schema; collapse it"
    print "     to github/codeql-action@<sha>."
    print "  4. For any UNLISTED WORKFLOWS above, add the path as a lockfile key. A workflow"
    print "     with no uses: takes an empty list:  \047.github/workflows/x.yml\047: []"
    print "     `gh actions-lock` has been observed to OMIT such a workflow entirely; that"
    print "     omission is itself the defect, so re-running the tool may not add it."
    print "  5. Every dependency ref: must be a string naming a short branch or tag and"
    print "     match the key ref unless the key is a full SHA. Preserve the immutable"
    print "     commit: pin; do not replace ref: with that SHA, a placeholder or a refs/ name."
    exit 1
  }
  printf "actions.lock is in sync and transitively closed:\n"
  printf "  * every uses: is locked under its own workflow path (job-level reusable refs included)\n"
  printf "  * every lockfile entry is still referenced\n"
  printf "  * every ref named in the lockfile resolves to a dependencies: record (0 dangling edges)\n"
  printf "  * every workflow file has a lockfile key (zero-uses: workflows included)\n"
  printf "  * dependency ref: metadata uses string-valued short names, matches mutable keys, and has no placeholders or SHAs (a job-level reusable target may name its own SHA)\n"
  if (nunref > 0)
    printf "  note: %d dependencies: record(s) are unreferenced - harmless, but prunable.\n", nunref
}
AWK

"$AWK" -v lockfile="$LOCK" "$PROG" "$LOCK" "${WORKFLOWS[@]}"
