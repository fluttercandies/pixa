use std::collections::BTreeMap;

#[derive(Clone, Debug)]
pub(crate) enum JsonValue {
    Object(BTreeMap<String, JsonValue>),
    Array(Vec<JsonValue>),
    String(String),
    Number(i64),
    Bool(bool),
    Null,
}

impl JsonValue {
    pub(crate) fn as_object(&self) -> Option<&BTreeMap<String, JsonValue>> {
        match self {
            JsonValue::Object(value) => Some(value),
            _ => None,
        }
    }

    pub(crate) fn as_array(&self) -> Option<&[JsonValue]> {
        match self {
            JsonValue::Array(value) => Some(value),
            _ => None,
        }
    }
}

pub(crate) struct JsonParser<'a> {
    input: &'a [u8],
    index: usize,
}

impl<'a> JsonParser<'a> {
    pub(crate) fn new(input: &'a str) -> Self {
        Self {
            input: input.as_bytes(),
            index: 0,
        }
    }

    pub(crate) fn parse(mut self) -> Result<JsonValue, String> {
        let value = self.parse_value()?;
        self.skip_whitespace();
        if self.index != self.input.len() {
            return Err("trailing bytes after runtime plugin plan JSON".to_string());
        }
        Ok(value)
    }

    fn parse_value(&mut self) -> Result<JsonValue, String> {
        self.skip_whitespace();
        match self.peek() {
            Some(b'{') => self.parse_object(),
            Some(b'[') => self.parse_array(),
            Some(b'"') => self.parse_string().map(JsonValue::String),
            Some(b't') => self.parse_literal(b"true", JsonValue::Bool(true)),
            Some(b'f') => self.parse_literal(b"false", JsonValue::Bool(false)),
            Some(b'n') => self.parse_literal(b"null", JsonValue::Null),
            Some(b'-' | b'0'..=b'9') => self.parse_number().map(JsonValue::Number),
            Some(byte) => Err(format!("unexpected JSON byte 0x{byte:02x}")),
            None => Err("unexpected end of runtime plugin plan JSON".to_string()),
        }
    }

    fn parse_object(&mut self) -> Result<JsonValue, String> {
        self.expect(b'{')?;
        let mut object = BTreeMap::new();
        loop {
            self.skip_whitespace();
            if self.consume_if(b'}') {
                break;
            }
            let key = self.parse_string()?;
            self.skip_whitespace();
            self.expect(b':')?;
            let value = self.parse_value()?;
            object.insert(key, value);
            self.skip_whitespace();
            if self.consume_if(b'}') {
                break;
            }
            self.expect(b',')?;
        }
        Ok(JsonValue::Object(object))
    }

    fn parse_array(&mut self) -> Result<JsonValue, String> {
        self.expect(b'[')?;
        let mut array = Vec::new();
        loop {
            self.skip_whitespace();
            if self.consume_if(b']') {
                break;
            }
            array.push(self.parse_value()?);
            self.skip_whitespace();
            if self.consume_if(b']') {
                break;
            }
            self.expect(b',')?;
        }
        Ok(JsonValue::Array(array))
    }

    fn parse_string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let mut bytes = Vec::new();
        loop {
            let byte = self
                .next()
                .ok_or_else(|| "unterminated JSON string".to_string())?;
            match byte {
                b'"' => break,
                b'\\' => self.parse_escape(&mut bytes)?,
                0x00..=0x1f => return Err("JSON string contains a control byte".to_string()),
                value => bytes.push(value),
            }
        }
        String::from_utf8(bytes).map_err(|error| format!("invalid UTF-8 in JSON string: {error}"))
    }

    fn parse_escape(&mut self, output: &mut Vec<u8>) -> Result<(), String> {
        let escaped = self
            .next()
            .ok_or_else(|| "unterminated JSON escape".to_string())?;
        match escaped {
            b'"' => output.push(b'"'),
            b'\\' => output.push(b'\\'),
            b'/' => output.push(b'/'),
            b'b' => output.push(0x08),
            b'f' => output.push(0x0c),
            b'n' => output.push(b'\n'),
            b'r' => output.push(b'\r'),
            b't' => output.push(b'\t'),
            b'u' => {
                let codepoint = self.parse_hex_codepoint()?;
                let character = char::from_u32(codepoint)
                    .ok_or_else(|| "invalid JSON unicode escape".to_string())?;
                let mut buffer = [0_u8; 4];
                output.extend_from_slice(character.encode_utf8(&mut buffer).as_bytes());
            }
            _ => return Err("invalid JSON escape".to_string()),
        }
        Ok(())
    }

    fn parse_hex_codepoint(&mut self) -> Result<u32, String> {
        let mut value = 0_u32;
        for _ in 0..4 {
            let byte = self
                .next()
                .ok_or_else(|| "truncated JSON unicode escape".to_string())?;
            let digit = hex_value(byte)?;
            value = value
                .checked_mul(16)
                .and_then(|current| current.checked_add(digit))
                .ok_or_else(|| "JSON unicode escape overflow".to_string())?;
        }
        Ok(value)
    }

    fn parse_number(&mut self) -> Result<i64, String> {
        let start = self.index;
        if self.consume_if(b'-') && !matches!(self.peek(), Some(b'0'..=b'9')) {
            return Err("invalid JSON number".to_string());
        }
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.index += 1;
        }
        if matches!(self.peek(), Some(b'.' | b'e' | b'E')) {
            return Err("runtime plugin plan only accepts integer JSON numbers".to_string());
        }
        std::str::from_utf8(&self.input[start..self.index])
            .map_err(|error| format!("invalid JSON number encoding: {error}"))?
            .parse::<i64>()
            .map_err(|error| format!("invalid JSON integer: {error}"))
    }

    fn parse_literal(&mut self, literal: &[u8], value: JsonValue) -> Result<JsonValue, String> {
        if self.input.get(self.index..self.index + literal.len()) == Some(literal) {
            self.index += literal.len();
            Ok(value)
        } else {
            Err("invalid JSON literal".to_string())
        }
    }

    fn skip_whitespace(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\n' | b'\r' | b'\t')) {
            self.index += 1;
        }
    }

    fn expect(&mut self, expected: u8) -> Result<(), String> {
        match self.next() {
            Some(value) if value == expected => Ok(()),
            _ => Err(format!("expected JSON byte {}", expected as char)),
        }
    }

    fn consume_if(&mut self, expected: u8) -> bool {
        if self.peek() == Some(expected) {
            self.index += 1;
            true
        } else {
            false
        }
    }

    fn peek(&self) -> Option<u8> {
        self.input.get(self.index).copied()
    }

    fn next(&mut self) -> Option<u8> {
        let value = self.peek()?;
        self.index += 1;
        Some(value)
    }
}

fn hex_value(byte: u8) -> Result<u32, String> {
    match byte {
        b'0'..=b'9' => Ok(u32::from(byte - b'0')),
        b'a'..=b'f' => Ok(u32::from(byte - b'a' + 10)),
        b'A'..=b'F' => Ok(u32::from(byte - b'A' + 10)),
        _ => Err("invalid JSON unicode escape digit".to_string()),
    }
}
