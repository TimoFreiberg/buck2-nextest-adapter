use std::{collections::HashSet, convert::TryFrom, path::PathBuf, sync::Arc};

use futures::StreamExt;
use prost_types::Duration;
use tokio::sync::{mpsc, Mutex};

use crate::{
    cli::Args,
    proto::test as p,
    report::{inspect_and_read, DestinationDir, ReportIdentity},
};

#[derive(Clone)]
pub struct Orchestrator {
    client: p::test_orchestrator_client::TestOrchestratorClient<tonic::transport::Channel>,
    destination: Arc<DestinationDir>,
    reserved: Arc<Mutex<HashSet<String>>>,
    state: Arc<Mutex<SessionState>>,
    timeout_seconds: u64,
}

#[derive(Default)]
struct SessionState {
    publication_open: bool,
    failed: bool,
    published: HashSet<String>,
}

impl Orchestrator {
    pub async fn new(channel: tonic::transport::Channel, args: &Args) -> Result<Self, String> {
        let destination =
            DestinationDir::open(&args.junit_dir).map_err(|error| error.to_string())?;
        Ok(Self {
            client: p::test_orchestrator_client::TestOrchestratorClient::new(channel)
                .max_encoding_message_size(usize::MAX)
                .max_decoding_message_size(usize::MAX),
            destination: Arc::new(destination),
            reserved: Arc::new(Mutex::new(HashSet::new())),
            state: Arc::new(Mutex::new(SessionState {
                publication_open: true,
                failed: false,
                published: HashSet::new(),
            })),
            timeout_seconds: args.timeout_seconds,
        })
    }

    pub async fn run(
        self,
        receiver: tokio::sync::mpsc::Receiver<p::ExternalRunnerSpec>,
    ) -> Result<(), String> {
        let (stop_sender, mut stop_receiver) = mpsc::channel::<()>(1);
        let stream_stop_sender = stop_sender.clone();
        let mut stream = tokio_stream::wrappers::ReceiverStream::new(receiver)
            .map(|spec| {
                let stop_sender = stream_stop_sender.clone();
                let executor = self.clone();
                async move {
                    let result = executor.process(spec).await;
                    if result.is_err() {
                        let _ = stop_sender.send(()).await;
                    }
                    result
                }
            })
            .buffer_unordered(10_000);
        drop(stop_sender);
        let mut verdict = 0;
        while let Some(result) = tokio::select! {
            result = stream.next() => result,
            Some(()) = stop_receiver.recv() => {
                self.fail_session().await;
                return Err("executor session stopped after an RPC or publication failure".into());
            }
        } {
            match result {
                Ok(status) if status == p::TestStatus::Pass as i32 => {}
                Ok(_) => verdict = 32,
                Err(error) => {
                    self.fail_session().await;
                    return Err(error);
                }
            }
        }
        let mut client = self.client.clone();
        if let Err(error) = client
            .end_of_test_results(p::EndOfTestResultsRequest { exit_code: verdict })
            .await
        {
            self.fail_session().await;
            return Err(format!("EndOfTestResults RPC failed: {error}"));
        }
        Ok(())
    }

    async fn process(&self, spec: p::ExternalRunnerSpec) -> Result<i32, String> {
        let target = spec
            .target
            .clone()
            .ok_or_else(|| "ExternalRunnerSpec has no target".to_string())?;
        let handle = target
            .handle
            .clone()
            .ok_or_else(|| "ExternalRunnerSpec target has no handle".to_string())?;
        let identity = ReportIdentity {
            cell: target.cell.clone(),
            package: target.package.clone(),
            target: target.target.clone(),
            configuration: target.configuration.clone(),
        };
        let filename = identity.filename().map_err(|error| error.to_string())?;
        let key = filename.to_ascii_lowercase();
        if !self.reserved.lock().await.insert(key) {
            let result = make_result(
                &target,
                handle,
                p::TestStatus::InfraFailure as i32,
                "duplicate configured target identity",
            );
            self.report(result).await?;
            return Ok(p::TestStatus::InfraFailure as i32);
        }

        let nextest = spec.test_type == "nextest";
        if nextest && spec.env.contains_key("BUCK2_NEXTEST_JUNIT_DIR") {
            let result = make_result(
                &target,
                handle,
                p::TestStatus::InfraFailure as i32,
                "reserved environment key is already present",
            );
            self.report(result).await?;
            return Ok(p::TestStatus::InfraFailure as i32);
        }
        let command = spec.command.into_iter().map(to_arg).collect();
        let mut env: Vec<p::EnvironmentVariable> = spec
            .env
            .into_iter()
            .map(|(key, value)| p::EnvironmentVariable {
                key,
                value: Some(to_arg(value)),
            })
            .collect();
        env.sort_by(|left, right| left.key.cmp(&right.key));
        let mut pre_create_dirs = Vec::new();
        if nextest {
            pre_create_dirs.push(p::DeclaredOutput {
                name: "junit".into(),
                supports_remote: false,
                ttl_config: None,
            });
            env.push(p::EnvironmentVariable {
                key: "BUCK2_NEXTEST_JUNIT_DIR".into(),
                value: Some(p::ArgValue {
                    content: Some(p::ArgValueContent {
                        value: Some(p::arg_value_content::Value::DeclaredOutput(p::OutputName {
                            name: "junit".into(),
                        })),
                    }),
                    format: None,
                }),
            });
        }
        env.sort_by(|left, right| left.key.cmp(&right.key));
        let request = p::ExecuteRequest2 {
            timeout: Some(Duration {
                seconds: self.timeout_seconds as i64,
                nanos: 0,
            }),
            host_sharing_requirements: Some(crate::proto::host_sharing::HostSharingRequirements {
                requirements: Some(
                    crate::proto::host_sharing::host_sharing_requirements::Requirements::Shared(
                        crate::proto::host_sharing::host_sharing_requirements::Shared {
                            weight_class: Some(crate::proto::host_sharing::WeightClass {
                                value: Some(
                                    crate::proto::host_sharing::weight_class::Value::Permits(1),
                                ),
                            }),
                        },
                    ),
                ),
            }),
            test_executable: Some(p::TestExecutable {
                stage: Some(p::TestStage {
                    item: Some(p::test_stage::Item::Testing(p::Testing {
                        suite: target.target.clone(),
                        testcases: vec![],
                        variant: None,
                        repeat_count: None,
                    })),
                }),
                target: Some(handle.clone()),
                cmd: command,
                pre_create_dirs,
                env,
            }),
            executor_override: None,
            required_local_resources: vec![],
            disable_test_execution_caching: nextest,
        };
        let mut client = self.client.clone();
        let response = client
            .execute2(request)
            .await
            .map_err(|error| format!("Execute2 RPC failed for {}: {error}", target_name(&target)))?
            .into_inner();
        let Some(response) = response.response else {
            return Err("Execute2 returned no response".into());
        };
        match response {
            p::execute_response2::Response::Cancelled(_) => Ok(p::TestStatus::Omitted as i32),
            p::execute_response2::Response::Result(result) => {
                let status = result
                    .status
                    .as_ref()
                    .and_then(|status| status.status.as_ref())
                    .map(|status| match status {
                        p::execution_status::Status::Finished(code) if *code == 0 => {
                            p::TestStatus::Pass as i32
                        }
                        p::execution_status::Status::Finished(_) => p::TestStatus::Fail as i32,
                        p::execution_status::Status::TimedOut(_) => p::TestStatus::Timeout as i32,
                    })
                    .unwrap_or(p::TestStatus::InfraFailure as i32);
                let details = format!(
                    "---- STDOUT ----\n{:?}\n---- STDERR ----\n{:?}\n",
                    result.stdout, result.stderr
                );
                if nextest {
                    match output_path(&result).and_then(|source| {
                        inspect_and_read(source).map_err(|error| error.to_string())
                    }) {
                        Ok(bytes) => {
                            if let Err(error) = self.publish_if_open(&filename, &bytes).await {
                                return self.report_infra(&target, handle, status, error).await;
                            }
                        }
                        Err(error) => {
                            return self.report_infra(&target, handle, status, error).await
                        }
                    }
                }
                self.report(make_result_with_details(
                    &target,
                    handle,
                    status,
                    details,
                    result.execution_time,
                    result.max_memory_used_bytes,
                ))
                .await?;
                Ok(status)
            }
        }
    }

    async fn report_infra(
        &self,
        target: &p::ConfiguredTarget,
        handle: p::ConfiguredTargetHandle,
        original: i32,
        reason: String,
    ) -> Result<i32, String> {
        let details = format!(
            "original status={} report export failed: {}",
            status_name(original),
            reason
        );
        self.report(make_result_with_details(
            target,
            handle,
            p::TestStatus::InfraFailure as i32,
            details,
            None,
            None,
        ))
        .await?;
        Ok(p::TestStatus::InfraFailure as i32)
    }

    async fn report(&self, result: p::TestResult) -> Result<(), String> {
        let mut client = self.client.clone();
        match client
            .report_test_result(p::ReportTestResultRequest {
                result: Some(result),
            })
            .await
        {
            Ok(_) => Ok(()),
            Err(error) => {
                self.fail_session().await;
                Err(format!("ReportTestResult RPC failed: {error}"))
            }
        }
    }

    async fn publish_if_open(&self, filename: &str, bytes: &[u8]) -> Result<(), String> {
        let mut state = self.state.lock().await;
        if !state.publication_open {
            return Err("publication was closed by executor failure or cancellation".into());
        }
        self.destination
            .publish(filename, bytes)
            .map_err(|error| error.to_string())?;
        state.published.insert(filename.to_owned());
        Ok(())
    }

    async fn fail_session(&self) {
        let mut state = self.state.lock().await;
        state.publication_open = false;
        state.failed = true;
    }
}

fn target_name(target: &p::ConfiguredTarget) -> String {
    format!("{}//{}:{}", target.cell, target.package, target.target)
}
fn status_name(status: i32) -> &'static str {
    p::TestStatus::try_from(status)
        .map(|s| s.as_str_name())
        .unwrap_or("UNKNOWN")
}

fn to_arg(value: p::ExternalRunnerSpecValue) -> p::ArgValue {
    p::ArgValue {
        content: Some(p::ArgValueContent {
            value: Some(p::arg_value_content::Value::SpecValue(value)),
        }),
        format: None,
    }
}
fn make_result(
    target: &p::ConfiguredTarget,
    handle: p::ConfiguredTargetHandle,
    status: i32,
    details: &str,
) -> p::TestResult {
    make_result_with_details(target, handle, status, details.to_string(), None, None)
}
fn make_result_with_details(
    target: &p::ConfiguredTarget,
    handle: p::ConfiguredTargetHandle,
    status: i32,
    details: String,
    duration: Option<Duration>,
    memory: Option<u64>,
) -> p::TestResult {
    p::TestResult {
        name: target_name(target),
        status,
        msg: None,
        target: Some(handle),
        duration,
        details,
        max_memory_used_bytes: memory,
    }
}
fn output_path(result: &p::ExecutionResult2) -> Result<PathBuf, String> {
    if result.outputs.len() != 1 {
        return Err("Execute2 returned an unexpected output count".into());
    }
    let entry = &result.outputs[0];
    if entry
        .declared_output
        .as_ref()
        .map(|name| name.name.as_str())
        != Some("junit")
    {
        return Err("Execute2 returned an output not named junit".into());
    }
    let output = entry
        .output
        .as_ref()
        .ok_or_else(|| "junit output has no output value".to_string())?;
    let path = match output.value.as_ref() {
        Some(p::output::Value::LocalPath(path)) => PathBuf::from(path),
        Some(p::output::Value::RemoteObject(_)) => return Err("junit output was remote".into()),
        None => return Err("junit output has no local path".into()),
    };
    if !path.is_absolute() {
        return Err("Buck junit output path must be absolute".into());
    }
    if path.as_os_str().to_string_lossy().contains('\0') {
        return Err("Buck junit output path contains NUL".into());
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn output(name: &str, value: Option<p::output::Value>) -> p::OutputEntry {
        p::OutputEntry {
            declared_output: Some(p::OutputName { name: name.into() }),
            output: value.map(|value| p::Output { value: Some(value) }),
        }
    }

    #[test]
    fn output_shape_requires_one_local_junit_directory() {
        let local = p::output::Value::LocalPath("/tmp/buck-output".into());
        assert_eq!(
            output_path(&p::ExecutionResult2 {
                outputs: vec![output("junit", Some(local))],
                ..Default::default()
            })
            .unwrap(),
            PathBuf::from("/tmp/buck-output")
        );
        assert!(output_path(&p::ExecutionResult2 {
            outputs: vec![],
            ..Default::default()
        })
        .is_err());
        assert!(output_path(&p::ExecutionResult2 {
            outputs: vec![output(
                "other",
                Some(p::output::Value::LocalPath("/tmp/x".into()))
            )],
            ..Default::default()
        })
        .is_err());
        assert!(output_path(&p::ExecutionResult2 {
            outputs: vec![output(
                "junit",
                Some(p::output::Value::RemoteObject(p::RemoteObject {
                    digest: None,
                    node: None
                }))
            )],
            ..Default::default()
        })
        .is_err());
        assert!(output_path(&p::ExecutionResult2 {
            outputs: vec![output(
                "junit",
                Some(p::output::Value::LocalPath("relative".into()))
            )],
            ..Default::default()
        })
        .is_err());
    }
}
