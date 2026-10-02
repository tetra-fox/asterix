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

// the sockets systemd passes, by their FileDescriptorName=: the HTTP listener
// `http`, and `tftp` if files are served over TFTP
fn systemd_sockets() -> Result<(TcpListener, Option<UdpSocket>), String> {
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
    let (mut http, mut tftp) = (None, None);
    for (fd, name) in (SD_LISTEN_FDS_START..).zip(names) {
        // SAFETY: systemd passed this process a socket on each fd it names, of the
        // kind its socket unit says
        match name {
            "http" => http = Some(unsafe { TcpListener::from_raw_fd(fd) }),
            "tftp" => tftp = Some(unsafe { UdpSocket::from_raw_fd(fd) }),
            other => return Err(format!("unexpected socket `{other}` from systemd")),
        }
    }
    let http = http.ok_or("no `http` socket from systemd")?;
    http.set_nonblocking(true)
        .map_err(|e| format!("listening socket: {e}"))?;
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
    let (listener, tftp) = systemd_sockets()?;
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
            serve(listener, files).await
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
