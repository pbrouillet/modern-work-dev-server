//! Azure VM lifecycle management via ARM REST API.
//!
//! Acquires bearer tokens from the Container App managed identity endpoint
//! (IDENTITY_ENDPOINT / IDENTITY_HEADER) or falls back to Azure CLI for
//! local development.  All Azure management operations use direct REST
//! calls so we avoid pulling in the legacy `azure_mgmt_*` crates.

use std::time::{Duration, Instant};

const ARM_BASE: &str = "https://management.azure.com";
const ARM_RESOURCE: &str = "https://management.azure.com/";
const API_VERSION_COMPUTE: &str = "2024-07-01";
const API_VERSION_NETWORK: &str = "2024-03-01";

// ── Power state enum ─────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PowerState {
    Running,
    Starting,
    Deallocated,
    Deallocating,
    Stopped,
    Unknown(String),
}

impl std::fmt::Display for PowerState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Running => write!(f, "running"),
            Self::Starting => write!(f, "starting"),
            Self::Deallocated => write!(f, "deallocated"),
            Self::Deallocating => write!(f, "deallocating"),
            Self::Stopped => write!(f, "stopped"),
            Self::Unknown(s) => write!(f, "{s}"),
        }
    }
}

// ── Manager ──────────────────────────────────────────────────────────

pub struct AzureVmManager {
    http: reqwest::Client,
    subscription_id: String,
    resource_group: String,
}

impl AzureVmManager {
    pub fn new(subscription_id: String, resource_group: String) -> Self {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("Failed to create HTTP client for Azure management");
        Self {
            http,
            subscription_id,
            resource_group,
        }
    }

    // ── Token acquisition ────────────────────────────────────────

    /// Acquire a bearer token for Azure Resource Manager.
    ///
    /// 1. Container App / App Service managed identity (IDENTITY_ENDPOINT).
    /// 2. Azure CLI fallback (`az account get-access-token`).
    async fn get_token(&self) -> Result<String, AzureVmError> {
        // Try managed identity first (Container Apps / App Service).
        if let (Ok(endpoint), Ok(id_header)) = (
            std::env::var("IDENTITY_ENDPOINT"),
            std::env::var("IDENTITY_HEADER"),
        ) {
            let url = format!("{endpoint}?api-version=2019-08-01&resource={ARM_RESOURCE}");
            let resp = self
                .http
                .get(&url)
                .header("X-IDENTITY-HEADER", &id_header)
                .send()
                .await
                .map_err(|e| AzureVmError::Token(format!("MI request failed: {e}")))?;

            let body = resp
                .text()
                .await
                .map_err(|e| AzureVmError::Token(format!("MI response read failed: {e}")))?;
            let json: serde_json::Value = serde_json::from_str(&body)
                .map_err(|e| AzureVmError::Token(format!("MI JSON parse failed: {e}")))?;

            return json["access_token"]
                .as_str()
                .map(|s| s.to_string())
                .ok_or_else(|| {
                    AzureVmError::Token(format!(
                        "MI response missing access_token: {body}"
                    ))
                });
        }

        // Fallback: Azure CLI.
        let output = tokio::process::Command::new("az")
            .args([
                "account",
                "get-access-token",
                "--resource",
                ARM_RESOURCE,
                "--query",
                "accessToken",
                "-o",
                "tsv",
            ])
            .output()
            .await
            .map_err(|e| AzureVmError::Token(format!("az CLI exec failed: {e}")))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(AzureVmError::Token(format!(
                "az CLI returned error: {stderr}"
            )));
        }

        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }

    // ── ARM helpers ──────────────────────────────────────────────

    fn vm_url(&self, vm_name: &str) -> String {
        format!(
            "{ARM_BASE}/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Compute/virtualMachines/{}",
            self.subscription_id, self.resource_group, vm_name
        )
    }

    /// Strip any domain suffix from a server name to get the Azure VM name.
    ///
    /// `"vm-spse-dev.spse.local"` → `"vm-spse-dev"`
    pub fn resolve_vm_name(server_name: &str) -> String {
        server_name
            .split('.')
            .next()
            .unwrap_or(server_name)
            .to_string()
    }

    // ── Public operations ────────────────────────────────────────

    /// Query the power state of a VM via its instance view.
    pub async fn get_vm_power_state(
        &self,
        vm_name: &str,
    ) -> Result<PowerState, AzureVmError> {
        let token = self.get_token().await?;
        let url = format!(
            "{}?$expand=instanceView&api-version={API_VERSION_COMPUTE}",
            self.vm_url(vm_name)
        );

        let resp = self
            .http
            .get(&url)
            .header("Authorization", format!("Bearer {token}"))
            .send()
            .await
            .map_err(|e| AzureVmError::Api(format!("GET VM failed: {e}")))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(AzureVmError::Api(format!(
                "GET VM returned {status}: {body}"
            )));
        }

        let body = resp.text().await.unwrap_or_default();
        let json: serde_json::Value = serde_json::from_str(&body)
            .map_err(|e| AzureVmError::Api(format!("VM JSON parse failed: {e}")))?;

        let statuses = json["properties"]["instanceView"]["statuses"]
            .as_array()
            .ok_or_else(|| {
                AzureVmError::Api("Missing instanceView.statuses in VM response".into())
            })?;

        for status in statuses {
            if let Some(code) = status["code"].as_str() {
                if let Some(power) = code.strip_prefix("PowerState/") {
                    return Ok(match power {
                        "running" => PowerState::Running,
                        "starting" => PowerState::Starting,
                        "deallocated" => PowerState::Deallocated,
                        "deallocating" => PowerState::Deallocating,
                        "stopped" => PowerState::Stopped,
                        other => PowerState::Unknown(other.to_string()),
                    });
                }
            }
        }

        Ok(PowerState::Unknown("no PowerState in statuses".into()))
    }

    /// Resolve the private IP of a VM by reading its first NIC.
    pub async fn get_vm_private_ip(
        &self,
        vm_name: &str,
    ) -> Result<String, AzureVmError> {
        let token = self.get_token().await?;

        // Step 1: GET VM to find the NIC resource ID.
        let vm_url = format!(
            "{}?api-version={API_VERSION_COMPUTE}",
            self.vm_url(vm_name)
        );
        let resp = self
            .http
            .get(&vm_url)
            .header("Authorization", format!("Bearer {token}"))
            .send()
            .await
            .map_err(|e| AzureVmError::Api(format!("GET VM failed: {e}")))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(AzureVmError::Api(format!(
                "GET VM returned {status}: {body}"
            )));
        }

        let body = resp.text().await.unwrap_or_default();
        let vm_json: serde_json::Value = serde_json::from_str(&body)
            .map_err(|e| AzureVmError::Api(format!("VM JSON parse failed: {e}")))?;

        let nic_id = vm_json["properties"]["networkProfile"]["networkInterfaces"]
            .as_array()
            .and_then(|nics| nics.first())
            .and_then(|nic| nic["id"].as_str())
            .ok_or_else(|| AzureVmError::Api("VM has no network interfaces".into()))?;

        // Step 2: GET the NIC to read its private IP.
        let token = self.get_token().await?;
        let nic_url = format!(
            "{ARM_BASE}{nic_id}?api-version={API_VERSION_NETWORK}"
        );
        let resp = self
            .http
            .get(&nic_url)
            .header("Authorization", format!("Bearer {token}"))
            .send()
            .await
            .map_err(|e| AzureVmError::Api(format!("GET NIC failed: {e}")))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(AzureVmError::Api(format!(
                "GET NIC returned {status}: {body}"
            )));
        }

        let body = resp.text().await.unwrap_or_default();
        let nic_json: serde_json::Value = serde_json::from_str(&body)
            .map_err(|e| AzureVmError::Api(format!("NIC JSON parse failed: {e}")))?;

        nic_json["properties"]["ipConfigurations"]
            .as_array()
            .and_then(|cfgs| cfgs.first())
            .and_then(|cfg| cfg["properties"]["privateIPAddress"].as_str())
            .map(|s| s.to_string())
            .ok_or_else(|| AzureVmError::Api("NIC has no private IP address".into()))
    }

    /// Trigger a VM start (fire-and-forget — does not wait for completion).
    pub async fn start_vm(&self, vm_name: &str) -> Result<(), AzureVmError> {
        let token = self.get_token().await?;
        let url = format!(
            "{}/start?api-version={API_VERSION_COMPUTE}",
            self.vm_url(vm_name)
        );

        let resp = self
            .http
            .post(&url)
            .header("Authorization", format!("Bearer {token}"))
            .header("Content-Length", "0")
            .send()
            .await
            .map_err(|e| AzureVmError::Api(format!("POST start VM failed: {e}")))?;

        let status = resp.status();
        // 200 = already running, 202 = accepted (starting).
        if status.is_success() || status.as_u16() == 202 {
            Ok(())
        } else {
            let body = resp.text().await.unwrap_or_default();
            Err(AzureVmError::Api(format!(
                "Start VM returned {status}: {body}"
            )))
        }
    }

    /// Ensure a VM is running and its RDP port is reachable.
    /// Returns the VM's private IP address.
    ///
    /// Flow:
    /// 1. Check power state.
    /// 2. If deallocated/stopped → start, then poll until Running (5 min).
    /// 3. Resolve private IP.
    /// 4. TCP-probe the RDP port until reachable (3 min).
    pub async fn ensure_vm_ready(
        &self,
        server_name: &str,
        rdp_port: u16,
    ) -> Result<String, AzureVmError> {
        let vm_name = Self::resolve_vm_name(server_name);

        tracing::info!(vm = %vm_name, "Checking Azure VM power state");
        let state = self.get_vm_power_state(&vm_name).await?;
        tracing::info!(vm = %vm_name, state = %state, "Current power state");

        match state {
            PowerState::Running => { /* already good */ }
            PowerState::Deallocated | PowerState::Stopped => {
                tracing::info!(vm = %vm_name, "Starting VM");
                self.start_vm(&vm_name).await?;
                self.wait_for_power_state(&vm_name, PowerState::Running, Duration::from_secs(300))
                    .await?;
            }
            PowerState::Starting => {
                tracing::info!(vm = %vm_name, "VM already starting — waiting");
                self.wait_for_power_state(&vm_name, PowerState::Running, Duration::from_secs(300))
                    .await?;
            }
            PowerState::Deallocating => {
                tracing::info!(vm = %vm_name, "VM deallocating — waiting, then starting");
                self.wait_for_power_state(
                    &vm_name,
                    PowerState::Deallocated,
                    Duration::from_secs(120),
                )
                .await?;
                self.start_vm(&vm_name).await?;
                self.wait_for_power_state(&vm_name, PowerState::Running, Duration::from_secs(300))
                    .await?;
            }
            PowerState::Unknown(ref s) => {
                tracing::warn!(vm = %vm_name, state = %s, "Unknown state — attempting start");
                self.start_vm(&vm_name).await?;
                self.wait_for_power_state(&vm_name, PowerState::Running, Duration::from_secs(300))
                    .await?;
            }
        }

        let ip = self.get_vm_private_ip(&vm_name).await?;
        tracing::info!(vm = %vm_name, ip = %ip, port = rdp_port, "VM running — probing RDP");

        self.wait_for_rdp(&ip, rdp_port, Duration::from_secs(180))
            .await?;
        tracing::info!(vm = %vm_name, ip = %ip, "RDP reachable");

        Ok(ip)
    }

    // ── Internal polling loops ───────────────────────────────────

    async fn wait_for_power_state(
        &self,
        vm_name: &str,
        target: PowerState,
        timeout: Duration,
    ) -> Result<(), AzureVmError> {
        let start = Instant::now();
        let poll = Duration::from_secs(10);

        loop {
            if start.elapsed() > timeout {
                return Err(AzureVmError::Timeout(format!(
                    "VM '{vm_name}' did not reach {target} within {}s",
                    timeout.as_secs()
                )));
            }
            tokio::time::sleep(poll).await;

            match self.get_vm_power_state(vm_name).await {
                Ok(state) if state == target => return Ok(()),
                Ok(state) => {
                    tracing::debug!(vm = %vm_name, state = %state, "Polling…");
                }
                Err(e) => {
                    tracing::warn!(vm = %vm_name, error = %e, "Poll error — retrying");
                }
            }
        }
    }

    async fn wait_for_rdp(
        &self,
        ip: &str,
        port: u16,
        timeout: Duration,
    ) -> Result<(), AzureVmError> {
        let start = Instant::now();
        let probe = Duration::from_secs(5);
        let addr = format!("{ip}:{port}");

        loop {
            if start.elapsed() > timeout {
                return Err(AzureVmError::Timeout(format!(
                    "RDP on {addr} not reachable within {}s",
                    timeout.as_secs()
                )));
            }
            match tokio::time::timeout(Duration::from_secs(3), tokio::net::TcpStream::connect(&addr))
                .await
            {
                Ok(Ok(_)) => return Ok(()),
                _ => {
                    tracing::debug!(addr = %addr, "RDP not reachable yet");
                    tokio::time::sleep(probe).await;
                }
            }
        }
    }
}

// ── Error type ───────────────────────────────────────────────────────

#[derive(Debug)]
pub enum AzureVmError {
    Token(String),
    Api(String),
    Timeout(String),
}

impl std::fmt::Display for AzureVmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Token(s) => write!(f, "Azure token error: {s}"),
            Self::Api(s) => write!(f, "Azure API error: {s}"),
            Self::Timeout(s) => write!(f, "Timeout: {s}"),
        }
    }
}

impl std::error::Error for AzureVmError {}
