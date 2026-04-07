mod auth;
mod azure_vm;
mod config;
mod gateway;
mod protocol;
mod telemetry;
mod tunnel;

use crate::azure_vm::AzureVmManager;
use crate::config::Config;
use crate::gateway::GatewayState;
use axum::{routing::get, Router, Json};
use serde_json::json;
use std::sync::Arc;

#[tokio::main]
async fn main() {
    let provider = telemetry::init_telemetry();

    let config = Config::parse_and_validate();
    let listen_port = config.listen_port;

    let azure_vm = if config.in_azure {
        let sub = config
            .azure_subscription_id
            .clone()
            .expect("validated at startup");
        let rg = config
            .azure_resource_group
            .clone()
            .expect("validated at startup");
        tracing::info!(
            subscription = %sub,
            resource_group = %rg,
            "Azure VM lifecycle management enabled"
        );
        Some(AzureVmManager::new(sub, rg))
    } else {
        None
    };

    let state = Arc::new(GatewayState::new(config, azure_vm));

    let app = Router::new()
        .route("/health", get(health))
        .route(
            "/remoteDesktopGateway/",
            get(gateway::handle_websocket).post(gateway::handle_legacy),
        )
        .route(
            "/remoteDesktopGateway",
            get(gateway::handle_websocket).post(gateway::handle_legacy),
        )
        .with_state(state);

    let addr = format!("0.0.0.0:{listen_port}");
    tracing::info!("RDP Bridge listening on {addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();

    telemetry::shutdown_telemetry(provider);
}

async fn health() -> Json<serde_json::Value> {
    Json(json!({ "status": "ok" }))
}
