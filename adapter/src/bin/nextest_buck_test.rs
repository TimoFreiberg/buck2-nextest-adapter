//! Production schema-v2 nextest runner.
//!
//! Buck owns the enclosing test command and declared JUnit directory. This
//! binary owns only validation, staging, reuse-build metadata, the single
//! nextest list/run lifecycle, and unchanged JUnit publication.
use buck2_nextest_adapter_contract::{
    manifest_v2::{load_and_validate, ManifestV2},
    nextest_v2::{
        command_from, drain_process_groups, ensure_dir, publish_junit, sanitized_env,
        send_process_tree, set_process_group, status_code, synthesize, ObservedSignal, SignalGuard,
        INFRASTRUCTURE_STATUS, RUNNER_VERSION,
    },
};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    env,
    ffi::{OsStr, OsString},
    fs::{self},
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[derive(Default)]
struct Args {
    manifest: Option<PathBuf>,
    record_count: Option<usize>,
    declared_inputs: Vec<PathBuf>,
    nextest: Option<Vec<OsString>>,
    suite_env: BTreeMap<String, String>,
    bundle_json: Option<String>,
    bundle_resources: Vec<PathBuf>,
    bundle_resources_seen: bool,
    profile: String,
    filter: String,
    no_tests: String,
    report_skipped: String,
    timeout: u64,
    profile_seen: bool,
    filter_seen: bool,
    no_tests_seen: bool,
    report_skipped_seen: bool,
    timeout_seen: bool,
}

fn usage() {
    eprintln!("usage: nextest_buck_test --manifest PATH --record-count N --declared-input PATH... --cargo-nextest-argv EXEC... --end-argv [--bundle-json JSON] [--bundle-resources PATH... --end-bundle-resources] [--profile NAME] [--filter EXPRESSION] [--no-tests auto|pass|warn|fail] [--report-skipped default|ignored] [--timeout-seconds N]");
}
#[derive(Debug)]
struct RunnerError {
    code: i32,
    message: String,
}
impl RunnerError {
    fn new(code: i32, message: impl Into<String>) -> Self { Self { code, message: message.into() } }
    fn infrastructure(message: impl Into<String>) -> Self { Self::new(INFRASTRUCTURE_STATUS, message) }
}
impl From<String> for RunnerError {
    fn from(message: String) -> Self { Self::new(2, message) }
}
impl From<&str> for RunnerError {
    fn from(message: &str) -> Self { Self::new(2, message) }
}

#[derive(Debug)]
struct ProcessFailure {
    message: String,
    retain_scratch: bool,
}
impl ProcessFailure {
    fn retained(message: impl Into<String>) -> Self {
        Self { message: message.into(), retain_scratch: true }
    }
}
impl From<String> for ProcessFailure {
    fn from(message: String) -> Self { Self { message, retain_scratch: false } }
}
impl From<&str> for ProcessFailure {
    fn from(message: &str) -> Self { Self { message: message.into(), retain_scratch: false } }
}

fn fail(message: impl AsRef<str>) -> ! {
    eprintln!("buck2-nextest-adapter: {}", message.as_ref());
    usage();
    std::process::exit(2)
}
fn take_value(argv: &[OsString], index: &mut usize, option: &str) -> OsString {
    *index += 1;
    let Some(value) = argv.get(*index) else { fail(format!("{option} requires a value")) };
    if value.to_string_lossy().starts_with("--") {
        fail(format!("{option} requires a value"));
    }
    value.clone()
}
fn take_vec(argv: &[OsString], index: &mut usize, option: &str) -> Vec<OsString> {
    *index += 1;
    let mut values = Vec::new();
    while let Some(value) = argv.get(*index) {
        if value == OsStr::new("--end-argv") { return values; }
        if value.to_string_lossy().contains('\n') { fail(format!("{option} contains a newline")); }
        values.push(value.clone());
        *index += 1;
    }
    fail(format!("{option} requires --end-argv"));
}
fn parse() -> Args {
    let argv: Vec<_> = env::args_os().skip(1).collect();
    if argv.iter().any(|arg| arg == OsStr::new("--help") || arg == OsStr::new("-h")) { usage(); std::process::exit(0); }
    let mut args = Args { profile: "ci".into(), filter: "test(=pass_case)".into(), no_tests: "auto".into(), report_skipped: "default".into(), ..Default::default() };
    let mut index = 0;
    while index < argv.len() {
        let option = &argv[index];
        if option == OsStr::new("--manifest") {
            if args.manifest.is_some() { fail("--manifest specified more than once"); }
            args.manifest = Some(PathBuf::from(take_value(&argv, &mut index, "--manifest")));
        } else if option == OsStr::new("--record-count") {
            if args.record_count.is_some() { fail("--record-count specified more than once"); }
            args.record_count = Some(take_value(&argv, &mut index, "--record-count").to_str().and_then(|v| v.parse().ok()).unwrap_or_else(|| fail("invalid --record-count")));
        } else if option == OsStr::new("--declared-input") {
            args.declared_inputs.push(PathBuf::from(take_value(&argv, &mut index, "--declared-input")));
        } else if option == OsStr::new("--suite-env") {
            let name = take_value(&argv, &mut index, "--suite-env").to_str().unwrap_or_else(|| fail("suite environment name is not UTF-8")).to_owned();
            let value = take_value(&argv, &mut index, "--suite-env").to_str().unwrap_or_else(|| fail("suite environment value is not UTF-8")).to_owned();
            if args.suite_env.insert(name, value).is_some() { fail("suite environment variable specified more than once"); }
        } else if option == OsStr::new("--cargo-nextest-argv") {
            if args.nextest.is_some() { fail("--cargo-nextest-argv specified more than once"); }
            args.nextest = Some(take_vec(&argv, &mut index, "--cargo-nextest-argv"));
        } else if option == OsStr::new("--bundle-json") {
            if args.bundle_json.is_some() { fail("--bundle-json specified more than once"); }
            args.bundle_json = Some(take_value(&argv, &mut index, "--bundle-json").to_str().unwrap_or_else(|| fail("bundle JSON is not UTF-8")).into());
        } else if option == OsStr::new("--bundle-resources") {
            if args.bundle_resources_seen { fail("--bundle-resources specified more than once"); }
            args.bundle_resources_seen = true;
            index += 1;
            while let Some(value) = argv.get(index) {
                if value == OsStr::new("--end-bundle-resources") { break; }
                args.bundle_resources.push(PathBuf::from(value));
                index += 1;
            }
            if index == argv.len() { fail("--bundle-resources requires --end-bundle-resources"); }
        } else if option == OsStr::new("--profile") {
            if args.profile_seen { fail("--profile specified more than once"); }
            args.profile_seen = true;
            args.profile = take_value(&argv, &mut index, "--profile").to_str().unwrap_or_else(|| fail("profile is not UTF-8")).into();
        } else if option == OsStr::new("--filter") {
            if args.filter_seen { fail("--filter specified more than once"); }
            args.filter_seen = true;
            args.filter = take_value(&argv, &mut index, "--filter").to_str().unwrap_or_else(|| fail("filter is not UTF-8")).into();
        } else if option == OsStr::new("--no-tests") {
            if args.no_tests_seen { fail("--no-tests specified more than once"); }
            args.no_tests_seen = true;
            args.no_tests = take_value(&argv, &mut index, "--no-tests").to_str().unwrap_or_else(|| fail("no-tests is not UTF-8")).into();
        } else if option == OsStr::new("--report-skipped") {
            if args.report_skipped_seen { fail("--report-skipped specified more than once"); }
            args.report_skipped_seen = true;
            args.report_skipped = take_value(&argv, &mut index, "--report-skipped").to_str().unwrap_or_else(|| fail("report-skipped is not UTF-8")).into();
        } else if option == OsStr::new("--timeout-seconds") {
            if args.timeout_seen { fail("--timeout-seconds specified more than once"); }
            args.timeout_seen = true;
            args.timeout = take_value(&argv, &mut index, "--timeout-seconds").to_str().and_then(|v| v.parse().ok()).unwrap_or_else(|| fail("invalid --timeout-seconds"));
        } else {
            fail(format!("unknown option: {}", option.to_string_lossy()));
        }
        index += 1;
    }
    args
}
fn abs(path: &Path, cwd: &Path) -> PathBuf { if path.is_absolute() { path.to_path_buf() } else { cwd.join(path) } }
fn validate_suite_environment(environment: &BTreeMap<String, String>) -> Result<(), String> {
    let reserved = [
        "PATH", "HOME", "TMPDIR", "CARGO_HOME", "CARGO_TARGET_DIR",
        "CARGO_MANIFEST_DIR", "CARGO_NET_OFFLINE", "CARGO_NET_GIT_FETCH_WITH_CLI",
        "BUCK2_NEXTEST_JUNIT_DIR",
    ];
    for (name, value) in environment {
        let valid_name = !name.is_empty()
            && name.bytes().enumerate().all(|(index, byte)| {
                (index == 0 && (byte.is_ascii_alphabetic() || byte == b'_'))
                    || (index > 0 && (byte.is_ascii_alphanumeric() || byte == b'_'))
            });
        if !valid_name || name.starts_with("BUCK2_NEXTEST_") || reserved.contains(&name.as_str()) {
            return Err(format!("suite environment name is reserved or invalid: {name}"));
        }
        if value.contains('\0') {
            return Err(format!("suite environment value contains NUL: {name}"));
        }
    }
    Ok(())
}
fn validate_controls(args: &Args) -> Result<(), String> {
    if args.manifest.is_none() || args.record_count.is_none() || args.nextest.as_ref().is_none_or(Vec::is_empty) { return Err("manifest, record-count, and non-empty declared launcher argv are required".into()); }
    if args.filter.is_empty() { return Err("filter must be non-empty".into()); }
    if args.profile.is_empty() || !args.profile.bytes().next().is_some_and(|b| b.is_ascii_alphanumeric()) || !args.profile.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') { return Err("profile must match [A-Za-z0-9][A-Za-z0-9_-]*".into()); }
    if !matches!(args.no_tests.as_str(), "auto" | "pass" | "warn" | "fail") { return Err("no-tests must be auto, pass, warn, or fail".into()); }
    if !matches!(args.report_skipped.as_str(), "default" | "ignored") { return Err("report-skipped must be default or ignored".into()); }
    if args.timeout > 86400 { return Err("timeout-seconds must be between 0 and 86400".into()); }
    Ok(())
}
fn empty_declared_directory(path: &Path, cwd: &Path) -> Result<PathBuf, String> {
    let path = abs(path, cwd);
    let metadata = fs::symlink_metadata(&path).map_err(|e| format!("BUCK2_NEXTEST_JUNIT_DIR cannot be inspected: {e}"))?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_dir() { return Err("BUCK2_NEXTEST_JUNIT_DIR must be a real directory".into()); }
    if fs::read_dir(&path).map_err(|e| e.to_string())?.next().is_some() { return Err("BUCK2_NEXTEST_JUNIT_DIR must be empty before dispatch".into()); }
    Ok(path)
}
fn ensure_directory_without_symlinks(path: &Path) -> Result<(), String> {
    if !path.is_absolute() {
        return Err(format!("scratch parent must be absolute: {}", path.display()));
    }
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component.as_os_str());
        match fs::symlink_metadata(&current) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() || !metadata.file_type().is_dir() {
                    return Err(format!("scratch parent contains an unsafe directory: {}", current.display()));
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&current).map_err(|error| format!("could not create scratch parent {}: {error}", current.display()))?;
                let metadata = fs::symlink_metadata(&current).map_err(|error| error.to_string())?;
                if metadata.file_type().is_symlink() || !metadata.file_type().is_dir() {
                    return Err(format!("scratch parent was replaced by an unsafe directory: {}", current.display()));
                }
            }
            Err(error) => return Err(format!("could not inspect scratch parent {}: {error}", current.display())),
        }
    }
    Ok(())
}

fn private_root(cwd: &Path) -> Result<PathBuf, String> {
    let parent = if let Some(value) = env::var_os("BUCK_SCRATCH_PATH") {
        let value = PathBuf::from(value);
        if value.is_absolute() || value.components().any(|component| matches!(component, std::path::Component::ParentDir | std::path::Component::RootDir | std::path::Component::CurDir)) {
            return Err("BUCK_SCRATCH_PATH must be a normalized project-relative path".into());
        }
        let parent = abs(&value, cwd);
        ensure_directory_without_symlinks(&parent)?;
        parent
    } else {
        let value = env::var_os("TMPDIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"));
        if !value.is_absolute() || value.as_os_str().is_empty() || value.components().any(|component| matches!(component, std::path::Component::ParentDir | std::path::Component::CurDir)) {
            return Err("TMPDIR must be an absolute safe scratch parent".into());
        }
        fs::canonicalize(&value).map_err(|error| format!("could not resolve TMPDIR: {error}"))?
    };
    for attempt in 0..1000 {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e| e.to_string())?.as_nanos();
        let root = parent.join(format!("buck2-nextest-test.{stamp}.{attempt}"));
        match fs::create_dir(&root) { Ok(()) => { #[cfg(unix)] { use std::os::unix::fs::PermissionsExt; fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?; } return Ok(root); }, Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue, Err(error) => return Err(format!("could not create private scratch root: {error}")) }
    }
    Err("could not create a unique private scratch root".into())
}
fn source_for(source: &str, declared: &[PathBuf], cwd: &Path) -> Result<PathBuf, String> {
    let source_absolute = abs(Path::new(source), cwd);
    let matches: BTreeSet<_> = declared
        .iter()
        .filter(|value| {
            let absolute = abs(value, cwd);
            value.to_string_lossy() == source
                || absolute == source_absolute
                // Buck's short_path can omit the configured output prefix. A
                // declared materialized artifact is still an exact match when
                // its final path components equal that short_path; require one
                // such match and never search outside the declared closure.
                || absolute.ends_with(Path::new(source))
        })
        .map(|value| abs(value, cwd))
        .collect();
    if matches.len() != 1 {
        return Err(format!("declared input does not exactly map to source: {source}"));
    }
    Ok(matches.into_iter().next().unwrap())
}
fn stage_manifest(root: &Path, cwd: &Path, manifest: &ManifestV2, declared: &[PathBuf]) -> Result<(), String> {
    let mut expected = BTreeSet::new();
    for record in &manifest.records {
        expected.insert(record.executable.source.clone());
        for runtime in &record.runtime { expected.insert(runtime.source.clone()); }
    }
    for source in &expected {
        source_for(source, declared, cwd)?;
    }
    for record in &manifest.records {
        let source = source_for(&record.executable.source, declared, cwd)?;
        let destination = root.join(&record.executable.destination);
        buck2_nextest_adapter_contract::nextest_v2::copy_regular(&source, &destination, true)?;
        for runtime in &record.runtime {
            let source = source_for(&runtime.source, declared, cwd)?;
            buck2_nextest_adapter_contract::nextest_v2::copy_regular(&source, &root.join("workspace").join(&record.cwd).join(&runtime.destination), false)?;
        }
    }
    Ok(())
}
fn paths_overlap(left: &str, right: &str) -> bool {
    left == right || left.starts_with(&(right.to_owned() + "/")) || right.starts_with(&(left.to_owned() + "/"))
}

fn parse_bundle(raw: Option<&str>, declared: &[PathBuf], cwd: &Path, root: &Path, manifest_paths: &BTreeSet<String>) -> Result<(BTreeMap<String, String>, Vec<(PathBuf, PathBuf)>), String> {
    let Some(raw) = raw else { return Ok((BTreeMap::new(), Vec::new())); };
    let value: Value = serde_json::from_str(raw).map_err(|e| format!("invalid bundle JSON: {e}"))?;
    let object = value.as_object().ok_or("bundle JSON must be an object")?;
    let expected: BTreeSet<&str> = ["bundle_environment", "bundle_platform", "bundle_resources", "bundle_version"].into_iter().collect();
    if object.keys().map(String::as_str).collect::<BTreeSet<_>>() != expected { return Err("bundle JSON has unexpected fields".into()); }
    if object.get("bundle_version").and_then(Value::as_u64) != Some(1) { return Err("unsupported bundle version".into()); }
    let platform = object.get("bundle_platform").and_then(Value::as_str).ok_or("bundle_platform must be a string")?;
    if platform.is_empty() || platform.chars().any(char::is_whitespace) { return Err("bundle_platform is invalid".into()); }
    let resources = object.get("bundle_resources").and_then(Value::as_array).ok_or("bundle_resources must be a list")?;
    if resources.len() != declared.len() { return Err("bundle resources must exactly match declared resources".into()); }
    let mut paths = BTreeSet::new(); let mut sources = BTreeSet::new(); let mut pairs = Vec::new();
    for resource in resources {
        let item = resource.as_object().ok_or("bundle resource must be an object")?;
        let keys: BTreeSet<&str> = ["digest", "path", "source"].into_iter().collect();
        if item.keys().map(String::as_str).collect::<BTreeSet<_>>() != keys { return Err("bundle resource has unexpected fields".into()); }
        let source = item["source"].as_str().ok_or("bundle resource source must be a string")?;
        let destination = item["path"].as_str().ok_or("bundle resource path must be a string")?;
        buck2_nextest_adapter_contract::nextest_v2::safe_relative(source, "bundle resource source")?;
        buck2_nextest_adapter_contract::nextest_v2::safe_relative(destination, "bundle resource path")?;
        if destination == "workspace" || destination.starts_with("workspace/") || destination == "meta" || destination.starts_with("meta/") || destination == "target" || destination.starts_with("target/") || destination == "manifest.json" || destination.starts_with("manifest.json/") || manifest_paths.iter().any(|path| paths_overlap(path, destination)) {
            return Err("bundle resource path is adapter-owned or overlaps a declared test artifact".into());
        }
        if !sources.insert(source) || !paths.insert(destination) { return Err("bundle resources contain duplicate source or path".into()); }
        let digest = item["digest"].as_str().ok_or("bundle resource digest must be a string")?;
        let mut parts = digest.split(':'); if parts.next() != Some("sha256") { return Err("bundle resource digest must use sha256:<hex>:<size>".into()); }
        let hash = parts.next().ok_or("bundle resource digest is missing hash")?; let size = parts.next().and_then(|v| v.parse::<u64>().ok()).ok_or("bundle resource digest has invalid size")?;
        if parts.next().is_some() || hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) { return Err("bundle resource digest must use sha256:<hex>:<size>".into()); }
        let input = source_for(source, declared, cwd)
            .map_err(|_| format!("bundle resource source is not uniquely declared: {source}"))?;
        buck2_nextest_adapter_contract::nextest_v2::regular(&input, false)?;
        let metadata = fs::metadata(&input).map_err(|e| e.to_string())?; let actual = buck2_nextest_adapter_contract::nextest_v2::sha256_digest(&input)?;
        if metadata.len() != size || !actual.eq_ignore_ascii_case(hash) { return Err(format!("bundle resource digest mismatch: {source}")); }
        pairs.push((input, root.join(destination)));
    }
    let declared_destinations: BTreeSet<_> = resources
        .iter()
        .filter_map(Value::as_object)
        .filter_map(|item| item.get("path"))
        .filter_map(Value::as_str)
        .collect();
    let mut environment = BTreeMap::new();
    for item in object["bundle_environment"].as_array().ok_or("bundle_environment must be a list")? {
        let item = item.as_object().ok_or("bundle environment must be an object")?;
        let name = item.get("name").and_then(Value::as_str).ok_or("bundle environment name must be a string")?;
        let kind = item.get("kind").and_then(Value::as_str).ok_or("bundle environment kind must be a string")?;
        let value = item.get("value").and_then(Value::as_str).ok_or("bundle environment value must be a string")?;
        let reserved = ["PATH", "HOME", "TMPDIR", "CARGO_HOME", "CARGO_TARGET_DIR", "CARGO_MANIFEST_DIR", "CARGO_NET_OFFLINE", "CARGO_NET_GIT_FETCH_WITH_CLI"];
        if !name.bytes().enumerate().all(|(i,b)| (i == 0 && (b.is_ascii_alphabetic() || b == b'_')) || (i > 0 && (b.is_ascii_alphanumeric() || b == b'_'))) || name.starts_with("BUCK2_NEXTEST_") || reserved.contains(&name) || !matches!(kind, "literal" | "relative_path") || value.contains('\0') || (kind == "relative_path" && (buck2_nextest_adapter_contract::nextest_v2::safe_relative(value, "bundle environment path").is_err() || !declared_destinations.contains(value))) || environment.insert(name.to_owned(), if kind == "relative_path" { abs(&root.join(value), cwd).to_string_lossy().into_owned() } else { value.to_owned() }).is_some() { return Err("invalid or duplicate bundle environment".into()); }
    }
    Ok((environment, pairs))
}
fn build_command(base: &[OsString], subcommand: &str, generated: &buck2_nextest_adapter_contract::nextest_v2::Synthesized, root: &Path, args: &Args, bundle_env: &BTreeMap<String, String>) -> Result<Command, String> {
    let mut argv = base.to_vec();
    argv.push("nextest".into()); argv.push(subcommand.into());
    let mut command = command_from(&argv)?;
    command.current_dir(&generated.workspace);
    sanitized_env(&mut command, root, &args.suite_env, bundle_env, &generated.workspace, &generated.target);
    command.arg("--cargo-metadata").arg(&generated.cargo_metadata).arg("--binaries-metadata").arg(&generated.binaries_metadata).arg("--target-dir-remap").arg(&generated.target).arg("--build-dir-remap").arg(&generated.target).arg("--workspace-remap").arg(&generated.workspace).arg("--config-file").arg(&generated.config_file);
    if subcommand == "list" { command.arg("--message-format").arg("json"); } else { command.arg("--profile").arg(&args.profile).arg("--message-format").arg("human").arg("--filterset").arg(&args.filter).arg("--no-tests").arg(&args.no_tests).arg("--success-output").arg("never").arg("--failure-output").arg("immediate-final"); }
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    Ok(command)
}
fn run_capture(mut command: Command) -> Result<(i32, Vec<u8>, Vec<u8>), ProcessFailure> {
    let mut groups = BTreeSet::new();
    set_process_group(&mut command);
    let guard = SignalGuard::install()?;
    let mut child = command.spawn().map_err(|e| format!("could not spawn setup command: {e}"))?;
    let root_pid = child.id() as i32;
    if root_pid <= 0 {
        let _ = child.kill();
        let _ = child.wait();
        return Err("setup command did not provide a valid process id".into());
    }
    groups.insert(root_pid);
    match buck2_nextest_adapter_contract::nextest_v2::collect_process_groups(root_pid) {
        Ok(found) => groups.extend(found),
        Err(error) => {
            let signal_error = buck2_nextest_adapter_contract::nextest_v2::send_group(root_pid, 9).err();
            let wait_error = child.wait().err().map(|error| error.to_string());
            let drain_error = drain_process_groups(&groups).err();
            let mut message = format!("could not inspect setup process group: {error}; escalated known process group");
            if let Some(error) = signal_error { message.push_str(&format!("; escalation failed: {error}")); }
            if let Some(error) = wait_error { message.push_str(&format!("; leader wait failed: {error}")); }
            if let Some(error) = drain_error { message.push_str(&format!("; process-group drain failed: {error}")); }
            return Err(ProcessFailure::retained(message));
        }
    }
    let stdout_pipe = child.stdout.take().map(|mut pipe| thread::spawn(move || {
        let mut output = Vec::new();
        pipe.read_to_end(&mut output).map(|_| output).map_err(|e| e.to_string())
    }));
    let stderr_pipe = child.stderr.take().map(|mut pipe| thread::spawn(move || {
        let mut output = Vec::new();
        pipe.read_to_end(&mut output).map(|_| output).map_err(|e| e.to_string())
    }));
    let mut signal = None;
    let mut signal_sent_at = None;
    let mut kill_sent = false;
    loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            let status = status_code(status)?;
            if signal.is_none() { signal = guard.observed(); }
            drain_process_groups(&groups)
                .map_err(|error| ProcessFailure::retained(format!("setup process groups did not become quiescent: {error}")))?;
            let stdout = stdout_pipe.map(|pipe| pipe.join().map_err(|_| "stdout reader panicked".to_owned())?).transpose()?.unwrap_or_default();
            let stderr = stderr_pipe.map(|pipe| pipe.join().map_err(|_| "stderr reader panicked".to_owned())?).transpose()?.unwrap_or_default();
            if let Some(signal) = signal { return Ok((signal.status(), stdout, stderr)); }
            return Ok((status, stdout, stderr));
        }
        if let Some(observed) = guard.observed() {
            if signal.is_none() {
                signal = Some(observed);
                send_process_tree(root_pid, &mut groups, observed.0)
                    .map_err(|error| ProcessFailure::retained(format!("could not signal setup process group tree: {error}")))?;
                signal_sent_at = Some(std::time::Instant::now());
            } else if !kill_sent && signal_sent_at.is_some_and(|sent| sent.elapsed() >= Duration::from_secs(5)) {
                send_process_tree(root_pid, &mut groups, 9)
                    .map_err(|error| ProcessFailure::retained(format!("could not kill setup process group tree: {error}")))?;
                kill_sent = true;
            }
        }
        thread::sleep(Duration::from_millis(10));
    }
}
fn version_matches(text: &str) -> bool {
    text.lines().any(|line| {
        let line = line.trim();
        line == RUNNER_VERSION || (line.starts_with(RUNNER_VERSION) && line[RUNNER_VERSION.len()..].starts_with(" ("))
    })
}
fn validate_list(stdout: &[u8], expected: &BTreeMap<String, (String, String)>) -> Result<(), String> {
    let text = std::str::from_utf8(stdout).map_err(|e| format!("nextest list output is not UTF-8: {e}"))?;
    let mut documents = text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str::<Value>(line).map_err(|e| format!("nextest list emitted invalid JSON: {e}")))
        .collect::<Result<Vec<_>, _>>()?;
    if documents.len() != 1 {
        return Err(format!("nextest list must emit exactly one JSON document, got {}", documents.len()));
    }
    let document = documents.pop().unwrap();
    let suites = document
        .get("rust-suites")
        .and_then(Value::as_object)
        .ok_or_else(|| format!("nextest list JSON has no rust-suites object: {document}"))?;
    let found: BTreeSet<_> = suites.keys().cloned().collect();
    let expected_ids: BTreeSet<_> = expected.keys().cloned().collect();
    if found != expected_ids {
        return Err(format!("nextest list identities differ from declared suite: expected {expected_ids:?}, got {found:?}"));
    }
    for (id, suite) in suites {
        let object = suite.as_object().ok_or_else(|| format!("nextest list suite {id} is not an object"))?;
        let reported_id = object.get("binary-id").and_then(Value::as_str).ok_or_else(|| format!("nextest list suite {id} has no binary-id"))?;
        if reported_id != id {
            return Err(format!("nextest list suite key {id} disagrees with binary-id {reported_id}"));
        }
        let (expected_name, expected_package) = expected.get(id).ok_or_else(|| format!("nextest list returned undeclared suite {id}"))?;
        for field in ["binary-name", "binary-path", "package-id", "cwd"] {
            if object.get(field).and_then(Value::as_str).is_none() {
                return Err(format!("nextest list suite {id} has no string {field}"));
            }
        }
        if object.get("binary-name").and_then(Value::as_str) != Some(expected_name)
            || object.get("package-id").and_then(Value::as_str) != Some(expected_package)
        {
            return Err(format!("nextest list suite {id} does not match synthesized package/binary metadata"));
        }
        if object.get("testcases").and_then(Value::as_object).is_none() {
            return Err(format!("nextest list suite {id} has no testcases object"));
        }
    }
    Ok(())
}
fn run_supervised(mut command: Command) -> Result<(i32, Option<ObservedSignal>, Vec<u8>, Vec<u8>), ProcessFailure> {
    set_process_group(&mut command);
    let guard = SignalGuard::install()?;
    let mut child = command.spawn().map_err(|e| format!("could not spawn nextest run: {e}"))?;
    let root_pid = child.id() as i32;
    if root_pid <= 0 {
        let _ = child.kill();
        let _ = child.wait();
        return Err("nextest run did not provide a valid process group id".into());
    }
    let mut groups = BTreeSet::new();
    groups.insert(root_pid);
    match buck2_nextest_adapter_contract::nextest_v2::collect_process_groups(root_pid) {
        Ok(found) => groups.extend(found),
        Err(error) => {
            let signal_error = buck2_nextest_adapter_contract::nextest_v2::send_group(root_pid, 9).err();
            let wait_error = child.wait().err().map(|error| error.to_string());
            let drain_error = drain_process_groups(&groups).err();
            let mut message = format!("could not inspect nextest process group: {error}; escalated known process group");
            if let Some(error) = signal_error { message.push_str(&format!("; escalation failed: {error}")); }
            if let Some(error) = wait_error { message.push_str(&format!("; leader wait failed: {error}")); }
            if let Some(error) = drain_error { message.push_str(&format!("; process-group drain failed: {error}")); }
            return Err(ProcessFailure::retained(message));
        }
    }
    let stdout_pipe = child.stdout.take().map(|mut pipe| thread::spawn(move || {
        let mut output = Vec::new();
        pipe.read_to_end(&mut output).map(|_| output).map_err(|e| e.to_string())
    }));
    let stderr_pipe = child.stderr.take().map(|mut pipe| thread::spawn(move || {
        let mut output = Vec::new();
        pipe.read_to_end(&mut output).map(|_| output).map_err(|e| e.to_string())
    }));
    let mut signal = None;
    let mut signal_sent_at = None;
    let mut kill_sent = false;
    loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            let status = status_code(status)?;
            if signal.is_none() {
                signal = guard.observed();
            }
            drain_process_groups(&groups)
                .map_err(|error| ProcessFailure::retained(format!("nextest process groups did not become quiescent: {error}")))?;
            let stdout = stdout_pipe.map(|pipe| pipe.join().map_err(|_| "stdout reader panicked".to_owned())?).transpose()?.unwrap_or_default();
            let stderr = stderr_pipe.map(|pipe| pipe.join().map_err(|_| "stderr reader panicked".to_owned())?).transpose()?.unwrap_or_default();
            return Ok((status, signal, stdout, stderr));
        }
        if let Some(observed) = guard.observed() {
            if signal.is_none() {
                signal = Some(observed);
                send_process_tree(root_pid, &mut groups, observed.0)
                    .map_err(|error| ProcessFailure::retained(format!("could not signal nextest process group tree: {error}")))?;
                signal_sent_at = Some(std::time::Instant::now());
            } else if !kill_sent && signal_sent_at.is_some_and(|sent| sent.elapsed() >= Duration::from_secs(5)) {
                send_process_tree(root_pid, &mut groups, 9)
                    .map_err(|error| ProcessFailure::retained(format!("could not kill nextest process group tree: {error}")))?;
                kill_sent = true;
            }
        }
        thread::sleep(Duration::from_millis(10));
    }
}
fn execute(args: Args) -> Result<i32, RunnerError> {
    validate_controls(&args).map_err(RunnerError::from)?;
    validate_suite_environment(&args.suite_env).map_err(RunnerError::from)?;
    let cwd = env::var_os("BUCK_PROJECT_ROOT")
        .map(PathBuf::from)
        .unwrap_or(env::current_dir().map_err(|e| RunnerError::from(e.to_string()))?);
    if !cwd.is_absolute() {
        return Err(RunnerError::from("BUCK_PROJECT_ROOT must be absolute"));
    }
    let declared_dir = PathBuf::from(env::var_os("BUCK2_NEXTEST_JUNIT_DIR").ok_or("BUCK2_NEXTEST_JUNIT_DIR is required")?);
    let declared_dir = empty_declared_directory(&declared_dir, &cwd)?;
    let manifest_path = abs(args.manifest.as_ref().unwrap(), &cwd);
    let manifest = load_and_validate(&manifest_path).map_err(|e| format!("manifest validation failed: {e}"))?;
    if manifest.records.len() != args.record_count.unwrap() { return Err("manifest record count does not match --record-count".into()); }
    let inputs: Vec<_> = args.declared_inputs.iter().map(|path| abs(path, &cwd)).collect();
    for input in &inputs { buck2_nextest_adapter_contract::nextest_v2::regular(input, false)?; }
    let root = private_root(&cwd)?;
    let execution = (|| -> Result<(i32, Option<PathBuf>), ProcessFailure> {
        stage_manifest(&root, &cwd, &manifest, &args.declared_inputs)?;
        ensure_dir(&root.join("home"))?; ensure_dir(&root.join("cargo-home"))?; ensure_dir(&root.join("tmp"))?;
        let generated = synthesize(&root, &manifest, &args.profile, &args.report_skipped, args.timeout)?;
        for record in &manifest.records {
            let id = record.id.as_deref().ok_or("validated record has no semantic ID")?;
            let source = source_for(&record.executable.source, &args.declared_inputs, &cwd)?;
            let destination = generated.staged_binaries.get(id).ok_or("synthesized binary is missing")?;
            buck2_nextest_adapter_contract::nextest_v2::copy_regular(&source, destination, true)?;
            for runtime in &record.runtime {
                let source = source_for(&runtime.source, &args.declared_inputs, &cwd)?;
                buck2_nextest_adapter_contract::nextest_v2::copy_regular(&source, &root.join("workspace").join(&record.cwd).join(&runtime.destination), false)?;
            }
        }
        let base = args.nextest.as_ref().unwrap();
        let mut version = base.to_vec(); version.push("nextest".into()); version.push("--version".into());
        let mut manifest_paths = BTreeSet::new();
        for record in &manifest.records {
            manifest_paths.insert(record.executable.destination.clone());
            for runtime in &record.runtime {
                manifest_paths.insert(format!("workspace/{}/{}", record.cwd, runtime.destination));
            }
        }
        let (bundle_env, bundle_pairs) = parse_bundle(args.bundle_json.as_deref(), &args.bundle_resources, &cwd, &root, &manifest_paths)?;
        for (source, destination) in bundle_pairs { buck2_nextest_adapter_contract::nextest_v2::copy_regular(&source, &destination, false)?; }
        let mut version_command = command_from(&version)?; version_command.current_dir(&generated.workspace); sanitized_env(&mut version_command, &root, &args.suite_env, &bundle_env, &generated.workspace, &generated.target); version_command.stdout(Stdio::piped()).stderr(Stdio::piped());
        let (version_status, version_stdout, version_stderr) = run_capture(version_command)
            .map_err(|error| ProcessFailure { message: error.message, retain_scratch: error.retain_scratch })?;
        let version_text = String::from_utf8_lossy(&version_stdout).to_string() + &String::from_utf8_lossy(&version_stderr);
        if version_status != 0 || !version_matches(&version_text) { return Err(format!("version boundary failed: expected {RUNNER_VERSION} with optional parenthesized build details, got {}", version_text.trim()).into()); }
        let list = build_command(base, "list", &generated, &root, &args, &bundle_env)?;
        let (list_status, list_stdout, list_stderr) = run_capture(list)
            .map_err(|error| ProcessFailure { message: error.message, retain_scratch: error.retain_scratch })?;
        if list_status != 0 { return Err(format!("list boundary failed with {list_status}: {}", String::from_utf8_lossy(&list_stderr)).into()); }
        validate_list(&list_stdout, &generated.list_expectations)?;
        let run = build_command(base, "run", &generated, &root, &args, &bundle_env)?;
        let (raw, signal, stdout, stderr) = run_supervised(run)
            .map_err(|error| ProcessFailure { message: error.message, retain_scratch: error.retain_scratch })?;
        if let Some(signal) = signal { eprintln!("buck2-nextest-adapter: terminated by signal {}", signal.0); return Ok((signal.status(), None)); }
        if !stdout.is_empty() { eprint!("{}", String::from_utf8_lossy(&stdout)); }
        if !stderr.is_empty() { eprint!("{}", String::from_utf8_lossy(&stderr)); }
        Ok((raw, Some(generated.junit)))
    })();
    let (result, retain_scratch) = match execution {
        Ok((status, Some(report))) if report.exists() => (
            publish_junit(&report, &declared_dir)
                .map(|()| status)
                .map_err(|error| {
                    eprintln!("buck2-nextest-adapter: raw nextest status={status}; JUnit publication failed: {error}");
                    RunnerError::infrastructure(error)
                }),
            false,
        ),
        Ok((status, Some(report))) if status == 0 || status == 100 => (
            Err(RunnerError::infrastructure(format!("required JUnit report is absent after nextest status {status}; expected {}", report.display()))),
            false,
        ),
        Ok((status, _)) => (Ok(status), false),
        Err(error) => {
            let result = Err(RunnerError::new(2, error.message.clone()));
            (result, error.retain_scratch)
        }
    };
    if retain_scratch {
        if let Err(error) = &result {
            return Err(RunnerError::new(2, format!("{}; retained scratch root {}", error.message, root.display())));
        }
        return Err(RunnerError::new(2, format!("process lifecycle failed; retained scratch root {}", root.display())));
    }
    match fs::remove_dir_all(&root) {
        Ok(()) => result,
        Err(error) => Err(RunnerError::new(2, format!("scratch cleanup failed; retained root {}: {error}", root.display())))
    }
}
fn main() {
    match execute(parse()) {
        Ok(status) => std::process::exit(status),
        Err(error) => {
            eprintln!("buck2-nextest-adapter: {}", error.message);
            usage();
            std::process::exit(error.code);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn controls_reject_invalid_values() {
        let args = Args { profile: "bad/name".into(), filter: "x".into(), no_tests: "auto".into(), report_skipped: "default".into(), timeout: 0, manifest: Some("m".into()), record_count: Some(1), nextest: Some(vec!["tool".into()]), ..Default::default() };
        assert!(validate_controls(&args).is_err());
    }
    #[test]
    fn bundle_paths_cannot_overlap_manifest_artifacts() {
        assert!(paths_overlap("work/bin/alpha", "work/bin/alpha"));
        assert!(paths_overlap("workspace/work/runtime/file", "workspace/work"));
        assert!(!paths_overlap("work/bin/alpha", "work/bin/beta"));
    }
    #[test]
    fn source_resolution_prefers_exact_declared_path() {
        let declared = vec![PathBuf::from("remapped/bin/test"), PathBuf::from("other/test")];
        assert_eq!(source_for("remapped/bin/test", &declared, Path::new("/tmp")), Ok(PathBuf::from("/tmp/remapped/bin/test")));
    }
    #[test]
    fn source_resolution_rejects_unrelated_declared_path() {
        let declared = vec![PathBuf::from("remapped/bin/test")];
        assert!(source_for("original/bin/test", &declared, Path::new("/tmp")).is_err());
    }
    #[test]
    fn version_matching_requires_the_pinned_release() {
        assert!(version_matches("cargo-nextest 0.9.143 (abc)"));
        assert!(version_matches("cargo-nextest 0.9.143"));
        assert!(!version_matches("cargo-nextest 0.9.143-custom"));
        assert!(!version_matches("cargo-nextest 0.9.142 (abc)"));
    }
    #[test] fn list_validation_requires_exact_declared_ids() {
        let mut expected = BTreeMap::new(); expected.insert("id".into(), ("test".into(), "package".into()));
        assert!(validate_list(br#"{"rust-suites":{"id":{"binary-id":"id","binary-name":"test","binary-path":"/tmp/test","package-id":"package","cwd":"/tmp/package","testcases":{}}}}
"#, &expected).is_ok());
        assert!(validate_list(br#"{"rust-suites":{"other":{"binary-id":"other","binary-name":"test","binary-path":"/tmp/test","package-id":"package","cwd":"/tmp/package","testcases":{}}}}
"#, &expected).is_err());
        assert!(validate_list(br#"{"rust-suites":{"id":{"binary-id":"id","binary-name":"wrong","binary-path":"/tmp/test","package-id":"package","cwd":"/tmp/package","testcases":{}}}}
"#, &expected).is_err());
    }
}
