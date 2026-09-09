use std::sync::OnceLock;

use reqwest::Url;
use tauri::{
  http::{Request, Response, StatusCode},
  plugin::Builder as PluginBuilder,
  Runtime, UriSchemeContext, UriSchemeResponder,
};

pub const WEBPROXY_SCHEME: &str = "webproxy";

static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();

fn client() -> &'static reqwest::Client {
  CLIENT.get_or_init(|| {
    reqwest::Client::builder()
      // Keep upstream HTTP cookies in the native client. Cookies belonging to
      // the custom WebView origin are intentionally not forwarded upstream.
      .cookie_store(true)
      .build()
      .expect("failed to build webproxy HTTP client")
  })
}

const HOP_BY_HOP_HEADERS: &[&str] = &[
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "proxy-connection",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
];

const RESPONSE_POLICY_HEADERS: &[&str] = &[
  "content-security-policy",
  "content-security-policy-report-only",
  "x-content-security-policy",
  "x-webkit-csp",
  "x-frame-options",
  "cross-origin-embedder-policy",
  "cross-origin-opener-policy",
  "cross-origin-resource-policy",
  "origin-agent-cluster",
  "clear-site-data",
];

pub fn register<R: Runtime>(builder: PluginBuilder<R>) -> PluginBuilder<R> {
  builder.register_asynchronous_uri_scheme_protocol(WEBPROXY_SCHEME, scheme_handler())
}

fn scheme_handler<R: Runtime>(
) -> impl Fn(UriSchemeContext<'_, R>, Request<Vec<u8>>, UriSchemeResponder) + Send + Sync + 'static
{
  move |_ctx, request, responder| {
    tauri::async_runtime::spawn(async move {
      responder.respond(handle(request).await);
    });
  }
}

async fn handle(request: Request<Vec<u8>>) -> Response<Vec<u8>> {
  if request.method().as_str() == "OPTIONS"
    && request
      .headers()
      .contains_key("access-control-request-method")
  {
    return preflight_response(&request);
  }

  match extract_target(&request) {
    Ok(target) => forward(target, request).await,
    Err(message) => error_response(StatusCode::BAD_REQUEST, &message),
  }
}

/// Converts the logical custom-protocol request back to the real HTTPS target.
///
/// Wry normally reverts its Android/Windows workaround before invoking this
/// handler, so the URI is `webproxy://example.com/path`. The http(s) branch is
/// kept as a defensive fallback for runtimes that expose the workaround URI.
fn extract_target(request: &Request<Vec<u8>>) -> Result<Url, String> {
  let uri = request.uri();
  let scheme = uri
    .scheme_str()
    .ok_or_else(|| "webproxy request has no URI scheme".to_string())?;

  let authority = match scheme {
    WEBPROXY_SCHEME => uri
      .authority()
      .map(|value| value.as_str().to_string())
      .ok_or_else(|| "webproxy request has no target host".to_string())?,
    "http" | "https" => {
      let host = uri
        .host()
        .and_then(|host| host.strip_prefix("webproxy."))
        .ok_or_else(|| "invalid webproxy workaround host".to_string())?;
      match uri.port_u16() {
        Some(port) => format!("{host}:{port}"),
        None => host.to_string(),
      }
    }
    other => return Err(format!("unexpected webproxy URI scheme {other:?}")),
  };

  let path_and_query = uri
    .path_and_query()
    .map(|value| value.as_str())
    .unwrap_or("/");

  Url::parse(&format!("https://{authority}{path_and_query}"))
    .map_err(|error| format!("invalid webproxy target: {error}"))
}

async fn forward(target: Url, request: Request<Vec<u8>>) -> Response<Vec<u8>> {
  let (parts, body) = request.into_parts();
  let method = match reqwest::Method::from_bytes(parts.method.as_str().as_bytes()) {
    Ok(method) => method,
    Err(error) => {
      return error_response(
        StatusCode::BAD_REQUEST,
        &format!("invalid webproxy method: {error}"),
      )
    }
  };

  let upstream_origin = target.origin().ascii_serialization();
  let mut upstream = client().request(method, target.clone());

  for (name, value) in &parts.headers {
    let lower = name.as_str().to_ascii_lowercase();

    if lower == "origin" {
      // The WebView sees a custom proxy origin; upstream should see the
      // corresponding HTTPS origin instead.
      upstream = upstream.header("origin", &upstream_origin);
      continue;
    }

    if should_strip_request_header(&lower) {
      continue;
    }

    upstream = upstream.header(name.as_str(), value.as_bytes());
  }

  // HTML may be rewritten below, so ask the server for identity encoding.
  // This also avoids passing a compressed body through a custom-protocol layer
  // that may need to alter security metadata.
  upstream = upstream.header("accept-encoding", "identity").body(body);

  let upstream = match upstream.send().await {
    Ok(response) => response,
    Err(error) => {
      return error_response(
        StatusCode::BAD_GATEWAY,
        &format!("webproxy upstream request failed: {error}"),
      )
    }
  };

  let status = upstream.status().as_u16();
  let headers = upstream.headers().clone();

  let bytes = match upstream.bytes().await {
    Ok(bytes) => bytes,
    Err(error) => {
      return error_response(
        StatusCode::BAD_GATEWAY,
        &format!("webproxy failed to read upstream response: {error}"),
      )
    }
  };

  let is_html = headers
    .get("content-type")
    .and_then(|value| value.to_str().ok())
    .map(|value| value.to_ascii_lowercase().starts_with("text/html"))
    .unwrap_or(false);
  let identity_encoded = headers
    .get("content-encoding")
    .and_then(|value| value.to_str().ok())
    .map(|value| value.eq_ignore_ascii_case("identity"))
    .unwrap_or(true);

  // Only rewrite complete HTML documents. Never modify range responses.
  let (body, body_changed) = if status == 200 && is_html && identity_encoded {
    strip_meta_frame_policies(&bytes)
  } else {
    (bytes.to_vec(), false)
  };

  let mut response = Response::builder().status(status);

  for (name, value) in &headers {
    let lower = name.as_str().to_ascii_lowercase();

    if should_strip_response_header(&lower, body_changed) {
      continue;
    }

    response = response.header(name.as_str(), value.as_bytes());
  }

  // Allow the host app to use fetch/XHR against webproxy URLs as well as use
  // them for iframe navigation.
  response = response
    .header("access-control-allow-origin", "*")
    .header("access-control-expose-headers", "*");

  response.body(body).unwrap()
}

fn should_strip_request_header(name: &str) -> bool {
  HOP_BY_HOP_HEADERS.contains(&name)
    || matches!(
      name,
      "host"
        | "content-length"
        | "accept-encoding"
        | "referer"
        | "cookie"
        | "x-frame-options"
    )
    || name.starts_with("sec-fetch-")
    || name.starts_with("access-control-request-")
}

fn should_strip_response_header(name: &str, body_changed: bool) -> bool {
  HOP_BY_HOP_HEADERS.contains(&name)
    || RESPONSE_POLICY_HEADERS.contains(&name)
    || name.starts_with("access-control-")
    || matches!(name, "content-length" | "set-cookie")
    || (body_changed && matches!(name, "etag" | "content-md5" | "digest"))
}

fn preflight_response(request: &Request<Vec<u8>>) -> Response<Vec<u8>> {
  let requested_headers = request
    .headers()
    .get("access-control-request-headers")
    .and_then(|value| value.to_str().ok())
    .unwrap_or("*");

  Response::builder()
    .status(StatusCode::NO_CONTENT)
    .header("access-control-allow-origin", "*")
    .header(
      "access-control-allow-methods",
      "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS",
    )
    .header("access-control-allow-headers", requested_headers)
    .header("access-control-max-age", "86400")
    .header(
      "vary",
      "Origin, Access-Control-Request-Method, Access-Control-Request-Headers",
    )
    .body(Vec::new())
    .unwrap()
}

fn error_response(status: StatusCode, message: &str) -> Response<Vec<u8>> {
  Response::builder()
    .status(status)
    .header("content-type", "text/plain; charset=utf-8")
    .header("access-control-allow-origin", "*")
    .body(message.as_bytes().to_vec())
    .unwrap()
}

/// Removes CSP/X-Frame-Options policies declared through `<meta http-equiv>`.
/// The scan operates on raw bytes so it does not need to guess the page's text
/// encoding; HTML tag and attribute names are ASCII by definition.
fn strip_meta_frame_policies(input: &[u8]) -> (Vec<u8>, bool) {
  let mut output = Vec::with_capacity(input.len());
  let mut copied_until = 0usize;
  let mut scan_from = 0usize;
  let mut changed = false;

  while let Some(start) = find_meta_tag(input, scan_from) {
    let Some(end) = find_tag_end(input, start) else {
      break;
    };
    let tag = &input[start..=end];

    let is_http_equiv = contains_ascii_case_insensitive(tag, b"http-equiv");
    let is_blocking_policy = contains_ascii_case_insensitive(tag, b"content-security-policy")
      || contains_ascii_case_insensitive(tag, b"x-frame-options");

    if is_http_equiv && is_blocking_policy {
      output.extend_from_slice(&input[copied_until..start]);
      copied_until = end + 1;
      changed = true;
    }

    scan_from = end + 1;
  }

  if !changed {
    return (input.to_vec(), false);
  }

  output.extend_from_slice(&input[copied_until..]);
  (output, true)
}

fn find_meta_tag(input: &[u8], mut from: usize) -> Option<usize> {
  const NEEDLE: &[u8] = b"<meta";
  while from + NEEDLE.len() <= input.len() {
    let relative = input[from..]
      .windows(NEEDLE.len())
      .position(|window| ascii_eq_ignore_case(window, NEEDLE))?;
    let start = from + relative;
    let next = input.get(start + NEEDLE.len()).copied();
    if next.map_or(true, |byte| byte.is_ascii_whitespace() || matches!(byte, b'/' | b'>')) {
      return Some(start);
    }
    from = start + NEEDLE.len();
  }
  None
}

fn find_tag_end(input: &[u8], start: usize) -> Option<usize> {
  let mut quote = None;
  for (offset, byte) in input[start..].iter().copied().enumerate() {
    match quote {
      Some(current) if byte == current => quote = None,
      Some(_) => {}
      None if matches!(byte, b'\'' | b'"') => quote = Some(byte),
      None if byte == b'>' => return Some(start + offset),
      None => {}
    }
  }
  None
}

fn contains_ascii_case_insensitive(haystack: &[u8], needle: &[u8]) -> bool {
  haystack
    .windows(needle.len())
    .any(|window| ascii_eq_ignore_case(window, needle))
}

fn ascii_eq_ignore_case(left: &[u8], right: &[u8]) -> bool {
  left.len() == right.len()
    && left
      .iter()
      .zip(right)
      .all(|(left, right)| left.eq_ignore_ascii_case(right))
}

#[cfg(test)]
mod tests {
  use super::*;

  fn request(uri: &str) -> Request<Vec<u8>> {
    Request::builder().uri(uri).body(Vec::new()).unwrap()
  }

  #[test]
  fn keeps_target_host_in_custom_scheme() {
    let target = extract_target(&request(
      "webproxy://doc.libsodium.org/key_derivation/hkdf?q=1",
    ))
    .unwrap();
    assert_eq!(
      target.as_str(),
      "https://doc.libsodium.org/key_derivation/hkdf?q=1"
    );
  }

  #[test]
  fn accepts_wry_http_workaround_uri() {
    let target = extract_target(&request(
      "http://webproxy.doc.libsodium.org/key_derivation/hkdf",
    ))
    .unwrap();
    assert_eq!(
      target.as_str(),
      "https://doc.libsodium.org/key_derivation/hkdf"
    );
  }

  #[test]
  fn removes_meta_csp_without_touching_other_meta_tags() {
    let html = br#"<!doctype html><head>
      <meta charset="utf-8">
      <META content="default-src 'none' > x" HTTP-EQUIV='Content-Security-Policy'>
      <meta name="description" content="content-security-policy">
    </head><body>ok</body>"#;
    let (html, changed) = strip_meta_frame_policies(html);
    let html = String::from_utf8(html).unwrap();
    assert!(changed);
    assert!(!html.contains("HTTP-EQUIV='Content-Security-Policy'"));
    assert!(html.contains("<meta charset=\"utf-8\">"));
    assert!(html.contains("name=\"description\""));
  }
}
