//! RD Gateway HTTP transport handler.
//!
//! Supports two transports:
//!   1. **WebSocket** (primary) — single connection upgraded from GET
//!   2. **Legacy HTTP** (fallback) — two correlated POST channels
//!
//! Both run the same state machine:
//!   Handshake → TunnelCreate → TunnelAuth → ChannelCreate → DataRelay

use crate::auth;
use crate::azure_vm::AzureVmManager;
use crate::config::Config;
use crate::protocol::*;
use crate::tunnel;

use axum::{
    body::Body,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    http::{HeaderMap, Response, StatusCode},
    response::IntoResponse,
};
use std::sync::Arc;
use std::time::Duration;
use tracing::Instrument;

// ── Shared state ─────────────────────────────────────────────────────

pub struct GatewayState {
    pub config: Config,
    pub azure_vm: Option<AzureVmManager>,
}

impl GatewayState {
    pub fn new(config: Config, azure_vm: Option<AzureVmManager>) -> Self {
        Self { config, azure_vm }
    }
}

// ── WebSocket transport ──────────────────────────────────────────────

pub async fn handle_websocket(
    ws: WebSocketUpgrade,
    State(state): State<Arc<GatewayState>>,
) -> impl IntoResponse {
    tracing::info!("WebSocket upgrade request received");
    ws.protocols(["remotedesktopgateway"])
        .on_upgrade(move |socket| {
            ws_connection(socket, state).instrument(tracing::info_span!("rdg_session"))
        })
}

async fn ws_connection(mut ws: WebSocket, state: Arc<GatewayState>) {
    let config = &state.config;

    // ── Step 1: Handshake ────────────────────────────────────────
    let Some(hs_req) = recv_typed(&mut ws, PKT_TYPE_HANDSHAKE_REQUEST).await else {
        tracing::warn!("No handshake request received");
        return;
    };

    let hs = match parse_handshake_request(&hs_req) {
        Ok(h) => h,
        Err(e) => {
            tracing::warn!("Bad handshake: {e}");
            return;
        }
    };

    let selected_auth = if hs.extended_auth & HTTP_EXTENDED_AUTH_PAA != 0
        && config.auth_username.is_some()
    {
        HTTP_EXTENDED_AUTH_PAA
    } else {
        HTTP_EXTENDED_AUTH_NONE
    };

    tracing::info!(
        client_major = hs.major,
        client_minor = hs.minor,
        client_version = hs.client_version,
        ext_auth = format_args!("0x{:04x}", hs.extended_auth),
        selected_auth = format_args!("0x{:04x}", selected_auth),
        "Handshake completed"
    );

    let resp = build_handshake_response(hs.major, hs.minor, selected_auth, ERROR_SUCCESS);
    if send_bin(&mut ws, resp).await.is_err() {
        return;
    }

    // ── Step 2: Tunnel Create ────────────────────────────────────
    let tunnel_span = tracing::info_span!("tunnel_create",
        auth_method = format_args!("0x{:04x}", selected_auth),
    );

    let Some(tc_data) = recv_typed(&mut ws, PKT_TYPE_TUNNEL_CREATE)
        .instrument(tunnel_span.clone())
        .await
    else {
        tracing::warn!("No tunnel create received");
        return;
    };

    let tc = match parse_tunnel_create(&tc_data) {
        Ok(t) => t,
        Err(e) => {
            tracing::warn!("Bad tunnel create: {e}");
            return;
        }
    };

    if let Some(ref cookie) = tc.paa_cookie {
        tracing::info!(parent: &tunnel_span, cookie_len = cookie.len(), "PAA cookie present");
        if !auth::validate_paa_cookie(cookie, config) {
            tracing::warn!(parent: &tunnel_span, "PAA cookie validation failed");
            let resp = build_tunnel_response(
                E_PROXY_COOKIE_AUTHENTICATION_ACCESS_DENIED,
                0,
            );
            let _ = send_bin(&mut ws, resp).await;
            return;
        }
    }

    let resp = build_tunnel_response(ERROR_SUCCESS, 10);
    if send_bin(&mut ws, resp).await.is_err() {
        return;
    }

    // ── Step 3: Tunnel Auth ──────────────────────────────────────
    let auth_span = tracing::info_span!("tunnel_auth");

    let Some(ta_data) = recv_typed(&mut ws, PKT_TYPE_TUNNEL_AUTH)
        .instrument(auth_span.clone())
        .await
    else {
        tracing::warn!("No tunnel auth received");
        return;
    };

    if let Ok(client_name) = parse_tunnel_auth(&ta_data) {
        tracing::info!(parent: &auth_span, client_name = %client_name, "Tunnel auth completed");
    }

    let resp = build_tunnel_auth_response(ERROR_SUCCESS, config.idle_timeout_minutes);
    if send_bin(&mut ws, resp).await.is_err() {
        return;
    }

    // ── Step 4: Channel Create ───────────────────────────────────
    let Some(cc_data) = recv_typed(&mut ws, PKT_TYPE_CHANNEL_CREATE).await else {
        tracing::warn!("No channel create received");
        return;
    };

    let cc = match parse_channel_create(&cc_data) {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("Bad channel create: {e}");
            return;
        }
    };

    // Resolve target host + port based on mode.
    let (target_host, target_port) = if let Some(ref azure_vm) = state.azure_vm {
        // ── Azure mode: resolve VM, ensure it's running ──────
        let channel_span = tracing::info_span!("channel_create_azure",
            requested_server = %cc.server,
            requested_port = cc.port,
        );

        tracing::info!(
            parent: &channel_span,
            "Azure mode — resolving VM from client request"
        );

        let port = if cc.port == 0 { config.rdp_target_port } else { cc.port };

        // Run ensure_vm_ready concurrently with keepalive pumping.
        // Pin the future so it survives across select! iterations.
        let vm_ready = azure_vm.ensure_vm_ready(&cc.server, port);
        tokio::pin!(vm_ready);

        let mut keepalive_tick =
            tokio::time::interval(Duration::from_secs(15));

        let result = loop {
            tokio::select! {
                // Send keepalives to prevent mstsc timeout.
                _ = keepalive_tick.tick() => {
                    let pkt = create_packet(PKT_TYPE_KEEPALIVE, &[]);
                    if send_bin(&mut ws, pkt).await.is_err() {
                        tracing::warn!(parent: &channel_span, "Client disconnected during VM start");
                        return;
                    }
                }
                // Handle incoming client messages (keepalives, close).
                msg = ws.recv() => {
                    match msg {
                        Some(Ok(Message::Binary(data))) => {
                            if let Some(hdr) = read_header(&data) {
                                if hdr.pkt_type == PKT_TYPE_KEEPALIVE {
                                    let pkt = create_packet(PKT_TYPE_KEEPALIVE, &[]);
                                    let _ = send_bin(&mut ws, pkt).await;
                                } else if hdr.pkt_type == PKT_TYPE_CLOSE_CHANNEL {
                                    tracing::info!(parent: &channel_span, "Client closed during VM start");
                                    return;
                                }
                            }
                        }
                        Some(Ok(Message::Close(_))) | None => {
                            tracing::info!(parent: &channel_span, "Client disconnected during VM start");
                            return;
                        }
                        _ => {}
                    }
                }
                // VM readiness check completes.
                result = &mut vm_ready => {
                    break result;
                }
            }
        };

        match result {
            Ok(ip) => {
                tracing::info!(parent: &channel_span, target_ip = %ip, "VM ready");
                (ip, port)
            }
            Err(e) => {
                tracing::error!(parent: &channel_span, error = %e, "Failed to ensure VM ready");
                let resp = build_channel_response(E_PROXY_INTERNALERROR);
                let _ = send_bin(&mut ws, resp).await;
                return;
            }
        }
    } else {
        // ── Standalone mode: use configured target ───────────
        let host = config
            .rdp_target_host
            .clone()
            .expect("rdp_target_host validated at startup");

        let channel_span = tracing::info_span!("channel_create",
            target_host = %host,
            target_port = config.rdp_target_port,
        );

        tracing::info!(
            parent: &channel_span,
            requested_server = %cc.server,
            requested_port = cc.port,
            "Channel create — routing to configured target"
        );

        (host, config.rdp_target_port)
    };

    let mut tcp = match tunnel::connect(&target_host, target_port).await {
        Ok(s) => s,
        Err(e) => {
            tracing::error!(error = %e, "Failed to connect to RDP target {target_host}:{target_port}");
            let resp = build_channel_response(E_PROXY_INTERNALERROR);
            let _ = send_bin(&mut ws, resp).await;
            return;
        }
    };

    let resp = build_channel_response(ERROR_SUCCESS);
    if send_bin(&mut ws, resp).await.is_err() {
        return;
    }

    // ── Step 5: Data relay ───────────────────────────────────────
    tracing::info!("Entering data relay");
    tunnel::relay_ws(&mut ws, &mut tcp)
        .instrument(tracing::info_span!("data_relay"))
        .await;
    tracing::info!("Session ended");
}

// ── Legacy HTTP transport (stub) ─────────────────────────────────────

/// Two-channel HTTP transport used by older clients.
///
/// The client opens two POST connections to the same path with the same
/// `RDG-Connection-Id` header.  The first becomes the OUT channel (server →
/// client, held open with chunked encoding) and the second becomes the IN
/// channel (client → server).
///
/// This is significantly more complex than WebSocket and is rarely needed
/// on Windows 10+.  For now we return 501 and log the attempt so we know
/// if a client actually tries it.
pub async fn handle_legacy(
    State(_state): State<Arc<GatewayState>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let conn_id = headers
        .get("RDG-Connection-Id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("<none>");
    tracing::warn!(
        "Legacy HTTP transport request (RDG-Connection-Id={conn_id}). \
         Not implemented — client should use WebSocket."
    );
    Response::builder()
        .status(StatusCode::NOT_IMPLEMENTED)
        .body(Body::empty())
        .unwrap()
}

// ── Helpers ──────────────────────────────────────────────────────────

/// Receive a single binary WebSocket message, verify its packet type,
/// and return just the payload (after the 8-byte header).
async fn recv_typed(ws: &mut WebSocket, expected_type: u16) -> Option<Vec<u8>> {
    loop {
        match ws.recv().await {
            Some(Ok(Message::Binary(data))) => {
                let hdr = read_header(&data)?;
                if hdr.pkt_type == expected_type {
                    return Some(data[HEADER_SIZE..].to_vec());
                }
                // Allow keepalives during setup.
                if hdr.pkt_type == PKT_TYPE_KEEPALIVE {
                    let pkt = create_packet(PKT_TYPE_KEEPALIVE, &[]);
                    let _ = ws.send(Message::Binary(pkt.into())).await;
                    continue;
                }
                tracing::warn!(
                    "Expected pkt 0x{expected_type:04x}, got 0x{:04x}",
                    hdr.pkt_type
                );
                return None;
            }
            Some(Ok(Message::Close(_))) | None => return None,
            _ => continue,
        }
    }
}

async fn send_bin(ws: &mut WebSocket, data: Vec<u8>) -> Result<(), ()> {
    ws.send(Message::Binary(data.into()))
        .await
        .map_err(|e| tracing::warn!("WebSocket send error: {e}"))
}
