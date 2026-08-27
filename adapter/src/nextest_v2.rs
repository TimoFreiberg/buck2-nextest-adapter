//! Shared schema-v2 nextest staging, metadata, and lifecycle helpers.
use crate::{
    digest::sha256_file,
    manifest_v2::{GenericRecord, ManifestV2},
    report::validate_report_xml,
};
use serde_json::{json, Map, Value};
use signal_hook::{
    consts::{SIGHUP, SIGINT, SIGTERM},
    iterator::{Handle, Signals},
};
use std::{
    collections::{BTreeMap, BTreeSet},
    env,
    ffi::OsString,
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    process::{Command, ExitStatus},
    sync::{
        atomic::{AtomicI32, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};

#[cfg(unix)]
use std::{os::raw::c_int, os::unix::fs::PermissionsExt};
#[cfg(unix)]
unsafe extern "C" {
    fn kill(pid: c_int, signal: c_int) -> c_int;
}

pub const RUNNER_VERSION: &str = "cargo-nextest 0.9.143";
pub const INFRASTRUCTURE_STATUS: i32 = 3;

pub fn safe_relative(value: &str, name: &str) -> Result<(), String> {
    if value.is_empty()
        || value.starts_with('/')
        || value.contains('\\')
        || value.contains('\0')
        || value
            .split('/')
            .any(|p| p.is_empty() || p == "." || p == "..")
    {
        return Err(format!("{name} must be a normalized relative POSIX path"));
    }
    Ok(())
}

pub fn regular(path: &Path, executable: bool) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|e| format!("cannot inspect {}: {e}", path.display()))?;
    if !metadata.file_type().is_file() {
        return Err(format!("{} is not a regular file", path.display()));
    }
    if executable && !is_executable(path) {
        return Err(format!("{} is not executable", path.display()));
    }
    File::open(path).map_err(|e| format!("{} is not readable: {e}", path.display()))?;
    Ok(())
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    fs::metadata(path)
        .map(|m| m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}
#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    fs::metadata(path).is_ok()
}

pub fn ensure_dir(path: &Path) -> Result<(), String> {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.file_type().is_symlink() || !metadata.file_type().is_dir() {
            return Err(format!("{} is not a real directory", path.display()));
        }
        return Ok(());
    }
    fs::create_dir_all(path).map_err(|e| format!("could not create {}: {e}", path.display()))?;
    let metadata = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_dir() {
        return Err(format!(
            "{} was replaced by a non-directory",
            path.display()
        ));
    }
    Ok(())
}

pub fn copy_regular(source: &Path, destination: &Path, executable: bool) -> Result<(), String> {
    regular(source, false)?;
    if let Some(parent) = destination.parent() {
        ensure_dir(parent)?;
    }
    if let Ok(metadata) = fs::symlink_metadata(destination) {
        if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
            return Err(format!(
                "staging destination is unsafe: {}",
                destination.display()
            ));
        }
    }
    fs::copy(source, destination)
        .map_err(|e| format!("could not stage {}: {e}", source.display()))?;
    if executable {
        #[cfg(unix)]
        {
            let mut permissions = fs::metadata(destination)
                .map_err(|e| e.to_string())?
                .permissions();
            permissions.set_mode(permissions.mode() | 0o111);
            fs::set_permissions(destination, permissions).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

pub fn generated_name(prefix: &str, id: &str) -> String {
    // Encode every byte, including underscores, so the result is injective.
    let mut value = String::from(prefix);
    for byte in id.as_bytes() {
        value.push_str(&format!("_{byte:02x}"));
    }
    value
}

fn json_write(path: &Path, value: &Value) -> Result<(), String> {
    let mut file = File::create(path).map_err(|e| e.to_string())?;
    serde_json::to_writer_pretty(&mut file, value).map_err(|e| e.to_string())?;
    file.write_all(b"\n").map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())
}

fn toml_basic_string(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len() + 2);
    escaped.push('"');
    for character in value.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\u{08}' => escaped.push_str("\\b"),
            '\u{0c}' => escaped.push_str("\\f"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            character if character.is_control() => {
                escaped.push_str(&format!("\\u{:04x}", character as u32))
            }
            character => escaped.push(character),
        }
    }
    escaped.push('"');
    escaped
}

pub struct Synthesized {
    pub workspace: PathBuf,
    pub target: PathBuf,
    pub cargo_metadata: PathBuf,
    pub binaries_metadata: PathBuf,
    pub config_file: PathBuf,
    pub junit: PathBuf,
    pub binary_ids: BTreeSet<String>,
    pub list_expectations: BTreeMap<String, (String, String, PathBuf)>,
}

pub fn synthesize(
    root: &Path,
    manifest: &ManifestV2,
    executable_paths: &BTreeMap<String, PathBuf>,
    profile: &str,
    report_skipped: &str,
    timeout: u64,
) -> Result<Synthesized, String> {
    let workspace = root.join("workspace");
    let target = root.join("target");
    let meta = root.join("meta");
    ensure_dir(&workspace)?;
    ensure_dir(&target)?;
    ensure_dir(&meta)?;
    ensure_dir(&workspace.join(".config"))?;
    let mut packages: BTreeMap<String, (String, String, Vec<(&GenericRecord, String)>)> =
        BTreeMap::new();
    let mut ids = BTreeSet::new();
    for record in &manifest.records {
        let id = record
            .id
            .as_deref()
            .ok_or("validated record has no semantic ID")?;
        let package_name = generated_name("buck2_pkg", &record.package_identity);
        let package_dir = record.cwd.clone();
        let binary_name = generated_name("buck2_test", id);
        ids.insert(id.to_owned());
        let entry = packages
            .entry(record.package_identity.clone())
            .or_insert_with(|| (package_name, package_dir, Vec::new()));
        entry.2.push((record, binary_name));
    }
    let mut cargo_packages = Vec::new();
    let mut nodes = Vec::new();
    let mut binaries = Map::new();
    let workspace_members: Vec<String> = packages
        .values()
        .map(|(_, package_dir, _)| package_dir.clone())
        .collect();
    let workspace_manifest = workspace.join("Cargo.toml");
    let workspace_members_toml = workspace_members
        .iter()
        .map(|member| format!("    \"{member}\""))
        .collect::<Vec<_>>()
        .join(",\n");
    fs::write(
        &workspace_manifest,
        format!("[workspace]\nresolver = \"2\"\nmembers = [\n{workspace_members_toml},\n]\n"),
    )
    .map_err(|e| e.to_string())?;
    let mut list_expectations = BTreeMap::new();
    for (_identity, (package_name, _package_dir, records)) in &packages {
        let package_root = workspace.join(&records[0].0.cwd);
        ensure_dir(&package_root.join("src"))?;
        let package_id = format!(
            "path+file://{}#{}@0.1.0",
            package_root.display(),
            package_name
        );
        let manifest_path = package_root.join("Cargo.toml");
        File::create(&manifest_path).map_err(|e| e.to_string())?.write_all(format!("[package]\nname = \"{package_name}\"\nversion = \"0.1.0\"\nedition = \"2021\"\n").as_bytes()).map_err(|e| e.to_string())?;
        let mut targets = Vec::new();
        for (record, binary_name) in records {
            let id = record.id.as_deref().unwrap();
            let executable_path = executable_paths
                .get(id)
                .ok_or_else(|| format!("missing resolved executable path for {id}"))?;
            let src_path = package_root.join("src").join(format!("{binary_name}.rs"));
            File::create(&src_path).map_err(|e| e.to_string())?;
            list_expectations.insert(
                id.to_owned(),
                (binary_name.clone(), package_id.clone(), executable_path.clone()),
            );
            targets.push(json!({"name": binary_name, "src_path": src_path, "kind":["test"], "crate_types":["bin"], "edition":"2021", "test":true, "doc":false, "doctest":false, "required-features":[]}));
            binaries.insert(id.to_owned(), json!({"binary-id":id,"binary-name":binary_name,"binary-path":executable_path,"build-platform":"target","kind":"test","package-id":package_id,"cwd":package_root}));
        }
        cargo_packages.push(json!({"id":package_id,"name":package_name,"version":"0.1.0","source":null,"manifest_path":manifest_path,"edition":"2021","authors":[],"categories":[],"keywords":[],"dependencies":[],"features":{},"default_run":null,"description":null,"documentation":null,"homepage":null,"license":null,"license_file":null,"links":null,"metadata":null,"publish":null,"readme":null,"repository":null,"rust_version":null,"targets":targets}));
        nodes.push(json!({"id":package_id,"dependencies":[],"deps":[],"features":[]}));
    }
    let package_ids: Vec<Value> = cargo_packages
        .iter()
        .map(|package| package["id"].clone())
        .collect();
    let cargo = json!({"version":1,"packages":cargo_packages,"workspace_root":workspace,"target_directory":target,"workspace_members":package_ids,"workspace_default_members":package_ids,"resolve":{"root":null,"nodes":nodes}});
    let binary = json!({"rust-binaries":binaries,"rust-build-meta":{"target-directory":target,"build-directory":target,"base-output-directories":["debug"],"non-test-binaries":{},"build-script-out-dirs":{},"build-script-info":{},"linked-paths":[],"platforms":{"host":{"platform":{"triple":manifest.records[0].platform,"target-features":"unknown"},"libdir":{"status":"unavailable","reason":"not-in-archive"}},"targets":[]},"target-platforms":[{"triple":manifest.records[0].platform,"target-features":"unknown"}],"target-platform":null}});
    json_write(&meta.join("cargo-metadata.json"), &cargo)?;
    json_write(&meta.join("binaries-metadata.json"), &binary)?;
    let junit = target.join("nextest").join(profile).join("junit.xml");
    let mut config = format!("[profile.{profile}]\n");
    if report_skipped == "ignored" {
        config.push_str("report-skipped = \"ignored\"\n");
    }
    if timeout != 0 {
        config.push_str(&format!("slow-timeout = {{ period = \"{timeout}s\", terminate-after = 1, grace-period = \"0s\" }}\n"));
    }
    let junit_path = junit
        .to_str()
        .ok_or("generated JUnit path is not valid UTF-8")?;
    config.push_str(&format!(
        "\n[profile.{profile}.junit]\npath = {}\n",
        toml_basic_string(junit_path)
    ));
    fs::write(workspace.join(".config/nextest.toml"), config).map_err(|e| e.to_string())?;
    Ok(Synthesized {
        workspace: workspace.clone(),
        target: target.clone(),
        cargo_metadata: meta.join("cargo-metadata.json"),
        binaries_metadata: meta.join("binaries-metadata.json"),
        config_file: workspace.join(".config/nextest.toml"),
        junit,
        binary_ids: ids,
        list_expectations,
    })
}

pub fn publish_junit(source: &Path, declared_dir: &Path) -> Result<(), String> {
    regular(source, false)?;
    ensure_dir(declared_dir)?;
    let metadata = fs::symlink_metadata(declared_dir).map_err(|e| e.to_string())?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_dir() {
        return Err("declared JUnit directory is unsafe".into());
    }
    let bytes = fs::read(source).map_err(|e| format!("could not read JUnit: {e}"))?;
    validate_report_xml(&bytes).map_err(|e| format!("JUnit is malformed: {e}"))?;
    for entry in fs::read_dir(declared_dir).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        return Err(format!(
            "declared JUnit directory is not empty: {}",
            entry.path().display()
        ));
    }
    let temporary = declared_dir.join(format!(".junit.xml.{}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?;
    }
    file.write_all(&bytes).map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    let destination = declared_dir.join("junit.xml");
    if fs::symlink_metadata(&destination).is_ok() {
        let _ = fs::remove_file(&temporary);
        return Err("declared JUnit destination already exists".into());
    }
    fs::rename(&temporary, &destination).map_err(|e| e.to_string())?;
    File::open(declared_dir)
        .and_then(|directory| directory.sync_all())
        .map_err(|e| e.to_string())
}

pub fn command_from(argv: &[OsString]) -> Result<Command, String> {
    let exe = argv.first().ok_or("declared launcher argv is empty")?;
    let cwd = env::current_dir().map_err(|e| e.to_string())?;
    let path = Path::new(exe);
    let path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        cwd.join(path)
    };
    regular(&path, true)?;
    let mut command = Command::new(path);
    command.args(&argv[1..]);
    Ok(command)
}

pub fn sanitized_env(
    command: &mut Command,
    root: &Path,
    suite_env: &BTreeMap<String, String>,
    bundle_env: &BTreeMap<String, String>,
    workspace: &Path,
    target: &Path,
) {
    command.env_clear();
    for (key, value) in bundle_env {
        command.env(key, value);
    }
    for (key, value) in suite_env {
        command.env(key, value);
    }
    // Runner-owned variables are applied last so neither the suite contract nor
    // a toolchain bundle can redirect scratch, metadata, or network policy.
    command
        .env("PATH", "")
        .env("HOME", root.join("home"))
        .env("CARGO_HOME", root.join("cargo-home"))
        .env("TMPDIR", root.join("tmp"))
        .env("CARGO_TARGET_DIR", target)
        .env("CARGO_MANIFEST_DIR", workspace)
        .env("CARGO_NET_OFFLINE", "true")
        .env("CARGO_NET_GIT_FETCH_WITH_CLI", "false");
}

#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub struct ObservedSignal(pub i32);
impl ObservedSignal {
    pub fn status(self) -> i32 {
        128 + self.0
    }
}
pub struct SignalGuard {
    first: Arc<AtomicI32>,
    handle: Handle,
    watcher: Option<thread::JoinHandle<()>>,
}
impl SignalGuard {
    pub fn install() -> Result<Self, String> {
        let first = Arc::new(AtomicI32::new(0));
        let state = first.clone();
        let mut signals = Signals::new([SIGHUP, SIGINT, SIGTERM]).map_err(|e| e.to_string())?;
        let handle = signals.handle();
        let watcher = thread::spawn(move || {
            for signal in signals.forever() {
                if matches!(signal, SIGHUP | SIGINT | SIGTERM) {
                    let _ = state.compare_exchange(0, signal, Ordering::SeqCst, Ordering::SeqCst);
                    break;
                }
            }
        });
        Ok(Self {
            first,
            handle,
            watcher: Some(watcher),
        })
    }
    pub fn observed(&self) -> Option<ObservedSignal> {
        match self.first.load(Ordering::SeqCst) {
            0 => None,
            signal => Some(ObservedSignal(signal)),
        }
    }
}
impl Drop for SignalGuard {
    fn drop(&mut self) {
        self.handle.close();
        if let Some(thread) = self.watcher.take() {
            let _ = thread.join();
        }
    }
}

#[cfg(unix)]
pub fn set_process_group(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    command.process_group(0);
}
#[cfg(not(unix))]
pub fn set_process_group(_command: &mut Command) {}

#[cfg(unix)]
pub fn send_group(pgid: i32, signal: i32) -> Result<(), String> {
    if pgid <= 0 {
        return Err("invalid process group".into());
    }
    let result = unsafe { kill(-(pgid as c_int), signal as c_int) };
    if result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(3) {
        Ok(())
    } else {
        Err(format!(
            "could not signal process group {pgid}: {}",
            std::io::Error::last_os_error()
        ))
    }
}
#[cfg(not(unix))]
pub fn send_group(_pgid: i32, _signal: i32) -> Result<(), String> {
    Err("process groups are unsupported".into())
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
pub fn collect_process_groups(root: i32) -> Result<BTreeSet<i32>, String> {
    if root <= 0 {
        return Err("invalid process root".into());
    }
    let output = Command::new("/bin/ps")
        .args(["-axo", "pid=,ppid=,pgid="])
        .output()
        .map_err(|error| format!("could not enumerate processes with /bin/ps: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "/bin/ps failed while enumerating processes: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let text = String::from_utf8(output.stdout)
        .map_err(|error| format!("/bin/ps emitted non-UTF-8 process data: {error}"))?;
    let mut children = BTreeMap::<i32, Vec<i32>>::new();
    let mut groups = BTreeMap::<i32, i32>::new();
    for line in text.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() != 3 {
            return Err(format!("malformed /bin/ps process row: {line:?}"));
        }
        let pid = fields[0]
            .parse::<i32>()
            .map_err(|_| format!("malformed process id: {:?}", fields[0]))?;
        let ppid = fields[1]
            .parse::<i32>()
            .map_err(|_| format!("malformed parent process id: {:?}", fields[1]))?;
        let pgid = fields[2]
            .parse::<i32>()
            .map_err(|_| format!("malformed process group id: {:?}", fields[2]))?;
        if pid <= 0 || pgid <= 0 {
            return Err(format!("invalid process row: {line:?}"));
        }
        children.entry(ppid).or_default().push(pid);
        groups.insert(pid, pgid);
    }
    let mut pending = vec![root];
    let mut seen = BTreeSet::new();
    let mut result = BTreeSet::new();
    while let Some(pid) = pending.pop() {
        if !seen.insert(pid) {
            continue;
        }
        if let Some(pgid) = groups.get(&pid) {
            result.insert(*pgid);
        }
        if let Some(descendants) = children.get(&pid) {
            pending.extend(descendants);
        }
    }
    Ok(result)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn collect_process_groups(_root: i32) -> Result<BTreeSet<i32>, String> {
    Err("process inspection is unsupported on this host".into())
}

fn own_process_group() -> Result<i32, String> {
    let pid = rustix::process::getpid();
    rustix::process::getpgid(Some(pid))
        .map(|group| group.as_raw_nonzero().get())
        .map_err(|error| format!("could not inspect runner process group: {error}"))
}

pub fn send_process_tree(root: i32, groups: &mut BTreeSet<i32>, signal: i32) -> Result<(), String> {
    groups.extend(collect_process_groups(root)?);
    let mut first_error = send_group(root, signal).err();
    for group in groups.iter().copied().filter(|group| *group != root) {
        if let Err(error) = send_group(group, signal) {
            first_error.get_or_insert(error);
        }
    }
    first_error.map_or(Ok(()), Err)
}

pub fn drain_process_groups(groups: &BTreeSet<i32>) -> Result<(), String> {
    let own_group = own_process_group()?;
    let groups: Vec<_> = groups
        .iter()
        .copied()
        .filter(|group| *group != own_group)
        .collect();
    let mut first_error = None;
    let grace = Instant::now() + Duration::from_secs(5);
    while Instant::now() < grace {
        let mut live = false;
        for group in groups.iter().copied() {
            match group_exists(group) {
                Ok(true) => {
                    live = true;
                    if let Err(error) = send_group(group, SIGTERM) {
                        first_error.get_or_insert(error);
                    }
                }
                Ok(false) => {}
                Err(error) => {
                    live = true;
                    first_error.get_or_insert(error);
                }
            }
        }
        if !live {
            return first_error.map_or(Ok(()), Err);
        }
        thread::sleep(Duration::from_millis(20));
    }
    for group in groups.iter().copied() {
        if let Err(error) = send_group(group, 9) {
            first_error.get_or_insert(error);
        }
    }
    let deadline = Instant::now() + Duration::from_secs(1);
    while Instant::now() < deadline {
        let live = groups
            .iter()
            .copied()
            .any(|group| group_exists(group).unwrap_or(true));
        if !live {
            return first_error.map_or(Ok(()), Err);
        }
        thread::sleep(Duration::from_millis(20));
    }
    Err(match first_error {
        Some(error) => format!("owned process groups did not become quiescent: {error}"),
        None => "owned process groups did not become quiescent".into(),
    })
}

#[cfg(unix)]
fn group_exists(pgid: i32) -> Result<bool, String> {
    if pgid <= 0 {
        return Err("invalid process group".into());
    }
    let result = unsafe { kill(-(pgid as c_int), 0) };
    if result == 0 {
        Ok(true)
    } else {
        let error = std::io::Error::last_os_error();
        match error.raw_os_error() {
            Some(3) => Ok(false),
            Some(1) => Ok(true),
            _ => Err(format!("could not inspect process group {pgid}: {error}")),
        }
    }
}
#[cfg(not(unix))]
fn group_exists(_pgid: i32) -> Result<bool, String> {
    Err("process groups are unsupported".into())
}

pub fn status_code(status: ExitStatus) -> Result<i32, String> {
    if let Some(code) = status.code() {
        return Ok(code);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            return Ok(128 + signal);
        }
    }
    Err("child has no usable exit status".into())
}

pub fn sha256_digest(path: &Path) -> Result<String, String> {
    sha256_file(path).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn generated_names_are_stable_and_injective() {
        assert_eq!(
            generated_name("buck2", "b2n1:p=a;o=//:x;b=one"),
            "buck2_62_32_6e_31_3a_70_3d_61_3b_6f_3d_2f_2f_3a_78_3b_62_3d_6f_6e_65"
        );
        assert_ne!(
            generated_name("buck2", "a_5f"),
            generated_name("buck2", "a%5f")
        );
    }
    #[test]
    fn safe_paths_reject_traversal() {
        assert!(safe_relative("../x", "cwd").is_err());
        assert!(safe_relative("work/x", "cwd").is_ok());
    }
    #[test]
    fn toml_paths_are_escaped_as_single_basic_strings() {
        assert_eq!(toml_basic_string("/tmp/a\"b\\c"), "\"/tmp/a\\\"b\\\\c\"");
        assert_eq!(toml_basic_string("line\nvalue"), "\"line\\nvalue\"");
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn owned_process_group_drain_terminates_descendants() {
        use std::process::Command;
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 60"]);
        set_process_group(&mut command);
        let mut child = command.spawn().expect("spawn owned process group");
        let root = child.id() as i32;
        let mut groups = collect_process_groups(root).expect("enumerate owned process groups");
        assert!(
            !groups.is_empty(),
            "owned process group must contain its leader"
        );
        send_process_tree(root, &mut groups, SIGTERM).expect("signal owned process group");
        child.wait().expect("wait owned process group leader");
        drain_process_groups(&groups).expect("drain owned process group");
    }
}
