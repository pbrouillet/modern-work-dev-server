//! TCP tunnel to the RDP target and bidirectional relay.

use crate::protocol;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

/// Open a TCP connection to the configured RDP target, ignoring
/// whatever the client requested (security: hardcoded target).
#[tracing::instrument(fields(target = %format!("{host}:{port}")))]
pub async fn connect(host: &str, port: u16) -> std::io::Result<TcpStream> {
    let addr = format!("{host}:{port}");
    tracing::info!("Connecting to RDP target");
    TcpStream::connect(&addr).await
}

/// Bidirectional relay between an axum WebSocket and a TCP stream.
///
/// - Data coming from the WebSocket are DATA packets; we unwrap them and
///   forward raw bytes to the TCP stream.
/// - Data coming from the TCP stream are raw RDP bytes; we wrap them in
///   DATA packets and send as binary WebSocket frames.
///
/// Returns when either side closes.
#[tracing::instrument(name = "ws_tcp_relay", skip_all)]
pub async fn relay_ws(
    ws: &mut axum::extract::ws::WebSocket,
    tcp: &mut TcpStream,
) {
    use axum::extract::ws::Message;

    let (mut tcp_read, mut tcp_write) = tcp.split();

    // We use a select loop so either direction can drive the relay.
    let mut tcp_buf = vec![0u8; 65536];

    loop {
        tokio::select! {
            // ── TCP → WebSocket ──────────────────────────────────
            result = tcp_read.read(&mut tcp_buf) => {
                match result {
                    Ok(0) | Err(_) => {
                        tracing::info!("RDP target connection closed");
                        break;
                    }
                    Ok(n) => {
                        let pkt = protocol::build_data_packet(&tcp_buf[..n]);
                        if ws.send(Message::Binary(pkt.into())).await.is_err() {
                            tracing::info!("WebSocket send failed, closing relay");
                            break;
                        }
                    }
                }
            }
            // ── WebSocket → TCP ──────────────────────────────────
            msg = ws.recv() => {
                match msg {
                    Some(Ok(Message::Binary(data))) => {
                        let hdr = match protocol::read_header(&data) {
                            Some(h) => h,
                            None => continue,
                        };
                        match hdr.pkt_type {
                            protocol::PKT_TYPE_DATA => {
                                let payload = &data[protocol::HEADER_SIZE..];
                                match protocol::parse_data_payload(payload) {
                                    Ok(rdp_bytes) => {
                                        if tcp_write.write_all(&rdp_bytes).await.is_err() {
                                            tracing::info!("TCP write failed");
                                            break;
                                        }
                                    }
                                    Err(e) => {
                                        tracing::warn!("Bad DATA payload: {e}");
                                    }
                                }
                            }
                            protocol::PKT_TYPE_KEEPALIVE => {
                                // Respond with keepalive
                                let pkt = protocol::create_packet(protocol::PKT_TYPE_KEEPALIVE, &[]);
                                let _ = ws.send(Message::Binary(pkt.into())).await;
                            }
                            protocol::PKT_TYPE_CLOSE_CHANNEL => {
                                tracing::info!("Client sent CLOSE_CHANNEL");
                                let resp = protocol::build_close_channel_response(protocol::ERROR_SUCCESS);
                                let _ = ws.send(Message::Binary(resp.into())).await;
                                break;
                            }
                            other => {
                                tracing::debug!("Relay ignoring pkt_type 0x{other:04x}");
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => {
                        tracing::info!("WebSocket closed by client");
                        break;
                    }
                    _ => {}
                }
            }
        }
    }
}
