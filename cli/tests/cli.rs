use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};

struct Store(PathBuf);

impl Store {
    fn new(name: &str) -> Store {
        let dir = std::env::temp_dir().join(format!("agent-clip-test-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Store(dir)
    }

    fn run(&self, args: &[&str], stdin: &str) -> Output {
        let mut child = Command::new(env!("CARGO_BIN_EXE_agent-clip"))
            .args(args)
            .env("AGENT_CLIPBOARD_DIR", &self.0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
        child.wait_with_output().unwrap()
    }

    fn out(&self, args: &[&str], stdin: &str) -> String {
        let o = self.run(args, stdin);
        assert!(o.status.success(), "{args:?}: {}", String::from_utf8_lossy(&o.stderr));
        String::from_utf8(o.stdout).unwrap()
    }

    fn lines(&self) -> Vec<String> {
        fs::read_to_string(self.0.join("clips.jsonl"))
            .unwrap()
            .lines()
            .map(String::from)
            .collect()
    }
}

impl Drop for Store {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn add_preserves_heredoc_bytes_and_dedupes_pending() {
    let s = Store::new("add");
    let cmd = "echo \"$HOME\" 'a b'\nsecond line";
    assert_eq!(
        s.out(&["add", "-p", "demo", "-n", "note"], &format!("{cmd}\n")),
        "agent-clip #1 [demo] echo \"$HOME\" 'a b' …\n"
    );
    assert_eq!(s.out(&["show", "1"], ""), format!("{cmd}\n"));
    assert!(s.out(&["add", "-p", "demo"], cmd).contains("#1 [demo]"));
    assert_eq!(s.lines().len(), 1);
    s.out(&["pull", "-p", "demo"], "");
    assert!(s.out(&["add", "-p", "demo"], cmd).starts_with("agent-clip #2 "));
}

#[test]
fn argv_is_shell_quoted() {
    let s = Store::new("argv");
    s.out(&["add", "-p", "x", "--", "git", "commit", "-m", "a b; c"], "");
    assert_eq!(s.out(&["show", "1"], ""), "git commit -m 'a b; c'\n");
}

#[test]
fn pull_prefers_newest_uncopied_and_records_copy() {
    let s = Store::new("pull");
    s.out(&["add", "-p", "x"], "one");
    s.out(&["add", "-p", "x"], "two");
    assert_eq!(s.out(&["pull", "-p", "x"], ""), "two\n");
    assert_eq!(s.out(&["pull", "-p", "x"], ""), "one\n");
    assert_eq!(s.out(&["pull", "-p", "x"], ""), "two\n");
    let o = s.run(&["pull", "-p", "nope"], "");
    assert_eq!(o.status.code(), Some(1));
}

#[test]
fn archive_hides_and_keeps_unparseable_lines() {
    let s = Store::new("archive");
    s.out(&["add", "-p", "x"], "one");
    fs::OpenOptions::new()
        .append(true)
        .open(s.0.join("clips.jsonl"))
        .unwrap()
        .write_all(b"not json\n")
        .unwrap();
    s.out(&["add", "-p", "x"], "two");
    assert_eq!(s.out(&["archive", "1"], ""), "archived 1 clip(s)\n");
    let lines = s.lines();
    assert_eq!(lines[1], "not json");
    assert!(!s.out(&["ls"], "").contains("one"));
    assert!(s.out(&["ls", "-a"], "").contains("x #1"));
}

#[test]
fn missing_id_and_bad_usage() {
    let s = Store::new("errors");
    assert_eq!(s.run(&["show", "9"], "").status.code(), Some(1));
    assert_eq!(s.run(&["ls", "--bogus"], "").status.code(), Some(2));
    assert_eq!(s.run(&["frob"], "").status.code(), Some(2));
}

#[test]
fn stats_groups_shapes() {
    let s = Store::new("stats");
    s.out(&["add", "-p", "a"], "git commit -m 'one' 12");
    s.out(&["add", "-p", "b"], "git commit -m \"two\" 345");
    let out = s.out(&["stats"], "");
    assert!(
        out.contains("     2  git commit -m <str> <n>\n        projects: a, b\n"),
        "{out}"
    );
}
