// Read-only TFTP (RFC 1350) for the files the manifest marks `tftp`, which
// devices such as Cisco's fetch first. Every transfer runs on the one socket
// systemd passes, from port 69, told apart by the client's address and port,
// as dnsmasq's --tftp-single-port does, so the service opens no sockets of its
// own. Options (RFC 2347) are ignored, which clients take as 512-byte blocks.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use hyper::body::Bytes;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;

use crate::{CONNECTION_TIMEOUT, CONNECTIONS_PER_PEER, Files, permits};

const BLOCK_SIZE: usize = 512;
// a block that is not acknowledged in time is sent again, at most RETRIES
// times, so a request with a forged source address draws at most RETRIES + 1
// blocks to that address
const ACK_TIMEOUT: Duration = Duration::from_secs(1);
const RETRIES: usize = 4;
// transfers hold no file descriptor; this bounds what requests from many
// addresses can make the server send at once
const MAX_TRANSFERS: usize = 512;
// longer than any request a device sends, which ends at a file name and a mode
const MAX_DATAGRAM: usize = 1024;

const FILE_NOT_FOUND: u16 = 1;
const ACCESS_VIOLATION: u16 = 2;

#[derive(Debug, PartialEq)]
pub enum Packet<'a> {
    Read { name: &'a str, netascii: bool },
    Write,
    Ack(u16),
    Error,
    Invalid,
}

pub fn parse(datagram: &[u8]) -> Packet<'_> {
    let Some((opcode, rest)) = datagram.split_first_chunk() else {
        return Packet::Invalid;
    };
    match u16::from_be_bytes(*opcode) {
        1 => {
            // the file name and the mode end in a zero byte each, options follow
            let mut fields = rest.split(|&byte| byte == 0);
            let (Some(name), Some(mode), Some(_)) = (fields.next(), fields.next(), fields.next())
            else {
                return Packet::Invalid;
            };
            let Ok(name) = std::str::from_utf8(name) else {
                return Packet::Invalid;
            };
            if mode.eq_ignore_ascii_case(b"octet") {
                Packet::Read {
                    name,
                    netascii: false,
                }
            } else if mode.eq_ignore_ascii_case(b"netascii") {
                Packet::Read {
                    name,
                    netascii: true,
                }
            } else {
                Packet::Invalid
            }
        }
        2 => Packet::Write,
        4 => match rest {
            [high, low] => Packet::Ack(u16::from_be_bytes([*high, *low])),
            _ => Packet::Invalid,
        },
        5 => Packet::Error,
        _ => Packet::Invalid,
    }
}

fn error(code: u16, message: &str) -> Vec<u8> {
    let mut packet = vec![0, 5];
    packet.extend_from_slice(&code.to_be_bytes());
    packet.extend_from_slice(message.as_bytes());
    packet.push(0);
    packet
}

// netascii, as RFC 1350 takes it from Telnet: CR LF for a line break, CR NUL
// for a CR on its own
fn netascii(body: &[u8]) -> Bytes {
    let mut converted = Vec::with_capacity(body.len());
    for &byte in body {
        match byte {
            b'\n' => converted.extend_from_slice(b"\r\n"),
            b'\r' => converted.extend_from_slice(b"\r\0"),
            _ => converted.push(byte),
        }
    }
    converted.into()
}

#[derive(Debug, PartialEq)]
pub enum Reply<'a> {
    Transfer { name: &'a str, body: Bytes },
    Refuse(u16, &'static str),
    Ignore,
}

// the answer to a packet from peer, which has no transfer running. Only
// requests are answered, so that a packet with a forged source address draws
// no more than its own length, or a file
pub fn respond<'a>(files: &Files, packet: &Packet<'a>, peer: IpAddr) -> Reply<'a> {
    match *packet {
        Packet::Read {
            name,
            netascii: as_netascii,
        } => {
            // a device may name the file as a path from the root
            let name = name.strip_prefix('/').unwrap_or(name);
            match files.get(name).filter(|file| file.tftp) {
                None => Reply::Refuse(FILE_NOT_FOUND, "not found"),
                Some(file) if !permits(file, peer) => Reply::Refuse(ACCESS_VIOLATION, "forbidden"),
                Some(file) if as_netascii => Reply::Transfer {
                    name,
                    body: netascii(&file.body),
                },
                // Bytes is reference counted: this does not copy the file
                Some(file) => Reply::Transfer {
                    name,
                    body: file.body.clone(),
                },
            }
        }
        Packet::Write => Reply::Refuse(ACCESS_VIOLATION, "read only"),
        Packet::Ack(_) | Packet::Error | Packet::Invalid => Reply::Ignore,
    }
}

enum FromClient {
    Ack(u16),
    Error,
}

// sends body to peer block by block, each until peer acknowledges it
async fn transfer(
    socket: &UdpSocket,
    peer: SocketAddr,
    body: &[u8],
    from_client: &mut mpsc::Receiver<FromClient>,
) -> Result<(), String> {
    // the last block is shorter than BLOCK_SIZE, empty if the one before is
    // full; block numbers start at 1 and wrap around after 65535
    for index in 0..=body.len() / BLOCK_SIZE {
        let number = (index + 1) as u16;
        let start = index * BLOCK_SIZE;
        let mut packet = vec![0, 3];
        packet.extend_from_slice(&number.to_be_bytes());
        packet.extend_from_slice(&body[start..body.len().min(start + BLOCK_SIZE)]);
        let mut attempts = 0;
        loop {
            if attempts > RETRIES {
                return Err(format!("block {number} not acknowledged"));
            }
            attempts += 1;
            socket
                .send_to(&packet, peer)
                .await
                .map_err(|e| e.to_string())?;
            let acknowledged = tokio::time::timeout(ACK_TIMEOUT, async {
                loop {
                    match from_client.recv().await {
                        Some(FromClient::Ack(acked)) if acked == number => return Ok(()),
                        // an earlier block acknowledged again, which must not
                        // send this block again, or every later block goes twice
                        Some(FromClient::Ack(_)) => {}
                        Some(FromClient::Error) => return Err("aborted by the client".to_string()),
                        None => unreachable!("the server keeps the sender while the transfer runs"),
                    }
                }
            })
            .await;
            match acknowledged {
                Ok(result) => break result?,
                Err(_) => continue,
            }
        }
    }
    Ok(())
}

// answers the packets of a socket, each transfer on its own task
pub async fn serve(socket: UdpSocket, files: Arc<Files>) {
    let socket = Arc::new(socket);
    // the transfers running, by client; a finished one has dropped its receiver
    let mut transfers: HashMap<SocketAddr, mpsc::Sender<FromClient>> = HashMap::new();
    let mut datagram = [0; MAX_DATAGRAM];
    loop {
        let (length, peer) = match socket.recv_from(&mut datagram).await {
            Ok(received) => received,
            Err(e) => {
                eprintln!("tftp: {e}");
                tokio::time::sleep(Duration::from_secs(1)).await;
                continue;
            }
        };
        transfers.retain(|_, sender| !sender.is_closed());
        let packet = parse(&datagram[..length]);
        if let Some(sender) = transfers.get(&peer) {
            let message = match packet {
                Packet::Ack(number) => FromClient::Ack(number),
                Packet::Error => FromClient::Error,
                // the client asking again: the transfer sends the block again
                _ => continue,
            };
            // a full queue drops the packet, as the network might, and the
            // client sends it again
            let _ = sender.try_send(message);
            continue;
        }
        let ip = peer.ip();
        match respond(&files, &packet, ip) {
            Reply::Transfer { name, body } => {
                let from_peer = transfers.keys().filter(|client| client.ip() == ip).count();
                if transfers.len() >= MAX_TRANSFERS || from_peer >= CONNECTIONS_PER_PEER {
                    eprintln!("{ip}: too many transfers");
                    continue;
                }
                eprintln!("{ip} TFTP {name} sending");
                let name = name.to_string();
                let (sender, mut receiver) = mpsc::channel(4);
                transfers.insert(peer, sender);
                let socket = socket.clone();
                tokio::spawn(async move {
                    let sent = tokio::time::timeout(
                        CONNECTION_TIMEOUT,
                        transfer(&socket, peer, &body, &mut receiver),
                    )
                    .await;
                    match sent {
                        Ok(Ok(())) => {}
                        Ok(Err(e)) => eprintln!("{ip} TFTP {name}: {e}"),
                        Err(_) => eprintln!("{ip} TFTP {name}: timed out"),
                    }
                });
            }
            Reply::Refuse(code, message) => {
                if let Packet::Read { name, .. } = packet {
                    eprintln!("{ip} TFTP {name} {message}");
                }
                if let Err(e) = socket.send_to(&error(code, message), peer).await {
                    eprintln!("{ip}: {e}");
                }
            }
            Reply::Ignore => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::File;

    fn files() -> Files {
        let file = |allowed: Option<&str>, tftp, body: &str| File {
            allowed: allowed.map(|address| address.parse().unwrap()),
            tftp,
            content_type: "text/xml",
            body: Bytes::copy_from_slice(body.as_bytes()),
        };
        Files::from([
            ("open.xml".to_string(), file(None, true, "a\nb\r")),
            (
                "kitchen.xml".to_string(),
                file(Some("127.0.0.21"), true, ""),
            ),
            ("http.xml".to_string(), file(None, false, "")),
        ])
    }

    #[test]
    fn requests_end_in_a_zero_byte_and_take_octet_or_netascii() {
        assert_eq!(
            parse(b"\0\x01open.xml\0OCTET\0blksize\x001024\0"),
            Packet::Read {
                name: "open.xml",
                netascii: false
            }
        );
        assert_eq!(
            parse(b"\0\x01open.xml\0netascii\0"),
            Packet::Read {
                name: "open.xml",
                netascii: true
            }
        );
        for invalid in [
            &b""[..],
            b"\0",
            b"\0\x01open.xml\0octet",
            b"\0\x01open.xml",
            b"\0\x01open.xml\0mail\0",
            b"\0\x01\xff\0octet\0",
            b"\0\x04\0",
            b"\0\x04\0\x01\0",
            b"\0\x03\0\x01data",
            b"\0\x06",
        ] {
            assert_eq!(parse(invalid), Packet::Invalid, "{invalid:?}");
        }
        assert_eq!(parse(b"\0\x02open.xml\0octet\0"), Packet::Write);
        assert_eq!(parse(b"\0\x04\x01\x02"), Packet::Ack(0x0102));
        assert_eq!(parse(b"\0\x05\0\x01gone\0"), Packet::Error);
    }

    #[test]
    fn only_tftp_files_go_to_the_addresses_allowed() {
        let files = files();
        let read = |name, peer: &str| {
            let packet = Packet::Read {
                name,
                netascii: false,
            };
            respond(&files, &packet, peer.parse().unwrap())
        };
        let open = Reply::Transfer {
            name: "open.xml",
            body: Bytes::from_static(b"a\nb\r"),
        };
        assert_eq!(read("open.xml", "127.0.0.22"), open);
        assert_eq!(read("/open.xml", "127.0.0.22"), open);
        assert!(matches!(
            read("kitchen.xml", "::ffff:127.0.0.21"),
            Reply::Transfer { .. }
        ));
        assert_eq!(
            read("kitchen.xml", "127.0.0.22"),
            Reply::Refuse(ACCESS_VIOLATION, "forbidden")
        );
        for missing in ["http.xml", "other.xml", "//open.xml", "../open.xml", ""] {
            assert_eq!(
                read(missing, "127.0.0.21"),
                Reply::Refuse(FILE_NOT_FOUND, "not found"),
                "{missing}"
            );
        }
        let netascii = Packet::Read {
            name: "open.xml",
            netascii: true,
        };
        assert_eq!(
            respond(&files, &netascii, "127.0.0.22".parse().unwrap()),
            Reply::Transfer {
                name: "open.xml",
                body: Bytes::from_static(b"a\r\nb\r\0")
            }
        );
        // only requests are answered
        let peer = "127.0.0.22".parse().unwrap();
        for packet in [Packet::Ack(1), Packet::Error, Packet::Invalid] {
            assert_eq!(respond(&files, &packet, peer), Reply::Ignore);
        }
        assert_eq!(
            respond(&files, &Packet::Write, peer),
            Reply::Refuse(ACCESS_VIOLATION, "read only")
        );
    }

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_io()
            .enable_time()
            .build()
            .unwrap()
    }

    // serve() on a port of 127.0.0.1, in a thread that runs until the tests end
    fn server(files: Files) -> SocketAddr {
        let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let address = socket.local_addr().unwrap();
        socket.set_nonblocking(true).unwrap();
        std::thread::spawn(move || {
            runtime().block_on(async {
                serve(UdpSocket::from_std(socket).unwrap(), Arc::new(files)).await;
            });
        });
        address
    }

    // the blocks a client on 127.0.0.21 receives for a read of name,
    // acknowledging each
    fn download(server: SocketAddr, name: &str) -> Vec<Vec<u8>> {
        let client = std::net::UdpSocket::bind("127.0.0.21:0").unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        client
            .send_to(format!("\0\x01{name}\0octet\0").as_bytes(), server)
            .unwrap();
        let mut blocks = Vec::new();
        loop {
            let mut datagram = [0; 1024];
            let (length, from) = client.recv_from(&mut datagram).unwrap();
            // every packet comes from the port the request went to
            assert_eq!(from, server);
            let packet = &datagram[..length];
            assert_eq!(&packet[..2], b"\0\x03", "{packet:?}");
            client
                .send_to(&[0, 4, packet[2], packet[3]], server)
                .unwrap();
            blocks.push(packet[4..].to_vec());
            if length < 4 + BLOCK_SIZE {
                return blocks;
            }
        }
    }

    #[test]
    fn a_file_goes_in_blocks_of_512_bytes_and_a_shorter_last_one() {
        let file = |size| File {
            allowed: None,
            tftp: true,
            content_type: "text/xml",
            body: Bytes::from(vec![b'x'; size]),
        };
        let server = server(Files::from([
            ("odd.xml".to_string(), file(1025)),
            ("even.xml".to_string(), file(1024)),
        ]));
        let sizes = |blocks: Vec<Vec<u8>>| blocks.iter().map(Vec::len).collect::<Vec<_>>();
        assert_eq!(sizes(download(server, "odd.xml")), [512, 512, 1]);
        assert_eq!(sizes(download(server, "even.xml")), [512, 512, 0]);
    }
}
