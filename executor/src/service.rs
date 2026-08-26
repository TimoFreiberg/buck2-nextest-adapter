use std::sync::Arc;

use futures::StreamExt;
use tokio::sync::{mpsc, Mutex};

use crate::{orchestrator::Orchestrator, proto::test as p, transport::Transport};

pub async fn run(transport: Transport, args: crate::cli::Args) -> Result<(), String> {
    let (sender, receiver) = mpsc::channel(10_000);
    let orchestrator_channel = make_channel(transport.orchestrator, "orchestrator").await?;
    let executor = Executor {
        sender: Arc::new(Mutex::new(Some(sender))),
    };
    let (shutdown_sender, shutdown_receiver) = tokio::sync::oneshot::channel();
    let executor_server = tokio::spawn(async move {
        let incoming = futures::stream::once(futures::future::ready(Ok::<_, std::io::Error>(
            transport.executor,
        )))
        .chain(futures::stream::once(futures::future::pending::<
            Result<_, std::io::Error>,
        >()));
        tonic::transport::Server::builder()
            .add_service(p::test_executor_server::TestExecutorServer::new(executor))
            .serve_with_incoming_shutdown(incoming, async move {
                let _ = shutdown_receiver.await;
            })
            .await
            .map_err(|error| format!("TestExecutor server failed: {error}"))
    });
    let orchestrator = Orchestrator::new(orchestrator_channel, &args).await?;
    let result = orchestrator.run(receiver).await;
    let _ = shutdown_sender.send(());
    match executor_server.await {
        Ok(Ok(())) => result,
        Ok(Err(error)) => Err(error),
        Err(error) => Err(format!("TestExecutor server task failed: {error}")),
    }
}

#[derive(Clone)]
struct Executor {
    sender: Arc<Mutex<Option<mpsc::Sender<p::ExternalRunnerSpec>>>>,
}

#[tonic::async_trait]
impl p::test_executor_server::TestExecutor for Executor {
    async fn external_runner_spec(
        &self,
        request: tonic::Request<p::ExternalRunnerSpecRequest>,
    ) -> Result<tonic::Response<p::Empty>, tonic::Status> {
        let spec = request.into_inner().test_spec.ok_or_else(|| {
            tonic::Status::invalid_argument("ExternalRunnerSpec request has no test_spec")
        })?;
        let sender =
            self.sender.lock().await.clone().ok_or_else(|| {
                tonic::Status::failed_precondition("executor spec stream is closed")
            })?;
        sender
            .send(spec)
            .await
            .map_err(|_| tonic::Status::internal("executor spec channel closed"))?;
        Ok(tonic::Response::new(p::Empty {}))
    }
    async fn end_of_test_requests(
        &self,
        _request: tonic::Request<p::Empty>,
    ) -> Result<tonic::Response<p::Empty>, tonic::Status> {
        self.sender.lock().await.take();
        Ok(tonic::Response::new(p::Empty {}))
    }
    async fn unstable_heap_dump(
        &self,
        _request: tonic::Request<p::UnstableHeapDumpRequest>,
    ) -> Result<tonic::Response<p::UnstableHeapDumpResponse>, tonic::Status> {
        Err(tonic::Status::unimplemented("heap dumps are unsupported"))
    }
}

async fn make_channel<T>(io: T, name: &str) -> Result<tonic::transport::Channel, String>
where
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Send + Sync + Unpin + 'static,
{
    let io = hyper_util::rt::TokioIo::new(io);
    let mut io = Some(io);
    let endpoint = tonic::transport::Endpoint::try_from(format!("http://{name}.invalid"))
        .map_err(|e| e.to_string())?;
    endpoint
        .connect_with_connector(tower::service_fn(move |_: tonic::transport::Uri| {
            let value = io
                .take()
                .ok_or_else(|| "connection cannot be reused".to_string());
            futures::future::ready(value)
        }))
        .await
        .map_err(|e| format!("failed to create {name} channel: {e}"))
}
