# RDP Bridge — Sequence Diagrams

## 1. MS-TSGU Handshake (Standalone Mode)

The full WebSocket-based RD Gateway connection from client to data relay, when `in_azure=false` (standalone mode with a fixed target host).

```mermaid
sequenceDiagram
    participant C as mstsc.exe
    participant CA as Container Apps<br/>Ingress
    participant GW as gateway.rs
    participant A as auth.rs
    participant P as protocol.rs
    participant T as tunnel.rs
    participant VM as Target VM<br/>:3389

    Note over C,CA: HTTPS connection to Container App FQDN

    C->>CA: GET /remoteDesktopGateway/<br/>(WebSocket upgrade, subprotocol: remotedesktopgateway)
    CA->>GW: WebSocket connection established

    rect rgb(240, 248, 255)
        Note over C,GW: Phase 1 — Handshake
        C->>GW: PKT_TYPE_HANDSHAKE_REQUEST<br/>(major=1, minor=0, extended_auth flags)
        GW->>P: parse_handshake_request()
        P-->>GW: HandshakeRequest { version, ext_auth }
        GW->>P: build_handshake_response()<br/>(selected auth method: PAA or NONE)
        P-->>GW: response bytes
        GW->>C: PKT_TYPE_HANDSHAKE_RESPONSE
    end

    rect rgb(245, 255, 245)
        Note over C,GW: Phase 2 — Tunnel Create
        C->>GW: PKT_TYPE_TUNNEL_CREATE<br/>(capabilities, PAA cookie)
        GW->>P: parse_tunnel_create()
        P->>A: decode_utf16le() (cookie)
        A-->>P: decoded string
        P-->>GW: TunnelCreateRequest { caps, cookie }
        GW->>A: validate_paa_cookie(cookie, config)
        A-->>GW: true / false
        Note over GW: Reject if validation fails
        GW->>P: build_tunnel_response(SUCCESS, tunnel_id)
        P-->>GW: response bytes
        GW->>C: PKT_TYPE_TUNNEL_RESPONSE
    end

    rect rgb(255, 248, 240)
        Note over C,GW: Phase 3 — Tunnel Auth
        C->>GW: PKT_TYPE_TUNNEL_AUTH<br/>(client name)
        GW->>P: parse_tunnel_auth()
        P-->>GW: client_name
        GW->>P: build_tunnel_auth_response(SUCCESS, idle_timeout)
        P-->>GW: response bytes
        GW->>C: PKT_TYPE_TUNNEL_AUTH_RESPONSE
    end

    rect rgb(255, 245, 250)
        Note over C,GW: Phase 4 — Channel Create
        C->>GW: PKT_TYPE_CHANNEL_CREATE<br/>(server_name, port)
        GW->>P: parse_channel_create()
        P-->>GW: ChannelCreateRequest { server, port }
        Note over GW: Standalone: use config.rdp_target_host
        GW->>T: connect(target_host, target_port)
        T->>VM: TCP connect :3389
        VM-->>T: TCP established
        T-->>GW: TcpStream
        GW->>P: build_channel_response(SUCCESS)
        P-->>GW: response bytes
        GW->>C: PKT_TYPE_CHANNEL_RESPONSE
    end

    rect rgb(248, 245, 255)
        Note over C,VM: Phase 5 — Data Relay
        GW->>T: relay_ws(ws, tcp)
        loop Bidirectional forwarding
            C->>T: WS Binary (PKT_TYPE_DATA)
            T->>P: read_header() + parse_data_payload()
            P-->>T: raw RDP bytes
            T->>VM: TCP write

            VM->>T: TCP read
            T->>P: build_data_packet(rdp_bytes)
            P-->>T: WS frame bytes
            T->>C: WS Binary (PKT_TYPE_DATA)
        end
        Note over C,VM: Connection ends on close,<br/>disconnect, or error
    end
```

## 2. Azure VM Lifecycle (Azure Mode)

When `in_azure=true`, the ChannelCreate phase triggers VM lifecycle management before establishing the TCP tunnel. This diagram shows the `ensure_vm_ready()` flow in `azure_vm.rs`, including keepalive pumping from `gateway.rs`.

```mermaid
sequenceDiagram
    participant C as mstsc.exe
    participant GW as gateway.rs
    participant AZ as azure_vm.rs
    participant MSI as Managed Identity<br/>Endpoint
    participant ARM as Azure ARM<br/>REST API
    participant VM as Target VM<br/>:3389

    C->>GW: PKT_TYPE_CHANNEL_CREATE<br/>(server: vm-spse-myenv.francecentral.cloudapp.azure.com)

    GW->>AZ: ensure_vm_ready(server_name, 3389)

    Note over AZ: Strip domain suffix<br/>→ "vm-spse-myenv"
    AZ->>AZ: resolve_vm_name()

    rect rgb(255, 248, 230)
        Note over AZ,MSI: Token Acquisition
        AZ->>MSI: GET /token?resource=https://management.azure.com
        MSI-->>AZ: Bearer token
        Note over AZ: Falls back to<br/>az account get-access-token<br/>if no IDENTITY_ENDPOINT
    end

    rect rgb(240, 248, 255)
        Note over AZ,ARM: Power State Check
        AZ->>ARM: GET /subscriptions/{sub}/resourceGroups/{rg}/<br/>providers/Microsoft.Compute/virtualMachines/{vm}<br/>?$expand=instanceView
        ARM-->>AZ: VM instanceView (powerState: deallocated)
    end

    rect rgb(245, 255, 245)
        Note over AZ,VM: VM Start & Wait
        AZ->>ARM: POST .../virtualMachines/{vm}/start
        ARM-->>AZ: 202 Accepted

        loop Poll until Running (timeout: 5 min)
            AZ->>ARM: GET .../virtualMachines/{vm}?$expand=instanceView
            ARM-->>AZ: powerState: starting
            Note over GW,C: Meanwhile, gateway.rs pumps keepalives
            GW->>C: PKT_TYPE_KEEPALIVE
            C->>GW: PKT_TYPE_KEEPALIVE (echo)
        end
        ARM-->>AZ: powerState: running
    end

    rect rgb(255, 245, 250)
        Note over AZ,ARM: IP Resolution
        AZ->>ARM: GET .../virtualMachines/{vm}<br/>(read NIC reference)
        ARM-->>AZ: networkInterfaces[0].id
        AZ->>ARM: GET .../networkInterfaces/{nic}<br/>(read IP config)
        ARM-->>AZ: privateIPAddress: 10.0.1.x
    end

    rect rgb(248, 245, 255)
        Note over AZ,VM: RDP Port Probe
        loop TCP probe until reachable (timeout: 3 min)
            AZ->>VM: TCP connect :3389
            VM--xAZ: Connection refused
            Note over GW,C: Keepalives continue
            GW->>C: PKT_TYPE_KEEPALIVE
        end
        AZ->>VM: TCP connect :3389
        VM-->>AZ: TCP established (then closed)
    end

    AZ-->>GW: Ok("10.0.1.x")
    GW->>GW: connect + relay begins
    GW->>C: PKT_TYPE_CHANNEL_RESPONSE (SUCCESS)
```

## 3. Data Relay — Bidirectional Forwarding

Detail of `tunnel::relay_ws()` showing how WebSocket frames and TCP bytes are forwarded, including keepalive and close-channel handling.

```mermaid
sequenceDiagram
    participant C as mstsc.exe<br/>(WebSocket)
    participant T as tunnel.rs<br/>(relay_ws)
    participant P as protocol.rs
    participant VM as Target VM<br/>(TCP :3389)

    Note over C,VM: tokio::select! loop — first available wins

    alt TCP → WebSocket direction
        VM->>T: TCP read: raw RDP bytes
        T->>P: build_data_packet(bytes)
        P-->>T: MS-TSGU DATA frame
        T->>C: WS Binary message
    end

    alt WebSocket → TCP direction (DATA)
        C->>T: WS Binary message
        T->>P: read_header()
        P-->>T: PacketHeader { type: DATA }
        T->>P: parse_data_payload()
        P-->>T: raw RDP bytes
        T->>VM: TCP write
    end

    alt WebSocket → keepalive echo
        C->>T: WS Binary (PKT_TYPE_KEEPALIVE)
        T->>P: read_header()
        P-->>T: PacketHeader { type: KEEPALIVE }
        T->>P: create_packet(KEEPALIVE, [])
        P-->>T: keepalive response
        T->>C: WS Binary (KEEPALIVE echo)
    end

    alt WebSocket → close channel
        C->>T: WS Binary (PKT_TYPE_CLOSE_CHANNEL)
        T->>P: read_header()
        P-->>T: PacketHeader { type: CLOSE_CHANNEL }
        T->>P: build_close_channel_response(SUCCESS)
        P-->>T: close response
        T->>C: WS Binary (CLOSE_CHANNEL_RESPONSE)
        Note over T: Exit relay loop
    end

    alt Either side disconnects
        Note over C,VM: TCP EOF, WS close, or error<br/>→ relay loop exits gracefully
    end
```
