//! MS-TSGU HTTP transport binary protocol types and helpers.
//!
//! Reference: [MS-TSGU] and the rdpgw open-source project for packet layouts.
//!
//! Every message on the wire starts with an 8-byte header:
//!
//! ```text
//! u16 LE  pkt_type
//! u16 LE  reserved (0)
//! u32 LE  packet_length (includes header)
//! ```

use byteorder::{LittleEndian, ReadBytesExt, WriteBytesExt};
use bytes::{BufMut, BytesMut};
use std::io::{self, Cursor, Read};

use crate::auth::decode_utf16le;

// ── Packet type constants ────────────────────────────────────────────

pub const PKT_TYPE_HANDSHAKE_REQUEST: u16 = 0x01;
pub const PKT_TYPE_HANDSHAKE_RESPONSE: u16 = 0x02;
pub const PKT_TYPE_EXTENDED_AUTH_MSG: u16 = 0x03;
pub const PKT_TYPE_TUNNEL_CREATE: u16 = 0x04;
pub const PKT_TYPE_TUNNEL_RESPONSE: u16 = 0x05;
pub const PKT_TYPE_TUNNEL_AUTH: u16 = 0x06;
pub const PKT_TYPE_TUNNEL_AUTH_RESPONSE: u16 = 0x07;
pub const PKT_TYPE_CHANNEL_CREATE: u16 = 0x08;
pub const PKT_TYPE_CHANNEL_RESPONSE: u16 = 0x09;
pub const PKT_TYPE_DATA: u16 = 0x0A;
pub const PKT_TYPE_SERVICE_MESSAGE: u16 = 0x0B;
pub const PKT_TYPE_REAUTH_MESSAGE: u16 = 0x0C;
pub const PKT_TYPE_KEEPALIVE: u16 = 0x0D;
pub const PKT_TYPE_CLOSE_CHANNEL: u16 = 0x10;
pub const PKT_TYPE_CLOSE_CHANNEL_RESPONSE: u16 = 0x11;

// ── Extended auth constants ──────────────────────────────────────────

pub const HTTP_EXTENDED_AUTH_NONE: u16 = 0x00;
pub const HTTP_EXTENDED_AUTH_SC: u16 = 0x01;
pub const HTTP_EXTENDED_AUTH_PAA: u16 = 0x02;
pub const HTTP_EXTENDED_AUTH_SSPI_NTLM: u16 = 0x04;

// ── Tunnel response field flags ──────────────────────────────────────

pub const HTTP_TUNNEL_RESPONSE_FIELD_TUNNEL_ID: u16 = 0x01;
pub const HTTP_TUNNEL_RESPONSE_FIELD_CAPS: u16 = 0x02;

// ── Tunnel auth response field flags ─────────────────────────────────

pub const HTTP_TUNNEL_AUTH_RESPONSE_FIELD_REDIR_FLAGS: u16 = 0x01;
pub const HTTP_TUNNEL_AUTH_RESPONSE_FIELD_IDLE_TIMEOUT: u16 = 0x02;

// ── Channel response field flags ─────────────────────────────────────

pub const HTTP_CHANNEL_RESPONSE_FIELD_CHANNELID: u16 = 0x01;

// ── Capability flags ─────────────────────────────────────────────────

pub const HTTP_CAPABILITY_IDLE_TIMEOUT: u32 = 0x02;

// ── Tunnel packet field flags ────────────────────────────────────────

pub const HTTP_TUNNEL_PACKET_FIELD_PAA_COOKIE: u16 = 0x01;

// ── Redirect flags ───────────────────────────────────────────────────

pub const HTTP_TUNNEL_REDIR_ENABLE_ALL: u32 = 0x8000_0000;

// ── Error codes ──────────────────────────────────────────────────────

pub const ERROR_SUCCESS: u32 = 0x0000_0000;
pub const E_PROXY_INTERNALERROR: u32 = 0x800759D8;
pub const E_PROXY_COOKIE_AUTHENTICATION_ACCESS_DENIED: u32 = 0x800759F8;

// ── Header ───────────────────────────────────────────────────────────

pub const HEADER_SIZE: usize = 8;

pub struct PacketHeader {
    pub pkt_type: u16,
    pub packet_length: u32,
}

/// Read the 8-byte header from a data slice.  Returns `None` if `data` is too
/// short or the advertised length exceeds the buffer.
pub fn read_header(data: &[u8]) -> Option<PacketHeader> {
    if data.len() < HEADER_SIZE {
        return None;
    }
    let mut cur = Cursor::new(data);
    let pkt_type = cur.read_u16::<LittleEndian>().ok()?;
    let _reserved = cur.read_u16::<LittleEndian>().ok()?;
    let packet_length = cur.read_u32::<LittleEndian>().ok()?;
    Some(PacketHeader {
        pkt_type,
        packet_length,
    })
}

/// Build the 8-byte header + payload into a single packet.
pub fn create_packet(pkt_type: u16, payload: &[u8]) -> Vec<u8> {
    let total = (HEADER_SIZE + payload.len()) as u32;
    let mut buf = BytesMut::with_capacity(total as usize);
    buf.put_u16_le(pkt_type);
    buf.put_u16_le(0); // reserved
    buf.put_u32_le(total);
    buf.put_slice(payload);
    buf.to_vec()
}

// ── Handshake ────────────────────────────────────────────────────────

pub struct HandshakeRequest {
    pub major: u8,
    pub minor: u8,
    pub client_version: u16,
    pub extended_auth: u16,
}

pub fn parse_handshake_request(payload: &[u8]) -> io::Result<HandshakeRequest> {
    let mut cur = Cursor::new(payload);
    let major = cur.read_u8()?;
    let minor = cur.read_u8()?;
    let client_version = cur.read_u16::<LittleEndian>()?;
    let extended_auth = cur.read_u16::<LittleEndian>()?;
    Ok(HandshakeRequest {
        major,
        minor,
        client_version,
        extended_auth,
    })
}

pub fn build_handshake_response(
    major: u8,
    minor: u8,
    extended_auth: u16,
    error_code: u32,
) -> Vec<u8> {
    let mut buf = Vec::with_capacity(12);
    buf.write_u32::<LittleEndian>(error_code).unwrap();
    buf.push(major);
    buf.push(minor);
    buf.write_u16::<LittleEndian>(0).unwrap(); // server version
    buf.write_u16::<LittleEndian>(extended_auth).unwrap();
    create_packet(PKT_TYPE_HANDSHAKE_RESPONSE, &buf)
}

// ── Tunnel Create ────────────────────────────────────────────────────

pub struct TunnelCreateRequest {
    pub caps_flags: u32,
    pub fields_present: u16,
    pub paa_cookie: Option<String>,
}

pub fn parse_tunnel_create(payload: &[u8]) -> io::Result<TunnelCreateRequest> {
    let mut cur = Cursor::new(payload);
    let caps_flags = cur.read_u32::<LittleEndian>()?;
    let fields_present = cur.read_u16::<LittleEndian>()?;
    let _reserved = cur.read_u16::<LittleEndian>()?;

    let paa_cookie = if fields_present & HTTP_TUNNEL_PACKET_FIELD_PAA_COOKIE != 0 {
        let size = cur.read_u16::<LittleEndian>()? as usize;
        let mut cookie_bytes = vec![0u8; size];
        cur.read_exact(&mut cookie_bytes)?;
        Some(decode_utf16le(&cookie_bytes))
    } else {
        None
    };

    Ok(TunnelCreateRequest {
        caps_flags,
        fields_present,
        paa_cookie,
    })
}

pub fn build_tunnel_response(error_code: u32, tunnel_id: u32) -> Vec<u8> {
    let mut buf = Vec::with_capacity(16);
    buf.write_u16::<LittleEndian>(0).unwrap(); // server version
    buf.write_u32::<LittleEndian>(error_code).unwrap();
    buf.write_u16::<LittleEndian>(
        HTTP_TUNNEL_RESPONSE_FIELD_TUNNEL_ID | HTTP_TUNNEL_RESPONSE_FIELD_CAPS,
    )
    .unwrap();
    buf.write_u16::<LittleEndian>(0).unwrap(); // reserved
    buf.write_u32::<LittleEndian>(tunnel_id).unwrap();
    buf.write_u32::<LittleEndian>(HTTP_CAPABILITY_IDLE_TIMEOUT)
        .unwrap();
    create_packet(PKT_TYPE_TUNNEL_RESPONSE, &buf)
}

// ── Tunnel Auth ──────────────────────────────────────────────────────

pub fn parse_tunnel_auth(payload: &[u8]) -> io::Result<String> {
    let mut cur = Cursor::new(payload);
    let size = cur.read_u16::<LittleEndian>()? as usize;
    let mut name_bytes = vec![0u8; size];
    cur.read_exact(&mut name_bytes)?;
    Ok(decode_utf16le(&name_bytes))
}

pub fn build_tunnel_auth_response(error_code: u32, idle_timeout_min: u32) -> Vec<u8> {
    let mut buf = Vec::with_capacity(16);
    buf.write_u32::<LittleEndian>(error_code).unwrap();
    buf.write_u16::<LittleEndian>(
        HTTP_TUNNEL_AUTH_RESPONSE_FIELD_REDIR_FLAGS
            | HTTP_TUNNEL_AUTH_RESPONSE_FIELD_IDLE_TIMEOUT,
    )
    .unwrap();
    buf.write_u16::<LittleEndian>(0).unwrap(); // reserved
    buf.write_u32::<LittleEndian>(HTTP_TUNNEL_REDIR_ENABLE_ALL)
        .unwrap(); // redir flags — allow all
    buf.write_u32::<LittleEndian>(idle_timeout_min).unwrap();
    create_packet(PKT_TYPE_TUNNEL_AUTH_RESPONSE, &buf)
}

// ── Channel Create ───────────────────────────────────────────────────

pub struct ChannelCreateRequest {
    pub server: String,
    pub port: u16,
}

pub fn parse_channel_create(payload: &[u8]) -> io::Result<ChannelCreateRequest> {
    let mut cur = Cursor::new(payload);
    let _resources_size = cur.read_u8()?;
    let _alternative = cur.read_u8()?;
    let port = cur.read_u16::<LittleEndian>()?;
    let _protocol = cur.read_u16::<LittleEndian>()?;
    let name_size = cur.read_u16::<LittleEndian>()? as usize;
    let mut name_bytes = vec![0u8; name_size];
    cur.read_exact(&mut name_bytes)?;
    let server = decode_utf16le(&name_bytes);
    Ok(ChannelCreateRequest { server, port })
}

pub fn build_channel_response(error_code: u32) -> Vec<u8> {
    let mut buf = Vec::with_capacity(12);
    buf.write_u32::<LittleEndian>(error_code).unwrap();
    buf.write_u16::<LittleEndian>(HTTP_CHANNEL_RESPONSE_FIELD_CHANNELID)
        .unwrap();
    buf.write_u16::<LittleEndian>(0).unwrap(); // reserved
    buf.write_u32::<LittleEndian>(1).unwrap(); // channel id
    create_packet(PKT_TYPE_CHANNEL_RESPONSE, &buf)
}

// ── Close Channel ────────────────────────────────────────────────────

pub fn build_close_channel_response(error_code: u32) -> Vec<u8> {
    let mut buf = Vec::with_capacity(12);
    buf.write_u32::<LittleEndian>(error_code).unwrap();
    buf.write_u16::<LittleEndian>(HTTP_CHANNEL_RESPONSE_FIELD_CHANNELID)
        .unwrap();
    buf.write_u16::<LittleEndian>(0).unwrap(); // reserved
    buf.write_u32::<LittleEndian>(1).unwrap(); // channel id
    create_packet(PKT_TYPE_CLOSE_CHANNEL_RESPONSE, &buf)
}

// ── Data ─────────────────────────────────────────────────────────────

/// Wrap raw RDP bytes in a DATA packet (pkt_type 0x0A).
/// Layout after header: u16 LE cbLen, then cbLen bytes of data.
pub fn build_data_packet(rdp_data: &[u8]) -> Vec<u8> {
    let mut payload = Vec::with_capacity(2 + rdp_data.len());
    payload
        .write_u16::<LittleEndian>(rdp_data.len() as u16)
        .unwrap();
    payload.extend_from_slice(rdp_data);
    create_packet(PKT_TYPE_DATA, &payload)
}

/// Extract the inner RDP bytes from a DATA packet payload (after header).
pub fn parse_data_payload(payload: &[u8]) -> io::Result<Vec<u8>> {
    let mut cur = Cursor::new(payload);
    let cb_len = cur.read_u16::<LittleEndian>()? as usize;
    let mut data = vec![0u8; cb_len];
    cur.read_exact(&mut data)?;
    Ok(data)
}
