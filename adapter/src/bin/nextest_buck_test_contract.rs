//! Schema-v2 generic test contract executable.
//!
//! Contract fixture (not a runner): validates that Buck supplied a declared
//! generic manifest and a regular-file provider closure, then prints the
//! observable provider/dispatch markers and the record IDs as JSON. It never
//! spawns a process and contains no runner or lifecycle logic.

use buck2_nextest_adapter_contract::manifest_v2::load_and_validate;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};

const PROVIDER_LINE: &str = "buck2-nextest-contract: provider=NextestBuckTestBinaryInfo";
const DISPATCH_LINE: &str = "buck2-nextest-contract: dispatch=contract-validation-only";

struct Args {
    manifest: PathBuf,
    record_count: usize,
    declared_inputs: Vec<PathBuf>,
}

fn fail(message: impl AsRef<str>) -> ! {
    eprintln!("nextest contract: {}", message.as_ref());
    std::process::exit(2)
}

/// Take the value for `flag`, rejecting a missing value or a value that is
/// itself another option.
fn take_value(flag: &str, args: &mut impl Iterator<Item = OsString>) -> Result<OsString, String> {
    let value = args
        .next()
        .ok_or_else(|| format!("{flag} requires a value"))?;
    if value.to_string_lossy().starts_with("--") {
        return Err(format!("{flag} requires a value"));
    }
    Ok(value)
}

/// Strict command-line parsing: unknown options, missing required options,
/// missing values, and repeated `--manifest`/`--record-count` are rejected.
/// `--declared-input` is repeatable by design: the Buck rule declares the
/// same closure file once per consuming record, so shared runtime files
/// legitimately appear more than once.
fn parse_args(args: impl Iterator<Item = OsString>) -> Result<Args, String> {
    let mut iter = args.into_iter();
    let mut manifest = None;
    let mut record_count = None;
    let mut declared_inputs = Vec::new();
    while let Some(arg) = iter.next() {
        match arg.to_string_lossy().as_ref() {
            "--manifest" => {
                if manifest.is_some() {
                    return Err("--manifest specified more than once".into());
                }
                manifest = Some(PathBuf::from(take_value("--manifest", &mut iter)?));
            }
            "--record-count" => {
                if record_count.is_some() {
                    return Err("--record-count specified more than once".into());
                }
                let value = take_value("--record-count", &mut iter)?;
                let value = value
                    .to_str()
                    .and_then(|value| value.parse::<usize>().ok())
                    .ok_or_else(|| "--record-count must be a non-negative integer".to_string())?;
                record_count = Some(value);
            }
            "--declared-input" => {
                declared_inputs.push(PathBuf::from(take_value("--declared-input", &mut iter)?));
            }
            other => return Err(format!("unknown option: {other}")),
        }
    }
    Ok(Args {
        manifest: manifest.ok_or_else(|| "--manifest is required".to_string())?,
        record_count: record_count.ok_or_else(|| "--record-count is required".to_string())?,
        declared_inputs,
    })
}

/// A declared provider input must be an existing regular file; symlinks are
/// rejected (metadata is read without following links).
fn check_declared_input(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        format!("declared provider input cannot be inspected: {path:?}: {error}")
    })?;
    if !metadata.file_type().is_file() {
        return Err(format!(
            "declared provider input is not a regular file: {path:?}"
        ));
    }
    Ok(())
}

/// Format record IDs as a JSON array, matching the Python fixture's
/// `json.dumps([...])` separators.
fn format_ids<'a>(ids: impl Iterator<Item = &'a str>) -> String {
    let mut formatted = String::from("[");
    for (position, id) in ids.enumerate() {
        if position > 0 {
            formatted.push_str(", ");
        }
        formatted
            .push_str(&serde_json::to_string(id).expect("record IDs serialize as JSON strings"));
    }
    formatted.push(']');
    formatted
}

fn main() {
    let args = parse_args(std::env::args_os().skip(1)).unwrap_or_else(|message| fail(message));
    let manifest = load_and_validate(&args.manifest)
        .unwrap_or_else(|error| fail(format!("invalid generic manifest: {error}")));
    if args.declared_inputs.is_empty() {
        fail("no declared provider inputs");
    }
    for path in &args.declared_inputs {
        check_declared_input(path).unwrap_or_else(|message| fail(message));
    }
    if manifest.records.len() != args.record_count {
        fail(format!(
            "expected {} records, got {}",
            args.record_count,
            manifest.records.len()
        ));
    }
    println!("{PROVIDER_LINE}");
    println!("buck2-nextest-contract: records={}", manifest.records.len());
    println!("{DISPATCH_LINE}");
    let ids = manifest.records.iter().map(|record| {
        record
            .id
            .as_deref()
            .unwrap_or_else(|| fail("validated record is missing its semantic ID"))
    });
    println!("{}", format_ids(ids));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    fn parse(values: &[&str]) -> Result<Args, String> {
        parse_args(values.iter().map(OsString::from))
    }

    #[test]
    fn parse_accepts_the_contract_invocation() {
        let args = parse(&[
            "--manifest",
            "manifest.json",
            "--record-count",
            "2",
            "--declared-input",
            "bin/one",
            "--declared-input",
            "bin/two",
        ])
        .unwrap();
        assert_eq!(args.manifest, PathBuf::from("manifest.json"));
        assert_eq!(args.record_count, 2);
        assert_eq!(
            args.declared_inputs,
            vec![PathBuf::from("bin/one"), PathBuf::from("bin/two")]
        );
    }

    #[test]
    fn parse_accepts_repeated_declared_inputs_for_shared_closure_files() {
        // The Buck rule declares the same runtime closure file once per
        // consuming record, so repeated --declared-input values are valid.
        let args = parse(&[
            "--manifest",
            "manifest.json",
            "--record-count",
            "2",
            "--declared-input",
            "executable",
            "--declared-input",
            "runtime/resource",
            "--declared-input",
            "runtime/resource",
        ])
        .unwrap();
        assert_eq!(args.declared_inputs.len(), 3);
    }

    #[test]
    fn parse_rejects_duplicates_unknown_and_missing() {
        assert!(parse(&["--manifest", "a", "--manifest", "b"]).is_err());
        assert!(parse(&["--record-count", "1", "--record-count", "2"]).is_err());
        assert!(parse(&["--manifest", "a", "--record-count", "1", "--unknown"]).is_err());
        assert!(parse(&["--record-count", "1", "--declared-input", "a"]).is_err());
        assert!(parse(&["--manifest", "a", "--declared-input", "a"]).is_err());
        assert!(parse(&["--manifest"]).is_err());
        assert!(parse(&["--manifest", "--record-count", "1"]).is_err());
        assert!(parse(&["--manifest", "a", "--record-count", "x"]).is_err());
        assert!(parse(&["--manifest", "a", "--record-count", "-1"]).is_err());
        assert!(parse(&["positional"]).is_err());
    }

    #[test]
    fn format_ids_matches_the_python_observable_array() {
        assert_eq!(
            format_ids(
                [
                    "b2n1:p=alpha;o=%2F%2Ftests%3Aunit;b=one",
                    "b2n1:p=beta;o=%2F%2Ftests%3Aunit;b=two",
                ]
                .into_iter()
            ),
            "[\"b2n1:p=alpha;o=%2F%2Ftests%3Aunit;b=one\", \"b2n1:p=beta;o=%2F%2Ftests%3Aunit;b=two\"]"
        );
        assert_eq!(format_ids(std::iter::empty()), "[]");
    }

    #[test]
    fn validated_records_yield_the_exact_ids_array() {
        let dir = tempfile::tempdir().unwrap();
        let manifest_path = dir.path().join("manifest.json");
        fs::write(
            &manifest_path,
            r#"{
                "schema_version": 2,
                "records": [
                    {
                        "package_identity": "alpha",
                        "owner_label": "//tests:unit",
                        "binary_identity": "one",
                        "display_name": "one",
                        "target_kind": "test",
                        "executable": {"source": "bin/source-one", "destination": "work/bin/one", "kind": "regular_file"},
                        "runtime": [],
                        "generated_outputs": [],
                        "cwd": "work",
                        "platform": "x86_64-unknown-linux-gnu"
                    },
                    {
                        "package_identity": "beta",
                        "owner_label": "//tests:unit",
                        "binary_identity": "two",
                        "display_name": "two",
                        "target_kind": "test",
                        "executable": {"source": "bin/source-two", "destination": "other-work/two/bin/two", "kind": "regular_file"},
                        "runtime": [],
                        "generated_outputs": [],
                        "cwd": "other-work/two",
                        "platform": "x86_64-unknown-linux-gnu"
                    }
                ]
            }"#,
        )
        .unwrap();
        let manifest = load_and_validate(&manifest_path).unwrap();
        assert_eq!(manifest.records.len(), 2);
        let ids = manifest
            .records
            .iter()
            .map(|record| record.id.as_deref().unwrap());
        assert_eq!(
            format_ids(ids),
            "[\"b2n1:p=alpha;o=%2F%2Ftests%3Aunit;b=one\", \"b2n1:p=beta;o=%2F%2Ftests%3Aunit;b=two\"]"
        );
    }

    #[test]
    fn manifest_duplicate_json_keys_are_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let manifest_path = dir.path().join("manifest.json");
        fs::write(
            &manifest_path,
            r#"{"schema_version":2,"schema_version":2,"records":[{"package_identity":"alpha","owner_label":"//tests:unit","binary_identity":"one","display_name":"one","target_kind":"test","executable":{"source":"bin/source-one","destination":"bin/one","kind":"regular_file"},"runtime":[],"generated_outputs":[],"cwd":"work","platform":"x86_64-unknown-linux-gnu","environment":{}}]}"#,
        )
        .unwrap();
        assert!(load_and_validate(&manifest_path).is_err());
    }
}
