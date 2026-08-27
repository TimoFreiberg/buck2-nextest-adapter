#[test]
fn pass_case() {
    let runtime = std::env::var("BUCK2_ARTIFACT_RUNTIME").expect("runtime environment");
    assert!(runtime == "declared" || runtime == "mutated");
    let content = std::fs::read_to_string("../runtime/buck2_artifact_runtime.txt")
        .expect("cwd-relative runtime input");
    assert_eq!(content, "buck2-nextest-artifact-runtime-v1\n");
    println!("buck2-nextest-artifact: runtime={runtime} content={}", content.trim());
    println!("buck2-nextest-artifact: cwd=work");
    println!("buck2-nextest-artifact: pass-test");
}

#[test]
fn fail_case() {
    println!("buck2-nextest-artifact: fail-test");
    assert_eq!(2 + 2, 5);
}

#[test]
#[ignore]
fn ignored_case() {
    println!("buck2-nextest-artifact: ignored-test");
}

#[test]
fn timeout_case() {
    if let Ok(marker) = std::env::var("BUCK2_NEXTEST_TIMEOUT_READINESS") {
        let mut file = std::fs::File::create(marker).expect("timeout readiness marker");
        use std::io::Write;
        file.write_all(b"ready\n").expect("timeout readiness payload");
    }
    println!("buck2-nextest-artifact: timeout-test");
    std::thread::sleep(std::time::Duration::from_secs(10));
}
