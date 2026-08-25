//! Schema-v2 generic manifest, semantic IDs, and metadata normalization.
use crate::{json, ContractError, ContractResult};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::Path,
};

pub const SCHEMA_VERSION: u8 = 2;
pub const ID_PREFIX: &str = "b2n1:";
const UNRESERVED: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~";

fn encode(value: &str) -> String {
    value
        .as_bytes()
        .iter()
        .map(|b| {
            if UNRESERVED.contains(b) {
                (*b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}
pub fn semantic_id(package: &str, owner: &str, binary: &str) -> ContractResult<String> {
    if package.is_empty() || owner.is_empty() || binary.is_empty() {
        return Err(ContractError::invalid(
            "semantic ID components must be non-empty",
        ));
    }
    Ok(format!(
        "{ID_PREFIX}p={};o={};b={}",
        encode(package),
        encode(owner),
        encode(binary)
    ))
}
pub fn decode_semantic_id(value: &str) -> ContractResult<(String, String, String)> {
    if !value.starts_with(ID_PREFIX) {
        return Err(ContractError::invalid("unsupported semantic ID prefix"));
    }
    let fields: Vec<_> = value[ID_PREFIX.len()..].split(';').collect();
    if fields.len() != 3
        || !fields
            .iter()
            .zip(["p=", "o=", "b="])
            .all(|(a, p)| a.starts_with(p))
    {
        return Err(ContractError::invalid("semantic ID fields are invalid"));
    }
    let mut values = Vec::new();
    for field in fields {
        let encoded = &field[2..];
        if encoded.is_empty() {
            return Err(ContractError::invalid(
                "semantic ID components must be non-empty",
            ));
        }
        let mut bytes = Vec::new();
        let mut chars = encoded.as_bytes().iter().copied();
        while let Some(byte) = chars.next() {
            if byte == b'%' {
                let hi = chars
                    .next()
                    .ok_or_else(|| ContractError::invalid("truncated semantic ID escape"))?;
                let lo = chars
                    .next()
                    .ok_or_else(|| ContractError::invalid("truncated semantic ID escape"))?;
                let hex = |x| match x {
                    b'0'..=b'9' => Some(x - b'0'),
                    b'A'..=b'F' => Some(x - b'A' + 10),
                    _ => None,
                };
                let decoded = hex(hi)
                    .and_then(|h| hex(lo).map(|l| h * 16 + l))
                    .ok_or_else(|| ContractError::invalid("invalid semantic ID escape"))?;
                if UNRESERVED.contains(&decoded) {
                    return Err(ContractError::invalid("non-canonical semantic ID escape"));
                }
                bytes.push(decoded);
            } else if UNRESERVED.contains(&byte) {
                bytes.push(byte);
            } else {
                return Err(ContractError::invalid("unsafe semantic ID byte"));
            }
        }
        values.push(
            String::from_utf8(bytes)
                .map_err(|_| ContractError::invalid("semantic ID is not UTF-8"))?,
        );
    }
    let result = (values[0].clone(), values[1].clone(), values[2].clone());
    if semantic_id(&result.0, &result.1, &result.2)? != value {
        return Err(ContractError::invalid("semantic ID is not canonical"));
    }
    Ok(result)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PathRecord {
    pub source: String,
    pub destination: String,
    pub kind: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GenericRecord {
    pub package_identity: String,
    pub owner_label: String,
    pub binary_identity: String,
    pub display_name: String,
    pub target_kind: String,
    pub executable: PathRecord,
    pub runtime: Vec<PathRecord>,
    pub generated_outputs: Vec<String>,
    pub cwd: String,
    pub platform: String,
    pub environment: BTreeMap<String, String>,
    #[serde(default)]
    pub id: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ManifestV2 {
    pub schema_version: u8,
    pub records: Vec<GenericRecord>,
}

fn safe_path(value: &str, field: &str) -> ContractResult<()> {
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
fn overlaps(a: &str, b: &str) -> bool {
    a == b || a.starts_with(&(b.to_owned() + "/")) || b.starts_with(&(a.to_owned() + "/"))
}
fn valid_owner(owner: &str) -> bool {
    owner.starts_with("//")
        && !owner.contains(char::is_whitespace)
        && owner[2..].split('/').all(|p| !p.is_empty())
}

impl ManifestV2 {
    pub fn validate(&self) -> ContractResult<Self> {
        if self.schema_version != SCHEMA_VERSION || self.records.is_empty() {
            return Err(ContractError::invalid(
                "generic manifest must have schema_version 2 and non-empty records",
            ));
        }
        let mut identities = BTreeSet::new();
        let mut sources = BTreeSet::new();
        let mut destinations = Vec::new();
        let mut normalized = Vec::new();
        for (i, record) in self.records.iter().enumerate() {
            let prefix = format!("records[{i}]");
            if record.package_identity.is_empty()
                || record.owner_label.is_empty()
                || record.binary_identity.is_empty()
                || record.display_name.is_empty()
                || record.target_kind.is_empty()
                || !valid_owner(&record.owner_label)
            {
                return Err(ContractError::invalid(format!(
                    "{prefix} identity fields are invalid"
                )));
            }
            let identity = (
                &record.package_identity,
                &record.owner_label,
                &record.binary_identity,
            );
            if !identities.insert(identity) {
                return Err(ContractError::invalid("duplicate semantic identity"));
            }
            let id = semantic_id(
                &record.package_identity,
                &record.owner_label,
                &record.binary_identity,
            )?;
            if let Some(given) = &record.id {
                if given != &id {
                    return Err(ContractError::invalid(
                        "record id does not match semantic identity",
                    ));
                }
            }
            let mut paths = Vec::new();
            safe_path(&record.executable.source, "executable.source")?;
            safe_path(&record.executable.destination, "executable.destination")?;
            if record.executable.kind != "regular_file"
                || !sources.insert(record.executable.source.clone())
            {
                return Err(ContractError::invalid(
                    "executable must be a unique regular file",
                ));
            }
            paths.push(record.executable.destination.clone());
            let mut runtime = Vec::new();
            for item in &record.runtime {
                safe_path(&item.source, "runtime.source")?;
                safe_path(&item.destination, "runtime.destination")?;
                if item.kind != "regular_file" || sources.contains(&item.source) {
                    return Err(ContractError::invalid(
                        "runtime entries must be regular files distinct from executables",
                    ));
                }
                paths.push(item.destination.clone());
                runtime.push(item.clone());
            }
            safe_path(&record.cwd, "cwd")?;
            paths.push(record.cwd.clone());
            for (pos, path) in paths.iter().enumerate() {
                if path == "manifest.json"
                    || path.starts_with("manifest.json/")
                    || destinations.iter().any(|old: &String| overlaps(old, path))
                {
                    return Err(ContractError::invalid(
                        "manifest paths overlap or are adapter-owned",
                    ));
                }
                destinations.push(path.clone());
                let _ = pos;
            }
            if record.generated_outputs.len() > 0 {
                return Err(ContractError::invalid("generated outputs are unsupported"));
            }
            if record.platform.is_empty() || record.platform.chars().any(char::is_whitespace) {
                return Err(ContractError::invalid(
                    "platform must be opaque and whitespace-free",
                ));
            }
            for (name, value) in &record.environment {
                if name.is_empty()
                    || !name.chars().enumerate().all(|(n, c)| {
                        c == '_' || c.is_ascii_alphanumeric() && (n > 0 || c.is_ascii_alphabetic())
                    })
                    || name.starts_with("BUCK2_NEXTEST_")
                    || value.contains('\0')
                {
                    return Err(ContractError::invalid("invalid environment"));
                }
            }
            normalized.push(GenericRecord {
                id: Some(id),
                runtime,
                ..record.clone()
            });
        }
        Ok(Self {
            schema_version: SCHEMA_VERSION,
            records: normalized,
        })
    }
}
pub fn load_and_validate(path: impl AsRef<Path>) -> ContractResult<ManifestV2> {
    Ok(json::decode_as::<ManifestV2>(&fs::read(path)?)?.validate()?)
}
