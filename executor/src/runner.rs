use crate::{cli, service, transport};

pub async fn run() -> Result<(), String> {
    let args = cli::process_args()?;
    let transport = transport::connect(&args.transport).await?;
    service::run(transport, args).await
}
