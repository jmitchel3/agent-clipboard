//! agent-clip: shared clipboard of shell commands that AI agents hand to the user.
//!
//! Agents add commands; the user copies them from the menu bar app (or `agent-clip copy`).
//! Nothing is ever deleted: archiving hides an entry from the menu but keeps it in the log,
//! so `agent-clip stats` can surface commands worth turning into aliases or tools.
//!
//! Store: $AGENT_CLIPBOARD_DIR/clips.jsonl (default ~/.agent-clipboard), one JSON object per line.
//! `add` appends a line; every other write rewrites the file atomically under the shared flock.
//! Lines that do not parse are written back verbatim, never dropped.

use serde::de::IgnoredAny;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, IsTerminal, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{exit, Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const USAGE: &str = "usage: agent-clip {add,list,ls,show,copy,pull,archive,projects,stats} ...

Shared clipboard of shell commands that AI agents hand to the user.

  add [-n NOTE] [-p PROJECT] [--cwd DIR] [--agent NAME] [-- CMD...]
                         add a command (stdin heredoc, or argv after --)
  list, ls [-p PROJECT] [-a] [-l N] [--json]
                         list clips (-a includes archived)
  show ID                print a clip's full command
  copy [ID] [-p PROJECT] copy a clip to the macOS clipboard (default: latest)
  pull [ID] [-p PROJECT] print newest uncopied clip for this project (used by `ac`)
  archive [IDS...] [-p PROJECT] [--copied]
                         hide clips from the menu (kept in the log)
  projects [-a]          list projects with clip counts
  stats [-p PROJECT] [-d DAYS] [-t TOP]
                         frequent commands: alias / tooling candidates";

fn die(msg: &str) -> ! {
    eprintln!("agent-clip: {msg}");
    exit(1)
}

fn usage_error(msg: &str) -> ! {
    eprintln!("{}\nagent-clip: error: {msg}", USAGE.lines().next().unwrap());
    exit(2)
}

fn emit(s: &str) {
    // Ignore EPIPE (`agent-clip list | head`).
    let _ = io::stdout().lock().write_all(s.as_bytes());
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

// MARK: - Store

struct Paths {
    dir: PathBuf,
    store: PathBuf,
}

fn paths() -> Paths {
    let dir = std::env::var_os("AGENT_CLIPBOARD_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".agent-clipboard"));
    Paths {
        store: dir.join("clips.jsonl"),
        dir,
    }
}

/// Exclusive flock on `.lock`, shared with the menu bar app; released when dropped.
struct Lock(File);

impl Drop for Lock {
    fn drop(&mut self) {
        unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}

fn lock(p: &Paths) -> Lock {
    let _ = fs::create_dir_all(&p.dir);
    let f = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o644)
        .open(p.dir.join(".lock"))
        .unwrap_or_else(|e| die(&format!("cannot open lock: {e}")));
    if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX) } != 0 {
        die("cannot acquire lock");
    }
    Lock(f)
}

/// Only the fields the CLI reads; everything else stays in the raw line.
#[derive(Deserialize, Default)]
#[serde(default)]
struct Clip {
    id: Option<i64>,
    ts: Option<f64>,
    project: Option<String>,
    note: Option<String>,
    cmd: Option<String>,
    copies: Option<Vec<IgnoredAny>>,
    archived: Option<bool>,
}

impl Clip {
    fn id(&self) -> i64 {
        self.id.unwrap_or(-1)
    }
    fn ts(&self) -> f64 {
        self.ts.unwrap_or(0.0)
    }
    fn project(&self) -> &str {
        self.project.as_deref().unwrap_or("")
    }
    fn note(&self) -> &str {
        self.note.as_deref().unwrap_or("")
    }
    fn cmd(&self) -> &str {
        self.cmd.as_deref().unwrap_or("")
    }
    fn copies(&self) -> usize {
        self.copies.as_ref().map_or(0, Vec::len)
    }
    fn archived(&self) -> bool {
        self.archived.unwrap_or(false)
    }
}

struct Entry {
    raw: String,
    clip: Option<Clip>,
}

struct Store {
    entries: Vec<Entry>,
    ends_with_newline: bool,
}

impl Store {
    fn load(p: &Paths) -> Store {
        let bytes = fs::read(&p.store).unwrap_or_default();
        let entries = bytes
            .split(|&b| b == b'\n')
            .filter_map(|line| {
                let raw = String::from_utf8_lossy(line).trim().to_string();
                if raw.is_empty() {
                    return None;
                }
                let clip = serde_json::from_str::<Clip>(&raw).ok().filter(|c| c.id.is_some());
                Some(Entry { raw, clip })
            })
            .collect();
        Store {
            entries,
            ends_with_newline: bytes.last().is_none_or(|&b| b == b'\n'),
        }
    }

    /// Parsed clips with their entry index, in file order.
    fn clips(&self) -> impl DoubleEndedIterator<Item = (usize, &Clip)> {
        self.entries
            .iter()
            .enumerate()
            .filter_map(|(i, e)| e.clip.as_ref().map(|c| (i, c)))
    }

    fn find(&self, ident: &str) -> usize {
        self.clips()
            .find(|(_, c)| c.id().to_string() == ident)
            .map(|(i, _)| i)
            .unwrap_or_else(|| die(&format!("no clip with id {ident}")))
    }

    fn clip(&self, i: usize) -> &Clip {
        self.entries[i].clip.as_ref().unwrap()
    }

    fn value(&self, i: usize) -> Value {
        serde_json::from_str(&self.entries[i].raw).unwrap_or(Value::Null)
    }

    /// Rewrites one entry through a full JSON round trip (key order preserved).
    fn modify(&mut self, i: usize, f: impl FnOnce(&mut Map<String, Value>)) {
        let mut v = self.value(i);
        if let Some(obj) = v.as_object_mut() {
            f(obj);
            let raw = serde_json::to_string(&v).unwrap();
            self.entries[i].clip = serde_json::from_str(&raw).ok();
            self.entries[i].raw = raw;
        }
    }

    fn record_copy(&mut self, i: usize) {
        let ts = now();
        self.modify(i, |o| match o.get_mut("copies").and_then(Value::as_array_mut) {
            Some(a) => a.push(json!(ts)),
            None => {
                o.insert("copies".into(), json!([ts]));
            }
        });
    }

    fn save(&self, p: &Paths) {
        let mut buf = String::with_capacity(self.entries.iter().map(|e| e.raw.len() + 1).sum());
        for e in &self.entries {
            buf.push_str(&e.raw);
            buf.push('\n');
        }
        let tmp = p.dir.join("clips.tmp");
        if let Err(e) = fs::write(&tmp, buf).and_then(|_| fs::rename(&tmp, &p.store)) {
            die(&format!("cannot write store: {e}"));
        }
    }

    fn append(&self, p: &Paths, line: &str) {
        let sep = if self.ends_with_newline { "" } else { "\n" };
        let res = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&p.store)
            .and_then(|mut f| f.write_all(format!("{sep}{line}\n").as_bytes()));
        if let Err(e) = res {
            die(&format!("cannot write store: {e}"));
        }
    }
}

// MARK: - Detection

/// Git repo name (worktrees resolve to the main repo), else the folder name. Same answer as
/// `git rev-parse --git-common-dir`, read straight from .git so no git process is spawned.
fn detect_project(cwd: &Path) -> String {
    let mut dir = Some(cwd);
    while let Some(d) = dir {
        let dotgit = d.join(".git");
        if let Ok(meta) = fs::metadata(&dotgit) {
            let common = if meta.is_dir() {
                dotgit.join("HEAD").exists().then(|| dotgit.clone())
            } else {
                gitfile_common_dir(&dotgit, d)
            };
            if let Some(c) = common {
                let c = fs::canonicalize(&c).unwrap_or(c);
                if let Some(name) = c.parent().and_then(Path::file_name) {
                    return name.to_string_lossy().into_owned();
                }
            }
        }
        dir = d.parent();
    }
    cwd.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "misc".into())
}

fn gitfile_common_dir(dotgit: &Path, base: &Path) -> Option<PathBuf> {
    let text = fs::read_to_string(dotgit).ok()?;
    let gitdir = base.join(text.trim_end().strip_prefix("gitdir:")?.trim());
    if !gitdir.join("HEAD").exists() {
        return None;
    }
    Some(match fs::read_to_string(gitdir.join("commondir")) {
        Ok(c) => gitdir.join(c.trim_end_matches(['\n', '\r'])),
        Err(_) => gitdir,
    })
}

fn detect_agent() -> &'static str {
    let set = |k: &str| std::env::var_os(k).is_some_and(|v| !v.is_empty());
    if set("CLAUDECODE") || set("CLAUDE_CODE_ENTRYPOINT") {
        return "claude";
    }
    let keys: Vec<String> = std::env::vars_os()
        .map(|(k, _)| k.to_string_lossy().into_owned())
        .collect();
    if keys.iter().any(|k| k.starts_with("CODEX_")) {
        return "codex";
    }
    if keys.iter().any(|k| k.starts_with("GROK_")) {
        return "grok";
    }
    "unknown"
}

fn pbcopy(text: &str) {
    let ok = Command::new("/usr/bin/pbcopy")
        .stdin(Stdio::piped())
        .spawn()
        .and_then(|mut child| {
            child.stdin.take().unwrap().write_all(text.as_bytes())?;
            child.wait()
        })
        .is_ok_and(|s| s.success());
    if !ok {
        die("pbcopy failed");
    }
}

// MARK: - Text helpers (Python str semantics, so output matches the original CLI)

fn py_space(c: char) -> bool {
    c.is_whitespace() || ('\x1c'..='\x1f').contains(&c)
}

fn py_strip(s: &str) -> &str {
    s.trim_matches(py_space)
}

fn py_splitlines(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut chars = s.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        if matches!(
            c,
            '\n' | '\r' | '\x0b' | '\x0c' | '\x1c' | '\x1d' | '\x1e' | '\u{85}' | '\u{2028}' | '\u{2029}'
        ) {
            out.push(&s[start..i]);
            start = i + c.len_utf8();
            if c == '\r' && chars.peek().is_some_and(|&(_, n)| n == '\n') {
                chars.next();
                start += 1;
            }
        }
    }
    if start < s.len() {
        out.push(&s[start..]);
    }
    out
}

fn first_line(cmd: &str, width: usize) -> String {
    let lines = py_splitlines(py_strip(cmd));
    let mut line = lines.first().copied().unwrap_or("").to_string();
    if line.chars().count() > width {
        line = line.chars().take(width - 1).collect::<String>() + "…";
    } else if lines.len() > 1 {
        line.push_str(" …");
    }
    line
}

fn word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// shlex.quote
fn sh_quote(s: &str) -> String {
    if s.is_empty() {
        return "''".into();
    }
    if s.chars().all(|c| c.is_ascii_alphanumeric() || "_@%+=:,./-".contains(c)) {
        return s.into();
    }
    format!("'{}'", s.replace('\'', "'\"'\"'"))
}

/// shlex.split(s, comments=True) in POSIX mode; Err on an unclosed quote or trailing backslash.
fn shlex_split(s: &str) -> Result<Vec<String>, ()> {
    let mut out = Vec::new();
    let mut chars = s.chars();
    loop {
        let mut token = String::new();
        let mut quoted = false;
        let mut state = ' ';
        let mut escaped_state = 'a';
        let done = loop {
            let c = chars.next();
            match state {
                ' ' => match c {
                    None => break true,
                    Some(' ' | '\t' | '\r' | '\n') => {}
                    Some('#') => {
                        chars.by_ref().find(|&c| c == '\n');
                    }
                    Some('\\') => {
                        escaped_state = 'a';
                        state = '\\';
                    }
                    Some(q @ ('\'' | '"')) => state = q,
                    Some(c) => {
                        token.push(c);
                        state = 'a';
                    }
                },
                '\'' | '"' => {
                    quoted = true;
                    match c {
                        None => return Err(()),
                        Some(c) if c == state => state = 'a',
                        Some('\\') if state == '"' => {
                            escaped_state = '"';
                            state = '\\';
                        }
                        Some(c) => token.push(c),
                    }
                }
                '\\' => match c {
                    None => return Err(()),
                    Some(c) => {
                        if escaped_state == '"' && c != '\\' && c != '"' {
                            token.push('\\');
                        }
                        token.push(c);
                        state = escaped_state;
                    }
                },
                _ => match c {
                    None => break true,
                    Some(' ' | '\t' | '\r' | '\n') => break false,
                    Some('#') => {
                        chars.by_ref().find(|&c| c == '\n');
                        break false;
                    }
                    Some(q @ ('\'' | '"')) => state = q,
                    Some('\\') => {
                        escaped_state = 'a';
                        state = '\\';
                    }
                    Some(c) => token.push(c),
                },
            }
        };
        if !token.is_empty() || quoted {
            out.push(token);
        }
        if done {
            return Ok(out);
        }
    }
}

fn head_tokens(cmd: &str, n: usize) -> String {
    let stripped = py_strip(cmd);
    let toks = py_splitlines(stripped)
        .first()
        .ok_or(())
        .and_then(|l| shlex_split(l))
        .unwrap_or_else(|_| {
            stripped
                .split(py_space)
                .filter(|t| !t.is_empty())
                .map(String::from)
                .collect()
        });
    let env_assign = |t: &str| {
        let w = t.chars().take_while(|&c| word_char(c)).count();
        w > 0 && t.chars().nth(w) == Some('=')
    };
    toks.iter()
        .filter(|t| !env_assign(t))
        .take(n)
        .cloned()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Collapse whitespace and blank out obvious variable parts so near-duplicates group together.
fn normalize(cmd: &str) -> String {
    let mut collapsed = String::with_capacity(cmd.len());
    let mut in_space = false;
    for c in py_strip(cmd).chars() {
        if py_space(c) {
            if !in_space {
                collapsed.push(' ');
            }
            in_space = true;
        } else {
            collapsed.push(c);
            in_space = false;
        }
    }

    let chars: Vec<char> = collapsed.chars().collect();
    let mut strs = String::with_capacity(collapsed.len());
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '\'' || c == '"' {
            if let Some(j) = chars[i + 1..].iter().position(|&d| d == c) {
                strs.push_str("<str>");
                i += j + 2;
                continue;
            }
        }
        strs.push(c);
        i += 1;
    }

    let hashes = map_words(&strs, |w| {
        let n = w.chars().count();
        ((7..=40).contains(&n) && w.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f'))).then_some("<hash>")
    });
    map_words(&hashes, |w| w.chars().all(char::is_numeric).then_some("<n>"))
}

/// Replaces whole runs of word characters (regex `\b...\b`) for which `f` returns Some.
fn map_words(s: &str, f: impl Fn(&str) -> Option<&'static str>) -> String {
    let mut out = String::with_capacity(s.len());
    let mut start: Option<usize> = None;
    for (i, c) in s.char_indices().chain(std::iter::once((s.len(), ' '))) {
        let in_word = i < s.len() && word_char(c);
        match (start, in_word) {
            (None, true) => start = Some(i),
            (Some(st), false) => {
                let w = &s[st..i];
                out.push_str(f(w).unwrap_or(w));
                start = None;
            }
            _ => {}
        }
        if !in_word && i < s.len() {
            out.push(c);
        }
    }
    out
}

/// Counter with Python's most_common ordering (ties keep first-seen order).
#[derive(Default)]
struct Tally {
    idx: HashMap<String, usize>,
    items: Vec<(String, usize)>,
}

impl Tally {
    fn add(&mut self, k: String, w: usize) {
        match self.idx.get(&k) {
            Some(&i) => self.items[i].1 += w,
            None => {
                self.idx.insert(k.clone(), self.items.len());
                self.items.push((k, w));
            }
        }
    }
    fn most_common(mut self) -> Vec<(String, usize)> {
        self.items.sort_by(|a, b| b.1.cmp(&a.1));
        self.items
    }
}

fn local_mdhm(ts: f64) -> String {
    let t = ts as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&t, &mut tm) };
    format!(
        "{:02}-{:02} {:02}:{:02}",
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min
    )
}

/// Python's `xs[-limit:]` start index.
fn tail_start(len: usize, limit: i64) -> usize {
    match limit {
        0 => 0,
        l if l > 0 => len.saturating_sub(l as usize),
        l => (l.unsigned_abs() as usize).min(len),
    }
}

// MARK: - Argument parsing

struct Args {
    vals: HashMap<&'static str, String>,
    flags: HashSet<&'static str>,
    pos: Vec<String>,
}

impl Args {
    fn val(&self, k: &str) -> Option<&str> {
        self.vals.get(k).map(String::as_str)
    }
    fn flag(&self, k: &str) -> bool {
        self.flags.contains(k)
    }
    fn int(&self, k: &str, default: i64) -> i64 {
        self.val(k).map_or(default, |v| {
            v.parse()
                .unwrap_or_else(|_| usage_error(&format!("argument --{k}: invalid int value: '{v}'")))
        })
    }
    fn max_pos(&self, n: usize) {
        if self.pos.len() > n {
            usage_error(&format!("unrecognized arguments: {}", self.pos[n..].join(" ")));
        }
    }
}

/// (short, long, takes_value). With `remainder`, the first positional and everything after it
/// is the command (argparse REMAINDER); a leading `--` is dropped.
fn parse(args: &[String], opts: &[(&str, &'static str, bool)], remainder: bool) -> Args {
    let mut a = Args {
        vals: HashMap::new(),
        flags: HashSet::new(),
        pos: Vec::new(),
    };
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        i += 1;
        if arg == "--" {
            a.pos.extend(args[i..].iter().cloned());
            break;
        }
        if arg == "-h" || arg == "--help" {
            println!("{USAGE}");
            exit(0);
        }
        let negative_number = arg.len() > 1 && arg[1..].parse::<f64>().is_ok();
        let (opt, inline) = if let Some(long) = arg.strip_prefix("--") {
            let (name, v) = long
                .split_once('=')
                .map_or((long, None), |(n, v)| (n, Some(v.to_string())));
            (opts.iter().find(|o| o.1 == name), v)
        } else if arg.starts_with('-') && arg.len() > 1 && !negative_number {
            let end = 1 + arg[1..].chars().next().map_or(0, char::len_utf8);
            let (short, rest) = (&arg[1..end], &arg[end..]);
            (
                opts.iter().find(|o| o.0 == short),
                (!rest.is_empty()).then(|| rest.to_string()),
            )
        } else {
            a.pos.push(arg.clone());
            if remainder {
                a.pos.extend(args[i..].iter().cloned());
                break;
            }
            continue;
        };
        let Some(&(_, long, takes_value)) = opt else {
            usage_error(&format!("unrecognized arguments: {arg}"))
        };
        if takes_value {
            let v = inline.or_else(|| {
                i += 1;
                args.get(i - 1).cloned()
            });
            a.vals.insert(
                long,
                v.unwrap_or_else(|| usage_error(&format!("argument --{long}: expected one argument"))),
            );
        } else if inline.is_some() {
            usage_error(&format!("argument --{long}: ignored explicit argument"));
        } else {
            a.flags.insert(long);
        }
    }
    a
}

const PROJECT: (&str, &str, bool) = ("p", "project", true);

// MARK: - Commands

fn visible<'a>(s: &'a Store, all: bool, project: Option<&'a str>) -> Vec<(usize, &'a Clip)> {
    s.clips()
        .filter(|(_, c)| (all || !c.archived()) && project.is_none_or(|p| c.project() == p))
        .collect()
}

fn cmd_add(args: &[String]) {
    let a = parse(
        args,
        &[("n", "note", true), PROJECT, ("", "cwd", true), ("", "agent", true)],
        true,
    );
    let cmd = if !a.pos.is_empty() {
        a.pos.iter().map(|s| sh_quote(s)).collect::<Vec<_>>().join(" ")
    } else if !io::stdin().is_terminal() {
        let mut s = String::new();
        io::stdin()
            .read_to_string(&mut s)
            .unwrap_or_else(|e| die(&format!("cannot read stdin: {e}")));
        s
    } else {
        die("pass the command via stdin (heredoc) or after --")
    };
    let cmd = cmd.trim_matches('\n');
    if py_strip(cmd).is_empty() {
        die("empty command");
    }
    let cwd = std::env::current_dir().unwrap_or_default();
    let run_dir = a.val("cwd").map_or(cwd.clone(), |d| cwd.join(d));
    let project = a.val("project").map_or_else(|| detect_project(&run_dir), String::from);

    let p = paths();
    let _lock = lock(&p);
    let store = Store::load(&p);
    // An identical command still waiting in the same project is the same request; don't queue it twice.
    if let Some((_, dup)) = store
        .clips()
        .rev()
        .find(|(_, c)| !c.archived() && c.copies() == 0 && c.project() == project && c.cmd() == cmd)
    {
        emit(&format!(
            "agent-clip #{} [{project}] {} (already queued)\n",
            dup.id(),
            first_line(cmd, 70)
        ));
        return;
    }
    let id = store.clips().map(|(_, c)| c.id()).max().unwrap_or(0) + 1;
    let agent = a
        .val("agent")
        .filter(|s| !s.is_empty())
        .map_or_else(|| detect_agent().to_string(), String::from);
    let clip = json!({
        "id": id,
        "ts": now(),
        "project": project,
        "cwd": a.val("cwd").map_or_else(|| cwd.to_string_lossy().into_owned(), String::from),
        "agent": agent,
        "note": a.val("note").unwrap_or(""),
        "cmd": cmd,
        "copies": [],
        "archived": false,
    });
    store.append(&p, &serde_json::to_string(&clip).unwrap());
    emit(&format!("agent-clip #{id} [{project}] {}\n", first_line(cmd, 70)));
}

fn cmd_list(args: &[String]) {
    let a = parse(
        args,
        &[PROJECT, ("a", "all", false), ("l", "limit", true), ("", "json", false)],
        false,
    );
    a.max_pos(0);
    let limit = a.int("limit", 30);
    let s = Store::load(&paths());
    let shown = visible(&s, a.flag("all"), a.val("project"));
    let shown = &shown[tail_start(shown.len(), limit)..];
    if a.flag("json") {
        let vals: Vec<Value> = shown.iter().map(|&(i, _)| s.value(i)).collect();
        emit(&(serde_json::to_string_pretty(&vals).unwrap() + "\n"));
        return;
    }
    let mut out = String::new();
    for (_, c) in shown {
        let mark = if c.archived() {
            "x"
        } else if c.copies() > 0 {
            "✓"
        } else {
            "•"
        };
        let note = if c.note().is_empty() {
            String::new()
        } else {
            format!("  ({})", c.note())
        };
        out += &format!(
            "{mark} #{:<4} {}  [{}] {}{note}\n",
            c.id(),
            local_mdhm(c.ts()),
            c.project(),
            first_line(c.cmd(), 70)
        );
    }
    emit(&out);
}

fn cmd_show(args: &[String]) {
    let a = parse(args, &[], false);
    a.max_pos(1);
    let Some(id) = a.pos.first() else {
        usage_error("the following arguments are required: id")
    };
    let s = Store::load(&paths());
    emit(&format!("{}\n", s.clip(s.find(id)).cmd()));
}

fn cmd_copy(args: &[String]) {
    let a = parse(args, &[PROJECT], false);
    a.max_pos(1);
    let p = paths();
    let _lock = lock(&p);
    let mut s = Store::load(&p);
    let i = match a.pos.first() {
        Some(id) => s.find(id),
        None => visible(&s, false, a.val("project"))
            .last()
            .map(|&(i, _)| i)
            .unwrap_or_else(|| die("nothing to copy")),
    };
    pbcopy(s.clip(i).cmd());
    s.record_copy(i);
    s.save(&p);
    let c = s.clip(i);
    emit(&format!("copied #{}: {}\n", c.id(), first_line(c.cmd(), 70)));
}

/// Print a clip (default: newest uncopied for the cwd's project) and record it as used.
fn cmd_pull(args: &[String]) {
    let a = parse(args, &[PROJECT], false);
    a.max_pos(1);
    let p = paths();
    let _lock = lock(&p);
    let mut s = Store::load(&p);
    let i = match a.pos.first() {
        Some(id) => s.find(id),
        None => {
            let project = a.val("project").map_or_else(
                || detect_project(&std::env::current_dir().unwrap_or_default()),
                String::from,
            );
            let shown = visible(&s, false, Some(&project));
            let pick = shown
                .iter()
                .rev()
                .find(|(_, c)| c.copies() == 0)
                .or(shown.last())
                .map(|&(i, _)| i);
            pick.unwrap_or_else(|| die(&format!("nothing queued for {project}")))
        }
    };
    s.record_copy(i);
    s.save(&p);
    emit(&format!("{}\n", s.clip(i).cmd()));
}

fn cmd_archive(args: &[String]) {
    let a = parse(args, &[PROJECT, ("", "copied", false)], false);
    let p = paths();
    let _lock = lock(&p);
    let mut s = Store::load(&p);
    let mut targets: Vec<usize> = if a.pos.is_empty() {
        visible(&s, false, a.val("project")).iter().map(|&(i, _)| i).collect()
    } else {
        a.pos.iter().map(|id| s.find(id)).collect()
    };
    if a.flag("copied") {
        targets.retain(|&i| s.clip(i).copies() > 0);
    }
    let mut changed = false;
    for &i in &targets {
        if !s.clip(i).archived() {
            s.modify(i, |o| {
                o.insert("archived".into(), Value::Bool(true));
            });
            changed = true;
        }
    }
    if changed {
        s.save(&p);
    }
    emit(&format!("archived {} clip(s)\n", targets.len()));
}

fn cmd_projects(args: &[String]) {
    let a = parse(args, &[("a", "all", false)], false);
    a.max_pos(0);
    let s = Store::load(&paths());
    let mut t = Tally::default();
    for (_, c) in s.clips().filter(|(_, c)| a.flag("all") || !c.archived()) {
        t.add(c.project().to_string(), 1);
    }
    let out: String = t.most_common().iter().map(|(p, n)| format!("{n:>4}  {p}\n")).collect();
    emit(&out);
}

fn cmd_stats(args: &[String]) {
    let a = parse(args, &[PROJECT, ("d", "days", true), ("t", "top", true)], false);
    a.max_pos(0);
    let top = a.int("top", 15).max(0) as usize;
    let days = a.int("days", 0);
    let s = Store::load(&paths());
    let cutoff = now() - days as f64 * 86400.0;
    let clips: Vec<&Clip> = s
        .clips()
        .map(|(_, c)| c)
        .filter(|c| a.val("project").is_none_or(|p| c.project() == p) && (days == 0 || c.ts() >= cutoff))
        .collect();
    if clips.is_empty() {
        emit("no clips\n");
        return;
    }
    let weight = |c: &Clip| 1 + c.copies();
    let mut out = format!(
        "{} clips, {} copies\n\n",
        clips.len(),
        clips.iter().map(|c| c.copies()).sum::<usize>()
    );

    for (title, n) in [("Top programs (adds + copies):", 1), ("\nTop subcommands:", 2)] {
        out += title;
        out.push('\n');
        let mut t = Tally::default();
        for c in &clips {
            t.add(head_tokens(c.cmd(), n), weight(c));
        }
        for (k, n) in t.most_common().into_iter().take(top) {
            out += &format!("  {n:>4}  {k}\n");
        }
    }

    out += "\nRepeated command shapes (alias / script candidates):\n";
    let mut order: Vec<String> = Vec::new();
    let mut shapes: HashMap<String, Vec<&Clip>> = HashMap::new();
    for c in &clips {
        let shape = normalize(c.cmd());
        shapes
            .entry(shape.clone())
            .or_insert_with(|| {
                order.push(shape);
                Vec::new()
            })
            .push(c);
    }
    let mut ranked: Vec<(&String, usize)> = order
        .iter()
        .map(|k| (k, shapes[k].iter().map(|c| weight(c)).sum()))
        .collect();
    ranked.sort_by(|a, b| b.1.cmp(&a.1));
    let mut shown = 0;
    for (shape, w) in ranked {
        let cs = &shapes[shape];
        if cs.len() < 2 {
            continue;
        }
        let mut projects: Vec<&str> = cs.iter().map(|c| c.project()).collect();
        projects.sort_unstable();
        projects.dedup();
        out += &format!(
            "  {w:>4}  {}\n        projects: {}\n",
            first_line(shape, 90),
            projects.join(", ")
        );
        shown += 1;
        if shown >= top {
            break;
        }
    }
    if shown == 0 {
        out += "  (none yet)\n";
    }
    emit(&out);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(action) = args.first() else {
        usage_error("the following arguments are required: action")
    };
    let rest = &args[1..];
    match action.as_str() {
        "add" => cmd_add(rest),
        "list" | "ls" => cmd_list(rest),
        "show" => cmd_show(rest),
        "copy" => cmd_copy(rest),
        "pull" => cmd_pull(rest),
        "archive" => cmd_archive(rest),
        "projects" => cmd_projects(rest),
        "stats" => cmd_stats(rest),
        "-h" | "--help" => println!("{USAGE}"),
        other => usage_error(&format!("argument action: invalid choice: '{other}'")),
    }
}
