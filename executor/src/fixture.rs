//! A compiled fixture used by the repository-level executor tests.
use std::{
    env, fs,
    path::PathBuf,
    process::{Command, Stdio},
    thread,
    time::Duration,
};

fn main() {
    if env::args_os()
        .nth(1)
        .is_some_and(|arg| arg == "--fixture-child")
    {
        thread::sleep(Duration::from_secs(30));
        return;
    }
    let mode = env::var("BUCK2_EXECUTOR_FIXTURE_MODE").unwrap_or_else(|_| "pass".into());
    let report_dir = env::var_os("BUCK2_NEXTEST_JUNIT_DIR").map(PathBuf::from);
    if mode == "cancel" {
        let marker = PathBuf::from(format!(
            "/tmp/buck2-nextest-executor-cancel-ready-{}",
            std::process::id()
        ));
        let child = Command::new(env::current_exe().unwrap())
            .arg("--fixture-child")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        fs::write(
            &marker,
            format!("ready\\n{}\\n{}\\n", std::process::id(), child.id()),
        )
        .unwrap();
        thread::sleep(Duration::from_secs(30));
        return;
    }
    let nonce = match env::var("BUCK2_EXECUTOR_FIXTURE_NONCE")
        .unwrap_or_else(|_| "fixture".into())
        .as_str()
    {
        "fixture" | "buck-fixture" => format!(
            "run-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ),
        value => value.to_owned(),
    };
    eprintln!("fixture stderr marker mode={mode}");
    println!("fixture stdout marker mode={mode}");
    let argv: Vec<_> = env::args_os().collect();
    let forwarded_executor_arg = argv.iter().any(|arg| {
        arg.to_string_lossy() == "--junit-dir"
            || arg.to_string_lossy() == "--timeout"
            || arg.to_string_lossy() == "--buck-test-info"
            || arg.to_string_lossy() == "ignored"
    });
    println!("fixture argv={argv:?}");
    println!(
        "fixture executor args forwarded={}",
        if forwarded_executor_arg { 1 } else { 0 }
    );
    if let Some(dir) = report_dir {
        let xml = format!("<testsuites><testsuite name=\"{mode}\"><testcase name=\"{nonce}\"/></testsuite></testsuites>");
        match mode.as_str() {
            "missing" => {}
            "malformed" => fs::write(dir.join("junit.xml"), b"<testsuites>").unwrap(),
            "symlink" => {
                fs::write(dir.join("not-junit.xml"), xml.as_bytes()).unwrap();
                #[cfg(unix)]
                std::os::unix::fs::symlink("not-junit.xml", dir.join("junit.xml")).unwrap();
            }
            "extra" => {
                fs::write(dir.join("junit.xml"), xml.as_bytes()).unwrap();
                fs::write(dir.join("extra.txt"), b"unexpected").unwrap();
            }
            _ => fs::write(dir.join("junit.xml"), xml.as_bytes()).unwrap(),
        }
    }
    match mode.as_str() {
        "fail" => std::process::exit(7),
        "timeout" => {
            thread::sleep(Duration::from_secs(30));
        }
        _ => {}
    }
}
