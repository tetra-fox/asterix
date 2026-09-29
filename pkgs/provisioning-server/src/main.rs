// Serves the files named in a manifest to phones over HTTP. systemd passes the
// listening socket and drops connections from networks that are not allowed;
// this program restricts single files to single addresses.
//
//   provisioning-server ROOT MANIFEST

use std::os::fd::{FromRawFd, RawFd};
use std::path::Path;
use std::process::ExitCode;
use std::sync::Arc;

use provisioning_server::{load, serve};

// first file descriptor systemd passes sockets on (sd_listen_fds(3))
const SD_LISTEN_FDS_START: RawFd = 3;

fn systemd_listener() -> Result<std::net::TcpListener, String> {
    let for_us = std::env::var("LISTEN_PID").is_ok_and(|pid| pid == std::process::id().to_string());
    if !for_us || std::env::var("LISTEN_FDS").as_deref() != Ok("1") {
        return Err("expected one listening socket from systemd (LISTEN_PID, LISTEN_FDS)".into());
    }
    // SAFETY: systemd passed this process exactly one socket, on the first fd it uses
    let listener = unsafe { std::net::TcpListener::from_raw_fd(SD_LISTEN_FDS_START) };
    listener
        .set_nonblocking(true)
        .map_err(|e| format!("listening socket: {e}"))?;
    Ok(listener)
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    let [_, root, manifest] = args.as_slice() else {
        return Err("usage: provisioning-server ROOT MANIFEST".into());
    };
    let files = Arc::new(load(Path::new(root), manifest)?);
    let listener = systemd_listener()?;
    tokio::runtime::Builder::new_current_thread()
        .enable_io()
        .enable_time()
        .build()
        .map_err(|e| format!("tokio runtime: {e}"))?
        .block_on(serve(listener, files))
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
