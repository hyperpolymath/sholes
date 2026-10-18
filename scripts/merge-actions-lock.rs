// SPDX-License-Identifier: MPL-2.0
//
// Merge an archetype's actions.lock fragment into the spine's lock at mint.
//
// An archetype that ships workflows must ship their lock records too. The
// julia-library archetype used to carry a whole actions.lock inside its
// overlay, and `cp -a` of the overlay REPLACED the spine's lock: every spine
// workflow lost its records, so each Julia mint started with Lock Sync red and
// its workflows refused at startup (ZeroInflatedCounts.jl and
// ResidualEvidenceTypes.jl, 2026-10-02). The records now live beside the
// overlay as a fragment and are merged in instead.
//
// Input is the format `gh actions-lock` writes (version 'v0.0.2'): a comment
// header, `version:`, then the `workflows:` and `dependencies:` maps, whose
// entries are single-quoted keys at four spaces followed by an indented body.
// The rules:
//
//   * both files must carry the same `version:` line;
//   * any other top-level key, or any line this shape does not explain, is
//     refused rather than dropped;
//   * entries are unioned per section. A key present in both files must have a
//     byte-identical entry, or the merge is refused: two resolutions of one ref
//     are a conflict for `gh actions-lock` to settle, not for this tool;
//   * the output keeps the base's header and sorts each section by key in byte
//     order, as `gh actions-lock` does, so a second merge changes nothing.
//
// The base file is rewritten in place.
//
// Usage: merge-actions-lock.rs <base-lock> <fragment-lock>

use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::process;

/// The two maps an actions.lock holds, in the order the file writes them.
const SECTIONS: [&str; 2] = ["workflows", "dependencies"];

/// One parsed lock file: its comment header, its `version:` line, and each
/// section's entries keyed by the unquoted key, holding the entry's full text.
struct Lock {
    header: Vec<String>,
    version: Option<String>,
    sections: [BTreeMap<String, String>; 2],
}

/// Parse a lock file's text, naming `path` and the line number in any error.
fn parse(path: &str, text: &str) -> Result<Lock, String> {
    let mut lock = Lock {
        header: Vec::new(),
        version: None,
        sections: [BTreeMap::new(), BTreeMap::new()],
    };
    let mut section: Option<usize> = None;
    let mut current: Option<String> = None;
    let mut seen_body = false;

    for (i, line) in text.lines().enumerate() {
        let at = |what: &str| format!("{}:{}: {}: {}", path, i + 1, what, line);

        if line.starts_with("        ") {
            let (s, key) = match (section, &current) {
                (Some(s), Some(k)) => (s, k.clone()),
                _ => return Err(at("indented line outside an entry")),
            };
            let entry = lock.sections[s]
                .get_mut(&key)
                .ok_or_else(|| at("entry body whose key was not recorded"))?;
            entry.push_str(line);
            entry.push('\n');
            continue;
        }

        if let Some(rest) = line.strip_prefix("    '") {
            let s = section.ok_or_else(|| at("entry outside a section"))?;
            let end = rest.find("':").ok_or_else(|| at("unterminated key"))?;
            let key = rest[..end].to_string();
            let tail = &rest[end + 2..];
            if !tail.is_empty() && tail != " []" {
                return Err(at("unexpected text after key"));
            }
            if lock.sections[s].contains_key(&key) {
                return Err(at("duplicate key"));
            }
            lock.sections[s].insert(key.clone(), format!("{}\n", line));
            current = Some(key);
            continue;
        }

        if line.starts_with('#') || line.trim().is_empty() {
            // Comments and blank lines belong to the header only; anywhere
            // else they would be silently lost on rewrite.
            if seen_body {
                return Err(at("comment or blank line after the header"));
            }
            lock.header.push(line.to_string());
            continue;
        }

        if line.starts_with(' ') {
            return Err(at("unrecognised indentation"));
        }

        seen_body = true;
        current = None;
        if line.starts_with("version:") {
            if lock.version.is_some() {
                return Err(at("second version line"));
            }
            lock.version = Some(line.to_string());
            section = None;
            continue;
        }
        let name = line.trim_end_matches(" {}").trim_end_matches(':');
        match SECTIONS.iter().position(|s| *s == name) {
            Some(s) if line == format!("{}:", name) || line == format!("{}: {{}}", name) => {
                section = Some(s);
            }
            _ => return Err(at("unknown top-level key")),
        }
    }

    if lock.version.is_none() {
        return Err(format!("{}: no version line", path));
    }
    Ok(lock)
}

/// Fold `frag`'s entries into `base`, refusing a version mismatch or a key
/// whose entry differs between the two. Returns how many entries were new.
fn merge(base: &mut Lock, frag: &Lock, frag_path: &str) -> Result<usize, String> {
    if base.version != frag.version {
        return Err(format!(
            "{}: version {:?} does not match the base's {:?}",
            frag_path,
            frag.version.as_deref().unwrap_or(""),
            base.version.as_deref().unwrap_or("")
        ));
    }
    let mut added = 0;
    for (s, name) in SECTIONS.iter().enumerate() {
        for (key, entry) in &frag.sections[s] {
            match base.sections[s].get(key) {
                Some(existing) if existing == entry => {}
                Some(_) => {
                    return Err(format!(
                        "{}: {} entry '{}' differs from the base's; \
                         regenerate with `gh actions-lock` instead of merging",
                        frag_path, name, key
                    ))
                }
                None => {
                    base.sections[s].insert(key.clone(), entry.clone());
                    added += 1;
                }
            }
        }
    }
    Ok(added)
}

/// Render a lock in the layout `gh actions-lock` writes.
fn render(lock: &Lock) -> String {
    let mut out = String::new();
    for line in &lock.header {
        out.push_str(line);
        out.push('\n');
    }
    out.push_str(lock.version.as_deref().unwrap_or(""));
    out.push('\n');
    for (s, name) in SECTIONS.iter().enumerate() {
        if lock.sections[s].is_empty() {
            out.push_str(&format!("{}: {{}}\n", name));
            continue;
        }
        out.push_str(&format!("{}:\n", name));
        for entry in lock.sections[s].values() {
            out.push_str(entry);
        }
    }
    out
}

/// Read and parse one lock file, exiting with status 1 on any failure.
fn load(path: &str) -> Lock {
    let text = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("merge-actions-lock: cannot read {}: {}", path, e);
        process::exit(1);
    });
    parse(path, &text).unwrap_or_else(|e| {
        eprintln!("merge-actions-lock: {}", e);
        process::exit(1);
    })
}

/// Merge the fragment named on the command line into the base lock, in place.
fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.len() != 2 {
        eprintln!("Usage: merge-actions-lock.rs <base-lock> <fragment-lock>");
        process::exit(2);
    }
    let (base_path, frag_path) = (&args[0], &args[1]);
    let mut base = load(base_path);
    let frag = load(frag_path);

    let added = merge(&mut base, &frag, frag_path).unwrap_or_else(|e| {
        eprintln!("merge-actions-lock: {}", e);
        process::exit(1);
    });

    // Write beside the target, then rename, so an interrupted mint never
    // leaves a truncated lock behind.
    let tmp = format!("{}.merge-tmp", base_path);
    if let Err(e) = fs::write(&tmp, render(&base)).and_then(|_| fs::rename(&tmp, base_path)) {
        eprintln!("merge-actions-lock: cannot write {}: {}", base_path, e);
        let _ = fs::remove_file(&tmp);
        process::exit(1);
    }
    println!(
        "  actions.lock: merged {} new entr{} from {}",
        added,
        if added == 1 { "y" } else { "ies" },
        frag_path
    );
}
