use std::{
    env, fs,
    path::{Path, PathBuf},
    process,
};

const PROTO_ROOT: &str = "../proto/upstream";
const PROTOS: &[&str] = &["buck2_test_proto/test.proto"];

fn main() {
    let output = env::args_os().nth(1).map(PathBuf::from).unwrap_or_else(|| {
        eprintln!("usage: buck2-nextest-executor-codegen OUTPUT_DIR");
        process::exit(2);
    });
    if let Err(error) = generate(&output) {
        eprintln!("protocol generation failed: {error}");
        process::exit(1);
    }
}

fn generate(output: &Path) -> Result<(), Box<dyn std::error::Error>> {
    fs::create_dir_all(output)?;
    let protoc = protoc_bin_vendored::protoc_bin_path().map_err(|error| {
        format!("locked protoc-bin-vendored has no binary for this platform: {error}")
    })?;
    let include = protoc_bin_vendored::include_path().map_err(|error| {
        format!("locked protoc-bin-vendored has no include directory for this platform: {error}")
    })?;
    env::set_var("PROTOC", protoc);
    let proto_root = Path::new(PROTO_ROOT);
    let include_paths = vec![
        proto_root.to_path_buf(),
        proto_root.join("buck2_data"),
        proto_root.join("buck2_host_sharing_proto"),
        proto_root.join("buck2_test_proto"),
        include,
    ];
    tonic_prost_build::configure()
        .build_client(true)
        .build_server(true)
        .out_dir(output)
        .compile_protos(
            &PROTOS
                .iter()
                .map(|path| proto_root.join(path))
                .collect::<Vec<_>>(),
            &include_paths,
        )?;
    Ok(())
}
