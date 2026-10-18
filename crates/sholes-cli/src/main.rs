// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Standalone clean/smudge/audit CLI and Git filter-process server.

mod packet_line;

use packet_line::{read_packet, write_data, write_flush, Packet};
use sholes_core::{
    audit as inspect, canonicalize_to_vec, project_to_vec, Classification, TargetEnvironment,
};
use std::env;
use std::fs;
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() -> ExitCode {
    match run(env::args().skip(1)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("sholes: {error}");
            ExitCode::from(1)
        }
    }
}

fn run<I>(mut args: I) -> Result<(), String>
where
    I: Iterator<Item = String>,
{
    let command = args.next().unwrap_or_else(|| "help".to_owned());
    match command.as_str() {
        "clean" => one_shot_clean(),
        "smudge" => one_shot_smudge(parse_target(args)?),
        "audit" => audit_command(args.collect()),
        "init" => init_command(args.collect()),
        "filter-process" | "git-filter" => filter_process(parse_target(args)?),
        "--version" | "-V" | "version" => {
            println!("sholes {VERSION}");
            Ok(())
        }
        "--help" | "-h" | "help" => {
            print_help();
            Ok(())
        }
        other => Err(format!("unknown command '{other}' (try `sholes help`)")),
    }
}

fn print_help() {
    println!(
        "sholes {VERSION}\n\n\
         Usage:\n  sholes clean < input > output\n  sholes smudge [--target posix|windows] < input > output\n  sholes audit [--json] [PATH ...]\n  sholes init [--global]\n  sholes filter-process [--target posix|windows]\n\n\
         `clean` stores canonical LF text. `smudge` projects text for the\n\
         selected working-tree environment. Binary and invalid UTF-8 input is\n\
         always copied byte-for-byte. `filter-process` is Git's long-running\n\
         packet-line protocol v2 entry point."
    );
}

fn init_command(arguments: Vec<String>) -> Result<(), String> {
    let global = arguments.iter().any(|argument| argument == "--global");
    if arguments.iter().any(|argument| argument != "--global") {
        return Err("usage: sholes init [--global]".to_owned());
    }
    if !global {
        println!("git config filter.sholes.process 'sholes filter-process'");
        println!("git config filter.sholes.required true");
        println!("git config filter.sholes.clean 'sholes clean'");
        println!("git config filter.sholes.smudge 'sholes smudge'");
        return Ok(());
    }

    let settings = [
        ("filter.sholes.process", "sholes filter-process"),
        ("filter.sholes.required", "true"),
        ("filter.sholes.clean", "sholes clean"),
        ("filter.sholes.smudge", "sholes smudge"),
    ];
    for (key, value) in settings {
        let status = std::process::Command::new("git")
            .args(["config", "--global", key, value])
            .status()
            .map_err(|error| format!("starting git config: {error}"))?;
        if !status.success() {
            return Err(format!("git config failed while setting {key}"));
        }
    }
    println!("configured the global Git sholes filter");
    Ok(())
}

fn parse_target<I>(args: I) -> Result<TargetEnvironment, String>
where
    I: IntoIterator<Item = String>,
{
    let configured = env::var("SHOLES_TARGET").ok();
    let mut target = sholes_core::target_from_env(configured.as_deref());
    let mut values = args.into_iter();
    while let Some(value) = values.next() {
        let raw = if let Some(value) = value.strip_prefix("--target=") {
            value.to_owned()
        } else if value == "--target" {
            values
                .next()
                .ok_or_else(|| "--target requires posix or windows".to_owned())?
        } else if value == "--windows" {
            "windows".to_owned()
        } else if value == "--posix" {
            "posix".to_owned()
        } else {
            return Err(format!("unknown option '{value}'"));
        };
        target = match raw.to_ascii_lowercase().as_str() {
            "posix" | "lf" => TargetEnvironment::Posix,
            "windows" | "crlf" => TargetEnvironment::Windows,
            _ => return Err(format!("invalid target '{raw}' (use posix or windows)")),
        };
    }
    Ok(target)
}

fn read_all_stdin() -> Result<Vec<u8>, String> {
    let stdin = io::stdin();
    let mut lock = stdin.lock();
    let mut input = Vec::new();
    lock.read_to_end(&mut input)
        .map_err(|error| format!("reading stdin: {error}"))?;
    Ok(input)
}

fn write_stdout(bytes: &[u8]) -> Result<(), String> {
    let stdout = io::stdout();
    let mut lock = stdout.lock();
    lock.write_all(bytes)
        .and_then(|_| lock.flush())
        .map_err(|error| format!("writing stdout: {error}"))
}

fn one_shot_clean() -> Result<(), String> {
    let input = read_all_stdin()?;
    let output = canonicalize_to_vec(&input).map_err(|error| format!("normalizing stdin: {error:?}"))?;
    write_stdout(&output)
}

fn one_shot_smudge(target: TargetEnvironment) -> Result<(), String> {
    let input = read_all_stdin()?;
    let output = project_to_vec(&input, target).map_err(|error| format!("projecting stdin: {error:?}"))?;
    write_stdout(&output)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct AuditOptions {
    json: bool,
}

fn audit_command(arguments: Vec<String>) -> Result<(), String> {
    let mut options = AuditOptions { json: false };
    let mut paths = Vec::new();
    for argument in arguments {
        if argument == "--json" {
            options.json = true;
        } else if argument == "--help" || argument == "-h" {
            println!("Usage: sholes audit [--json] [PATH ...]\nDefaults to the current directory.");
            return Ok(());
        } else {
            paths.push(PathBuf::from(argument));
        }
    }
    if paths.is_empty() {
        paths.push(PathBuf::from("."));
    }

    let mut files = Vec::new();
    for path in paths {
        collect_files(&path, &mut files).map_err(|error| format!("{}: {error}", path.display()))?;
    }
    files.sort();

    let mut failed = false;
    for path in files {
        let bytes = fs::read(&path).map_err(|error| format!("{}: {error}", path.display()))?;
        let report = inspect(&bytes);
        if !report.is_canonical() {
            failed = true;
        }
        if options.json {
            println!(
                "{{\"path\":\"{}\",\"classification\":\"{}\",\"bytes\":{},\"crlf\":{},\"lone_cr\":{},\"lf\":{},\"canonical_lf\":{}}}",
                json_escape(&path.display().to_string()),
                classification_name(report.classification),
                report.bytes,
                report.crlf,
                report.lone_cr,
                report.lf,
                report.canonical_lf
            );
        } else if report.is_binary() {
            println!("BINARY  {}  ({} bytes, preserved)", path.display(), report.bytes);
        } else if report.is_canonical() {
            println!("OK      {}  ({} bytes, LF)", path.display(), report.bytes);
        } else {
            println!(
                "FIX     {}  ({} bytes, {} CRLF, {} lone CR)",
                path.display(),
                report.bytes,
                report.crlf,
                report.lone_cr
            );
        }
    }
    if failed {
        Err("non-canonical text found".to_owned())
    } else {
        Ok(())
    }
}

fn collect_files(path: &Path, files: &mut Vec<PathBuf>) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.is_file() {
        files.push(path.to_owned());
        return Ok(());
    }
    if !metadata.is_dir() {
        return Ok(());
    }
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let child = entry.path();
        let name = entry.file_name();
        if name == ".git" || name == "target" || name == ".arena" {
            continue;
        }
        collect_files(&child, files)?;
    }
    Ok(())
}

fn classification_name(classification: Classification) -> &'static str {
    match classification {
        Classification::Binary => "binary",
        Classification::Text(_) => "text",
    }
}

fn json_escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            character if character.is_control() => {
                escaped.push_str(&format!("\\u{:04x}", character as u32));
            }
            character => escaped.push(character),
        }
    }
    escaped
}

fn packet_text(packet: Packet) -> Result<Option<String>, String> {
    match packet {
        Packet::Data(bytes) => String::from_utf8(bytes)
            .map(Some)
            .map_err(|_| "Git protocol metadata was not UTF-8".to_owned()),
        Packet::Flush => Ok(None),
        Packet::Delimiter | Packet::ResponseEnd => Err("unexpected Git protocol delimiter".to_owned()),
    }
}

fn filter_process(target: TargetEnvironment) -> Result<(), String> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut writer = BufWriter::new(stdout.lock());

    let mut saw_client = false;
    let mut saw_version = false;
    loop {
        let packet = read_packet(&mut reader).map_err(|error| format!("reading Git handshake: {error}"))?;
        match packet {
            Some(Packet::Data(bytes)) if bytes == b"git-filter-client\n" => saw_client = true,
            Some(Packet::Data(bytes)) if bytes == b"version=2\n" => saw_version = true,
            Some(Packet::Flush) => break,
            Some(Packet::Data(_)) => {}
            Some(Packet::Delimiter | Packet::ResponseEnd) => {
                return Err("unexpected control packet in Git handshake".to_owned())
            }
            None => return Err("Git closed before completing the filter handshake".to_owned()),
        }
    }
    if !saw_client || !saw_version {
        return Err("unsupported Git filter handshake (need client/version=2)".to_owned());
    }
    write_data(&mut writer, b"git-filter-server\n").map_err(|error| format!("writing handshake: {error}"))?;
    write_data(&mut writer, b"version=2\n").map_err(|error| format!("writing handshake: {error}"))?;
    write_data(&mut writer, b"capability=clean\n").map_err(|error| format!("writing handshake: {error}"))?;
    write_data(&mut writer, b"capability=smudge\n").map_err(|error| format!("writing handshake: {error}"))?;
    write_flush(&mut writer).map_err(|error| format!("writing handshake: {error}"))?;
    writer.flush().map_err(|error| format!("flushing handshake: {error}"))?;

    loop {
        let mut command = None;
        let mut pathname = None;
        let first_packet = read_packet(&mut reader)
            .map_err(|error| format!("reading Git request: {error}"))?;
        let first_packet = match first_packet {
            Some(packet) => packet,
            None => break,
        };
        match packet_text(first_packet)? {
            Some(line) if line == "command=clean\n" => command = Some("clean"),
            Some(line) if line == "command=smudge\n" => command = Some("smudge"),
            Some(line) if line.starts_with("pathname=") => pathname = Some(line),
            Some(_) => {}
            None => return Err("empty Git request".to_owned()),
        }
        loop {
            let packet = read_packet(&mut reader).map_err(|error| format!("reading Git request: {error}"))?;
            match packet_text(packet.ok_or_else(|| "Git closed during a request".to_owned())?)? {
                Some(line) if line == "command=clean\n" => command = Some("clean"),
                Some(line) if line == "command=smudge\n" => command = Some("smudge"),
                Some(line) if line.starts_with("pathname=") => pathname = Some(line),
                Some(_) => {}
                None => break,
            }
        }
        let command = match command {
            Some(command) => command,
            None => return Err("Git request did not specify clean or smudge".to_owned()),
        };
        let _pathname = pathname;

        let mut content = Vec::new();
        loop {
            let packet = read_packet(&mut reader)
                .map_err(|error| format!("reading Git content for {command}: {error}"))?;
            match packet {
                Some(Packet::Data(bytes)) => content.extend_from_slice(&bytes),
                Some(Packet::Flush) => break,
                Some(Packet::Delimiter | Packet::ResponseEnd) => {
                    return Err("unexpected Git control packet in content".to_owned())
                }
                None => return Err("Git closed during content".to_owned()),
            }
        }

        let result = if command == "clean" {
            canonicalize_to_vec(&content)
        } else {
            project_to_vec(&content, target)
        };
        match result {
            Ok(output) => {
                write_data(&mut writer, b"status=success\n")
                    .map_err(|error| format!("writing Git status: {error}"))?;
                write_flush(&mut writer).map_err(|error| format!("writing Git status: {error}"))?;
                write_data(&mut writer, &output)
                    .map_err(|error| format!("writing Git content: {error}"))?;
                write_flush(&mut writer).map_err(|error| format!("writing Git content: {error}"))?;
            }
            Err(error) => {
                write_data(&mut writer, b"status=error\n")
                    .map_err(|error| format!("writing Git error status: {error}"))?;
                write_data(&mut writer, format!("errmsg={error:?}\n").as_bytes())
                    .map_err(|error| format!("writing Git error status: {error}"))?;
                write_flush(&mut writer).map_err(|error| format!("writing Git error status: {error}"))?;
            }
        }
        writer.flush().map_err(|error| format!("flushing Git response: {error}"))?;
    }
    Ok(())
}
