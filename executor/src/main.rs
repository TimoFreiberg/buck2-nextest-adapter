#[tokio::main(flavor = "multi_thread")]
async fn main() {
    if let Err(error) = buck2_nextest_executor::runner::run().await {
        eprintln!("nextest v2 executor: {error}");
        std::process::exit(1);
    }
}
