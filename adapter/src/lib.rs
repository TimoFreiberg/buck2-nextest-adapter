//! Shared contracts and small utilities for the Rust Buck2/nextest adapter.

pub mod digest;
mod error;
pub mod export;
pub mod json;
pub mod manifest_v1;
pub mod manifest_v2;
pub mod report;

pub use error::{ContractError, ContractResult};

#[cfg(test)]
mod contract_tests {
    use super::manifest_v2::*;
    use std::collections::BTreeMap;

    fn path(source: &str, destination: &str) -> PathRecord {
        PathRecord {
            source: source.into(),
            destination: destination.into(),
            kind: "regular_file".into(),
        }
    }
    fn record(binary: &str) -> GenericRecord {
        GenericRecord {
            package_identity: "pkg".into(),
            owner_label: "//tests:unit".into(),
            binary_identity: binary.into(),
            display_name: binary.into(),
            target_kind: "test".into(),
            executable: path("bin/source", "bin/test"),
            runtime: vec![],
            generated_outputs: vec![],
            cwd: "work".into(),
            platform: "x86_64-unknown-linux-gnu".into(),
            environment: BTreeMap::new(),
            id: None,
        }
    }

    #[test]
    fn semantic_id_round_trip_and_canonical_rejection() {
        let id = semantic_id("package name", "//tests:unit", "bin/α").unwrap();
        assert_eq!(
            decode_semantic_id(&id).unwrap(),
            ("package name".into(), "//tests:unit".into(), "bin/α".into())
        );
        assert!(decode_semantic_id(
            &id.replace("%20", "%20")
                .replace("package%20name", "package%20name")
        )
        .is_ok());
        assert!(
            decode_semantic_id("b2n1:p=package%20name;o=%2f%2Ftests%3Aunit;b=bin%2F%CE%B1")
                .is_err()
        );
    }

    #[test]
    fn schema_v2_positive_and_negative_validation() {
        let manifest = ManifestV2 {
            schema_version: 2,
            records: vec![record("one")],
        };
        let normalized = manifest.validate().unwrap();
        assert!(normalized.records[0]
            .id
            .as_ref()
            .unwrap()
            .starts_with("b2n1:"));
        let mut duplicate = record("two");
        duplicate.executable.destination = "bin/test".into();
        assert!(ManifestV2 {
            schema_version: 2,
            records: vec![record("one"), duplicate]
        }
        .validate()
        .is_err());
        assert!(ManifestV2 {
            schema_version: 1,
            records: vec![record("one")]
        }
        .validate()
        .is_err());
    }
}
