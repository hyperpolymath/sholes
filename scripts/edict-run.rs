// SPDX-License-Identifier: MPL-2.0
//
// edict-run: the stage-2 trial runner of standards A7 (section 8.1, M2).
//
// An edict is a contractile rule with two halves: `applies-when`, a test on
// the repo's identity (its chora deed), and `requires`, a test on reality (a
// descriptile deed). A rule is NOT-APPLICABLE when applies-when fails, HOLDS
// when both pass, VIOLATED when it applies and requires fails, and UNRESOLVED
// when it applies and the reality it names is absent. Identity selects the
// edicts; a repo does not list them.
//
// This is a TRIAL. It reads one contractile deed and one descriptile deed,
// knows only the forms below, and gates nothing in CI except its own test.
//
//   (contractile-deed :schema-version "1.0.0" :verb must
//     (rule :id "<id>" [!]
//       :text "<prose>"
//       (applies-when (chora (<clause> :<key> <value>)) ...)   ; all must match
//       (requires     (state (<clause> :<key> <value>)) ...))) ; all must match
//
// A test value is an atom, a string, or `(:one-of v1 v2 ...)`. `!` marks a
// blocking rule; every `must` rule blocks (A7 8.4).
//
// Usage: edict-run.rs CHORA.deed Mustfile.deed STATE.deed
// Exit:  0 nothing blocking, 1 a blocking rule is violated or unresolved,
//        2 a read or parse error.
//
// Single file, std only, compiled on demand by scripts/rust-tool.sh.

#![forbid(unsafe_code)]

use std::env;
use std::fs;
use std::process;

#[derive(Debug, Clone, PartialEq)]
enum Sx {
    Atom(String),
    Str(String),
    List(Vec<Sx>),
}

/// Read a string literal starting at the opening quote `cs[i]`. Returns the
/// token (a leading `"` marks it as a string) and the index after the close.
fn read_string(cs: &[char], mut i: usize) -> Result<(String, usize), String> {
    let mut s = String::from("\"");
    i += 1;
    while i < cs.len() {
        match cs[i] {
            '\\' if i + 1 < cs.len() => {
                s.push(cs[i + 1]);
                i += 2;
            }
            '"' => return Ok((s, i + 1)),
            d => {
                s.push(d);
                i += 1;
            }
        }
    }
    Err("unterminated string".into())
}

fn ends_atom(c: char) -> bool {
    c.is_whitespace() || c == '(' || c == ')' || c == ';'
}

/// Read an atom starting at `cs[i]`. A tagged literal such as #uuid"…" or
/// #u5"…" is one token: the quoted body is kept and ends the atom.
fn read_atom(cs: &[char], mut i: usize) -> (String, usize) {
    let mut s = String::new();
    while i < cs.len() && !ends_atom(cs[i]) {
        if cs[i] == '"' {
            let close = cs[i + 1..].iter().position(|&c| c == '"');
            let end = close.map_or(cs.len(), |p| i + 1 + p);
            s.extend(&cs[i..end]);
            s.push('"');
            return (s, (end + 1).min(cs.len()));
        }
        s.push(cs[i]);
        i += 1;
    }
    (s, i)
}

fn tokenize(src: &str) -> Result<Vec<String>, String> {
    let cs: Vec<char> = src.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < cs.len() {
        let c = cs[i];
        if c == ';' {
            i = cs[i..]
                .iter()
                .position(|&c| c == '\n')
                .map_or(cs.len(), |p| i + p);
        } else if c.is_whitespace() {
            i += 1;
        } else if c == '(' || c == ')' {
            out.push(c.to_string());
            i += 1;
        } else {
            let (tok, next) = if c == '"' {
                read_string(&cs, i)?
            } else {
                read_atom(&cs, i)
            };
            out.push(tok);
            i = next;
        }
    }
    Ok(out)
}

fn parse(tokens: &[String], pos: &mut usize) -> Result<Sx, String> {
    let t = tokens.get(*pos).ok_or("unexpected end of input")?;
    *pos += 1;
    if t == "(" {
        let mut items = Vec::new();
        loop {
            match tokens.get(*pos) {
                None => return Err("unclosed (".into()),
                Some(x) if x == ")" => {
                    *pos += 1;
                    return Ok(Sx::List(items));
                }
                _ => items.push(parse(tokens, pos)?),
            }
        }
    } else if t == ")" {
        Err("unexpected )".into())
    } else if let Some(s) = t.strip_prefix('"') {
        Ok(Sx::Str(s.to_string()))
    } else {
        Ok(Sx::Atom(t.clone()))
    }
}

fn read_deed(path: &str) -> Result<Sx, String> {
    let src = fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    let toks = tokenize(&src).map_err(|e| format!("{path}: {e}"))?;
    let mut pos = 0;
    let doc = parse(&toks, &mut pos).map_err(|e| format!("{path}: {e}"))?;
    if pos != toks.len() {
        return Err(format!("{path}: text after the top-level form"));
    }
    Ok(doc)
}

fn head(x: &Sx) -> Option<&str> {
    match x {
        Sx::List(v) => match v.first() {
            Some(Sx::Atom(a)) => Some(a.as_str()),
            _ => None,
        },
        _ => None,
    }
}

fn items(x: &Sx) -> &[Sx] {
    match x {
        Sx::List(v) => v,
        _ => &[],
    }
}

/// The value after keyword `key` in a list, if any.
fn field<'a>(x: &'a Sx, key: &str) -> Option<&'a Sx> {
    let v = items(x);
    v.iter()
        .position(|e| matches!(e, Sx::Atom(a) if a == key))
        .and_then(|i| v.get(i + 1))
}

/// Top-level child clauses of a deed with the given head.
fn clause<'a>(doc: &'a Sx, name: &str) -> Option<&'a Sx> {
    items(doc).iter().find(|c| head(c) == Some(name))
}

fn text(x: &Sx) -> String {
    match x {
        Sx::Atom(a) => a.clone(),
        Sx::Str(s) => s.clone(),
        Sx::List(v) => format!("({})", v.iter().map(text).collect::<Vec<_>>().join(" ")),
    }
}

#[derive(Debug, PartialEq)]
enum Test {
    Pass,
    Fail(String),
    Absent(String),
}

/// One test such as (lineage :type standalone) against a deed.
fn run_test(deed: &Sx, t: &Sx) -> Result<Test, String> {
    let name = head(t).ok_or("a test must be (<clause> :<key> <value> ...)")?;
    let tv = items(t);
    let Some(target) = clause(deed, name) else {
        return Ok(Test::Absent(format!("({name}) is absent")));
    };
    let mut i = 1;
    while i < tv.len() {
        let key = match &tv[i] {
            Sx::Atom(k) if k.starts_with(':') => k.as_str(),
            other => {
                return Err(format!(
                    "expected a :key in ({name} …), found {}",
                    text(other)
                ))
            }
        };
        let want = tv
            .get(i + 1)
            .ok_or(format!("({name} {key}) has no value"))?;
        let Some(have) = field(target, key) else {
            return Ok(Test::Absent(format!("({name} {key}) is absent")));
        };
        let ok = match want {
            Sx::List(alts) if matches!(alts.first(), Some(Sx::Atom(a)) if a == ":one-of") => {
                alts[1..].iter().any(|a| text(a) == text(have))
            }
            _ => text(want) == text(have),
        };
        if !ok {
            return Ok(Test::Fail(format!(
                "({name} {key}) is {}, wanted {}",
                text(have),
                text(want)
            )));
        }
        i += 2;
    }
    Ok(Test::Pass)
}

/// Every test under a half such as (applies-when (chora …) …) against `deed`.
fn run_half(half: &Sx, side: &str, deed: &Sx) -> Result<Test, String> {
    for group in &items(half)[1..] {
        if head(group) != Some(side) {
            return Err(format!(
                "expected ({side} …) in ({}), found {}",
                head(half).unwrap_or("?"),
                text(group)
            ));
        }
        for t in &items(group)[1..] {
            match run_test(deed, t)? {
                Test::Pass => {}
                other => return Ok(other),
            }
        }
    }
    Ok(Test::Pass)
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.len() != 3 {
        eprintln!("usage: edict-run.rs CHORA.deed Mustfile.deed STATE.deed");
        process::exit(2);
    }
    let load = |p: &str| {
        read_deed(p).unwrap_or_else(|e| {
            eprintln!("edict-run: {e}");
            process::exit(2)
        })
    };
    let (chora, edicts, state) = (load(&args[0]), load(&args[1]), load(&args[2]));
    if head(&edicts) != Some("contractile-deed") {
        eprintln!("edict-run: {} is not a contractile-deed", args[1]);
        process::exit(2);
    }
    if head(&state) != Some("descriptile-deed") {
        eprintln!("edict-run: {} is not a descriptile-deed", args[2]);
        process::exit(2);
    }
    let verb = field(&edicts, ":verb").map(text).unwrap_or_default();
    let mut blocking = 0;
    for rule in items(&edicts).iter().filter(|r| head(r) == Some("rule")) {
        let id = field(rule, ":id").map(text).unwrap_or_else(|| "?".into());
        let bang = items(rule)
            .iter()
            .any(|e| matches!(e, Sx::Atom(a) if a == "!"));
        let blocks = verb == "must" || bang;
        let half = |n: &str| items(rule).iter().find(|e| head(e) == Some(n));
        let (Some(aw), Some(rq)) = (half("applies-when"), half("requires")) else {
            eprintln!("edict-run: rule {id} lacks applies-when or requires");
            process::exit(2);
        };
        let outcome = (|| -> Result<(&str, String), String> {
            match run_half(aw, "chora", &chora)? {
                Test::Pass => {}
                Test::Fail(w) | Test::Absent(w) => return Ok(("not-applicable", w)),
            }
            Ok(match run_half(rq, "state", &state)? {
                Test::Pass => ("holds", String::new()),
                Test::Fail(w) => ("violated", w),
                Test::Absent(w) => ("unresolved", w),
            })
        })()
        .unwrap_or_else(|e| {
            eprintln!("edict-run: rule {id}: {e}");
            process::exit(2)
        });
        let (verdict, why) = outcome;
        let tag = if blocks && (verdict == "violated" || verdict == "unresolved") {
            blocking += 1;
            " [blocking]"
        } else {
            ""
        };
        if why.is_empty() {
            println!("{verb}/{id}: {verdict}{tag}");
        } else {
            println!("{verb}/{id}: {verdict}{tag}: {why}");
        }
    }
    process::exit(if blocking > 0 { 1 } else { 0 });
}
