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
