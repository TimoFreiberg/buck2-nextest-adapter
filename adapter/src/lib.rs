//! Shared contracts and small utilities for the Rust Buck2/nextest adapter.

pub mod digest;
mod error;
pub mod export;
pub mod json;
pub mod manifest_v1;
pub mod manifest_v2;
pub mod nextest_v2;
pub mod report;

pub use error::{ContractError, ContractResult};

#[cfg(test)]
mod contract_tests {
    use super::manifest_v2::*;
    fn path(source: &str) -> PathRecord {
        PathRecord {
            source: source.into(),
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
            executable: path("bin/source"),
            cwd: "work".into(),
            platform: "x86_64-unknown-linux-gnu".into(),
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
    fn schema_v2_rejects_unsafe_cwds_and_cross_package_overlaps() {
        for cwd in ["work\"quote", "work\nline", "work\u{0007}bell"] {
            let mut candidate = record("one");
            candidate.cwd = cwd.into();
            assert!(
                ManifestV2 {
                    schema_version: 2,
                    records: vec![candidate],
                }
                .validate()
                .is_err(),
                "cwd should be rejected: {cwd:?}"
            );
        }

        let mut nested = record("two");
        nested.package_identity = "other".into();
        nested.binary_identity = "two".into();
        nested.display_name = "two".into();
        nested.cwd = "work/nested".into();
        nested.executable = path("bin/source-two");
        assert!(ManifestV2 {
            schema_version: 2,
            records: vec![record("one"), nested],
        }
        .validate()
        .is_err());

        let mut second_record = record("two");
        second_record.package_identity = "other".into();
        second_record.binary_identity = "two".into();
        second_record.display_name = "two".into();
        second_record.cwd = "work/bin".into();
        second_record.executable = path("bin/source-two");
        assert!(ManifestV2 {
            schema_version: 2,
            records: vec![record("one"), second_record],
        }
        .validate()
        .is_err());
    }

    #[test]
    fn schema_v2_rejects_removed_runtime_and_generated_output_fields() {
        for field in ["runtime", "generated_outputs"] {
            let json = format!(
                r#"{{"schema_version":2,"records":[{{"package_identity":"pkg","owner_label":"//tests:unit","binary_identity":"one","display_name":"one","target_kind":"test","executable":{{"source":"bin/source","kind":"regular_file"}},"{field}":[],"cwd":"work","platform":"x86_64-unknown-linux-gnu"}}]}}"#
            );
            assert!(serde_json::from_str::<ManifestV2>(&json).is_err(), "{field} must remain unknown");
        }
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
        duplicate.executable = path("bin/source-two");
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
