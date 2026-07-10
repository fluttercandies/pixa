use crate::cancel::{cancelled_error, RuntimeCancelToken, RuntimeCancelWaker};
use crate::metadata::{image_metadata, ImageMetadataFormat};
use crate::progress::{
    emit_progress, RuntimeProgressEvent, RuntimeProgressSink, RuntimeProgressStage,
};
use crate::request::RuntimeRequest;
use crate::{RuntimeError, RuntimeResult};
use bytes::Bytes;
use http::header::{
    AGE, AUTHORIZATION, CACHE_CONTROL, CONTENT_LENGTH, COOKIE, DATE, ETAG, EXPIRES,
    IF_MODIFIED_SINCE, IF_NONE_MATCH, LAST_MODIFIED, LOCATION, PROXY_AUTHORIZATION, VARY,
};
use http::{HeaderMap, HeaderName, HeaderValue, Method, Request, StatusCode, Uri};
use http_body_util::{BodyExt, Empty};
use hyper::rt::{Read as HyperRead, ReadBufCursor, Write as HyperWrite};
use hyper_rustls::{builderstates::WantsSchemes, HttpsConnectorBuilder};
use hyper_util::client::legacy::connect::proxy::Tunnel;
use hyper_util::client::legacy::connect::{Connected, Connection, HttpConnector};
use hyper_util::client::legacy::Client;
use hyper_util::client::proxy::matcher::Matcher;
use hyper_util::rt::TokioExecutor;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::runtime::{Builder as RuntimeBuilder, Runtime};
use tower_service::Service;

type DirectHttpClient = Client<HttpConnector, Empty<Bytes>>;
type DirectHttpsConnector = hyper_rustls::HttpsConnector<HttpConnector>;
type DirectHttpsClient = Client<DirectHttpsConnector, Empty<Bytes>>;
type HttpProxyClient = Client<ProxiedHttpConnector, Empty<Bytes>>;
type HttpsProxyConnector = hyper_rustls::HttpsConnector<Tunnel<HttpConnector>>;
type HttpsProxyClient = Client<HttpsProxyConnector, Empty<Bytes>>;

static HTTP_TRANSPORT: OnceLock<Box<dyn RuntimeHttpTransport>> = OnceLock::new();

#[derive(Clone)]
enum HyperClient {
    DirectHttp(DirectHttpClient),
    DirectHttps(DirectHttpsClient),
    HttpProxy(HttpProxyClient),
    HttpsProxy(HttpsProxyClient),
}

impl HyperClient {
    async fn request(
        &self,
        request: Request<Empty<Bytes>>,
    ) -> Result<http::Response<hyper::body::Incoming>, hyper_util::client::legacy::Error> {
        match self {
            Self::DirectHttp(client) => client.request(request).await,
            Self::DirectHttps(client) => client.request(request).await,
            Self::HttpProxy(client) => client.request(request).await,
            Self::HttpsProxy(client) => client.request(request).await,
        }
    }
}

#[derive(Clone)]
struct ProxiedHttpConnector {
    inner: HttpConnector,
    proxy_uri: Uri,
}

struct ProxiedConnection<T> {
    inner: T,
}

struct ProxyPolicy {
    matcher: Matcher,
}

#[derive(Clone, Debug)]
enum ProxyRoute {
    DirectHttp,
    DirectHttps,
    HttpProxy { uri: Uri, auth: Option<HeaderValue> },
    HttpsProxy { uri: Uri, auth: Option<HeaderValue> },
}

impl ProxyPolicy {
    fn from_env() -> Self {
        if std::env::var_os("REQUEST_METHOD").is_some() {
            return Self::from_values("", "", "", "");
        }
        Self::from_values(
            &first_env(&["PIXA_ALL_PROXY", "ALL_PROXY", "all_proxy"]),
            &first_env(&["PIXA_HTTP_PROXY", "HTTP_PROXY", "http_proxy"]),
            &first_env(&["PIXA_HTTPS_PROXY", "HTTPS_PROXY", "https_proxy"]),
            &first_env(&["PIXA_NO_PROXY", "NO_PROXY", "no_proxy"]),
        )
    }

    fn from_values(all: &str, http: &str, https: &str, no: &str) -> Self {
        Self {
            matcher: Matcher::builder()
                .all(all)
                .http(http)
                .https(https)
                .no(no_proxy_with_loopback(no))
                .build(),
        }
    }

    fn route(&self, uri: &Uri) -> RuntimeResult<ProxyRoute> {
        let Some(intercept) = self.matcher.intercept(uri) else {
            return match uri.scheme_str() {
                Some("https") => Ok(ProxyRoute::DirectHttps),
                _ => Ok(ProxyRoute::DirectHttp),
            };
        };
        let proxy_uri = validate_http_proxy_uri(intercept.uri())?;
        let auth = intercept.basic_auth().cloned();
        match uri.scheme_str() {
            Some("http") => Ok(ProxyRoute::HttpProxy {
                uri: proxy_uri,
                auth,
            }),
            Some("https") => Ok(ProxyRoute::HttpsProxy {
                uri: proxy_uri,
                auth,
            }),
            _ => Ok(ProxyRoute::DirectHttp),
        }
    }
}

impl ProxyRoute {
    fn cache_key(&self, connect_timeout_ms: u64) -> String {
        match self {
            Self::DirectHttp => format!("direct-http:{connect_timeout_ms}"),
            Self::DirectHttps => format!("direct-https:{connect_timeout_ms}"),
            Self::HttpProxy { uri, auth } => format!(
                "http-proxy:{}",
                proxy_route_identity(1, connect_timeout_ms, uri, auth)
            ),
            Self::HttpsProxy { uri, auth } => format!(
                "https-proxy:{}",
                proxy_route_identity(2, connect_timeout_ms, uri, auth)
            ),
        }
    }
}

#[derive(Debug)]
pub(crate) struct HttpFetchOutcome {
    pub(crate) bytes: Vec<u8>,
    pub(crate) source_label: String,
    pub(crate) cache_metadata: HttpCacheMetadata,
}

#[derive(Debug)]
pub(crate) struct HttpNotModifiedOutcome {
    pub(crate) source_label: String,
    pub(crate) cache_metadata: HttpCacheMetadata,
}

#[derive(Debug)]
pub(crate) enum HttpFetchResult {
    Fetched(HttpFetchOutcome),
    NotModified(HttpNotModifiedOutcome),
}

#[derive(Clone, Debug, Default)]
pub(crate) struct HttpCacheMetadata {
    pub(crate) etag: Option<String>,
    pub(crate) last_modified: Option<String>,
    pub(crate) cache_control: Option<String>,
    pub(crate) date: Option<String>,
    pub(crate) expires: Option<String>,
    pub(crate) age: Option<String>,
    pub(crate) vary: Option<String>,
    pub(crate) vary_request_key: Option<String>,
    pub(crate) fetched_at_ms: i64,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct HttpConditionalHeaders {
    pub(crate) etag: Option<String>,
    pub(crate) last_modified: Option<String>,
}

pub(crate) trait RuntimeHttpTransport: Send + Sync {
    fn fetch(
        &self,
        network_concurrency: usize,
        request: &RuntimeRequest,
        uri: Uri,
        conditional: Option<&HttpConditionalHeaders>,
        cancel_token: Option<&RuntimeCancelToken>,
        progress_sink: Option<&dyn RuntimeProgressSink>,
    ) -> RuntimeResult<HttpFetchResult>;
}

struct HttpTransport {
    runtime: Runtime,
    clients: Mutex<BTreeMap<String, HyperClient>>,
    gate: Arc<AdaptiveConcurrencyGate>,
    proxy_policy: ProxyPolicy,
}

struct AdaptiveConcurrencyGate {
    state: Mutex<AdaptiveConcurrencyState>,
    notify: tokio::sync::Notify,
}

#[derive(Debug)]
struct AdaptiveConcurrencyState {
    active: usize,
    limit: usize,
}

struct AdaptiveConcurrencyPermit {
    gate: Arc<AdaptiveConcurrencyGate>,
}

struct AsyncCancelNotify {
    notify: tokio::sync::Notify,
}

impl AsyncCancelNotify {
    fn new() -> Self {
        Self {
            notify: tokio::sync::Notify::new(),
        }
    }
}

impl RuntimeCancelWaker for AsyncCancelNotify {
    fn wake_cancelled(&self) {
        self.notify.notify_one();
    }
}

impl ProxiedHttpConnector {
    fn new(proxy_uri: Uri, connect_timeout_ms: u64) -> Self {
        Self {
            inner: build_http_connector(connect_timeout_ms),
            proxy_uri,
        }
    }
}

impl Service<Uri> for ProxiedHttpConnector {
    type Response = ProxiedConnection<<HttpConnector as Service<Uri>>::Response>;
    type Error = <HttpConnector as Service<Uri>>::Error;
    type Future = Pin<Box<dyn Future<Output = Result<Self::Response, Self::Error>> + Send>>;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Service::<Uri>::poll_ready(&mut self.inner, cx)
    }

    fn call(&mut self, _dst: Uri) -> Self::Future {
        let connecting = self.inner.call(self.proxy_uri.clone());
        Box::pin(async move { connecting.await.map(|inner| ProxiedConnection { inner }) })
    }
}

impl<T> Connection for ProxiedConnection<T>
where
    T: Connection,
{
    fn connected(&self) -> Connected {
        self.inner.connected().proxy(true)
    }
}

impl<T> HyperRead for ProxiedConnection<T>
where
    T: HyperRead + Unpin,
{
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: ReadBufCursor<'_>,
    ) -> Poll<Result<(), std::io::Error>> {
        Pin::new(&mut self.get_mut().inner).poll_read(cx, buf)
    }
}

impl<T> HyperWrite for ProxiedConnection<T>
where
    T: HyperWrite + Unpin,
{
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<Result<usize, std::io::Error>> {
        Pin::new(&mut self.get_mut().inner).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), std::io::Error>> {
        Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }

    fn poll_shutdown(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Result<(), std::io::Error>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

impl AdaptiveConcurrencyGate {
    fn new(limit: usize) -> Self {
        Self {
            state: Mutex::new(AdaptiveConcurrencyState {
                active: 0,
                limit: limit.max(1),
            }),
            notify: tokio::sync::Notify::new(),
        }
    }

    async fn acquire(self: &Arc<Self>, limit: usize) -> RuntimeResult<AdaptiveConcurrencyPermit> {
        let limit = limit.max(1);
        loop {
            let notified = self.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            {
                let mut state = self.state.lock().map_err(|_| {
                    RuntimeError::new("fetch", true, "HTTP concurrency guard poisoned")
                })?;
                state.limit = limit;
                if state.active < state.limit {
                    state.active += 1;
                    return Ok(AdaptiveConcurrencyPermit { gate: self.clone() });
                }
            }
            notified.await;
        }
    }

    fn release(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.active = state.active.saturating_sub(1);
        }
        self.notify.notify_one();
    }
}

impl Drop for AdaptiveConcurrencyPermit {
    fn drop(&mut self) {
        self.gate.release();
    }
}

fn http_runtime_worker_threads(available_parallelism: usize) -> usize {
    available_parallelism.clamp(1, 2)
}

impl HttpTransport {
    fn new(network_concurrency: usize) -> RuntimeResult<Self> {
        Self::new_with_proxy_policy(network_concurrency, ProxyPolicy::from_env())
    }

    fn new_with_proxy_policy(
        network_concurrency: usize,
        proxy_policy: ProxyPolicy,
    ) -> RuntimeResult<Self> {
        let available_parallelism = std::thread::available_parallelism()
            .map(|parallelism| parallelism.get())
            .unwrap_or(1);
        let runtime = RuntimeBuilder::new_multi_thread()
            .worker_threads(http_runtime_worker_threads(available_parallelism))
            .thread_name("pixa-http")
            .enable_io()
            .enable_time()
            .build()
            .map_err(|error| {
                RuntimeError::new(
                    "fetch",
                    true,
                    format!("failed to initialize HTTP runtime: {error}"),
                )
            })?;

        Ok(Self {
            runtime,
            clients: Mutex::new(BTreeMap::new()),
            gate: Arc::new(AdaptiveConcurrencyGate::new(network_concurrency)),
            proxy_policy,
        })
    }

    fn fetch_hyper(
        &self,
        network_concurrency: usize,
        request: &RuntimeRequest,
        uri: Uri,
        conditional: Option<&HttpConditionalHeaders>,
        cancel_token: Option<&RuntimeCancelToken>,
        progress_sink: Option<&dyn RuntimeProgressSink>,
    ) -> RuntimeResult<HttpFetchResult> {
        self.runtime
            .block_on(async {
                tokio::time::timeout(
                    Duration::from_millis(request.limits.timeout_ms),
                    self.fetch_async(
                        network_concurrency,
                        request,
                        uri,
                        conditional,
                        cancel_token,
                        progress_sink,
                    ),
                )
                .await
            })
            .map_err(|_| RuntimeError::new("fetch", true, "network request timed out"))?
    }

    async fn fetch_async(
        &self,
        network_concurrency: usize,
        request: &RuntimeRequest,
        uri: Uri,
        conditional: Option<&HttpConditionalHeaders>,
        cancel_token: Option<&RuntimeCancelToken>,
        progress_sink: Option<&dyn RuntimeProgressSink>,
    ) -> RuntimeResult<HttpFetchResult> {
        ensure_not_cancelled(cancel_token)?;
        let _permit = self.gate.acquire(network_concurrency).await?;

        let mut headers = header_map(&request.headers)?;
        apply_conditional_headers(&mut headers, conditional)?;
        let mut current = uri;

        for redirect_count in 0..=request.limits.max_redirects {
            ensure_not_cancelled(cancel_token)?;
            let route = self.proxy_policy.route(&current)?;
            let client = self.client(request.limits.connect_timeout_ms, &route)?;
            let request_headers = headers_for_route(&headers, &route);
            emit_progress(
                progress_sink,
                RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "fetch.request")
                    .with_message(redact_uri(&current.to_string())),
            );
            let response =
                send_get(&client, current.clone(), request_headers, cancel_token).await?;
            let status = response.status();

            if is_redirect_status(status) {
                if redirect_count == request.limits.max_redirects {
                    return Err(RuntimeError::new("fetch", true, "too many redirects"));
                }
                let location = response.headers().get(LOCATION).ok_or_else(|| {
                    RuntimeError::new("fetch", false, "redirect missing location")
                })?;
                let next = resolve_redirect_uri(&current, location)?;
                validate_redirect_transition(&current, &next, request.redirect_policy)?;
                if is_cross_host_redirect(&current, &next) {
                    if !request.redirect_policy.allow_cross_host_redirects {
                        return Err(RuntimeError::new(
                            "fetch",
                            false,
                            "refused cross-host redirect",
                        ));
                    }
                    strip_cross_host_sensitive_headers(&mut headers);
                }
                emit_progress(
                    progress_sink,
                    RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "fetch.redirect")
                        .with_message(redact_uri(&next.to_string())),
                );
                current = next;
                continue;
            }

            if status == StatusCode::NOT_MODIFIED {
                emit_progress(
                    progress_sink,
                    RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "fetch.notModified")
                        .with_message(redact_uri(&current.to_string())),
                );
                return Ok(HttpFetchResult::NotModified(HttpNotModifiedOutcome {
                    source_label: redact_uri(&current.to_string()),
                    cache_metadata: HttpCacheMetadata::from_headers(response.headers(), &headers),
                }));
            }

            if !status.is_success() {
                return Err(RuntimeError::new(
                    "fetch",
                    is_retryable_status(status),
                    format!("HTTP status {}", status.as_u16()),
                ));
            }

            let expected_bytes =
                validate_content_length(response.headers(), request.limits.max_encoded_bytes)?;
            let metadata = HttpCacheMetadata::from_headers(response.headers(), &headers);
            let bytes = read_body(
                response.into_body(),
                request.limits.max_encoded_bytes,
                Duration::from_millis(request.limits.idle_timeout_ms),
                cancel_token,
                progress_sink,
                expected_bytes,
            )
            .await?;
            emit_progress(
                progress_sink,
                RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "fetch.complete")
                    .with_bytes(bytes.len(), expected_bytes)
                    .with_message(redact_uri(&current.to_string())),
            );
            return Ok(HttpFetchResult::Fetched(HttpFetchOutcome {
                bytes,
                source_label: redact_uri(&current.to_string()),
                cache_metadata: metadata,
            }));
        }

        Err(RuntimeError::new("fetch", true, "too many redirects"))
    }

    fn client(&self, connect_timeout_ms: u64, route: &ProxyRoute) -> RuntimeResult<HyperClient> {
        let key = route.cache_key(connect_timeout_ms);
        let mut clients = self
            .clients
            .lock()
            .map_err(|_| RuntimeError::new("fetch", true, "HTTP client cache lock poisoned"))?;
        if let Some(client) = clients.get(&key) {
            return Ok(client.clone());
        }

        let client = build_client(connect_timeout_ms, route)?;
        clients.insert(key, client.clone());
        Ok(client)
    }
}

impl RuntimeHttpTransport for HttpTransport {
    fn fetch(
        &self,
        network_concurrency: usize,
        request: &RuntimeRequest,
        uri: Uri,
        conditional: Option<&HttpConditionalHeaders>,
        cancel_token: Option<&RuntimeCancelToken>,
        progress_sink: Option<&dyn RuntimeProgressSink>,
    ) -> RuntimeResult<HttpFetchResult> {
        self.fetch_hyper(
            network_concurrency,
            request,
            uri,
            conditional,
            cancel_token,
            progress_sink,
        )
    }
}

pub(crate) fn fetch(
    network_concurrency: usize,
    request: &RuntimeRequest,
    uri: &str,
    conditional: Option<&HttpConditionalHeaders>,
    cancel_token: Option<&RuntimeCancelToken>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
) -> RuntimeResult<HttpFetchResult> {
    let uri = parse_network_uri(uri)?;
    transport(network_concurrency)?.fetch(
        network_concurrency,
        request,
        uri,
        conditional,
        cancel_token,
        progress_sink,
    )
}

impl HttpCacheMetadata {
    fn from_headers(headers: &HeaderMap, request_headers: &HeaderMap) -> Self {
        let vary = header_list_string(headers, VARY);
        let vary_request_key = vary
            .as_deref()
            .and_then(|value| vary_request_key_for_headers(value, request_headers));
        Self {
            etag: header_string(headers, ETAG),
            last_modified: header_string(headers, LAST_MODIFIED),
            cache_control: header_list_string(headers, CACHE_CONTROL),
            date: header_string(headers, DATE),
            expires: header_string(headers, EXPIRES),
            age: header_string(headers, AGE),
            vary,
            vary_request_key,
            fetched_at_ms: crate::cache::now_millis(),
        }
    }
}

pub(crate) fn request_vary_key(
    vary: &str,
    request_headers: &BTreeMap<String, String>,
) -> RuntimeResult<Option<String>> {
    let request_headers = header_map(request_headers)?;
    Ok(vary_request_key_for_headers(vary, &request_headers))
}

fn vary_request_key_for_headers(vary: &str, headers: &HeaderMap) -> Option<String> {
    let mut names = BTreeSet::new();
    for name in vary
        .split(',')
        .map(str::trim)
        .filter(|name| !name.is_empty())
    {
        if name == "*" {
            return None;
        }
        names.insert(name.to_ascii_lowercase());
    }
    let mut hasher = Sha256::new();
    for name in names {
        hash_framed(&mut hasher, name.as_bytes());
        if let Some(value) = headers.get(name.as_str()) {
            hasher.update([1]);
            hash_framed(&mut hasher, value.as_bytes());
        } else {
            hasher.update([0]);
        }
    }
    Some(hex_lower(&hasher.finalize()))
}

fn hash_framed(hasher: &mut Sha256, value: &[u8]) {
    hasher.update(u64::try_from(value.len()).unwrap_or(u64::MAX).to_be_bytes());
    hasher.update(value);
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

fn headers_for_route(headers: &HeaderMap, route: &ProxyRoute) -> HeaderMap {
    let mut routed = headers.clone();
    routed.remove(PROXY_AUTHORIZATION);
    if let ProxyRoute::HttpProxy {
        auth: Some(auth), ..
    } = route
    {
        routed.insert(PROXY_AUTHORIZATION, auth.clone());
    }
    routed
}

fn validate_http_proxy_uri(uri: &Uri) -> RuntimeResult<Uri> {
    match (uri.scheme_str(), uri.authority()) {
        (Some("http"), Some(_)) => Ok(uri.clone()),
        (Some("https"), Some(_)) => Err(RuntimeError::new(
            "fetch",
            false,
            "HTTPS proxy endpoints are not supported; use an HTTP proxy endpoint for CONNECT",
        )),
        _ => Err(RuntimeError::new(
            "fetch",
            false,
            "proxy endpoint must be an absolute HTTP URI",
        )),
    }
}

fn first_env(names: &[&str]) -> String {
    names
        .iter()
        .find_map(|name| std::env::var(name).ok())
        .unwrap_or_default()
}

fn no_proxy_with_loopback(no_proxy: &str) -> String {
    const LOOPBACK_NO_PROXY: &str = "localhost,127.0.0.1,::1";
    let trimmed = no_proxy.trim();
    if trimmed.is_empty() {
        LOOPBACK_NO_PROXY.to_string()
    } else if trimmed.split(',').any(|entry| entry.trim() == "*") {
        trimmed.to_string()
    } else {
        format!("{trimmed},{LOOPBACK_NO_PROXY}")
    }
}

#[cfg(test)]
fn auth_cache_key(auth: &Option<HeaderValue>) -> String {
    let mut hasher = Sha256::new();
    hash_identity_field(&mut hasher, 0, b"pixa.http.proxy-auth.v2");
    hash_identity_field(&mut hasher, 1, &[u8::from(auth.is_some())]);
    if let Some(auth) = auth {
        hash_identity_field(&mut hasher, 2, auth.as_bytes());
    }
    format!("sha256:{}", hex_lower(&hasher.finalize()))
}

fn proxy_route_identity(
    route_kind: u8,
    connect_timeout_ms: u64,
    uri: &Uri,
    auth: &Option<HeaderValue>,
) -> String {
    let mut hasher = Sha256::new();
    hash_identity_field(&mut hasher, 0, b"pixa.http.proxy-route.v2");
    hash_identity_field(&mut hasher, 1, &[route_kind]);
    hash_identity_field(&mut hasher, 2, &connect_timeout_ms.to_be_bytes());
    hash_identity_field(&mut hasher, 3, uri.to_string().as_bytes());
    hash_identity_field(&mut hasher, 4, &[u8::from(auth.is_some())]);
    if let Some(auth) = auth {
        hash_identity_field(&mut hasher, 5, auth.as_bytes());
    }
    format!("sha256:{}", hex_lower(&hasher.finalize()))
}

fn hash_identity_field(hasher: &mut Sha256, tag: u8, value: &[u8]) {
    hasher.update([tag]);
    hash_framed(hasher, value);
}

fn header_string(headers: &HeaderMap, name: HeaderName) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn header_list_string(headers: &HeaderMap, name: HeaderName) -> Option<String> {
    let values = headers
        .get_all(name)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
    (!values.is_empty()).then(|| values.join(", "))
}

fn transport(network_concurrency: usize) -> RuntimeResult<&'static dyn RuntimeHttpTransport> {
    if let Some(transport) = HTTP_TRANSPORT.get() {
        return Ok(transport.as_ref());
    }

    let transport: Box<dyn RuntimeHttpTransport> =
        Box::new(HttpTransport::new(network_concurrency)?);
    if HTTP_TRANSPORT.set(transport).is_err() {
        return HTTP_TRANSPORT
            .get()
            .map(|transport| transport.as_ref())
            .ok_or_else(|| RuntimeError::new("fetch", true, "HTTP transport unavailable"));
    }
    HTTP_TRANSPORT
        .get()
        .map(|transport| transport.as_ref())
        .ok_or_else(|| RuntimeError::new("fetch", true, "HTTP transport unavailable"))
}

fn build_client(connect_timeout_ms: u64, route: &ProxyRoute) -> RuntimeResult<HyperClient> {
    match route {
        ProxyRoute::DirectHttp => Ok(HyperClient::DirectHttp(
            Client::builder(TokioExecutor::new()).build(build_http_connector(connect_timeout_ms)),
        )),
        ProxyRoute::DirectHttps => Ok(HyperClient::DirectHttps(
            Client::builder(TokioExecutor::new()).build(build_https_connector(
                build_http_connector(connect_timeout_ms),
            )?),
        )),
        ProxyRoute::HttpProxy { uri, .. } => Ok(HyperClient::HttpProxy(
            Client::builder(TokioExecutor::new())
                .build(ProxiedHttpConnector::new(uri.clone(), connect_timeout_ms)),
        )),
        ProxyRoute::HttpsProxy { uri, auth } => {
            let mut tunnel = Tunnel::new(uri.clone(), build_http_connector(connect_timeout_ms));
            if let Some(auth) = auth.clone() {
                tunnel = tunnel.with_auth(auth);
            }
            Ok(HyperClient::HttpsProxy(
                Client::builder(TokioExecutor::new()).build(build_https_connector(tunnel)?),
            ))
        }
    }
}

fn build_http_connector(connect_timeout_ms: u64) -> HttpConnector {
    let mut http = HttpConnector::new();
    http.enforce_http(false);
    http.set_connect_timeout(Some(Duration::from_millis(connect_timeout_ms)));
    http.set_nodelay(true);
    http
}

fn build_https_connector<C>(connector: C) -> RuntimeResult<hyper_rustls::HttpsConnector<C>> {
    let connector =
        https_connector_builder_with_roots(HttpsConnectorBuilder::new().with_native_roots())?
            .https_or_http()
            .enable_http1()
            .enable_http2()
            .wrap_connector(connector);

    Ok(connector)
}

fn https_connector_builder_with_roots(
    native_roots: std::io::Result<HttpsConnectorBuilder<WantsSchemes>>,
) -> RuntimeResult<HttpsConnectorBuilder<WantsSchemes>> {
    match native_roots {
        Ok(builder) => Ok(builder),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Ok(HttpsConnectorBuilder::new().with_webpki_roots())
        }
        Err(error) => Err(RuntimeError::new(
            "fetch",
            true,
            format!("failed to load system TLS roots: {error}"),
        )),
    }
}

async fn send_get(
    client: &HyperClient,
    uri: Uri,
    headers: HeaderMap,
    cancel_token: Option<&RuntimeCancelToken>,
) -> RuntimeResult<http::Response<hyper::body::Incoming>> {
    let mut builder = Request::builder().method(Method::GET).uri(uri);
    let request_headers = builder
        .headers_mut()
        .ok_or_else(|| RuntimeError::new("fetch", true, "failed to build request headers"))?;
    for (name, value) in headers {
        if let Some(name) = name {
            request_headers.insert(name, value);
        }
    }
    let request = builder.body(Empty::<Bytes>::new()).map_err(|error| {
        RuntimeError::new(
            "fetch",
            false,
            format!("failed to build HTTP request: {error}"),
        )
    })?;

    cancelable(cancel_token, client.request(request))
        .await?
        .map_err(|error| RuntimeError::new("fetch", true, format!("network fetch failed: {error}")))
}

async fn read_body(
    mut body: hyper::body::Incoming,
    max_encoded_bytes: usize,
    idle_timeout: Duration,
    cancel_token: Option<&RuntimeCancelToken>,
    progress_sink: Option<&dyn RuntimeProgressSink>,
    expected_bytes: Option<usize>,
) -> RuntimeResult<Vec<u8>> {
    let mut bytes = Vec::new();
    let mut progressive_preview = ProgressiveJpegPreviewState::default();
    loop {
        ensure_not_cancelled(cancel_token)?;
        let frame = cancelable(
            cancel_token,
            tokio::time::timeout(idle_timeout, body.frame()),
        )
        .await?
        .map_err(|_| RuntimeError::new("fetch", true, "network response idle timeout"))?;
        let Some(frame) = frame else {
            break;
        };
        let frame = frame.map_err(|error| {
            RuntimeError::new("fetch", true, format!("failed to read response: {error}"))
        })?;
        if let Ok(chunk) = frame.into_data() {
            bytes.extend_from_slice(&chunk);
            if bytes.len() > max_encoded_bytes {
                return Err(RuntimeError::new(
                    "fetch",
                    false,
                    "response exceeds max encoded byte limit",
                ));
            }
            emit_progress(
                progress_sink,
                RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "fetch.progress")
                    .with_bytes(bytes.len(), expected_bytes),
            );
            progressive_preview.maybe_emit(&bytes, expected_bytes, progress_sink);
        }
    }
    Ok(bytes)
}

#[derive(Default)]
struct ProgressiveJpegPreviewState {
    is_progressive: Option<bool>,
    last_emitted_scan_count: usize,
    last_emitted_len: usize,
}

impl ProgressiveJpegPreviewState {
    fn maybe_emit(
        &mut self,
        bytes: &[u8],
        expected_bytes: Option<usize>,
        progress_sink: Option<&dyn RuntimeProgressSink>,
    ) {
        if progress_sink.is_none() {
            return;
        }
        if self.is_progressive.is_none() {
            self.is_progressive = match image_metadata(bytes) {
                Ok(metadata) if metadata.format == ImageMetadataFormat::Jpeg => {
                    Some(metadata.progressive)
                }
                Ok(_) => Some(false),
                Err(_) => None,
            };
        }
        if self.is_progressive != Some(true) {
            return;
        }
        let Some(scan_count) = jpeg_scan_count_with_payload(bytes) else {
            return;
        };
        if scan_count == 0 {
            return;
        }
        if scan_count <= self.last_emitted_scan_count && bytes.len() < self.last_emitted_len + 65536
        {
            return;
        }
        let Some(preview) = progressive_jpeg_preview_bytes(bytes) else {
            return;
        };
        self.last_emitted_scan_count = scan_count;
        self.last_emitted_len = bytes.len();
        emit_progress(
            progress_sink,
            RuntimeProgressEvent::new(RuntimeProgressStage::Fetch, "fetch.progressivePreview")
                .with_bytes(bytes.len(), expected_bytes)
                .with_message("image/jpeg")
                .with_preview_bytes(preview),
        );
    }
}

fn progressive_jpeg_preview_bytes(bytes: &[u8]) -> Option<Vec<u8>> {
    if !bytes.starts_with(&[0xff, 0xd8]) || jpeg_scan_count_with_payload(bytes)? == 0 {
        return None;
    }
    const MAX_PROGRESSIVE_PREVIEW_BYTES: usize = 2 * 1024 * 1024;
    if bytes.len() > MAX_PROGRESSIVE_PREVIEW_BYTES {
        return None;
    }
    let mut preview = bytes.to_vec();
    while preview.last() == Some(&0xff) {
        preview.pop();
    }
    if !preview.ends_with(&[0xff, 0xd9]) {
        preview.extend_from_slice(&[0xff, 0xd9]);
    }
    Some(preview)
}

fn jpeg_scan_count_with_payload(bytes: &[u8]) -> Option<usize> {
    if !bytes.starts_with(&[0xff, 0xd8]) {
        return None;
    }
    let mut offset = 2_usize;
    let mut scans = 0_usize;
    while offset + 1 < bytes.len() {
        if bytes[offset] != 0xff {
            offset += 1;
            continue;
        }
        while offset < bytes.len() && bytes[offset] == 0xff {
            offset += 1;
        }
        if offset >= bytes.len() {
            return Some(scans);
        }
        let marker = bytes[offset];
        offset += 1;
        if marker == 0x00 {
            continue;
        }
        if marker == 0xd9 {
            return Some(scans);
        }
        if is_standalone_jpeg_marker(marker) {
            continue;
        }
        if offset + 2 > bytes.len() {
            return Some(scans);
        }
        let segment_len = u16::from_be_bytes([bytes[offset], bytes[offset + 1]]) as usize;
        if segment_len < 2 {
            return Some(scans);
        }
        let segment_end = offset.saturating_add(segment_len);
        if segment_end > bytes.len() {
            return Some(scans);
        }
        if marker == 0xda {
            if segment_end < bytes.len() {
                scans += 1;
            }
            offset = segment_end;
            continue;
        }
        offset = segment_end;
    }
    Some(scans)
}

fn is_standalone_jpeg_marker(marker: u8) -> bool {
    matches!(marker, 0x01 | 0xd0..=0xd7)
}

async fn cancelable<T, F>(cancel_token: Option<&RuntimeCancelToken>, future: F) -> RuntimeResult<T>
where
    F: Future<Output = T>,
{
    let Some(token) = cancel_token.cloned() else {
        return Ok(future.await);
    };
    tokio::select! {
        value = future => Ok(value),
        () = wait_for_cancel(token) => Err(cancelled_error()),
    }
}

async fn wait_for_cancel(token: RuntimeCancelToken) {
    if token.is_cancelled() {
        return;
    }
    let waker = Arc::new(AsyncCancelNotify::new());
    let notified = waker.notify.notified();
    tokio::pin!(notified);
    token.register_waker(&waker);
    if token.is_cancelled() {
        return;
    }
    notified.await;
}

fn ensure_not_cancelled(cancel_token: Option<&RuntimeCancelToken>) -> RuntimeResult<()> {
    if let Some(token) = cancel_token {
        token.ensure_not_cancelled()?;
    }
    Ok(())
}

fn parse_network_uri(uri: &str) -> RuntimeResult<Uri> {
    let uri = uri.parse::<Uri>().map_err(|error| {
        RuntimeError::new("fetch", false, format!("invalid network URI: {error}"))
    })?;
    match uri.scheme_str() {
        Some("http") | Some("https") if uri.authority().is_some() => Ok(uri),
        _ => Err(RuntimeError::new(
            "fetch",
            false,
            "network source must use absolute http or https URI",
        )),
    }
}

fn resolve_redirect_uri(current: &Uri, location: &HeaderValue) -> RuntimeResult<Uri> {
    let location = location
        .to_str()
        .map_err(|_| RuntimeError::new("fetch", false, "invalid redirect location"))?
        .trim();
    if location.is_empty() {
        return Err(RuntimeError::new("fetch", false, "empty redirect location"));
    }
    if location.starts_with("http://") || location.starts_with("https://") {
        return parse_network_uri(location);
    }

    let scheme = current
        .scheme_str()
        .ok_or_else(|| RuntimeError::new("fetch", false, "redirect base missing scheme"))?;
    let authority = current
        .authority()
        .ok_or_else(|| RuntimeError::new("fetch", false, "redirect base missing authority"))?
        .as_str();

    let resolved = if location.starts_with("//") {
        format!("{scheme}:{location}")
    } else if location.starts_with('/') {
        format!("{scheme}://{authority}{location}")
    } else {
        let base_path = current
            .path_and_query()
            .map(|value| value.as_str().split('?').next().unwrap_or("/"))
            .unwrap_or("/");
        let prefix = base_path
            .rsplit_once('/')
            .map(|(prefix, _)| format!("{prefix}/"))
            .unwrap_or_else(|| "/".to_string());
        format!("{scheme}://{authority}{prefix}{location}")
    };

    parse_network_uri(&resolved)
}

fn validate_redirect_transition(
    current: &Uri,
    next: &Uri,
    policy: crate::request::RuntimeRedirectPolicy,
) -> RuntimeResult<()> {
    if current.scheme_str() == Some("https")
        && next.scheme_str() == Some("http")
        && !policy.allow_https_to_http
    {
        return Err(RuntimeError::new(
            "fetch",
            false,
            "refused https to http redirect",
        ));
    }
    Ok(())
}

fn header_map(headers: &std::collections::BTreeMap<String, String>) -> RuntimeResult<HeaderMap> {
    let mut map = HeaderMap::new();
    for (name, value) in headers {
        let header_name = HeaderName::from_bytes(name.as_bytes()).map_err(|_| {
            RuntimeError::new("fetch", false, format!("invalid header name: {name}"))
        })?;
        let header_value = HeaderValue::from_str(value).map_err(|_| {
            RuntimeError::new("fetch", false, format!("invalid header value for {name}"))
        })?;
        map.insert(header_name, header_value);
    }
    Ok(map)
}

fn apply_conditional_headers(
    headers: &mut HeaderMap,
    conditional: Option<&HttpConditionalHeaders>,
) -> RuntimeResult<()> {
    let Some(conditional) = conditional else {
        return Ok(());
    };
    if let Some(etag) = conditional.etag.as_deref() {
        if !headers.contains_key(IF_NONE_MATCH) {
            headers.insert(
                IF_NONE_MATCH,
                HeaderValue::from_str(etag)
                    .map_err(|_| RuntimeError::new("fetch", false, "invalid cached etag header"))?,
            );
        }
    }
    if let Some(last_modified) = conditional.last_modified.as_deref() {
        if !headers.contains_key(IF_MODIFIED_SINCE) {
            headers.insert(
                IF_MODIFIED_SINCE,
                HeaderValue::from_str(last_modified).map_err(|_| {
                    RuntimeError::new("fetch", false, "invalid cached last-modified header")
                })?,
            );
        }
    }
    Ok(())
}

fn validate_content_length(
    headers: &HeaderMap,
    max_encoded_bytes: usize,
) -> RuntimeResult<Option<usize>> {
    if let Some(length) = content_length(headers)? {
        if length > max_encoded_bytes {
            return Err(RuntimeError::new(
                "fetch",
                false,
                "response exceeds max encoded byte limit",
            ));
        }
        return Ok(Some(length));
    }
    Ok(None)
}

fn content_length(headers: &HeaderMap) -> RuntimeResult<Option<usize>> {
    let Some(value) = headers.get(CONTENT_LENGTH) else {
        return Ok(None);
    };
    let length = value
        .to_str()
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .ok_or_else(|| RuntimeError::new("fetch", false, "invalid content-length header"))?;
    Ok(Some(length))
}

fn is_redirect_status(status: StatusCode) -> bool {
    matches!(
        status,
        StatusCode::MOVED_PERMANENTLY
            | StatusCode::FOUND
            | StatusCode::SEE_OTHER
            | StatusCode::TEMPORARY_REDIRECT
            | StatusCode::PERMANENT_REDIRECT
    )
}

fn is_cross_host_redirect(current: &Uri, next: &Uri) -> bool {
    current.scheme_str() != next.scheme_str() || current.authority() != next.authority()
}

fn strip_cross_host_sensitive_headers(headers: &mut HeaderMap) {
    headers.remove(AUTHORIZATION);
    headers.remove(COOKIE);
    headers.remove(PROXY_AUTHORIZATION);
    headers.remove("x-api-key");
    headers.remove("x-auth-token");
    headers.remove("x-amz-security-token");
    headers.remove("x-pixa-s3-access-key-id");
    headers.remove("x-pixa-s3-secret-access-key");
    headers.remove("x-pixa-s3-session-token");
}

fn is_retryable_status(status: StatusCode) -> bool {
    status.is_server_error()
        || status == StatusCode::TOO_MANY_REQUESTS
        || status == StatusCode::REQUEST_TIMEOUT
}

fn redact_uri(uri: &str) -> String {
    let Some(query_start) = uri.find('?') else {
        return uri.to_string();
    };
    let (base, query_with_marker) = uri.split_at(query_start);
    let query_and_fragment = &query_with_marker[1..];
    let (query, fragment) = query_and_fragment
        .split_once('#')
        .map_or((query_and_fragment, ""), |(query, fragment)| {
            (query, fragment)
        });
    let redacted = query
        .split('&')
        .map(|pair| {
            let name = pair.split_once('=').map_or(pair, |(name, _)| name);
            if is_sensitive_query_name(name) {
                format!("{name}=<redacted>")
            } else {
                pair.to_string()
            }
        })
        .collect::<Vec<String>>()
        .join("&");
    if fragment.is_empty() {
        format!("{base}?{redacted}")
    } else {
        format!("{base}?{redacted}#{fragment}")
    }
}

fn is_sensitive_query_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    matches!(
        lower.as_str(),
        "access_token"
            | "auth"
            | "authorization"
            | "expires"
            | "key"
            | "policy"
            | "signature"
            | "sig"
            | "token"
            | "x-amz-credential"
            | "x-amz-signature"
            | "x-amz-security-token"
    ) || lower.contains("token")
        || lower.contains("signature")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request::{
        CacheMode, RuntimeLimits, RuntimePriority, RuntimeRedirectPolicy, RuntimeRetryPolicy,
        RuntimeSource,
    };
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
    use rustls::{ServerConfig, ServerConnection, StreamOwned};
    use std::collections::BTreeMap;
    use std::io::{Error, ErrorKind, Read, Write};
    use std::net::{Shutdown, TcpListener};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Barrier, Mutex};
    use std::thread;
    use std::time::Duration;

    #[test]
    fn adaptive_concurrency_gate_applies_lower_limit_to_new_acquires() {
        let runtime = RuntimeBuilder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        runtime.block_on(async {
            let gate = Arc::new(AdaptiveConcurrencyGate::new(2));
            let first = gate.acquire(2).await.unwrap();
            let second = gate.acquire(2).await.unwrap();
            let queued_gate = gate.clone();
            let queued = tokio::spawn(async move { queued_gate.acquire(1).await.unwrap() });

            tokio::time::sleep(Duration::from_millis(20)).await;
            assert!(!queued.is_finished());
            drop(first);
            tokio::time::sleep(Duration::from_millis(20)).await;
            assert!(!queued.is_finished());
            drop(second);

            let third = tokio::time::timeout(Duration::from_secs(1), queued)
                .await
                .unwrap()
                .unwrap();
            drop(third);
        });
    }

    #[test]
    fn adaptive_concurrency_gate_preserves_user_limits_above_sixteen() {
        let gate = AdaptiveConcurrencyGate::new(64);

        let state = gate.state.lock().unwrap();
        assert_eq!(state.limit, 64);
    }

    #[test]
    fn http_transport_exceeds_sixteen_parallel_loopback_fetches() {
        const REQUESTS: usize = 64;
        let server = spawn_concurrency_http_server(REQUESTS, Duration::from_millis(300));
        let transport = Arc::new(
            HttpTransport::new_with_proxy_policy(
                REQUESTS,
                ProxyPolicy::from_values("", "", "", "*"),
            )
            .unwrap(),
        );
        let start = Arc::new(Barrier::new(REQUESTS + 1));
        let mut fetches = Vec::with_capacity(REQUESTS);
        for _ in 0..REQUESTS {
            let transport = transport.clone();
            let start = start.clone();
            let uri = server.url.clone();
            fetches.push(thread::spawn(move || {
                let request = test_request(uri.clone());
                start.wait();
                let result = transport
                    .fetch(REQUESTS, &request, uri.parse().unwrap(), None, None, None)
                    .expect("parallel loopback fetch should complete");
                assert!(matches!(result, HttpFetchResult::Fetched(_)));
            }));
        }

        start.wait();
        for fetch in fetches {
            fetch.join().unwrap();
        }
        let peak = server.join();
        assert!(
            peak >= 17,
            "64 configured requests only reached {peak} concurrent origin fetches"
        );
    }

    #[test]
    fn http_runtime_workers_are_bounded_independently_of_request_concurrency() {
        assert_eq!(http_runtime_worker_threads(1), 1);
        assert_eq!(http_runtime_worker_threads(4), 2);
        assert_eq!(http_runtime_worker_threads(12), 2);
    }

    #[test]
    fn adaptive_concurrency_gate_retains_release_before_waiter_registration() {
        let runtime = RuntimeBuilder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        runtime.block_on(async {
            let gate = Arc::new(AdaptiveConcurrencyGate::new(1));
            let permit = gate.acquire(1).await.unwrap();

            drop(permit);

            tokio::time::timeout(Duration::from_millis(50), gate.notify.notified())
                .await
                .expect("a release in the acquire registration window must be retained");
        });
    }

    #[test]
    fn async_cancel_notification_is_retained_before_waiter_registration() {
        let runtime = RuntimeBuilder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        runtime.block_on(async {
            let cancel_notify = AsyncCancelNotify::new();

            cancel_notify.wake_cancelled();

            tokio::time::timeout(Duration::from_millis(50), cancel_notify.notify.notified())
                .await
                .expect("cancellation in the waiter registration window must be retained");
        });
    }

    #[test]
    fn detects_cross_host_redirects() {
        let current = "https://images.example.com/a.jpg".parse::<Uri>().unwrap();
        let same = "https://images.example.com/b.jpg".parse::<Uri>().unwrap();
        let cross = "https://cdn.example.com/b.jpg".parse::<Uri>().unwrap();
        let downgrade = "http://images.example.com/b.jpg".parse::<Uri>().unwrap();

        assert!(!is_cross_host_redirect(&current, &same));
        assert!(is_cross_host_redirect(&current, &cross));
        assert!(is_cross_host_redirect(&current, &downgrade));
    }

    #[test]
    fn strips_sensitive_headers_for_cross_host_redirects() {
        let mut headers = HeaderMap::new();
        headers.insert(AUTHORIZATION, HeaderValue::from_static("Bearer secret"));
        headers.insert(COOKIE, HeaderValue::from_static("session=secret"));
        headers.insert("x-api-key", HeaderValue::from_static("secret"));
        headers.insert("accept", HeaderValue::from_static("image/webp"));

        strip_cross_host_sensitive_headers(&mut headers);

        assert!(!headers.contains_key(AUTHORIZATION));
        assert!(!headers.contains_key(COOKIE));
        assert!(!headers.contains_key("x-api-key"));
        assert_eq!(headers.get("accept").unwrap(), "image/webp");
    }

    #[test]
    fn cross_host_redirect_strips_sensitive_headers_on_next_hop() {
        let second =
            spawn_http_server("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".to_string());
        let first = spawn_http_server(format!(
            "HTTP/1.1 302 Found\r\nLocation: {}\r\nContent-Length: 0\r\n\r\n",
            second.url
        ));
        let mut request = test_request(first.url.clone());
        request
            .headers
            .insert("authorization".to_string(), "Bearer secret".to_string());
        request
            .headers
            .insert("cookie".to_string(), "session=secret".to_string());
        request
            .headers
            .insert("x-api-key".to_string(), "secret".to_string());
        request
            .headers
            .insert("accept".to_string(), "image/webp".to_string());

        fetch(2, &request, &first.url, None, None, None).unwrap();

        let second_request = second.join();
        assert!(!second_request
            .to_ascii_lowercase()
            .contains("authorization:"));
        assert!(!second_request.to_ascii_lowercase().contains("cookie:"));
        assert!(!second_request.to_ascii_lowercase().contains("x-api-key:"));
        assert!(second_request
            .to_ascii_lowercase()
            .contains("accept: image/webp"));
        first.join();
    }

    #[test]
    fn cross_host_redirect_can_be_refused_by_policy() {
        let second =
            spawn_http_server("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".to_string());
        let first = spawn_http_server(format!(
            "HTTP/1.1 302 Found\r\nLocation: {}\r\nContent-Length: 0\r\n\r\n",
            second.url
        ));
        let mut request = test_request(first.url.clone());
        request.redirect_policy.allow_cross_host_redirects = false;

        let error = match fetch(2, &request, &first.url, None, None, None) {
            Ok(_) => panic!("cross-host redirect should be refused"),
            Err(error) => error,
        };

        assert_eq!(error.stage, "fetch");
        assert!(error.message.contains("cross-host"));
        first.join();
        second.shutdown_without_request();
    }

    #[test]
    fn rejects_https_to_http_downgrade_on_every_redirect_hop() {
        let http = "http://images.example.test/start".parse::<Uri>().unwrap();
        let https = "https://images.example.test/secure".parse::<Uri>().unwrap();
        let downgraded = "http://images.example.test/final".parse::<Uri>().unwrap();
        let policy = RuntimeRedirectPolicy::default();

        validate_redirect_transition(&http, &https, policy)
            .expect("HTTP to HTTPS upgrade should be allowed");
        let error = validate_redirect_transition(&https, &downgraded, policy)
            .expect_err("the later HTTPS to HTTP hop must be refused");

        assert_eq!(error.stage, "fetch");
        assert!(error.message.contains("https to http"));
    }

    #[test]
    fn fetches_200_response_body() {
        let server =
            spawn_http_server("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".to_string());
        let mut request = test_request(server.url.clone());
        request
            .headers
            .insert("accept".to_string(), "image/webp,image/*".to_string());

        let result =
            fetch(2, &request, &server.url, None, None, None).expect("200 response should fetch");
        let fetched = match result {
            HttpFetchResult::Fetched(fetched) => fetched,
            HttpFetchResult::NotModified(_) => panic!("200 response must not be 304"),
        };
        let raw_request = server.join().to_ascii_lowercase();

        assert_eq!(fetched.bytes, b"ok");
        assert!(raw_request.contains("accept: image/webp,image/*"));
    }

    #[test]
    fn emits_progress_with_byte_counts_and_redacted_uri() {
        let server = spawn_http_server(
            "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nabcdef".to_string(),
        );
        let uri = format!("{}?token=secret&safe=image", server.url);
        let request = test_request(uri.clone());
        let sink = RecordingProgressSink::default();

        let result =
            fetch(2, &request, &uri, None, None, Some(&sink)).expect("response should fetch");
        let fetched = match result {
            HttpFetchResult::Fetched(fetched) => fetched,
            HttpFetchResult::NotModified(_) => panic!("200 response must not be 304"),
        };
        let events = sink.events();

        assert_eq!(fetched.bytes, b"abcdef");
        assert!(events.iter().any(|event| {
            event.name == "fetch.request"
                && event.message.as_deref().is_some_and(|message| {
                    message.contains("token=<redacted>")
                        && message.contains("safe=image")
                        && !message.contains("secret")
                })
        }));
        assert!(events.iter().any(|event| {
            event.name == "fetch.progress"
                && event.received_bytes == Some(6)
                && event.expected_bytes == Some(6)
        }));
        assert!(events.iter().any(|event| {
            event.name == "fetch.complete"
                && event.received_bytes == Some(6)
                && event.expected_bytes == Some(6)
                && event.message.as_deref().is_some_and(|message| {
                    message.contains("token=<redacted>") && !message.contains("secret")
                })
        }));
        server.join();
    }

    #[test]
    fn emits_progressive_jpeg_preview_during_streaming_fetch() {
        let body = progressive_jpeg_with_scan();
        let split = body.len() - 2;
        let mut head = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            ""
        )
        .into_bytes();
        head.extend_from_slice(&body[..split]);
        let server =
            spawn_split_http_server_bytes(head, body[split..].to_vec(), Duration::from_millis(20));
        let request = test_request(server.url.clone());
        let sink = RecordingProgressSink::default();

        let result = fetch(2, &request, &server.url, None, None, Some(&sink))
            .expect("progressive JPEG response should fetch");
        let fetched = match result {
            HttpFetchResult::Fetched(fetched) => fetched,
            HttpFetchResult::NotModified(_) => panic!("200 response must not be 304"),
        };
        let events = sink.events();
        let preview = events
            .iter()
            .find(|event| event.name == "fetch.progressivePreview")
            .and_then(|event| event.preview_bytes.as_deref())
            .expect("progressive preview event should carry bytes");

        assert_eq!(fetched.bytes, body);
        assert!(preview.starts_with(&[0xff, 0xd8]));
        assert!(preview.ends_with(&[0xff, 0xd9]));
        server.join();
    }

    #[test]
    fn returns_not_modified_with_conditional_headers() {
        let server = spawn_http_server(
            "HTTP/1.1 304 Not Modified\r\nETag: \"v1\"\r\nLast-Modified: Wed, 21 Oct 2015 07:28:00 GMT\r\nCache-Control: max-age=60\r\nContent-Length: 0\r\n\r\n"
                .to_string(),
        );
        let request = test_request(server.url.clone());
        let conditional = HttpConditionalHeaders {
            etag: Some("\"v1\"".to_string()),
            last_modified: Some("Wed, 21 Oct 2015 07:28:00 GMT".to_string()),
        };

        let result = fetch(2, &request, &server.url, Some(&conditional), None, None)
            .expect("304 response should be surfaced as not-modified");
        let not_modified = match result {
            HttpFetchResult::Fetched(_) => panic!("304 response must not read a body"),
            HttpFetchResult::NotModified(not_modified) => not_modified,
        };
        let raw_request = server.join().to_ascii_lowercase();

        assert_eq!(not_modified.cache_metadata.etag.as_deref(), Some("\"v1\""));
        assert_eq!(
            not_modified.cache_metadata.cache_control.as_deref(),
            Some("max-age=60")
        );
        assert!(raw_request.contains("if-none-match: \"v1\""));
        assert!(raw_request.contains("if-modified-since: wed, 21 oct 2015 07:28:00 gmt"));
    }

    #[test]
    fn cache_metadata_combines_repeated_vary_fields() {
        let server = spawn_http_server(
            "HTTP/1.1 200 OK\r\nVary: Accept\r\nVary: User-Agent\r\nContent-Length: 2\r\n\r\nok"
                .to_string(),
        );
        let mut request = test_request(server.url.clone());
        request
            .headers
            .insert("accept".to_string(), "image/webp".to_string());
        request
            .headers
            .insert("user-agent".to_string(), "pixa-test".to_string());

        let fetched = match fetch(2, &request, &server.url, None, None, None).unwrap() {
            HttpFetchResult::Fetched(fetched) => fetched,
            HttpFetchResult::NotModified(_) => panic!("200 response must not be 304"),
        };
        server.join();

        assert_eq!(
            fetched.cache_metadata.vary.as_deref(),
            Some("Accept, User-Agent")
        );
        assert!(fetched.cache_metadata.vary_request_key.is_some());
    }

    #[test]
    fn rejects_404_status_as_not_retryable() {
        let server = spawn_http_server(
            "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found".to_string(),
        );
        let request = test_request(server.url.clone());

        let error = fetch(2, &request, &server.url, None, None, None)
            .expect_err("404 response should fail");

        assert_eq!(error.stage, "fetch");
        assert!(!error.retryable);
        assert!(error.message.contains("404"));
        server.join();
    }

    #[test]
    fn rejects_oversized_content_length_before_body_read() {
        let server =
            spawn_http_server("HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\noversize".to_string());
        let mut request = test_request(server.url.clone());
        request.limits.max_encoded_bytes = 2;

        let error = fetch(2, &request, &server.url, None, None, None)
            .expect_err("oversized response should fail");

        assert_eq!(error.stage, "fetch");
        assert!(!error.retryable);
        assert!(error.message.contains("max encoded"));
        server.join();
    }

    #[test]
    fn times_out_when_response_headers_do_not_arrive() {
        let server = spawn_delayed_http_server(
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".to_string(),
            Duration::from_millis(200),
        );
        let mut request = test_request(server.url.clone());
        request.limits.timeout_ms = 40;

        let error = fetch(2, &request, &server.url, None, None, None)
            .expect_err("slow response headers should hit the request timeout");

        assert_eq!(error.stage, "fetch");
        assert!(error.retryable);
        assert!(error.message.contains("timed out"));
        server.shutdown_without_request();
    }

    #[test]
    fn times_out_when_response_body_stalls_between_chunks() {
        let server = spawn_split_http_server(
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_string(),
            "ok".to_string(),
            Duration::from_millis(120),
        );
        let mut request = test_request(server.url.clone());
        request.limits.timeout_ms = 1_000;
        request.limits.idle_timeout_ms = 30;

        let error = fetch(2, &request, &server.url, None, None, None)
            .expect_err("stalled response body should hit idle timeout");

        assert_eq!(error.stage, "fetch");
        assert!(error.retryable);
        assert!(error.message.contains("idle timeout"));
        server.join();
    }

    #[test]
    fn http_proxy_sends_absolute_uri_and_proxy_authorization() {
        let proxy = spawn_http_server("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".to_string());
        let uri = "http://images.example.test/photo.jpg?token=secret".to_string();
        let request = test_request(uri.clone());
        let transport = HttpTransport::new_with_proxy_policy(
            2,
            ProxyPolicy::from_values("", &format!("http://user:pass@{}", proxy.address), "", ""),
        )
        .unwrap();

        let result = transport
            .fetch(2, &request, uri.parse().unwrap(), None, None, None)
            .expect("HTTP proxy response should fetch");
        let fetched = match result {
            HttpFetchResult::Fetched(fetched) => fetched,
            HttpFetchResult::NotModified(_) => panic!("proxy 200 response must not be 304"),
        };
        let raw_request = proxy.join();

        assert_eq!(fetched.bytes, b"ok");
        assert!(raw_request
            .starts_with("GET http://images.example.test/photo.jpg?token=secret HTTP/1.1"));
        assert!(raw_request
            .to_ascii_lowercase()
            .contains("proxy-authorization: basic dxnlcjpwyxnz"));
    }

    #[test]
    fn https_proxy_uses_connect_and_does_not_leak_origin_authorization() {
        let proxy = spawn_http_server(
            "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n".to_string(),
        );
        let uri = "https://secure.example.test/image.png".to_string();
        let mut request = test_request(uri.clone());
        request.headers.insert(
            "authorization".to_string(),
            "Bearer origin-secret".to_string(),
        );
        let transport = HttpTransport::new_with_proxy_policy(
            2,
            ProxyPolicy::from_values("", "", &format!("http://user:pass@{}", proxy.address), ""),
        )
        .unwrap();

        let error = transport
            .fetch(2, &request, uri.parse().unwrap(), None, None, None)
            .expect_err("proxy 407 should fail the HTTPS tunnel");
        let raw_request = proxy.join();
        let lower = raw_request.to_ascii_lowercase();

        assert_eq!(error.stage, "fetch");
        assert!(raw_request.starts_with("CONNECT secure.example.test:443 HTTP/1.1"));
        assert!(lower.contains("proxy-authorization: basic dxnlcjpwyxnz"));
        assert!(!lower.contains("authorization: bearer origin-secret"));
    }

    #[test]
    fn https_source_requires_tls_handshake() {
        let server =
            spawn_http_server("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".to_string());
        let uri = server.url.replacen("http://", "https://", 1);
        let request = test_request(uri.clone());
        let transport =
            HttpTransport::new_with_proxy_policy(2, ProxyPolicy::from_values("", "", "", "*"))
                .unwrap();

        let error = transport
            .fetch(2, &request, uri.parse().unwrap(), None, None, None)
            .expect_err("plaintext endpoint must not satisfy an HTTPS source");

        assert_eq!(error.stage, "fetch");
        assert!(error.retryable);
        assert!(error.message.contains("network fetch failed"));
        server.join();
    }

    #[test]
    fn https_source_rejects_self_signed_certificate() {
        let server =
            spawn_self_signed_tls_server("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".into());
        let request = test_request(server.url.clone());
        let transport =
            HttpTransport::new_with_proxy_policy(2, ProxyPolicy::from_values("", "", "", "*"))
                .unwrap();

        let error = transport
            .fetch(2, &request, server.url.parse().unwrap(), None, None, None)
            .expect_err("self-signed endpoint must fail TLS certificate verification");
        let message = error.message.to_ascii_lowercase();
        let server_message = server.join().to_ascii_lowercase();

        assert_eq!(error.stage, "fetch");
        assert!(error.retryable);
        assert!(message.contains("connect"), "{message}");
        assert!(
            server_message.contains("alert")
                || server_message.contains("certificate")
                || server_message.contains("unknown"),
            "{server_message}"
        );
    }

    #[test]
    fn https_connector_falls_back_to_webpki_roots_when_native_roots_are_missing() {
        let builder = https_connector_builder_with_roots(Err(Error::new(
            ErrorKind::NotFound,
            "no native root CA certificates found",
        )));

        assert!(builder.is_ok());
    }

    #[test]
    fn https_connector_reports_non_missing_native_root_errors() {
        let error = match https_connector_builder_with_roots(Err(Error::new(
            ErrorKind::PermissionDenied,
            "system keychain is not readable",
        ))) {
            Ok(_) => panic!("non-missing native root failures should stay explicit"),
            Err(error) => error,
        };

        assert_eq!(error.stage, "fetch");
        assert!(error.retryable);
        assert!(error.message.contains("failed to load system TLS roots"));
        assert!(error.message.contains("system keychain is not readable"));
    }

    #[test]
    fn rejects_https_proxy_endpoint_before_fetch() {
        let policy = ProxyPolicy::from_values("", "", "https://proxy.example.test:443", "");
        let uri = "https://secure.example.test/image.png"
            .parse::<Uri>()
            .unwrap();

        let error = policy
            .route(&uri)
            .expect_err("HTTPS proxy endpoints are intentionally unsupported");

        assert_eq!(error.stage, "fetch");
        assert!(error.message.contains("HTTPS proxy endpoints"));
    }

    #[test]
    fn proxy_policy_excludes_loopback_hosts_by_default() {
        let policy = ProxyPolicy::from_values("", "http://proxy.example.test:8080", "", "");

        let localhost = policy
            .route(&"http://localhost/image.jpg".parse::<Uri>().unwrap())
            .expect("localhost route should resolve");
        let ipv4 = policy
            .route(&"http://127.0.0.1/image.jpg".parse::<Uri>().unwrap())
            .expect("IPv4 loopback route should resolve");
        let ipv6 = policy
            .route(&"http://[::1]/image.jpg".parse::<Uri>().unwrap())
            .expect("IPv6 loopback route should resolve");
        let remote = policy
            .route(
                &"http://images.example.test/image.jpg"
                    .parse::<Uri>()
                    .unwrap(),
            )
            .expect("remote route should resolve");

        assert!(matches!(localhost, ProxyRoute::DirectHttp));
        assert!(matches!(ipv4, ProxyRoute::DirectHttp));
        assert!(matches!(ipv6, ProxyRoute::DirectHttp));
        assert!(matches!(remote, ProxyRoute::HttpProxy { .. }));
    }

    #[test]
    fn direct_http_and_https_routes_use_separate_clients() {
        let policy = ProxyPolicy::from_values("", "", "", "*");
        let http = policy
            .route(
                &"http://images.example.test/image.jpg"
                    .parse::<Uri>()
                    .unwrap(),
            )
            .expect("HTTP route should resolve");
        let https = policy
            .route(
                &"https://images.example.test/image.jpg"
                    .parse::<Uri>()
                    .unwrap(),
            )
            .expect("HTTPS route should resolve");

        assert!(matches!(http, ProxyRoute::DirectHttp));
        assert!(matches!(https, ProxyRoute::DirectHttps));
        assert_ne!(http.cache_key(500), https.cache_key(500));
    }

    #[test]
    fn proxy_cache_identity_cryptographically_partitions_and_hides_auth() {
        let first_auth = HeaderValue::from_static("Basic first-secret");
        let second_auth = HeaderValue::from_static("Basic second-secret");
        let first = auth_cache_key(&Some(first_auth.clone()));
        let second = auth_cache_key(&Some(second_auth));

        assert!(first.starts_with("sha256:"));
        assert_ne!(first, second);
        assert!(!first.contains("first-secret"));

        let route = ProxyRoute::HttpProxy {
            uri: "http://user:password@proxy.example.test:8080"
                .parse()
                .unwrap(),
            auth: Some(first_auth),
        };
        let route_key = route.cache_key(500);
        assert!(route_key.starts_with("http-proxy:sha256:"));
        assert!(!route_key.contains("user"));
        assert!(!route_key.contains("password"));
        assert!(!route_key.contains("first-secret"));
    }

    fn test_request(uri: String) -> RuntimeRequest {
        RuntimeRequest {
            source: RuntimeSource::Network { uri },
            headers: BTreeMap::new(),
            namespace: "test".to_string(),
            cache_key: "0123456789abcdef".to_string(),
            encoded_cache_key: "0123456789abcdef".to_string(),
            target_width: None,
            target_height: None,
            decoder_mime_type: None,
            decoder_format_id: None,
            cache_mode: CacheMode::NoStore,
            ttl_ms: None,
            private_cache: false,
            processors: Vec::new(),
            limits: RuntimeLimits::default(),
            redirect_policy: RuntimeRedirectPolicy::default(),
            priority: RuntimePriority::Normal,
            retry: RuntimeRetryPolicy::default(),
        }
    }

    struct TestServer {
        url: String,
        address: String,
        handle: thread::JoinHandle<String>,
    }

    impl TestServer {
        fn join(self) -> String {
            self.handle.join().unwrap()
        }

        fn shutdown_without_request(self) {
            let _ = std::net::TcpStream::connect(self.url.trim_start_matches("http://"));
            let _ = self.handle.join();
        }
    }

    fn spawn_http_server(response: String) -> TestServer {
        spawn_delayed_http_server(response, Duration::ZERO)
    }

    fn spawn_delayed_http_server(response: String, delay: Duration) -> TestServer {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0_u8; 4096];
            let length = stream.read(&mut buffer).unwrap_or(0);
            let request = String::from_utf8_lossy(&buffer[..length]).to_string();
            if !delay.is_zero() {
                thread::sleep(delay);
            }
            stream.write_all(response.as_bytes()).unwrap();
            stream.flush().unwrap();
            finish_http_test_response(&mut stream);
            request
        });
        TestServer {
            url: format!("http://{address}"),
            address: address.to_string(),
            handle,
        }
    }

    struct ConcurrencyTestServer {
        url: String,
        handle: thread::JoinHandle<usize>,
    }

    impl ConcurrencyTestServer {
        fn join(self) -> usize {
            self.handle.join().unwrap()
        }
    }

    fn spawn_concurrency_http_server(
        request_count: usize,
        response_delay: Duration,
    ) -> ConcurrencyTestServer {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let active = Arc::new(AtomicUsize::new(0));
            let peak = Arc::new(AtomicUsize::new(0));
            let mut handlers = Vec::with_capacity(request_count);
            for _ in 0..request_count {
                let (mut stream, _) = listener.accept().unwrap();
                let active = active.clone();
                let peak = peak.clone();
                handlers.push(thread::spawn(move || {
                    let mut buffer = [0_u8; 4096];
                    let _ = stream.read(&mut buffer);
                    let current = active.fetch_add(1, Ordering::SeqCst) + 1;
                    peak.fetch_max(current, Ordering::SeqCst);
                    thread::sleep(response_delay);
                    stream
                        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                        .unwrap();
                    stream.flush().unwrap();
                    finish_http_test_response(&mut stream);
                    active.fetch_sub(1, Ordering::SeqCst);
                }));
            }
            for handler in handlers {
                handler.join().unwrap();
            }
            peak.load(Ordering::SeqCst)
        });
        ConcurrencyTestServer {
            url: format!("http://{address}"),
            handle,
        }
    }

    fn spawn_split_http_server(head: String, body: String, delay: Duration) -> TestServer {
        spawn_split_http_server_bytes(head.into_bytes(), body.into_bytes(), delay)
    }

    fn spawn_split_http_server_bytes(head: Vec<u8>, body: Vec<u8>, delay: Duration) -> TestServer {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0_u8; 4096];
            let length = stream.read(&mut buffer).unwrap_or(0);
            let request = String::from_utf8_lossy(&buffer[..length]).to_string();
            stream.write_all(&head).unwrap();
            stream.flush().unwrap();
            thread::sleep(delay);
            let _ = stream.write_all(&body);
            let _ = stream.flush();
            finish_http_test_response(&mut stream);
            request
        });
        TestServer {
            url: format!("http://{address}"),
            address: address.to_string(),
            handle,
        }
    }

    fn finish_http_test_response(stream: &mut std::net::TcpStream) {
        let _ = stream.shutdown(Shutdown::Write);
        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
        let mut drain = [0_u8; 64];
        while stream.read(&mut drain).is_ok_and(|length| length > 0) {}
    }

    struct TlsTestServer {
        url: String,
        handle: thread::JoinHandle<String>,
    }

    impl TlsTestServer {
        fn join(self) -> String {
            self.handle.join().unwrap()
        }
    }

    fn spawn_self_signed_tls_server(response: String) -> TlsTestServer {
        let rcgen::CertifiedKey { cert, signing_key } =
            rcgen::generate_simple_self_signed(vec!["127.0.0.1".to_string()]).unwrap();
        let cert_der: CertificateDer<'static> = cert.der().clone();
        let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(signing_key.serialize_der()));
        let config = Arc::new(
            ServerConfig::builder()
                .with_no_client_auth()
                .with_single_cert(vec![cert_der], key_der)
                .unwrap(),
        );
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            stream
                .set_write_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let connection = ServerConnection::new(config).unwrap();
            let mut stream = StreamOwned::new(connection, stream);
            let mut buffer = [0_u8; 1024];
            match stream.read(&mut buffer) {
                Ok(length) if length > 0 => {
                    let _ = stream.write_all(response.as_bytes());
                    let _ = stream.flush();
                    "handshake accepted".to_string()
                }
                Ok(_) => "empty TLS request".to_string(),
                Err(error) => error.to_string(),
            }
        });

        TlsTestServer {
            url: format!("https://{address}"),
            handle,
        }
    }

    #[derive(Default)]
    struct RecordingProgressSink {
        events: Mutex<Vec<RuntimeProgressEvent>>,
    }

    impl RecordingProgressSink {
        fn events(&self) -> Vec<RuntimeProgressEvent> {
            self.events.lock().unwrap().clone()
        }
    }

    impl RuntimeProgressSink for RecordingProgressSink {
        fn emit(&self, event: RuntimeProgressEvent) {
            self.events.lock().unwrap().push(event);
        }
    }

    fn progressive_jpeg_with_scan() -> Vec<u8> {
        let mut bytes = vec![0xff, 0xd8];
        bytes.extend_from_slice(&[0xff, 0xe0, 0x00, 0x04, 0x00, 0x00]);
        bytes.extend_from_slice(&[0xff, 0xc2, 0x00, 0x11, 0x08]);
        bytes.extend_from_slice(&1_u16.to_be_bytes());
        bytes.extend_from_slice(&1_u16.to_be_bytes());
        bytes.extend_from_slice(&[0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
        bytes.extend_from_slice(&[
            0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00,
        ]);
        bytes.extend_from_slice(&[0x00, 0x3f, 0x7f, 0x00]);
        bytes.extend_from_slice(&[0xff, 0xd9]);
        bytes
    }
}
