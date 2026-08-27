use std::{
    env,
    fs::{self, OpenOptions},
    io::Write,
    path::Path,
    process::Command,
    thread,
    time::Duration,
};

fn write_atomic(path: &Path, contents: &str) {
    let temporary = path.with_extension("tmp");
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .expect("create observation temporary");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .expect("set observation permissions");
    }
    file.write_all(contents.as_bytes()).expect("write observation");
    file.sync_all().expect("sync observation");
    fs::rename(temporary, path).expect("commit observation");
}

#[test]
fn pass_case() {
    assert_eq!(std::env::var("BUCK2_ARTIFACT_RUNTIME").as_deref(), Ok("declared"));
    println!("nextest-v2 fixture: cwd={}", std::env::current_dir().unwrap().display());
}

#[test]
fn fail_case() {
    println!("nextest-v2 fixture: fail");
    assert_eq!(2 + 2, 5);
}

#[test]
#[ignore]
fn ignored_case() {
    println!("nextest-v2 fixture: ignored");
}

#[test]
fn timeout_case() {
    if std::env::var_os("BUCK2_NEXTEST_TIMEOUT_READINESS").is_some() {
        println!("nextest-v2 fixture: timeout readiness");
    }
    std::thread::sleep(std::time::Duration::from_secs(10));
}

#[cfg(unix)]
fn process_start_identity() -> String {
    let pid = std::process::id().to_string();
    let output = Command::new("/bin/ps")
        .args(["-p", &pid, "-o", "pid=,lstart="])
        .output()
        .expect("inspect test process start identity");
    assert!(output.status.success(), "ps failed");
    String::from_utf8(output.stdout)
        .expect("ps output is UTF-8")
        .split_whitespace()
        .skip(1)
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(not(unix))]
fn process_start_identity() -> String {
    format!("pid-{}", std::process::id())
}

#[test]
fn cancellation_case() {
    let directory = env::var("NEXTEST_TEST_OBSERVATION_DIR").expect("cancellation observation directory");
    let nonce = env::var("NEXTEST_TEST_NONCE").expect("cancellation nonce");
    let directory = Path::new(&directory);
    fs::create_dir_all(directory).expect("create observation directory");
    let state = directory.join("state.json");
    let process_start_identity = process_start_identity();
    let contents = format!(
        "{{\"schema\":1,\"nonce\":{},\"test_pid\":{},\"test_start_identity\":{},\"ready\":true}}\n",
        serde_json::to_string(&nonce).expect("encode cancellation nonce"),
        std::process::id(),
        serde_json::to_string(&process_start_identity).expect("encode process identity"),
    );
    write_atomic(&state, &contents);
    loop {
        thread::sleep(Duration::from_secs(1));
    }
}
