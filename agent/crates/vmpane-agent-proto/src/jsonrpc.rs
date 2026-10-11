//! JSON-RPC 2.0 messages as they travel in type-0 frames: one object per frame, no batches.
//!
//! [`Message::parse`] checks, in this order (the shared vectors fix the order, so both sides report the same
//! error): nesting depth on the raw bytes (before any parser recurses), JSON syntax, string and key lengths,
//! then the JSON-RPC shape. Unknown members are ignored for forward compatibility.

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

use crate::error::{ErrorCode, ParseError};
use crate::limits::{MAX_JSON_DEPTH, MAX_STRING};

/// A request id: an integer or a string. Fractional numbers and null are refused in requests.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Id {
    Int(i64),
    Str(String),
}

impl Id {
    fn to_value(&self) -> Value {
        match self {
            Id::Int(n) => Value::from(*n),
            Id::Str(s) => Value::from(s.as_str()),
        }
    }

    fn from_value(value: &Value) -> Option<Id> {
        match value {
            Value::Number(n) => n.as_i64().map(Id::Int),
            Value::String(s) => Some(Id::Str(s.clone())),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ErrorObject {
    pub code: i32,
    pub message: String,
    pub data: Option<Value>,
}

impl ErrorObject {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> ErrorObject {
        ErrorObject {
            code: code.code(),
            message: message.into(),
            data: None,
        }
    }

    pub fn known_code(&self) -> Option<ErrorCode> {
        ErrorCode::from_code(self.code)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Request {
    pub id: Id,
    pub method: String,
    pub params: Option<Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Notification {
    pub method: String,
    pub params: Option<Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Response {
    /// None only for an error about a request whose id could not be read.
    pub id: Option<Id>,
    pub outcome: Result<Value, ErrorObject>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Message {
    Request(Request),
    Notification(Notification),
    Response(Response),
}

/// Decodes `params` into a method's parameter type; absent params read as `{}`.
pub fn decode_params<T: DeserializeOwned>(params: Option<&Value>) -> Result<T, ErrorObject> {
    let value = params.cloned().unwrap_or_else(|| Value::Object(Map::new()));
    serde_json::from_value(value)
        .map_err(|err| ErrorObject::new(ErrorCode::InvalidParams, format!("invalid params: {err}")))
}

/// Encodes a method's parameters or result.
pub fn encode_value<T: Serialize>(value: &T) -> Value {
    // Every protocol type serializes to JSON without fallible custom code.
    serde_json::to_value(value).unwrap_or(Value::Null)
}

impl Request {
    pub fn new<T: Serialize>(id: Id, method: &str, params: &T) -> Request {
        Request {
            id,
            method: method.to_owned(),
            params: Some(encode_value(params)),
        }
    }

    pub fn decode_params<T: DeserializeOwned>(&self) -> Result<T, ErrorObject> {
        decode_params(self.params.as_ref())
    }
}

impl Notification {
    pub fn new<T: Serialize>(method: &str, params: &T) -> Notification {
        Notification {
            method: method.to_owned(),
            params: Some(encode_value(params)),
        }
    }

    pub fn decode_params<T: DeserializeOwned>(&self) -> Result<T, ErrorObject> {
        decode_params(self.params.as_ref())
    }
}

impl Response {
    pub fn ok<T: Serialize>(id: Id, result: &T) -> Response {
        Response {
            id: Some(id),
            outcome: Ok(encode_value(result)),
        }
    }

    pub fn error(id: Option<Id>, error: ErrorObject) -> Response {
        Response {
            id,
            outcome: Err(error),
        }
    }

    /// The typed result, or the peer's error; a result of the wrong shape reads as `invalidParams`.
    pub fn decode_result<T: DeserializeOwned>(&self) -> Result<T, ErrorObject> {
        match &self.outcome {
            Ok(value) => serde_json::from_value(value.clone()).map_err(|err| {
                ErrorObject::new(ErrorCode::InvalidParams, format!("invalid result: {err}"))
            }),
            Err(err) => Err(err.clone()),
        }
    }
}

impl Message {
    pub fn parse(bytes: &[u8]) -> Result<Message, ParseError> {
        if exceeds_depth(bytes, MAX_JSON_DEPTH) {
            return Err(ParseError::Depth);
        }
        let value: Value = serde_json::from_slice(bytes).map_err(|_| ParseError::Parse)?;
        check_strings(&value)?;
        Message::from_value(value)
    }

    fn from_value(value: Value) -> Result<Message, ParseError> {
        let Value::Object(mut obj) = value else {
            return Err(ParseError::Invalid("not an object"));
        };
        if obj.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
            return Err(ParseError::Invalid("jsonrpc is not \"2.0\""));
        }
        if let Some(method) = obj.remove("method") {
            let Value::String(method) = method else {
                return Err(ParseError::Invalid("method is not a string"));
            };
            let params = match obj.remove("params") {
                None => None,
                Some(p @ (Value::Object(_) | Value::Array(_))) => Some(p),
                Some(_) => return Err(ParseError::Invalid("params is not an object or array")),
            };
            return match obj.get("id") {
                None => Ok(Message::Notification(Notification { method, params })),
                Some(id) => {
                    let id = Id::from_value(id).ok_or(ParseError::Invalid("bad request id"))?;
                    Ok(Message::Request(Request { id, method, params }))
                }
            };
        }
        let id = match obj.get("id") {
            None => return Err(ParseError::Invalid("response without id")),
            Some(Value::Null) => None,
            Some(id) => Some(Id::from_value(id).ok_or(ParseError::Invalid("bad response id"))?),
        };
        let outcome = match (obj.remove("result"), obj.remove("error")) {
            (Some(result), None) if id.is_some() => Ok(result),
            (None, Some(error)) => Err(parse_error_object(error)?),
            (Some(_), None) => return Err(ParseError::Invalid("result with a null id")),
            _ => return Err(ParseError::Invalid("needs exactly one of result and error")),
        };
        Ok(Message::Response(Response { id, outcome }))
    }

    pub fn to_value(&self) -> Value {
        let mut obj = Map::new();
        obj.insert("jsonrpc".into(), Value::from("2.0"));
        match self {
            Message::Request(r) => {
                obj.insert("id".into(), r.id.to_value());
                obj.insert("method".into(), Value::from(r.method.as_str()));
                if let Some(p) = &r.params {
                    obj.insert("params".into(), p.clone());
                }
            }
            Message::Notification(n) => {
                obj.insert("method".into(), Value::from(n.method.as_str()));
                if let Some(p) = &n.params {
                    obj.insert("params".into(), p.clone());
                }
            }
            Message::Response(r) => {
                obj.insert("id".into(), r.id.as_ref().map_or(Value::Null, Id::to_value));
                match &r.outcome {
                    Ok(result) => {
                        obj.insert("result".into(), result.clone());
                    }
                    Err(err) => {
                        let mut e = Map::new();
                        e.insert("code".into(), Value::from(err.code));
                        e.insert("message".into(), Value::from(err.message.as_str()));
                        if let Some(data) = &err.data {
                            e.insert("data".into(), data.clone());
                        }
                        obj.insert("error".into(), Value::Object(e));
                    }
                }
            }
        }
        Value::Object(obj)
    }

    /// The frame payload. Fails if a string in it breaks [`MAX_STRING`]; the caller must not send it.
    pub fn to_bytes(&self) -> Result<Vec<u8>, ParseError> {
        let value = self.to_value();
        check_strings(&value)?;
        serde_json::to_vec(&value).map_err(|_| ParseError::Parse)
    }
}

impl From<Request> for Message {
    fn from(r: Request) -> Message {
        Message::Request(r)
    }
}

impl From<Notification> for Message {
    fn from(n: Notification) -> Message {
        Message::Notification(n)
    }
}

impl From<Response> for Message {
    fn from(r: Response) -> Message {
        Message::Response(r)
    }
}

fn parse_error_object(value: Value) -> Result<ErrorObject, ParseError> {
    let Value::Object(mut obj) = value else {
        return Err(ParseError::Invalid("error is not an object"));
    };
    let code = obj
        .get("code")
        .and_then(Value::as_i64)
        .and_then(|c| i32::try_from(c).ok())
        .ok_or(ParseError::Invalid("error code is not an integer"))?;
    let Some(Value::String(message)) = obj.remove("message") else {
        return Err(ParseError::Invalid("error message is not a string"));
    };
    Ok(ErrorObject {
        code,
        message,
        data: obj.remove("data"),
    })
}

/// True when arrays and objects nest deeper than `max` (the top level counts as 1). Scans raw bytes, skipping
/// strings, so no parser ever recurses past the limit; malformed JSON is left to the parser.
pub fn exceeds_depth(bytes: &[u8], max: usize) -> bool {
    let (mut depth, mut in_string, mut escaped) = (0usize, false, false);
    for &b in bytes {
        if in_string {
            match b {
                _ if escaped => escaped = false,
                b'\\' => escaped = true,
                b'"' => in_string = false,
                _ => {}
            }
            continue;
        }
        match b {
            b'"' => in_string = true,
            b'[' | b'{' => {
                depth += 1;
                if depth > max {
                    return true;
                }
            }
            b']' | b'}' => depth = depth.saturating_sub(1),
            _ => {}
        }
    }
    false
}

fn check_strings(value: &Value) -> Result<(), ParseError> {
    match value {
        Value::String(s) if s.len() > MAX_STRING => Err(ParseError::StringTooLong),
        Value::Array(items) => items.iter().try_for_each(check_strings),
        Value::Object(obj) => obj.iter().try_for_each(|(key, item)| {
            if key.len() > MAX_STRING {
                Err(ParseError::StringTooLong)
            } else {
                check_strings(item)
            }
        }),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn parse(text: &str) -> Result<Message, ParseError> {
        Message::parse(text.as_bytes())
    }

    #[test]
    fn reads_each_kind() {
        let req = parse(r#"{"jsonrpc":"2.0","id":7,"method":"agent.ping"}"#).unwrap();
        assert_eq!(
            req,
            Message::Request(Request {
                id: Id::Int(7),
                method: "agent.ping".into(),
                params: None
            })
        );
        let note =
            parse(r#"{"jsonrpc":"2.0","method":"exec.exited","params":{"execId":1}}"#).unwrap();
        assert!(matches!(note, Message::Notification(n) if n.params == Some(json!({"execId": 1}))));
        let ok = parse(r#"{"jsonrpc":"2.0","id":"a","result":{}}"#).unwrap();
        assert!(matches!(
            ok,
            Message::Response(Response {
                id: Some(Id::Str(_)),
                outcome: Ok(_)
            })
        ));
        let err =
            parse(r#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"x"}}"#).unwrap();
        assert!(
            matches!(err, Message::Response(Response { id: None, outcome: Err(e) }) if e.code == -32700)
        );
    }

    #[test]
    fn round_trips() {
        let messages: [Message; 3] = [
            Request::new(Id::Int(1), "file.stat", &json!({"path": "/tmp"})).into(),
            Notification::new("clipboard.changed", &json!({"seq": 3})).into(),
            Response::error(
                Some(Id::Str("x".into())),
                ErrorObject::new(ErrorCode::Busy, "busy"),
            )
            .into(),
        ];
        for message in messages {
            assert_eq!(
                parse(&String::from_utf8(message.to_bytes().unwrap()).unwrap()),
                Ok(message)
            );
        }
    }

    #[test]
    fn enforces_depth_on_raw_bytes() {
        let nest = |n: usize| format!("{}{}", "[".repeat(n), "]".repeat(n));
        let at_limit = format!(
            r#"{{"jsonrpc":"2.0","method":"m","params":{}}}"#,
            nest(MAX_JSON_DEPTH - 1)
        );
        let over = format!(
            r#"{{"jsonrpc":"2.0","method":"m","params":{}}}"#,
            nest(MAX_JSON_DEPTH)
        );
        assert!(parse(&at_limit).is_ok());
        assert_eq!(parse(&over), Err(ParseError::Depth));
        // Brackets inside strings, escaped quotes included, do not count.
        let in_string = format!(r#"{{"jsonrpc":"2.0","method":"\"{}"}}"#, "[".repeat(100));
        assert!(parse(&in_string).is_ok());
        // Unbalanced garbage deeper than the limit is a depth error before it is a syntax error.
        assert_eq!(parse(&"[".repeat(10_000)), Err(ParseError::Depth));
    }

    #[test]
    fn enforces_string_lengths() {
        let ok = format!(
            r#"{{"jsonrpc":"2.0","method":"m","params":{{"s":"{}"}}}}"#,
            "a".repeat(MAX_STRING)
        );
        let long = format!(
            r#"{{"jsonrpc":"2.0","method":"m","params":{{"s":"{}"}}}}"#,
            "a".repeat(MAX_STRING + 1)
        );
        let key = format!(
            r#"{{"jsonrpc":"2.0","method":"m","params":{{"{}":1}}}}"#,
            "k".repeat(MAX_STRING + 1)
        );
        assert!(parse(&ok).is_ok());
        assert_eq!(parse(&long), Err(ParseError::StringTooLong));
        assert_eq!(parse(&key), Err(ParseError::StringTooLong));
    }

    #[test]
    fn rejects_bad_shapes() {
        let cases = [
            "[]",
            r#"{"jsonrpc":"1.0","method":"m"}"#,
            r#"{"method":"m"}"#,
            r#"{"jsonrpc":"2.0","method":1}"#,
            r#"{"jsonrpc":"2.0","method":"m","id":1.5}"#,
            r#"{"jsonrpc":"2.0","method":"m","id":null}"#,
            r#"{"jsonrpc":"2.0","method":"m","params":3}"#,
            r#"{"jsonrpc":"2.0","id":1}"#,
            r#"{"jsonrpc":"2.0","id":1,"result":1,"error":{"code":1,"message":""}}"#,
            r#"{"jsonrpc":"2.0","id":null,"result":1}"#,
            r#"{"jsonrpc":"2.0","result":1}"#,
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":"x","message":""}}"#,
        ];
        for case in cases {
            assert!(matches!(parse(case), Err(ParseError::Invalid(_))), "{case}");
        }
        assert_eq!(Message::parse(b"{\"a\":\"\xff\"}"), Err(ParseError::Parse));
        assert_eq!(parse("{"), Err(ParseError::Parse));
    }

    #[test]
    fn typed_params_default_when_absent() {
        #[derive(serde::Deserialize, Default, PartialEq, Debug)]
        struct P {
            #[serde(default)]
            n: u32,
        }
        assert_eq!(decode_params::<P>(None), Ok(P::default()));
        let bad = decode_params::<P>(Some(&json!({"n": "x"}))).unwrap_err();
        assert_eq!(bad.known_code(), Some(ErrorCode::InvalidParams));
    }
}
