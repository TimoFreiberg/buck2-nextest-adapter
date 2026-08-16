#[test]
fn pass_case() {
    println!("buck2-nextest-artifact: pass-test");
    assert_eq!(std::env::var("BUCK2_NEXTEST_RUNTIME"), Ok(String::from("declared")));
}

#[test]
fn fail_case() {
    println!("buck2-nextest-artifact: fail-test");
    assert_eq!(2 + 2, 5);
}
