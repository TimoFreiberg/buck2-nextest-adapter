use std::fs;
use std::path::PathBuf;

const RESOURCE_KEY: &str = "nextest-generated-rust-runtime-resource.txt";
const RESOURCE_SENTINEL: &str = "buck2-nextest-generated-runtime-resource-v1\n";
const MISSING_MESSAGE: &str = "buck2-nextest runtime closure missing generated resource";

#[test]
fn provider_runtime_resource_case() {
    let executable = std::env::current_exe().expect("current_exe");
    println!("buck2-nextest runtime executable={}", executable.display());
    let database = executable.with_extension("resources.json");
    let database_bytes = match fs::read(&database) {
        Ok(bytes) => bytes,
        Err(_) => {
            eprintln!("{MISSING_MESSAGE}: database={}", database.display());
            panic!("{MISSING_MESSAGE}");
        }
    };
    let resource_database: serde_json::Map<String, serde_json::Value> =
        serde_json::from_slice(&database_bytes).expect("resource database JSON");
    let relative = match resource_database.get(RESOURCE_KEY).and_then(serde_json::Value::as_str) {
        Some(relative) => relative,
        None => {
            eprintln!("{MISSING_MESSAGE}: key={RESOURCE_KEY}");
            panic!("{MISSING_MESSAGE}");
        }
    };
    let resource = executable
        .parent()
        .expect("executable parent")
        .join(relative);
    let resource = fs::canonicalize(resource).expect("canonicalize generated resource");
    let contents = match fs::read_to_string(&resource) {
        Ok(contents) => contents,
        Err(_) => {
            eprintln!("{MISSING_MESSAGE}: path={}", resource.display());
            panic!("{MISSING_MESSAGE}");
        }
    };
    assert_eq!(contents, RESOURCE_SENTINEL, "generated resource sentinel");
    let observation = std::env::var_os("NEXTEST_TEST_OBSERVATION_DIR").map(|directory| {
        PathBuf::from(directory)
            .join("runtime-closure-observation.txt")
            .into_os_string()
    });
    if let Some(observation) = observation {
        if let Some(parent) = PathBuf::from(&observation).parent() {
            fs::create_dir_all(parent).expect("create runtime closure observation directory");
        }
        fs::write(
            observation,
            format!("executable={}\ndatabase={}\nresource={}\n", executable.display(), database.display(), resource.display()),
        )
        .expect("write runtime closure observation");
    }
    println!("buck2-nextest runtime resource=ok key={RESOURCE_KEY}");
}
