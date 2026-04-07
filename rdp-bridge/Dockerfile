FROM rust:1.86-slim AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock* ./
COPY src/ src/
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/rdp-bridge /usr/local/bin/rdp-bridge
EXPOSE 8080
ENV RUST_LOG=rdp_bridge=info
HEALTHCHECK --interval=15s --timeout=3s CMD curl -f http://localhost:8080/health || exit 1
ENTRYPOINT ["/usr/local/bin/rdp-bridge"]
