//! Schema-v1 artifact manifest contract.
use crate::{json, ContractError, ContractResult};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TestCase {
    pub name: String,
    pub ignored: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ArtifactIdentity {
    pub package_name: String,
    pub binary_id: String,
    pub binary_name: String,
    pub target_kind: String,
    pub test_cases: Vec<TestCase>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ManifestPaths {
    pub executable: String,
    pub working_directory: String,
    pub runtime_inputs: Vec<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Platform {
    pub target_triple: String,
    pub target_features: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Build {
    pub generated_outputs: Vec<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ManifestV1 {
    pub schema_version: u8,
    pub artifact: ArtifactIdentity,
    pub paths: ManifestPaths,
    pub environment: BTreeMap<String, String>,
    pub platform: Platform,
    pub build: Build,
}

fn relative(value: &str, field: &str) -> ContractResult<()> {
    if value.is_empty()
        || value.starts_with('/')
        || value.contains('\\')
        || value.contains('\0')
        || value
            .split('/')
            .any(|p| p.is_empty() || p == "." || p == "..")
    {
        return Err(ContractError::invalid(format!(
            "{field} must be a normalized relative POSIX path"
        )));
    }
    Ok(())
}
fn env_name(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c == '_' || c.is_ascii_alphabetic())
        && chars.all(|c| c == '_' || c.is_ascii_alphanumeric())
}

impl ManifestV1 {
    pub fn validate(&self, root: Option<&Path>) -> ContractResult<ValidatedManifestV1> {
        if self.schema_version != 1 {
            return Err(ContractError::invalid(
                "unsupported manifest schema version",
            ));
        }
        if self.artifact.package_name.is_empty()
            || self.artifact.binary_id.is_empty()
            || self.artifact.binary_name.is_empty()
            || self.artifact.target_kind != "test"
        {
            return Err(ContractError::invalid(
                "manifest artifact identity is invalid",
            ));
        }
        if self.artifact.test_cases.is_empty() {
            return Err(ContractError::invalid(
                "artifact.test_cases must not be empty",
            ));
        }
        let mut names = std::collections::BTreeSet::new();
        for case in &self.artifact.test_cases {
            if case.name.is_empty() || !names.insert(&case.name) {
                return Err(ContractError::invalid(
                    "test case names must be non-empty and unique",
                ));
            }
        }
        relative(&self.paths.executable, "paths.executable")?;
        relative(&self.paths.working_directory, "paths.working_directory")?;
        let mut runtime_paths = Vec::new();
        for path in &self.paths.runtime_inputs {
            relative(path, "paths.runtime_inputs")?;
            if !runtime_paths.iter().all(|old: &String| old != path) {
                return Err(ContractError::invalid(
                    "runtime_inputs contains a duplicate path",
                ));
            }
            runtime_paths.push(path.clone());
        }
        if self.paths.executable == self.paths.working_directory
            || self
                .paths
                .executable
                .starts_with(&(self.paths.working_directory.clone() + "/"))
            || self
                .paths
                .working_directory
                .starts_with(&(self.paths.executable.clone() + "/"))
        {
            return Err(ContractError::invalid(
                "executable and working directory overlap",
            ));
        }
        for (name, value) in &self.environment {
            if !env_name(name)
                || name == "PATH"
                || name.starts_with("BUCK2_NEXTEST_")
                || value.contains('\0')
            {
                return Err(ContractError::invalid(format!(
                    "invalid or adapter-owned environment variable: {name}"
                )));
            }
        }
        if !self.build.generated_outputs.is_empty() {
            return Err(ContractError::invalid(
                "generated_outputs must be empty in schema version 1",
            ));
        }
        let (executable, working_directory, runtime) = if let Some(root) = root {
            let e = rooted(root, &self.paths.executable)?;
            let w = rooted(root, &self.paths.working_directory)?;
            let r = self
                .paths
                .runtime_inputs
                .iter()
                .map(|p| rooted(root, p))
                .collect::<ContractResult<Vec<_>>>()?;
            (Some(e), Some(w), r)
        } else {
            (None, None, Vec::new())
        };
        Ok(ValidatedManifestV1 {
            manifest: self.clone(),
            executable,
            working_directory,
            runtime_inputs: runtime,
        })
    }
}
fn rooted(root: &Path, value: &str) -> ContractResult<PathBuf> {
    relative(value, "path")?;
    let path = root.join(value);
    if path.is_symlink() {
        return Err(ContractError::invalid(
            "manifest path must not traverse a symlink",
        ));
    }
    Ok(path)
}

#[derive(Debug, Clone)]
pub struct ValidatedManifestV1 {
    pub manifest: ManifestV1,
    pub executable: Option<PathBuf>,
    pub working_directory: Option<PathBuf>,
    pub runtime_inputs: Vec<PathBuf>,
}

pub fn load_and_validate(
    path: impl AsRef<Path>,
    root: Option<&Path>,
) -> ContractResult<ValidatedManifestV1> {
    let bytes = fs::read(path)?;
    let manifest: ManifestV1 = json::decode_as(&bytes)?;
    manifest.validate(root)
}

#[derive(Debug, Clone)]
pub struct EmitManifest {
    pub output: PathBuf,
    pub artifact: PathBuf,
    pub runtime_input: String,
    pub runtime_source: PathBuf,
    pub runtime_environment: String,
    pub target_triple: String,
}
pub fn emit_manifest(options: &EmitManifest) -> ContractResult<()> {
    if !options.artifact.is_file()
        || options.artifact.is_symlink()
        || !options.runtime_source.is_file()
        || options.runtime_source.is_symlink()
    {
        return Err(ContractError::invalid(
            "artifact and runtime source must be regular files",
        ));
    }
    relative(&options.runtime_input, "runtime_input")?;
    let manifest = ManifestV1 {
        schema_version: 1,
        artifact: ArtifactIdentity {
            package_name: "buck2-nextest-buck-artifact".into(),
            binary_id: "buck2_nextest_rust_test".into(),
            binary_name: "buck2_nextest_rust_test".into(),
            target_kind: "test".into(),
            test_cases: vec![],
        },
        paths: ManifestPaths {
            executable: "bin/buck2_nextest_rust_test".into(),
            working_directory: "work".into(),
            runtime_inputs: vec![options.runtime_input.clone()],
        },
        environment: [(
            "BUCK2_ARTIFACT_RUNTIME".into(),
            options.runtime_environment.clone(),
        )]
        .into_iter()
        .collect(),
        platform: Platform {
            target_triple: options.target_triple.clone(),
            target_features: "unknown".into(),
        },
        build: Build {
            generated_outputs: vec![],
        },
    };
    let bytes = serde_json::to_vec_pretty(&manifest)?;
    if let Some(parent) = options.output.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&options.output, [bytes.as_slice(), b"\n"].concat())?;
    Ok(())
}
