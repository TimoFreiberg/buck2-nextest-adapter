use std::{env, ffi::OsString, net::SocketAddr, path::PathBuf};

use crate::{SUPPORTED_BUCK_COMMIT, SUPPORTED_BUCK_VERSION};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransportArgs {
    Fd {
        executor: i32,
        orchestrator: i32,
    },
    Tcp {
        executor: SocketAddr,
        orchestrator: SocketAddr,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Args {
    pub transport: TransportArgs,
    pub timeout_seconds: u64,
    pub junit_dir: PathBuf,
    pub config_entries: Vec<String>,
}

fn error(message: impl Into<String>) -> String {
    format!(
        "unsupported Buck2 test executor invocation: {}; supported Buck2 version is {} (commit {})",
        message.into(),
        SUPPORTED_BUCK_VERSION,
        SUPPORTED_BUCK_COMMIT
    )
}

fn text(value: OsString, what: &str) -> Result<String, String> {
    let value = value
        .into_string()
        .map_err(|_| error(format!("{what} is not UTF-8")))?;
    if value.as_bytes().contains(&0) {
        return Err(error(format!("{what} contains NUL")));
    }
    Ok(value)
}

fn value<I>(iter: &mut I, option: &str) -> Result<String, String>
where
    I: Iterator<Item = OsString>,
{
    let value = iter
        .next()
        .ok_or_else(|| error(format!("{option} requires a value")))?;
    let value = text(value, option)?;
    if value.starts_with("--") {
        return Err(error(format!("{option} requires a value")));
    }
    Ok(value)
}

fn parse_i32(value: String, option: &str) -> Result<i32, String> {
    let parsed = value
        .parse::<i32>()
        .map_err(|_| error(format!("{option} must be an integer")))?;
    if parsed < 0 {
        return Err(error(format!("{option} must be non-negative")));
    }
    Ok(parsed)
}

fn parse_addr(value: String, option: &str) -> Result<SocketAddr, String> {
    value
        .parse()
        .map_err(|_| error(format!("{option} must be a loopback socket address")))
}

pub fn parse<I>(args: I) -> Result<Args, String>
where
    I: IntoIterator<Item = OsString>,
{
    let mut iter = args.into_iter();
    let mut trace_id = None;
    let mut config_entries = Vec::new();
    let mut transport = None;

    loop {
        let Some(raw) = iter.next() else {
            return Err(error("missing transport preamble"));
        };
        let arg = text(raw, "argument")?;
        match arg.as_str() {
            "--buck-trace-id" => {
                if trace_id.is_some() {
                    return Err(error("--buck-trace-id specified more than once"));
                }
                let value = value(&mut iter, "--buck-trace-id")?;
                if value.is_empty() {
                    return Err(error("--buck-trace-id must not be empty"));
                }
                trace_id = Some(value);
            }
            "--config-entry" => config_entries.push(value(&mut iter, "--config-entry")?),
            "--executor-fd" => {
                if transport.is_some() {
                    return Err(error("transport specified more than once or mixed"));
                }
                let executor = parse_i32(value(&mut iter, "--executor-fd")?, "--executor-fd")?;
                let next = text(
                    iter.next()
                        .ok_or_else(|| error("--orchestrator-fd is required"))?,
                    "argument",
                )?;
                if next != "--orchestrator-fd" {
                    return Err(error(
                        "--orchestrator-fd must immediately follow --executor-fd",
                    ));
                }
                let orchestrator =
                    parse_i32(value(&mut iter, "--orchestrator-fd")?, "--orchestrator-fd")?;
                if executor == orchestrator {
                    return Err(error(
                        "executor and orchestrator file descriptors must differ",
                    ));
                }
                transport = Some(TransportArgs::Fd {
                    executor,
                    orchestrator,
                });
                break;
            }
            "--executor-addr" => {
                if transport.is_some() {
                    return Err(error("transport specified more than once or mixed"));
                }
                let executor = parse_addr(value(&mut iter, "--executor-addr")?, "--executor-addr")?;
                let next = text(
                    iter.next()
                        .ok_or_else(|| error("--orchestrator-addr is required"))?,
                    "argument",
                )?;
                if next != "--orchestrator-addr" {
                    return Err(error(
                        "--orchestrator-addr must immediately follow --executor-addr",
                    ));
                }
                let orchestrator = parse_addr(
                    value(&mut iter, "--orchestrator-addr")?,
                    "--orchestrator-addr",
                )?;
                if executor == orchestrator {
                    return Err(error("executor and orchestrator addresses must differ"));
                }
                if !executor.ip().is_loopback() || !orchestrator.ip().is_loopback() {
                    return Err(error(
                        "executor and orchestrator addresses must be loopback",
                    ));
                }
                transport = Some(TransportArgs::Tcp {
                    executor,
                    orchestrator,
                });
                break;
            }
            "--" => return Err(error("transport preamble is missing")),
            other => return Err(error(format!("unexpected preamble argument {other}"))),
        }
    }

    if trace_id.is_none() {
        return Err(error("--buck-trace-id is required"));
    }
    let separator = text(
        iter.next()
            .ok_or_else(|| error("missing argument separator"))?,
        "argument",
    )?;
    if separator != "--" {
        return Err(error("transport flags must be followed by --"));
    }
    if text(
        iter.next()
            .ok_or_else(|| error("missing Buck compatibility arguments"))?,
        "argument",
    )? != "ignored"
    {
        return Err(error("missing Buck compatibility argument"));
    }
    if text(
        iter.next()
            .ok_or_else(|| error("missing --buck-test-info"))?,
        "argument",
    )? != "--buck-test-info"
    {
        return Err(error("missing --buck-test-info"));
    }
    if value(&mut iter, "--buck-test-info")? != "ignored" {
        return Err(error("--buck-test-info must be ignored"));
    }

    let mut timeout_seconds = 600;
    let mut timeout_seen = false;
    let mut junit_dir = None;
    while let Some(raw) = iter.next() {
        let arg = text(raw, "argument")?;
        match arg.as_str() {
            "--timeout" => {
                if timeout_seen {
                    return Err(error("--timeout specified more than once"));
                }
                timeout_seen = true;
                timeout_seconds = value(&mut iter, "--timeout")?
                    .parse::<u64>()
                    .map_err(|_| error("--timeout must be an unsigned 64-bit integer"))?;
                if timeout_seconds > i64::MAX as u64 {
                    return Err(error(
                        "--timeout exceeds the supported protobuf duration range",
                    ));
                }
            }
            "--junit-dir" => {
                if junit_dir.is_some() {
                    return Err(error("--junit-dir specified more than once"));
                }
                let path = PathBuf::from(value(&mut iter, "--junit-dir")?);
                if !path.is_absolute() {
                    return Err(error("--junit-dir must be absolute"));
                }
                junit_dir = Some(path);
            }
            "--env" | "--test-arg" => return Err(error(format!("{arg} is not supported"))),
            other => return Err(error(format!("unknown executor option {other}"))),
        }
    }

    Ok(Args {
        transport: transport.ok_or_else(|| error("missing transport"))?,
        timeout_seconds,
        junit_dir: junit_dir.ok_or_else(|| error("--junit-dir is required"))?,
        config_entries,
    })
}

pub fn process_args() -> Result<Args, String> {
    parse(env::args_os().skip(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_args(args: &[&str]) -> Result<Args, String> {
        parse(args.iter().map(OsString::from))
    }

    const PREFIX: &[&str] = &[
        "--buck-trace-id",
        "trace",
        "--config-entry",
        "host=mac",
        "--executor-fd",
        "3",
        "--orchestrator-fd",
        "4",
        "--",
        "ignored",
        "--buck-test-info",
        "ignored",
    ];

    #[test]
    fn accepts_stock_fd_shape_and_unbounded_timeout() {
        let mut args = PREFIX.to_vec();
        args.extend([
            "--timeout",
            "9223372036854775807",
            "--junit-dir",
            "/tmp/root/junit",
        ]);
        let parsed = parse_args(&args).unwrap();
        assert_eq!(parsed.timeout_seconds, i64::MAX as u64);
        args[9] = "18446744073709551615";
        assert!(parse_args(&args).is_err());
        assert!(matches!(
            parsed.transport,
            TransportArgs::Fd {
                executor: 3,
                orchestrator: 4
            }
        ));
    }

    #[test]
    fn accepts_tcp_shape_and_zero_timeout() {
        let mut args = vec![
            "--buck-trace-id",
            "trace",
            "--executor-addr",
            "127.0.0.1:1",
            "--orchestrator-addr",
            "127.0.0.1:2",
            "--",
            "ignored",
            "--buck-test-info",
            "ignored",
            "--timeout",
            "0",
            "--junit-dir",
            "/tmp/root/junit",
        ];
        let parsed = parse_args(&args).unwrap();
        assert_eq!(parsed.timeout_seconds, 0);
        assert!(matches!(parsed.transport, TransportArgs::Tcp { .. }));
        args[2] = "127.0.0.2:1";
        assert!(parse_args(&args).is_err());
    }

    #[test]
    fn rejects_missing_duplicate_unknown_and_unsafe_options() {
        assert!(parse_args(PREFIX).is_err());
        let mut duplicate = PREFIX.to_vec();
        duplicate.extend([
            "--junit-dir",
            "/tmp/root/junit",
            "--junit-dir",
            "/tmp/root/junit",
        ]);
        assert!(parse_args(&duplicate).is_err());
        let mut duplicate_timeout = PREFIX.to_vec();
        duplicate_timeout.extend([
            "--timeout",
            "600",
            "--timeout",
            "600",
            "--junit-dir",
            "/tmp/root/junit",
        ]);
        assert!(parse_args(&duplicate_timeout).is_err());
        let mut unknown = PREFIX.to_vec();
        unknown.extend(["--junit-dir", "/tmp/root/junit", "--wat"]);
        assert!(parse_args(&unknown).is_err());
        let mut unsupported = PREFIX.to_vec();
        unsupported.extend(["--junit-dir", "/tmp/root/junit", "--env", "X=Y"]);
        assert!(parse_args(&unsupported).is_err());
    }
}
