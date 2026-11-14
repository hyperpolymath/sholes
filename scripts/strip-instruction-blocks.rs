// SPDX-License-Identifier: MPL-2.0
//
// Remove only HTML comments containing TEMPLATE INSTRUCTIONS after minting.
//
// Ported from strip-instruction-blocks.rb: Ruby is not an estate-authorised
// language, and this runs on every mint. Single file, std only, no
// dependencies — compiled on demand by `just repo-init` (see the rust_tool
// helper in build/just/repo-init.just).
//
// The match is deliberately tempered: an HTML comment is only removed when the
// marker appears BEFORE its own `-->`, so a block cannot swallow the
// terminator of a preceding comment. That is what keeps an SPDX comment that
// sits immediately above an instructions block intact.
//
// Usage: strip-instruction-blocks.rs FILE...   or   ... - < newline-separated paths

#![forbid(unsafe_code)]

use std::env;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process;

const MARKER: &str = "TEMPLATE INSTRUCTIONS";
const OPEN: &str = "<!--";
const CLOSE: &str = "-->";

/// Remove every HTML comment whose body contains MARKER, then collapse runs of
/// three or more newlines to two.
///
/// Indexing is by byte, which is safe because every boundary we slice at is an
/// ASCII delimiter (`<!--`, `-->`); a multi-byte character can never be split.
fn strip_blocks(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut i = 0usize;

    while i < bytes.len() {
        let start = match find_from(text, OPEN, i) {
            Some(p) => p,
            None => {
                out.push_str(&text[i..]);
                break;
            }
        };
        // Everything before this comment is copied verbatim.
        out.push_str(&text[i..start]);

        let end = match find_from(text, CLOSE, start + OPEN.len()) {
            Some(p) => p,
            // Unterminated comment: not ours to touch.
            None => {
                out.push_str(&text[start..]);
                break;
            }
        };

        let body = &text[start + OPEN.len()..end];
        if body.contains(MARKER) {
            // Drop the comment, plus trailing horizontal space, plus one
            // newline, so a removed block does not leave a blank line behind.
            let mut j = end + CLOSE.len();
            while j < bytes.len() && (bytes[j] == b' ' || bytes[j] == b'\t') {
                j += 1;
            }
            if j < bytes.len() && bytes[j] == b'\n' {
                j += 1;
            }
            i = j;
        } else {
            // A comment without the marker is preserved exactly.
            out.push_str(&text[start..end + CLOSE.len()]);
            i = end + CLOSE.len();
        }
    }

    collapse_blank_runs(&out)
}

fn find_from(haystack: &str, needle: &str, from: usize) -> Option<usize> {
    haystack[from..].find(needle).map(|p| from + p)
}

/// Ruby's `gsub(/\n{3,}/, "\n\n")`: three or more newlines become two.
fn collapse_blank_runs(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut run = 0usize;
    for ch in s.chars() {
        if ch == '\n' {
            run += 1;
            if run <= 2 {
                out.push(ch);
            }
        } else {
            run = 0;
            out.push(ch);
        }
    }
    out
}

fn process(path: &Path, changed: &mut usize) -> Result<(), String> {
    let bytes = fs::read(path).map_err(|e| format!("{}: {}", path.display(), e))?;
    // Non-UTF-8 files are skipped, never rewritten blind.
    let text = match String::from_utf8(bytes) {
        Ok(t) => t,
        Err(_) => return Ok(()),
    };
    if !text.contains(MARKER) {
        return Ok(());
    }
    let updated = strip_blocks(&text);
    if updated == text {
        return Ok(());
    }
    fs::write(path, updated).map_err(|e| format!("{}: {}", path.display(), e))?;
    println!("  instruction block: stripped from {}", path.display());
    *changed += 1;
    Ok(())
}

/// The files to clean: every argument, where `-` reads one path per line
/// from stdin. A directory is refused rather than walked. This tool used to
/// walk its ROOT argument, and so entered git-ignored caches: minting
/// metadatastician/lintel it edited the pinned sibling checkouts under
/// _build/dependencies/, breaking their pins, and it stripped the fixture
/// blocks of the template's own tests, which the mint's leftover check
/// exempts. Which files belong to a repository is the caller's question
/// (repo-init asks git: its mint_files), not a guess made here.
fn targets(args: &[String]) -> Result<Vec<PathBuf>, String> {
    let mut out = Vec::new();
    for a in args {
        if a == "-" {
            let mut buf = String::new();
            io::stdin()
                .read_to_string(&mut buf)
                .map_err(|e| format!("stdin: {}", e))?;
            out.extend(buf.lines().filter(|l| !l.is_empty()).map(PathBuf::from));
        } else {
            out.push(PathBuf::from(a));
        }
    }
    for p in &out {
        if p.is_dir() {
            return Err(format!(
                "{} is a directory; pass files (e.g. `git ls-files | {} -`)",
                p.display(),
                "strip-instruction-blocks"
            ));
        }
    }
    Ok(out)
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("usage: strip-instruction-blocks FILE... | strip-instruction-blocks - < list");
        process::exit(2);
    }
    let files = match targets(&args) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("strip-instruction-blocks: {}", e);
            process::exit(2);
        }
    };
    let mut changed = 0usize;
    for f in &files {
        if let Err(e) = process(f, &mut changed) {
            // Fail loudly: a file the caller named that cannot be read or
            // written is not "clean", it is unchecked.
            eprintln!("strip-instruction-blocks: {}", e);
            process::exit(1);
        }
    }
    if changed > 0 {
        println!("  instruction blocks: {} file(s) cleaned", changed);
    } else {
        println!("  instruction blocks: none found");
    }
}
