//! JSON decoding which rejects duplicate object keys after escape decoding.
use crate::{ContractError, ContractResult};
use serde::de::{DeserializeSeed, Deserializer as _, MapAccess, SeqAccess, Visitor};
use serde::Deserialize;
use serde_json::{Deserializer, Value};
use std::{collections::BTreeSet, fmt};

struct StrictValue;
struct StrictVisitor;

impl<'de> DeserializeSeed<'de> for StrictValue {
    type Value = Value;
    fn deserialize<D>(self, deserializer: D) -> Result<Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        deserializer.deserialize_any(StrictVisitor)
    }
}

impl<'de> Visitor<'de> for StrictVisitor {
    type Value = Value;
    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a JSON value")
    }
    fn visit_unit<E>(self) -> Result<Value, E>
    where
        E: serde::de::Error,
    {
        Ok(Value::Null)
    }
    fn visit_bool<E>(self, value: bool) -> Result<Value, E>
    where
        E: serde::de::Error,
    {
        Ok(Value::Bool(value))
    }
    fn visit_i64<E>(self, value: i64) -> Result<Value, E>
    where
        E: serde::de::Error,
    {
        Ok(Value::Number(value.into()))
    }
    fn visit_u64<E>(self, value: u64) -> Result<Value, E>
    where
        E: serde::de::Error,
    {
        Ok(Value::Number(value.into()))
    }
    fn visit_f64<E>(self, value: f64) -> Result<Value, E>
    where
        E: serde::de::Error,
    {
        serde_json::Number::from_f64(value)
            .map(Value::Number)
            .ok_or_else(|| E::custom("non-finite JSON number"))
    }
    fn visit_str<E>(self, value: &str) -> Result<Value, E>
    where
        E: serde::de::Error,
    {
        Ok(Value::String(value.to_owned()))
    }
    fn visit_borrowed_str<E>(self, value: &'de str) -> Result<Value, E>
    where
        E: serde::de::Error,
    {
        Ok(Value::String(value.to_owned()))
    }
    fn visit_string<E>(self, value: String) -> Result<Value, E>
    where
        E: serde::de::Error,
    {
        Ok(Value::String(value))
    }
    fn visit_seq<A>(self, mut access: A) -> Result<Value, A::Error>
    where
        A: SeqAccess<'de>,
    {
        let mut values = Vec::new();
        while let Some(value) = access.next_element_seed(StrictValue)? {
            values.push(value);
        }
        Ok(Value::Array(values))
    }
    fn visit_map<A>(self, mut access: A) -> Result<Value, A::Error>
    where
        A: MapAccess<'de>,
    {
        let mut values = serde_json::Map::new();
        let mut keys = BTreeSet::new();
        while let Some(key) = access.next_key::<String>()? {
            if !keys.insert(key.clone()) {
                return Err(serde::de::Error::custom(format!(
                    "duplicate JSON key: {key}"
                )));
            }
            let value = access.next_value_seed(StrictValue)?;
            values.insert(key, value);
        }
        Ok(Value::Object(values))
    }
}

/// Parse one complete JSON document, rejecting duplicate decoded object keys.
pub fn decode(input: &[u8]) -> ContractResult<Value> {
    let mut deserializer = Deserializer::from_slice(input);
    let value = deserializer
        .deserialize_any(StrictVisitor)
        .map_err(ContractError::from)?;
    deserializer.end().map_err(ContractError::from)?;
    Ok(value)
}

/// Decode JSON and deserialize it into a typed value after strict duplicate checking.
pub fn decode_as<T: DeserializeOwned>(input: &[u8]) -> ContractResult<T> {
    let value = decode(input)?;
    Ok(serde_json::from_value(value)?)
}

pub trait DeserializeOwned: for<'de> Deserialize<'de> {}
impl<T: for<'de> Deserialize<'de>> DeserializeOwned for T {}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn duplicate_keys_are_rejected() {
        assert!(decode(br#"{\"a\":1,\"a\":2}"#).is_err());
    }
    #[test]
    fn escaped_duplicate_keys_are_rejected() {
        assert!(decode(br#"{\"a\":1,\"\\u0061\":2}"#).is_err());
    }
    #[test]
    fn bool_is_not_an_integer() {
        #[derive(Deserialize)]
        struct Number {
            #[allow(dead_code)]
            value: u64,
        }
        assert!(decode_as::<Number>(br#"{"value":true}"#).is_err());
        assert!(decode_as::<Number>(br#"{"value":1}"#).is_ok());
    }
}
