use crate::http_transport::{self, HttpFetchResult};
use crate::plugin_host::{RuntimePluginExecutor, RuntimePluginFetchRequest, RuntimePluginOutput};
use crate::request::RuntimeSource;
use crate::{RuntimeError, RuntimeResult};
use hmac::{Hmac, KeyInit, Mac};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha256 = Hmac<Sha256>;

pub const S3_FETCHER_MODULE_ID: &str = "pixa.fetcher.s3";

const HEADER_REGION: &str = "x-pixa-s3-region";
const HEADER_ACCESS_KEY_ID: &str = "x-pixa-s3-access-key-id";
const HEADER_SECRET_ACCESS_KEY: &str = "x-pixa-s3-secret-access-key";
const HEADER_SESSION_TOKEN: &str = "x-pixa-s3-session-token";
const HEADER_ENDPOINT: &str = "x-pixa-s3-endpoint";
const HEADER_FORCE_PATH_STYLE: &str = "x-pixa-s3-force-path-style";
const EMPTY_SHA256_HEX: &str = "e3b0c44298fc1c149afbf4c8996fb924\
    27ae41e4649b934ca495991b7852b855";

/// Built-in runtime fetcher for AWS S3 object GET.
#[derive(Default)]
pub struct S3RuntimePluginExecutor;

impl RuntimePluginExecutor for S3RuntimePluginExecutor {
    fn fetch(
        &self,
        request: RuntimePluginFetchRequest<'_>,
    ) -> RuntimeResult<Option<RuntimePluginOutput>> {
        if !is_s3_source_kind(request.source_kind) {
            return Ok(None);
        }
        if request.video_frame.is_some() {
            return Err(RuntimeError::new(
                "fetch",
                false,
                "S3 fetcher does not support video frame requests",
            ));
        }
        let context = request.context.ok_or_else(|| {
            RuntimeError::new("fetch", true, "S3 fetcher requires host request context")
        })?;
        let config = S3FetchConfig::from_headers(&context.request.headers)?;
        let object = S3ObjectLocator::parse(request.locator)?;
        let signed = S3SignedGet::build(&object, &config, amz_datetime_now()?)?;

        let mut http_request = context.request.clone();
        http_request.source = RuntimeSource::Network {
            uri: signed.uri.clone(),
        };
        http_request.headers = signed.headers;
        http_request.limits.max_encoded_bytes = http_request
            .limits
            .max_encoded_bytes
            .min(request.max_output_bytes);

        match http_transport::fetch(
            context.network_concurrency,
            &http_request,
            &signed.uri,
            None,
            context.cancel_token,
            context.progress_sink,
        )? {
            HttpFetchResult::Fetched(outcome) => {
                Ok(Some(RuntimePluginOutput::from_vec(outcome.bytes, None)))
            }
            HttpFetchResult::NotModified(_) => Err(RuntimeError::new(
                "fetch",
                true,
                "S3 fetcher received an unexpected not-modified response",
            )),
        }
    }
}

fn is_s3_source_kind(source_kind: &str) -> bool {
    matches!(
        source_kind.trim().to_ascii_lowercase().as_str(),
        "s3" | "s3-object"
    )
}

struct S3FetchConfig {
    region: String,
    access_key_id: String,
    secret_access_key: String,
    session_token: Option<String>,
    endpoint: Option<S3Endpoint>,
    force_path_style: bool,
}

impl S3FetchConfig {
    fn from_headers(headers: &BTreeMap<String, String>) -> RuntimeResult<Self> {
        Ok(Self {
            region: required_header(headers, HEADER_REGION)?,
            access_key_id: required_header(headers, HEADER_ACCESS_KEY_ID)?,
            secret_access_key: required_header(headers, HEADER_SECRET_ACCESS_KEY)?,
            session_token: optional_header(headers, HEADER_SESSION_TOKEN),
            endpoint: optional_header(headers, HEADER_ENDPOINT)
                .map(|value| S3Endpoint::parse(&value))
                .transpose()?,
            force_path_style: optional_header(headers, HEADER_FORCE_PATH_STYLE)
                .as_deref()
                .is_some_and(parse_truthy_header),
        })
    }
}

#[derive(Clone)]
struct S3Endpoint {
    scheme: String,
    authority: String,
    path_prefix: String,
}

impl S3Endpoint {
    fn parse(value: &str) -> RuntimeResult<Self> {
        let uri = value
            .parse::<http::Uri>()
            .map_err(|_| RuntimeError::new("fetch", false, "invalid S3 endpoint URI"))?;
        let scheme = uri.scheme_str().ok_or_else(|| {
            RuntimeError::new(
                "fetch",
                false,
                "S3 endpoint must include http or https scheme",
            )
        })?;
        if !matches!(scheme, "http" | "https") {
            return Err(RuntimeError::new(
                "fetch",
                false,
                "S3 endpoint scheme must be http or https",
            ));
        }
        let authority = uri
            .authority()
            .map(|authority| authority.as_str().to_string())
            .ok_or_else(|| RuntimeError::new("fetch", false, "S3 endpoint must include a host"))?;
        let path_and_query = uri.path_and_query();
        if path_and_query.is_some_and(|value| value.query().is_some()) {
            return Err(RuntimeError::new(
                "fetch",
                false,
                "S3 endpoint must not include a query string",
            ));
        }
        let path_prefix = path_and_query
            .map(|value| value.path().trim_end_matches('/').to_string())
            .filter(|value| !value.is_empty() && value != "/")
            .unwrap_or_default();
        Ok(Self {
            scheme: scheme.to_string(),
            authority,
            path_prefix,
        })
    }
}

struct S3ObjectLocator {
    bucket: String,
    key: String,
    query: Vec<(String, String)>,
}

impl S3ObjectLocator {
    fn parse(locator: &str) -> RuntimeResult<Self> {
        let uri = locator
            .parse::<http::Uri>()
            .map_err(|_| RuntimeError::new("fetch", false, "invalid S3 locator"))?;
        if uri.scheme_str() != Some("s3") {
            return Err(RuntimeError::new(
                "fetch",
                false,
                "S3 locator must use the s3 scheme",
            ));
        }
        let bucket = uri
            .authority()
            .map(|authority| authority.as_str().trim().to_string())
            .filter(|value| !value.is_empty())
            .ok_or_else(|| RuntimeError::new("fetch", false, "S3 locator must include a bucket"))?;
        if bucket.contains('@') || bucket.contains('/') || bucket.chars().any(char::is_whitespace) {
            return Err(RuntimeError::new("fetch", false, "invalid S3 bucket name"));
        }
        let path_and_query = uri.path_and_query().ok_or_else(|| {
            RuntimeError::new("fetch", false, "S3 locator must include an object key")
        })?;
        let raw_key = path_and_query.path().trim_start_matches('/');
        let key = percent_decode_utf8(raw_key)?;
        if key.is_empty() {
            return Err(RuntimeError::new("fetch", false, "S3 object key is empty"));
        }
        let query = parse_query(path_and_query.query().unwrap_or(""))?;
        Ok(Self { bucket, key, query })
    }
}

struct S3SignedGet {
    uri: String,
    headers: BTreeMap<String, String>,
}

impl S3SignedGet {
    fn build(
        object: &S3ObjectLocator,
        config: &S3FetchConfig,
        date: AmzDateTime,
    ) -> RuntimeResult<Self> {
        let endpoint = config.endpoint.clone().unwrap_or_else(|| S3Endpoint {
            scheme: "https".to_string(),
            authority: format!("s3.{}.amazonaws.com", config.region),
            path_prefix: String::new(),
        });
        let path_style = config.force_path_style;
        let authority = if path_style {
            endpoint.authority.clone()
        } else {
            if !is_virtual_host_bucket(&object.bucket) {
                return Err(RuntimeError::new(
                    "fetch",
                    false,
                    "S3 bucket requires path-style endpoint",
                ));
            }
            format!("{}.{}", object.bucket, endpoint.authority)
        };
        let canonical_uri = if path_style {
            join_uri_path(&endpoint.path_prefix, Some(&object.bucket), &object.key)
        } else {
            join_uri_path(&endpoint.path_prefix, None, &object.key)
        };
        let canonical_query = canonical_query(&object.query);
        let uri = if canonical_query.is_empty() {
            format!("{}://{}{}", endpoint.scheme, authority, canonical_uri)
        } else {
            format!(
                "{}://{}{}?{}",
                endpoint.scheme, authority, canonical_uri, canonical_query
            )
        };
        let amz_date = date.timestamp;
        let date_scope = date.date;
        let mut signing_headers = BTreeMap::from([
            ("host".to_string(), authority.clone()),
            (
                "x-amz-content-sha256".to_string(),
                EMPTY_SHA256_HEX.to_string(),
            ),
            ("x-amz-date".to_string(), amz_date.clone()),
        ]);
        if let Some(token) = config.session_token.as_deref() {
            signing_headers.insert("x-amz-security-token".to_string(), token.to_string());
        }
        let signed_headers = signing_headers
            .keys()
            .cloned()
            .collect::<Vec<String>>()
            .join(";");
        let canonical_headers = signing_headers
            .iter()
            .map(|(name, value)| format!("{name}:{}\n", normalize_header_value(value)))
            .collect::<String>();
        let canonical_request = format!(
            "GET\n{canonical_uri}\n{canonical_query}\n{canonical_headers}\n{signed_headers}\n{EMPTY_SHA256_HEX}"
        );
        let credential_scope = format!("{date_scope}/{}/s3/aws4_request", config.region);
        let string_to_sign = format!(
            "AWS4-HMAC-SHA256\n{amz_date}\n{credential_scope}\n{}",
            sha256_hex(canonical_request.as_bytes())
        );
        let signature = sigv4_signature(
            &config.secret_access_key,
            &date_scope,
            &config.region,
            string_to_sign.as_bytes(),
        )?;
        let authorization = format!(
            "AWS4-HMAC-SHA256 Credential={}/{credential_scope}, SignedHeaders={signed_headers}, Signature={signature}",
            config.access_key_id
        );
        let mut headers = signing_headers;
        headers.insert("authorization".to_string(), authorization);
        Ok(Self { uri, headers })
    }
}

#[derive(Clone)]
struct AmzDateTime {
    date: String,
    timestamp: String,
}

fn amz_datetime_now() -> RuntimeResult<AmzDateTime> {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| RuntimeError::new("fetch", true, "system clock is before Unix epoch"))?
        .as_secs();
    Ok(amz_datetime_from_unix_seconds(seconds))
}

fn amz_datetime_from_unix_seconds(seconds: u64) -> AmzDateTime {
    let days = (seconds / 86_400) as i64;
    let second_of_day = seconds % 86_400;
    let (year, month, day) = civil_from_days(days);
    let hour = second_of_day / 3_600;
    let minute = (second_of_day % 3_600) / 60;
    let second = second_of_day % 60;
    AmzDateTime {
        date: format!("{year:04}{month:02}{day:02}"),
        timestamp: format!("{year:04}{month:02}{day:02}T{hour:02}{minute:02}{second:02}Z"),
    }
}

fn civil_from_days(days_since_unix_epoch: i64) -> (i64, i64, i64) {
    let z = days_since_unix_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    let year = y + i64::from(month <= 2);
    (year, month, day)
}

fn sigv4_signature(
    secret_access_key: &str,
    date: &str,
    region: &str,
    string_to_sign: &[u8],
) -> RuntimeResult<String> {
    let date_key = hmac_sha256(
        format!("AWS4{secret_access_key}").as_bytes(),
        date.as_bytes(),
    )?;
    let region_key = hmac_sha256(&date_key, region.as_bytes())?;
    let service_key = hmac_sha256(&region_key, b"s3")?;
    let signing_key = hmac_sha256(&service_key, b"aws4_request")?;
    Ok(hex_lower(&hmac_sha256(&signing_key, string_to_sign)?))
}

fn hmac_sha256(key: &[u8], input: &[u8]) -> RuntimeResult<Vec<u8>> {
    let mut mac = HmacSha256::new_from_slice(key)
        .map_err(|_| RuntimeError::new("fetch", true, "failed to initialize S3 signing key"))?;
    mac.update(input);
    Ok(mac.finalize().into_bytes().to_vec())
}

fn sha256_hex(input: &[u8]) -> String {
    hex_lower(&Sha256::digest(input))
}

fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

fn required_header(headers: &BTreeMap<String, String>, name: &str) -> RuntimeResult<String> {
    optional_header(headers, name)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| RuntimeError::new("fetch", false, format!("missing S3 header {name}")))
}

fn optional_header(headers: &BTreeMap<String, String>, name: &str) -> Option<String> {
    headers
        .iter()
        .find(|(candidate, _)| candidate.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn parse_truthy_header(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "path-style" | "path_style"
    )
}

fn join_uri_path(prefix: &str, bucket: Option<&str>, key: &str) -> String {
    let mut path = String::new();
    if !prefix.is_empty() {
        path.push('/');
        path.push_str(prefix.trim_matches('/'));
    }
    if let Some(bucket) = bucket {
        path.push('/');
        path.push_str(&percent_encode_path(bucket));
    }
    path.push('/');
    path.push_str(&percent_encode_path(key));
    path
}

fn canonical_query(query: &[(String, String)]) -> String {
    let mut pairs = query
        .iter()
        .map(|(name, value)| (percent_encode_query(name), percent_encode_query(value)))
        .collect::<Vec<(String, String)>>();
    pairs.sort();
    pairs
        .into_iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect::<Vec<String>>()
        .join("&")
}

fn parse_query(query: &str) -> RuntimeResult<Vec<(String, String)>> {
    if query.is_empty() {
        return Ok(Vec::new());
    }
    query
        .split('&')
        .map(|pair| {
            let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
            Ok((percent_decode_utf8(name)?, percent_decode_utf8(value)?))
        })
        .collect()
}

fn percent_decode_utf8(value: &str) -> RuntimeResult<String> {
    let mut bytes = Vec::with_capacity(value.len());
    let mut iter = value.as_bytes().iter().copied();
    while let Some(byte) = iter.next() {
        if byte != b'%' {
            bytes.push(byte);
            continue;
        }
        let high = iter.next().ok_or_else(invalid_percent_encoding)?;
        let low = iter.next().ok_or_else(invalid_percent_encoding)?;
        bytes.push((hex_value(high)? << 4) | hex_value(low)?);
    }
    String::from_utf8(bytes)
        .map_err(|_| RuntimeError::new("fetch", false, "S3 locator is not valid UTF-8"))
}

fn invalid_percent_encoding() -> RuntimeError {
    RuntimeError::new("fetch", false, "invalid percent encoding in S3 locator")
}

fn hex_value(byte: u8) -> RuntimeResult<u8> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        b'A'..=b'F' => Ok(byte - b'A' + 10),
        _ => Err(invalid_percent_encoding()),
    }
}

fn percent_encode_path(value: &str) -> String {
    percent_encode(value, true)
}

fn percent_encode_query(value: &str) -> String {
    percent_encode(value, false)
}

fn percent_encode(value: &str, preserve_slash: bool) -> String {
    let mut output = String::with_capacity(value.len());
    for byte in value.bytes() {
        if is_unreserved(byte) || (preserve_slash && byte == b'/') {
            output.push(byte as char);
        } else {
            output.push('%');
            output.push_str(&hex_lower(&[byte]).to_ascii_uppercase());
        }
    }
    output
}

fn is_unreserved(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~')
}

fn normalize_header_value(value: &str) -> String {
    value.split_whitespace().collect::<Vec<&str>>().join(" ")
}

fn is_virtual_host_bucket(bucket: &str) -> bool {
    !bucket.is_empty()
        && bucket.len() <= 63
        && !bucket.starts_with('-')
        && !bucket.ends_with('-')
        && bucket
            .chars()
            .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '-' || ch == '.')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_amz_datetime_from_unix_seconds() {
        let formatted = amz_datetime_from_unix_seconds(1_684_064_096);

        assert_eq!(formatted.date, "20230514");
        assert_eq!(formatted.timestamp, "20230514T113456Z");
    }

    #[test]
    fn canonicalizes_s3_query_parameters() {
        let query = parse_query("versionId=3&response-content-type=image%2Fgif&empty=")
            .expect("query should parse");

        assert_eq!(
            canonical_query(&query),
            "empty=&response-content-type=image%2Fgif&versionId=3"
        );
    }
}
