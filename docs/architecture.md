# Architecture — Modern Work DevSPSE

## Deployment Layers

The project uses AZD with **three sequential layers**. Each layer's Bicep outputs are stored in the azd environment and consumed by subsequent layers via `${varName}` references in `main.parameters.json`.

```
azd up
  │
  ├─ Layer 1: networking          (infra/networking/)
  │   ├─ NSG, VNet (2 subnets), Public IP
  │   ├─ ACR (Basic)
  │   ├─ Log Analytics Workspace
  │   ├─ Application Insights
  │   └─ Container Apps Environment (VNet-integrated)
  │
  ├─ Layer 2: storage             (infra/storage/)
  │   ├─ Storage Account (Standard_LRS)
  │   ├─ scripts blob container
  │   └─ isos blob container
  │
  ├─ Layer 3: compute             (infra/compute/)
  │   ├─ Storage Account update (add VNet rule)
  │   ├─ VM (NIC, OS disk, data disk)
  │   └─ RBAC: VM → Storage Blob Data Contributor
  │
  └─ Post-provision hooks
      ├─ build-rdp-bridge.ps1     → ACR build + Container App create/update
      ├─ postprovision.ps1        → Storage firewall lock-down (Deny + VNet rule)
      └─ generate-rdp.ps1         → Auto-generate spsedev.rdp
```

### Why three layers?

The Container Apps Environment (CAE) with VNet integration takes 15–20 minutes for infrastructure warm-up on first deploy. Placing it in the `networking` layer (which runs first) gives it time to provision while storage and compute deploy. The Container App itself is created via CLI in the `postprovision` hook (not Bicep) because its first-revision creation on a VNet-integrated CAE consistently exceeds the ARM deployment timeout.

---

## Network Layout

```
VNet: 10.0.0.0/16  (vnet-spse-<env>)
│
├── snet-default:        10.0.1.0/24
│   ├── VM NIC
│   ├── NSG: Allow RDP from VNet + configurable source CIDR
│   └── Service endpoint: Microsoft.Storage
│
└── snet-container-apps: 10.0.4.0/23
    └── Delegated to Microsoft.App/environments (CAE)
```

---

## RDP Bridge

The rdp-bridge is a Rust/Axum application that implements the MS-TSGU (RD Gateway HTTP transport) protocol over WebSocket. It allows mstsc.exe to connect to Azure VMs through an Azure Container App without exposing RDP ports publicly.

### Connection flow

```
mstsc.exe (Dev Box)
  │
  │  HTTPS/WSS (port 443)
  ▼
Azure Container Apps ingress
  │
  │  WebSocket upgrade → /remoteDesktopGateway/
  ▼
rdp-bridge (Rust binary)
  │
  │  MS-TSGU handshake (5 phases):
  │    1. Handshake (version + auth negotiation)
  │    2. Tunnel Create (capabilities + PAA cookie)
  │    3. Tunnel Auth (client name + idle timeout)
  │    4. Channel Create (target server name + port)
  │       └─ Azure mode: resolve VM → check state → start if needed → wait
  │    5. Data Relay (bidirectional RDP byte forwarding)
  │
  │  TCP (port 3389)
  ▼
VM private IP (10.0.1.x)
```

### Azure VM lifecycle (`RDP_BRIDGE_IN_AZURE=true`)

When enabled, the bridge acts as a multi-VM RD Gateway:

1. Client sends server name in Channel Create (e.g., `vm-spse-myenv.francecentral.cloudapp.azure.com`)
2. Bridge strips domain suffix → `vm-spse-myenv`
3. Queries Azure ARM API for VM power state
4. If deallocated/stopped → starts the VM, polls until running (timeout: 5 min)
5. Resolves VM private IP via NIC
6. TCP-probes RDP port until reachable (timeout: 3 min)
7. Sends keepalives to mstsc during the wait (prevents timeout)
8. Connects and relays RDP traffic

Authentication with Azure uses the Container App's **managed identity** (IDENTITY_ENDPOINT) with Azure CLI fallback for local development.

### CLI arguments

```
rdp-bridge --help

Options:
  --rdp-target-host     Target RDP host (required when --in-azure is not set)
  --rdp-target-port     Target RDP port [default: 3389]
  --auth-username       PAA cookie validation username
  --auth-password       PAA cookie validation password
  --listen-port         Listen port [default: 8080]
  --idle-timeout-minutes  Idle timeout sent to client [default: 30]
  --in-azure            Enable Azure VM lifecycle management
  --azure-subscription-id  Azure subscription ID (required with --in-azure)
  --azure-resource-group   Azure resource group (required with --in-azure)
```

All options also accept environment variables (e.g., `RDP_BRIDGE_IN_AZURE`, `AZURE_SUBSCRIPTION_ID`).

---

## Storage Firewall Lifecycle

| Phase | defaultAction | Why |
|---|---|---|
| Storage layer deploy | `Allow` | Upload hook needs data-plane access |
| `upload-scripts.ps1` | Temporarily `Allow` | Uploads via `az storage blob upload-batch --auth-mode login` |
| Compute layer deploy | `Allow` + VNet rule | VM subnet gets service-endpoint access |
| `postprovision.ps1` | `Deny` + VNet rule | Blocks external access; VM retains access via service endpoint |

**Auth strategy**: Always `--auth-mode login` (Entra ID / RBAC). No storage account keys — corporate policy blocks key access on Dev Box.

---

## RBAC Assignments

| Principal | Role | Scope | Purpose |
|---|---|---|---|
| VM managed identity | Storage Blob Data Contributor | Storage Account | azcopy with managed identity for scripts/ISOs |
| Container App managed identity | AcrPull | ACR | Pull rdp-bridge image |
| Container App managed identity | Virtual Machine Contributor | Resource Group | Start/stop VMs on connection |
| Container App managed identity | Reader | Resource Group | Read NIC metadata for IP resolution |

---

## Build & Deploy

### rdp-bridge container

Built remotely on ACR via `az acr build` (no local Docker required):

```powershell
.\hooks\build-rdp-bridge.ps1
```

The hook:
1. Creates the Container App via `az containerapp create` if it doesn't exist
2. Assigns RBAC roles (AcrPull, VM Contributor, Reader)
3. Builds the Docker image on ACR
4. Configures ACR registry auth (managed identity)
5. Updates the Container App with the real image and env vars

### Validation

```powershell
# Bicep compilation
az bicep build --file infra/networking/main.bicep
az bicep build --file infra/storage/main.bicep
az bicep build --file infra/compute/main.bicep

# Rust compilation
cd rdp-bridge && cargo build --release

# PowerShell syntax check
Get-ChildItem scripts -Recurse -Filter *.ps1 | ForEach-Object {
    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $_.FullName -Raw), [ref]$null)
}
```

---

## File Layout

```
azure.yaml                        # AZD config: 3 layers + hooks
spsedev.rdp                        # Auto-generated RDP file (not committed)
infra/
  networking/
    main.bicep                     # Layer 1: VNet, ACR, LAW, AppInsights, CAE
    main.parameters.json
  storage/
    main.bicep                     # Layer 2: Storage Account + containers
    main.parameters.json
  compute/
    main.bicep                     # Layer 3: VM + RBAC
    main.parameters.json
    modules/
      network.bicep                # VNet/NSG/PIP module (used by networking layer)
      vm.bicep                     # VM resource module
      container-app.bicep          # Container App module (currently unused — CLI-managed)
      vm-extension.bicep           # CSE module (disabled during dev)
hooks/
  build-rdp-bridge.ps1             # ACR build + Container App create/update
  upload-scripts.ps1               # Upload scripts/ and isos/ to blob storage
  postprovision.ps1                # Secure storage firewall
  generate-rdp.ps1                 # Generate spsedev.rdp from azd outputs
rdp-bridge/
  Cargo.toml                       # Rust dependencies
  Dockerfile                       # Multi-stage build (rust:1.86 → debian:bookworm-slim)
  src/
    main.rs                        # Entry point, Axum router
    config.rs                      # Clap CLI + env var parsing
    gateway.rs                     # MS-TSGU state machine (WebSocket transport)
    protocol.rs                    # Binary protocol types (packets, headers, errors)
    tunnel.rs                      # TCP relay + bidirectional forwarding
    auth.rs                        # PAA cookie validation
    azure_vm.rs                    # Azure VM lifecycle (start, power state, IP resolution)
    telemetry.rs                   # OpenTelemetry + Application Insights
scripts/
  bootstrap.ps1                    # 13-phase state machine orchestrator
  Start-Setup.ps1                  # Manual entry point
  phases/01..13-*.ps1              # Individual provisioning phases
  helpers/                         # Common.ps1, Download-FromBlob.ps1, etc.
  config/                          # serials.json, sp-farm-config.json, vs-workloads.json
```
