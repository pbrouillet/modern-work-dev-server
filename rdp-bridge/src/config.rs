use clap::Parser;

/// RD Gateway WebSocket bridge — proxies RDP over WebSocket to Azure VMs.
///
/// In standalone mode (default), routes all connections to a single
/// configured RDP target.  With --in-azure / RDP_BRIDGE_IN_AZURE=true,
/// the bridge resolves the client-requested server name to an Azure VM,
/// starts it if deallocated, and waits for it to become RDP-reachable.
#[derive(Parser, Debug, Clone)]
#[command(name = "rdp-bridge", version, about)]
pub struct Config {
    /// Target RDP host (private IP or hostname).
    /// Required when --in-azure is not set.
    #[arg(long, env = "RDP_TARGET_HOST")]
    pub rdp_target_host: Option<String>,

    /// Target RDP port.
    #[arg(long, env = "RDP_TARGET_PORT", default_value_t = 3389)]
    pub rdp_target_port: u16,

    /// Username for PAA cookie validation.
    /// If set, the client's PAA cookie must contain this value (case-insensitive).
    #[arg(long, env = "AUTH_USERNAME")]
    pub auth_username: Option<String>,

    /// Password for PAA cookie validation (reserved for future NTLM support).
    #[arg(long, env = "AUTH_PASSWORD")]
    pub auth_password: Option<String>,

    /// Port the bridge listens on.
    #[arg(long, env = "LISTEN_PORT", default_value_t = 8080)]
    pub listen_port: u16,

    /// Idle timeout in minutes sent to the RDP client.
    #[arg(long, env = "IDLE_TIMEOUT_MINUTES", default_value_t = 30)]
    pub idle_timeout_minutes: u32,

    /// Enable Azure VM lifecycle management.
    /// When true, the bridge acts as a multi-VM RD Gateway: it resolves
    /// the client-requested server name to an Azure VM in the configured
    /// resource group, checks its power state, starts it if necessary,
    /// and waits for it to become RDP-reachable before connecting.
    #[arg(long, env = "RDP_BRIDGE_IN_AZURE")]
    pub in_azure: bool,

    /// Azure subscription ID containing target VMs.
    /// Required when --in-azure is set.
    #[arg(long, env = "AZURE_SUBSCRIPTION_ID")]
    pub azure_subscription_id: Option<String>,

    /// Azure resource group containing target VMs.
    /// Required when --in-azure is set.
    #[arg(long, env = "AZURE_RESOURCE_GROUP")]
    pub azure_resource_group: Option<String>,
}

impl Config {
    /// Parse CLI args / env vars, filter empty strings, and validate
    /// required combinations.  Exits with a clear error on invalid config.
    pub fn parse_and_validate() -> Self {
        let mut config = Self::parse();

        // Treat empty strings the same as absent.
        config.rdp_target_host = config.rdp_target_host.filter(|s| !s.is_empty());
        config.auth_username = config.auth_username.filter(|s| !s.is_empty());
        config.auth_password = config.auth_password.filter(|s| !s.is_empty());
        config.azure_subscription_id = config.azure_subscription_id.filter(|s| !s.is_empty());
        config.azure_resource_group = config.azure_resource_group.filter(|s| !s.is_empty());

        if config.in_azure {
            if config.azure_subscription_id.is_none() {
                eprintln!(
                    "error: AZURE_SUBSCRIPTION_ID is required when RDP_BRIDGE_IN_AZURE is set"
                );
                std::process::exit(1);
            }
            if config.azure_resource_group.is_none() {
                eprintln!(
                    "error: AZURE_RESOURCE_GROUP is required when RDP_BRIDGE_IN_AZURE is set"
                );
                std::process::exit(1);
            }
        } else if config.rdp_target_host.is_none() {
            eprintln!(
                "error: RDP_TARGET_HOST is required when RDP_BRIDGE_IN_AZURE is not set"
            );
            std::process::exit(1);
        }

        config
    }
}
