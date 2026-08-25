//! Minimal, strict-enough JUnit XML validation.
use crate::{ContractError, ContractResult};
use quick_xml::{events::Event, Reader};
use std::io::Cursor;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidatedReport {
    pub root: String,
    pub test_suites: usize,
}

pub fn validate_report_xml(input: &[u8]) -> ContractResult<ValidatedReport> {
    let mut reader = Reader::from_reader(Cursor::new(input));
    reader.config_mut().trim_text(true);
    let mut buffer = Vec::new();
    let mut stack: Vec<Vec<u8>> = Vec::new();
    let mut root = None;
    let mut suites = 0usize;
    loop {
        match reader.read_event_into(&mut buffer) {
            Ok(Event::Eof) => break,
            Ok(Event::Start(event)) => {
                let name = event.name().as_ref().to_vec();
                if stack.is_empty() {
                    if root.is_some() {
                        return Err(ContractError::invalid("XML has multiple roots"));
                    }
                    root = Some(String::from_utf8_lossy(&name).into_owned());
                }
                if name.as_slice() == b"testsuite" {
                    suites += 1;
                }
                stack.push(name);
            }
            Ok(Event::Empty(event)) => {
                let name = event.name().as_ref().to_vec();
                if stack.is_empty() && root.is_some() {
                    return Err(ContractError::invalid("XML has multiple roots"));
                }
                if stack.is_empty() {
                    root = Some(String::from_utf8_lossy(&name).into_owned());
                }
                if name.as_slice() == b"testsuite" {
                    suites += 1;
                }
            }
            Ok(Event::End(event)) => {
                let name = event.name().as_ref().to_vec();
                let Some(open) = stack.pop() else {
                    return Err(ContractError::invalid("XML has an unmatched closing tag"));
                };
                if open != name {
                    return Err(ContractError::invalid(
                        "XML closing tag does not match opening tag",
                    ));
                }
            }
            Ok(Event::Text(_) | Event::CData(_) | Event::Comment(_) | Event::Decl(_)) => {}
            Ok(Event::DocType(_)) => {
                return Err(ContractError::invalid("XML doctypes are not allowed"))
            }
            Ok(other) => {
                return Err(ContractError::invalid(format!(
                    "unsupported XML event: {other:?}"
                )))
            }
            Err(error) => return Err(ContractError::Xml(error.to_string())),
        }
        buffer.clear();
    }
    if !stack.is_empty() {
        return Err(ContractError::invalid("XML has an unclosed tag"));
    }
    let root = root.ok_or_else(|| ContractError::invalid("XML report is empty"))?;
    if root != "testsuites" && root != "testsuite" {
        return Err(ContractError::invalid(
            "XML report root must be testsuites or testsuite",
        ));
    }
    Ok(ValidatedReport {
        root,
        test_suites: suites,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn malformed_xml_is_rejected() {
        assert!(validate_report_xml(br#"<testsuites><testsuite></testsuites>"#).is_err());
    }
    #[test]
    fn valid_report_is_accepted() {
        assert_eq!(
            validate_report_xml(br#"<testsuites><testsuite/></testsuites>"#)
                .unwrap()
                .test_suites,
            1
        );
    }
}
