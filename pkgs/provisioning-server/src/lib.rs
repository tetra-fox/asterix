// The request handling of provisioning-server, a library so that its fuzz
// target (fuzz/) runs the same code on connections held in memory.

use std::collections::HashMap;
use std::convert::Infallible;
use std::net::IpAddr;
use std::path::Path;
use std::time::Duration;

use http_body_util::Full;
use hyper::body::{Bytes, Incoming};
use hyper::header::{ALLOW, CONTENT_TYPE, HeaderValue};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use tokio::io::{AsyncRead, AsyncWrite};

// a phone fetches a few kilobytes; slower connections are dropped
const CONNECTION_TIMEOUT: Duration = Duration::from_secs(30);
// requests are a request line and a few headers (hyper's minimum is 8 KiB)
const MAX_REQUEST_BUFFER: usize = 16 * 1024;

pub struct File {
    allowed: Option<IpAddr>,
    content_type: &'static str,
    body: Bytes,
}

pub type Files = HashMap<String, File>;

// one line per file: `NAME`, or `NAME ADDRESS` for a file only ADDRESS may fetch
fn parse_manifest(text: &str) -> Result<Vec<(String, Option<IpAddr>)>, String> {
    text.lines()
        .enumerate()
        .map(|(index, line)| {
            let error = |message: String| format!("manifest line {}: {message}", index + 1);
            match line.split_whitespace().collect::<Vec<_>>().as_slice() {
                [name] => Ok((name.to_string(), None)),
                [name, address] => {
                    let address: IpAddr = address
                        .parse()
                        .map_err(|_| error(format!("invalid address `{address}`")))?;
                    Ok((name.to_string(), Some(address.to_canonical())))
                }
                _ => Err(error("expected a file name and at most one address".into())),
            }
        })
        .collect()
}

pub fn load(root: &Path, manifest: &str) -> Result<Files, String> {
    let text = std::fs::read_to_string(manifest).map_err(|e| format!("{manifest}: {e}"))?;
    parse_manifest(&text)?
        .into_iter()
        .map(|(name, allowed)| {
            let path = root.join(&name);
            let body = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
            let xml = Path::new(&name)
                .extension()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("xml"));
            let content_type = if xml {
                "text/xml"
            } else {
                "application/octet-stream"
            };
            let file = File {
                allowed,
                content_type,
                body: Bytes::from(body),
            };
            Ok((name, file))
        })
        .collect()
}

fn route<'a>(
    files: &'a Files,
    method: &Method,
    path: &str,
    peer: IpAddr,
) -> Result<&'a File, StatusCode> {
    if method != Method::GET && method != Method::HEAD {
        return Err(StatusCode::METHOD_NOT_ALLOWED);
    }
    let Some(file) = path.strip_prefix('/').and_then(|name| files.get(name)) else {
        return Err(StatusCode::NOT_FOUND);
    };
    match file.allowed {
        // IPv4 clients show up as ::ffff:a.b.c.d on an IPv6 socket
        Some(allowed) if allowed != peer.to_canonical() => Err(StatusCode::FORBIDDEN),
        _ => Ok(file),
    }
}

fn respond(files: &Files, request: &Request<Incoming>, peer: IpAddr) -> Response<Full<Bytes>> {
    match route(files, request.method(), request.uri().path(), peer) {
        Ok(file) => {
            // Bytes is reference counted: this does not copy the file
            let mut response = Response::new(Full::new(file.body.clone()));
            let content_type = HeaderValue::from_static(file.content_type);
            response.headers_mut().insert(CONTENT_TYPE, content_type);
            response
        }
        Err(status) => {
            let mut response = Response::new(Full::default());
            *response.status_mut() = status;
            if status == StatusCode::METHOD_NOT_ALLOWED {
                let allow = HeaderValue::from_static("GET, HEAD");
                response.headers_mut().insert(ALLOW, allow);
            }
            response
        }
    }
}

// answers one request from peer and logs it, or logs what ended the connection
pub async fn serve_connection(
    stream: impl AsyncRead + AsyncWrite + Unpin,
    peer: IpAddr,
    files: &Files,
) {
    let service = service_fn(|request: Request<Incoming>| {
        let response = respond(files, &request, peer);
        let (method, path, status) = (request.method(), request.uri().path(), response.status());
        eprintln!("{peer} {method} {path} {}", status.as_u16());
        std::future::ready(Ok::<_, Infallible>(response))
    });
    let connection = http1::Builder::new()
        .keep_alive(false)
        .max_buf_size(MAX_REQUEST_BUFFER)
        .serve_connection(TokioIo::new(stream), service);
    match tokio::time::timeout(CONNECTION_TIMEOUT, connection).await {
        Ok(Ok(())) => {}
        Ok(Err(e)) => eprintln!("{peer}: {e}"),
        Err(_) => eprintln!("{peer}: timed out"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn files() -> Files {
        parse_manifest("open.xml\nkitchen.xml 10.0.20.21\n")
            .unwrap()
            .into_iter()
            .map(|(name, allowed)| {
                let file = File {
                    allowed,
                    content_type: "text/xml",
                    body: Bytes::new(),
                };
                (name, file)
            })
            .collect()
    }

    fn status(method: &Method, path: &str, peer: &str) -> StatusCode {
        match route(&files(), method, path, peer.parse().unwrap()) {
            Ok(_) => StatusCode::OK,
            Err(status) => status,
        }
    }

    #[test]
    fn restricted_file_is_served_to_its_address_only() {
        assert_eq!(
            status(&Method::GET, "/kitchen.xml", "10.0.20.21"),
            StatusCode::OK
        );
        assert_eq!(
            status(&Method::GET, "/kitchen.xml", "10.0.20.22"),
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            status(&Method::GET, "/kitchen.xml", "::ffff:10.0.20.21"),
            StatusCode::OK
        );
        assert_eq!(
            status(&Method::GET, "/open.xml", "10.0.20.22"),
            StatusCode::OK
        );
    }

    #[test]
    fn only_listed_files_are_read_and_only_with_get_or_head() {
        assert_eq!(
            status(&Method::GET, "/", "10.0.20.21"),
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            status(&Method::GET, "/other.xml", "10.0.20.21"),
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            status(&Method::GET, "/../open.xml", "10.0.20.21"),
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            status(&Method::HEAD, "/open.xml", "10.0.20.21"),
            StatusCode::OK
        );
        assert_eq!(
            status(&Method::POST, "/open.xml", "10.0.20.21"),
            StatusCode::METHOD_NOT_ALLOWED
        );
    }

    #[test]
    fn manifest_errors_name_the_line() {
        assert_eq!(
            parse_manifest("a.xml\nb.xml 10.0.20.0/24\n")
                .err()
                .as_deref(),
            Some("manifest line 2: invalid address `10.0.20.0/24`")
        );
        assert_eq!(
            parse_manifest("a.xml 10.0.20.1 10.0.20.2").err().as_deref(),
            Some("manifest line 1: expected a file name and at most one address")
        );
    }
}
