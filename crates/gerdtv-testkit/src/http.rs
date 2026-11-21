//! A tiny HTTP/1.1 server for the test kit's mock servers (fault stream server, mock Xtream Codes, mock TMDB,
//! mock release server). Deliberately minimal: GET/HEAD only, one request per connection (`Connection: close`),
//! no TLS. That is all the clients under test (reqwest, libmpv/FFmpeg) need, and it keeps the fault behaviour
//! (stalls, drops, throttling) fully under the test's control, which a full server framework would hide.
//!
//! Debug hint: `curl -v http://<addr>/<path>` against a running server shows exactly what a client receives.

use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

/// A parsed request head.
#[derive(Debug, Clone)]
pub struct Request {
    pub method: String,
    /// The path without the query string, percent-decoding not applied (tests use plain ASCII paths).
    pub path: String,
    pub query: Vec<(String, String)>,
    pub headers: Vec<(String, String)>,
}

impl Request {
    pub fn param(&self, name: &str) -> Option<&str> {
        self.query
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

/// Handlers write the whole response themselves, so they can stall, throttle or cut the connection mid-body.
pub type Handler = Arc<
    dyn Fn(Request, TcpStream) -> Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync + 'static,
>;

/// A running server; dropping it stops accepting connections (open responses finish or are cut by their task).
pub struct Server {
    pub addr: SocketAddr,
    task: JoinHandle<()>,
}

impl Server {
    /// Binds 127.0.0.1 on a free port and serves every connection with `handler`.
    pub async fn start(handler: Handler) -> Server {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind a local port");
        let addr = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                let handler = handler.clone();
                tokio::spawn(async move {
                    if let Some(req) = read_request(&mut stream).await {
                        handler(req, stream).await;
                    }
                });
            }
        });
        Server { addr, task }
    }

    /// `http://127.0.0.1:<port>` + path.
    pub fn url(&self, path: &str) -> String {
        format!("http://{}{}", self.addr, path)
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Reads the request head (up to the blank line). Bodies are never needed: every mock is GET-only.
async fn read_request(stream: &mut TcpStream) -> Option<Request> {
    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = stream.read(&mut chunk).await.ok()?;
        if n == 0 || buf.len() > 64 * 1024 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    let head = String::from_utf8_lossy(&buf);
    let mut lines = head.split("\r\n");
    let mut first = lines.next()?.split(' ');
    let method = first.next()?.to_string();
    let target = first.next()?.to_string();
    let (path, query) = target.split_once('?').unwrap_or((&target, ""));
    let query = query
        .split('&')
        .filter(|p| !p.is_empty())
        .map(|p| {
            let (k, v) = p.split_once('=').unwrap_or((p, ""));
            (k.to_string(), v.to_string())
        })
        .collect();
    let headers = lines
        .take_while(|l| !l.is_empty())
        .filter_map(|l| {
            l.split_once(':')
                .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
        })
        .collect();
    Some(Request {
        method,
        path: path.to_string(),
        query,
        headers,
    })
}

/// Writes a status line and headers. `length: None` means the body runs until the connection closes (live streams).
pub async fn write_head(
    stream: &mut TcpStream,
    status: u16,
    content_type: &str,
    length: Option<usize>,
) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        206 => "Partial Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        416 => "Range Not Satisfiable",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        _ => "Status",
    };
    let mut head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nConnection: close\r\n"
    );
    if let Some(n) = length {
        head.push_str(&format!("Content-Length: {n}\r\n"));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).await
}

/// A complete small response (JSON, playlists, errors).
pub async fn respond(mut stream: TcpStream, status: u16, content_type: &str, body: &[u8]) {
    if write_head(&mut stream, status, content_type, Some(body.len()))
        .await
        .is_ok()
    {
        let _ = stream.write_all(body).await;
    }
    let _ = stream.shutdown().await;
}
