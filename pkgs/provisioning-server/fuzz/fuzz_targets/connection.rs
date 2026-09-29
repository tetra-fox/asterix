// Sends the fuzzer's bytes to the provisioning server as one peer's connection,
// through hyper's parser into the server's routing and response. The first byte
// picks the peer, the second how many bytes the connection holds in each
// direction (1 << byte % 16), and the rest is what the peer sends.

#![no_main]

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::LazyLock;
use std::time::Duration;

use libfuzzer_sys::{Corpus, fuzz_target};
use provisioning_server::{Files, load, serve_connection};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::runtime::Runtime;
use tokio::time::Instant;

const MANIFEST: &str = "cfgc074ad000101.xml 10.0.20.21\ncfgc074ad000102.xml\nnotes.txt fd00::21\n";

// a response head is ASCII, so a byte above 0x7f in a response comes from a file;
// searching for one byte runs memchr, which libFuzzer, unlike memcmp, does not record
const FILES: [(&str, &[u8]); 3] = [
    ("cfgc074ad000101.xml", b"<P34>\xf1 password of 101</P34>"),
    ("cfgc074ad000102.xml", b"<P34>password of 102</P34>"),
    ("notes.txt", b"\xf3 notes for fd00::21"),
];

const ADAPTER_101: Ipv4Addr = Ipv4Addr::new(10, 0, 20, 21);

// each peer with the bytes of the files it must never receive
const PEERS: [(IpAddr, &[u8]); 4] = [
    (IpAddr::V4(ADAPTER_101), b"\xf3"),
    (IpAddr::V6(ADAPTER_101.to_ipv6_mapped()), b"\xf3"),
    (IpAddr::V4(Ipv4Addr::new(10, 0, 20, 22)), b"\xf1\xf3"),
    (
        IpAddr::V6(Ipv6Addr::new(0xfd00, 0, 0, 0, 0, 0, 0, 0x21)),
        b"\xf1",
    ),
];

static SERVED: LazyLock<Files> = LazyLock::new(|| {
    // load() reads from disk: the files are written for it and removed once loaded
    let root =
        std::env::temp_dir().join(format!("provisioning-server-fuzz-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    for (name, contents) in FILES {
        std::fs::write(root.join(name), contents).unwrap();
    }
    let manifest = root.join("manifest");
    std::fs::write(&manifest, MANIFEST).unwrap();
    let files = load(&root, manifest.to_str().unwrap()).unwrap();
    std::fs::remove_dir_all(&root).unwrap();
    files
});

// the paused clock moves only when no task can run, straight to the next timer
static RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .start_paused(true)
        .build()
        .unwrap()
});

fuzz_target!(|data: &[u8]| -> Corpus {
    let Some((&[peer, capacity], sent)) = data.split_first_chunk() else {
        return Corpus::Reject;
    };
    let (peer, forbidden) = PEERS[usize::from(peer) % PEERS.len()];
    let (client, server) = tokio::io::duplex(1 << (capacity % 16));
    let (mut from_server, mut to_server) = tokio::io::split(client);

    let response = RUNTIME.block_on(async {
        let send = async {
            // the write fails if the server closed the connection before reading everything
            if to_server.write_all(sent).await.is_ok() {
                // hyper drops a request whose peer closes its side before the response
                // is written, so the peer waits until the server has nothing left to do
                tokio::time::sleep(Duration::from_millis(1)).await;
                to_server.shutdown().await.unwrap();
            }
            Instant::now()
        };
        let receive = async {
            let mut response = Vec::new();
            from_server.read_to_end(&mut response).await.unwrap();
            response
        };
        let ((), done, response) =
            tokio::join!(serve_connection(server, peer, &SERVED), send, receive);
        // only the server's connection timeout can move the clock after the peer is done
        assert_eq!(Instant::now(), done, "the connection outlived its peer");
        response
    });

    for byte in forbidden {
        assert!(
            !response.contains(byte),
            "{peer} received the file with byte {byte:#x}"
        );
    }
    Corpus::Keep
});
