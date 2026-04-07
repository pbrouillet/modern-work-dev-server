//! OpenTelemetry + Application Insights telemetry initialization.
//!
//! When `APPLICATIONINSIGHTS_CONNECTION_STRING` is set, traces are exported
//! to Application Insights via the OTLP HTTP/protobuf endpoint.  When unset,
//! we fall back to a plain `tracing_subscriber::fmt` subscriber (local dev).
//!
//! All existing `tracing::info!` / `warn!` / `error!` calls are automatically
//! bridged as OTel span events via the `tracing-opentelemetry` layer.

use opentelemetry::trace::TracerProvider as _;
use opentelemetry_sdk::{
    trace::{BatchSpanProcessor, TracerProvider},
    Resource,
};
use opentelemetry_otlp::{SpanExporter, WithExportConfig, WithHttpConfig};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};
use std::collections::HashMap;

/// Parsed fields from an Application Insights connection string.
struct AppInsightsConfig {
    ingestion_endpoint: String,
    instrumentation_key: String,
}

/// Parse `APPLICATIONINSIGHTS_CONNECTION_STRING` into its components.
/// Format: `InstrumentationKey=<guid>;IngestionEndpoint=https://…;…`
fn parse_connection_string(cs: &str) -> Option<AppInsightsConfig> {
    let mut ikey = None;
    let mut endpoint = None;
    for part in cs.split(';') {
        let part = part.trim();
        if let Some(val) = part.strip_prefix("InstrumentationKey=") {
            ikey = Some(val.to_string());
        } else if let Some(val) = part.strip_prefix("IngestionEndpoint=") {
            endpoint = Some(val.trim_end_matches('/').to_string());
        }
    }
    Some(AppInsightsConfig {
        ingestion_endpoint: endpoint?,
        instrumentation_key: ikey?,
    })
}

/// Initialize telemetry.
///
/// - With `APPLICATIONINSIGHTS_CONNECTION_STRING`: sets up an OTLP exporter
///   targeting App Insights, layered with fmt output.
/// - Without: fmt-only subscriber.
///
/// Returns a guard that **must** be held for the lifetime of the program.
/// Dropping it flushes and shuts down the tracer provider.
pub fn init_telemetry() -> Option<TracerProvider> {
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "rdp_bridge=info".into());

    let cs = std::env::var("APPLICATIONINSIGHTS_CONNECTION_STRING").ok();

    let fmt_layer = tracing_subscriber::fmt::layer()
        .with_target(true)
        .with_thread_ids(false);

    match cs.as_deref().and_then(parse_connection_string) {
        Some(config) => {
            let otlp_endpoint = format!("{}/v1/traces", config.ingestion_endpoint);

            tracing::info!(
                endpoint = %otlp_endpoint,
                "Initializing OTel export to Application Insights"
            );

            let mut headers = HashMap::new();
            headers.insert(
                "x-ms-ikey".to_string(),
                config.instrumentation_key.clone(),
            );

            let exporter = SpanExporter::builder()
                .with_http()
                .with_endpoint(&otlp_endpoint)
                .with_headers(headers)
                .build()
                .expect("Failed to create OTLP span exporter");

            let service_name = std::env::var("OTEL_SERVICE_NAME")
                .unwrap_or_else(|_| "rdp-bridge".to_string());

            let resource = Resource::new(vec![
                opentelemetry::KeyValue::new("service.name", service_name),
                opentelemetry::KeyValue::new("service.version", env!("CARGO_PKG_VERSION")),
            ]);

            let provider = TracerProvider::builder()
                .with_span_processor(
                    BatchSpanProcessor::builder(exporter, opentelemetry_sdk::runtime::Tokio).build(),
                )
                .with_resource(resource)
                .build();

            let tracer = provider.tracer("rdp-bridge");
            let otel_layer = tracing_opentelemetry::layer().with_tracer(tracer);

            tracing_subscriber::registry()
                .with(env_filter)
                .with(fmt_layer)
                .with(otel_layer)
                .init();

            Some(provider)
        }
        None => {
            tracing_subscriber::registry()
                .with(env_filter)
                .with(fmt_layer)
                .init();

            tracing::info!("No APPLICATIONINSIGHTS_CONNECTION_STRING — OTel disabled");
            None
        }
    }
}

/// Flush all pending spans and shut down the tracer provider.
pub fn shutdown_telemetry(provider: Option<TracerProvider>) {
    if let Some(provider) = provider {
        if let Err(e) = provider.shutdown() {
            eprintln!("OTel shutdown error: {e}");
        }
    }
}
