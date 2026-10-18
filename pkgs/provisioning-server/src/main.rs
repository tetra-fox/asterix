// Serves the files named in a manifest to phones over HTTP, and those it marks
// over TFTP too. systemd passes the sockets and drops packets from networks
// that are not allowed; this program restricts single files to single
// addresses.
//
//   provisioning-server ROOT MANIFEST

use std::net::{TcpListener, UdpSocket};
use std::os::fd::{FromRawFd, RawFd};
use std::path::Path;
use std::process::ExitCode;
use std::sync::Arc;

use provisioning_server::{load, serve, tftp};

// first file descriptor systemd passes sockets on (sd_listen_fds(3))
const SD_LISTEN_FDS_START: RawFd = 3;

// the sockets systemd passes, by their FileDescriptorName=: one or more HTTP
// listeners `http`, and `tftp` if files are served over TFTP
fn systemd_sockets() -> Result<(Vec<TcpListener>, Option<UdpSocket>), String> {
    let for_us = std::env::var("LISTEN_PID").is_ok_and(|pid| pid == std::process::id().to_string());
    let count: Option<usize> = std::env::var("LISTEN_FDS")
        .ok()
        .and_then(|n| n.parse().ok());
    let names = std::env::var("LISTEN_FDNAMES").unwrap_or_default();
    let names: Vec<&str> = names.split(':').collect();
    if !for_us || count != Some(names.len()) {
        return Err(
            "expected sockets from systemd (LISTEN_PID, LISTEN_FDS, LISTEN_FDNAMES)".into(),
        );
    }
    let (mut http, mut tftp) = (Vec::new(), None);
    for (fd, name) in (SD_LISTEN_FDS_START..).zip(names) {
        // SAFETY: systemd passed this process a socket on each fd it names, of the
        // kind its socket unit says
        match name {
            "http" => http.push(unsafe { TcpListener::from_raw_fd(fd) }),
            "tftp" => tftp = Some(unsafe { UdpSocket::from_raw_fd(fd) }),
            other => return Err(format!("unexpected socket `{other}` from systemd")),
        }
    }
    if http.is_empty() {
        return Err("no `http` socket from systemd".into());
    }
    for listener in &http {
        listener
            .set_nonblocking(true)
            .map_err(|e| format!("listening socket: {e}"))?;
    }
    if let Some(tftp) = &tftp {
        tftp.set_nonblocking(true)
            .map_err(|e| format!("tftp socket: {e}"))?;
    }
    Ok((http, tftp))
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    let [_, root, manifest] = args.as_slice() else {
        return Err("usage: provisioning-server ROOT MANIFEST".into());
    };
    let files = Arc::new(load(Path::new(root), manifest)?);
    let (mut listeners, tftp) = systemd_sockets()?;
    let first = listeners.remove(0);
    tokio::runtime::Builder::new_current_thread()
        .enable_io()
        .enable_time()
        .build()
        .map_err(|e| format!("tokio runtime: {e}"))?
        .block_on(async {
            if let Some(socket) = tftp {
                let socket = tokio::net::UdpSocket::from_std(socket)
                    .map_err(|e| format!("tftp socket: {e}"))?;
                tokio::spawn(tftp::serve(socket, files.clone()));
            }
            // each listener has its own connection limits, see serve
            for listener in listeners {
                let files = files.clone();
                tokio::spawn(async move {
                    if let Err(message) = serve(listener, files).await {
                        eprintln!("provisioning-server: {message}");
                        std::process::exit(1);
                    }
                });
            }
            serve(first, files).await
        })
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("provisioning-server: {message}");
            ExitCode::FAILURE
        }
    }
}
