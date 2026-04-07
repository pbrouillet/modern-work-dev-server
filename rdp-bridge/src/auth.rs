/// PAA cookie validation.
///
/// When mstsc is configured with an RD Gateway and the handshake selects PAA
/// (HTTP_EXTENDED_AUTH_PAA), the client sends a PAA cookie inside the
/// TunnelCreate message.  The cookie is a UTF-16LE string whose content
/// depends on the authentication mechanism negotiated at the HTTP level.
///
/// For our dev bridge we accept any cookie and optionally match the decoded
/// string against the configured `AUTH_USERNAME`.  The VM's own NLA layer
/// provides the real credential check.

use crate::config::Config;

/// Decode a UTF-16LE byte slice into a Rust String, stripping any NUL terminator.
pub fn decode_utf16le(data: &[u8]) -> String {
    let iter = data
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]));
    String::from_utf16_lossy(&iter.collect::<Vec<u16>>())
        .trim_end_matches('\0')
        .to_string()
}

/// Validate a PAA cookie against the configured credentials.
/// Returns `true` if no auth is configured or if the cookie contains the
/// expected username (case-insensitive substring match).
pub fn validate_paa_cookie(cookie: &str, config: &Config) -> bool {
    match &config.auth_username {
        None => true,
        Some(expected) => {
            let lower = cookie.to_lowercase();
            lower.contains(&expected.to_lowercase())
        }
    }
}
