use std::{fmt, io};

pub type ContractResult<T> = Result<T, ContractError>;

#[derive(Debug)]
pub enum ContractError {
    Invalid(String),
    Io(io::Error),
    Json(serde_json::Error),
    Xml(String),
}

impl ContractError {
    pub(crate) fn invalid(message: impl Into<String>) -> Self {
        Self::Invalid(message.into())
    }
}

impl fmt::Display for ContractError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid(message) => write!(f, "invalid contract: {message}"),
            Self::Io(error) => write!(f, "I/O error: {error}"),
            Self::Json(error) => write!(f, "JSON error: {error}"),
            Self::Xml(message) => write!(f, "XML error: {message}"),
        }
    }
}

impl std::error::Error for ContractError {}
impl From<io::Error> for ContractError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}
impl From<serde_json::Error> for ContractError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}
