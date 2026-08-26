#![deny(unsafe_op_in_unsafe_fn)]

pub mod cli;
pub mod orchestrator;
pub mod proto;
pub mod report;
pub mod runner;
pub mod service;
pub mod transport;

pub const SUPPORTED_BUCK_COMMIT: &str = "1560aca2002865cd73d7cafb22c705cfb640b2bc";
pub const SUPPORTED_BUCK_VERSION: &str =
    "buck2 2026-07-14-1560aca2002865cd73d7cafb22c705cfb640b2bc";
