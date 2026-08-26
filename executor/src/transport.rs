use std::{
    io,
    os::fd::{FromRawFd, RawFd},
};

use tokio::io::{AsyncRead, AsyncWrite};

use crate::cli::TransportArgs;

pub struct Duplex<T> {
    pub read: T,
    pub write: T,
}

pub enum Connection {
    #[cfg(unix)]
    Fd(tokio::net::UnixStream),
    Tcp(tokio::net::TcpStream),
}

impl AsyncRead for Connection {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        match self.get_mut() {
            #[cfg(unix)]
            Self::Fd(stream) => std::pin::Pin::new(stream).poll_read(cx, buf),
            Self::Tcp(stream) => std::pin::Pin::new(stream).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for Connection {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<io::Result<usize>> {
        match self.get_mut() {
            #[cfg(unix)]
            Self::Fd(stream) => std::pin::Pin::new(stream).poll_write(cx, buf),
            Self::Tcp(stream) => std::pin::Pin::new(stream).poll_write(cx, buf),
        }
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        match self.get_mut() {
            #[cfg(unix)]
            Self::Fd(stream) => std::pin::Pin::new(stream).poll_flush(cx),
            Self::Tcp(stream) => std::pin::Pin::new(stream).poll_flush(cx),
        }
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<io::Result<()>> {
        match self.get_mut() {
            #[cfg(unix)]
            Self::Fd(stream) => std::pin::Pin::new(stream).poll_shutdown(cx),
            Self::Tcp(stream) => std::pin::Pin::new(stream).poll_shutdown(cx),
        }
    }
}

impl tonic::transport::server::Connected for Connection {
    type ConnectInfo = ();

    fn connect_info(&self) -> Self::ConnectInfo {}
}

pub struct Transport {
    pub orchestrator: Connection,
    pub executor: Connection,
}

pub async fn connect(args: &TransportArgs) -> Result<Transport, String> {
    match args {
        #[cfg(unix)]
        TransportArgs::Fd {
            executor,
            orchestrator,
        } => {
            let executor = unsafe {
                tokio::net::UnixStream::from_std(std::os::unix::net::UnixStream::from_raw_fd(
                    *executor as RawFd,
                ))
            }
            .map_err(|error| format!("failed to wrap executor FD: {error}"))?;
            let orchestrator = unsafe {
                tokio::net::UnixStream::from_std(std::os::unix::net::UnixStream::from_raw_fd(
                    *orchestrator as RawFd,
                ))
            }
            .map_err(|error| format!("failed to wrap orchestrator FD: {error}"))?;
            Ok(Transport {
                orchestrator: Connection::Fd(orchestrator),
                executor: Connection::Fd(executor),
            })
        }
        TransportArgs::Tcp {
            executor,
            orchestrator,
        } => {
            let executor = tokio::net::TcpStream::connect(executor)
                .await
                .map_err(|error| format!("failed to connect executor address: {error}"))?;
            let orchestrator = tokio::net::TcpStream::connect(orchestrator)
                .await
                .map_err(|error| format!("failed to connect orchestrator address: {error}"))?;
            Ok(Transport {
                orchestrator: Connection::Tcp(orchestrator),
                executor: Connection::Tcp(executor),
            })
        }
        #[cfg(not(unix))]
        TransportArgs::Fd { .. } => {
            Err("file-descriptor transport is unsupported on this platform".into())
        }
    }
}
