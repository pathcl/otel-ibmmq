# 04 — Observability Stack Decisions

## Tempo instead of Jaeger

**Decision:** use Grafana Tempo for traces.

**Why:** Tempo is already part of the target production stack (Mimir + Grafana + Tempo).
Using it in the lab means the Grafana datasource configuration, TraceQL queries, and
service graph view are directly transferable to production. Jaeger would require a
separate UI and different query language.

**Trade-off:** Tempo with local storage is fine for a lab but requires explicit
`block_retention` and `wal` config. Jaeger's all-in-one image is simpler to start.
We accept this for consistency with the production stack.

**Tempo config choices:**
- `backend: local` — no S3/GCS needed for a lab
- `block_retention: 1h` — traces disappear after an hour, keeping disk usage minimal
- `stream_over_http_enabled: true` — required for Grafana's streaming trace panel

## OTel Collector as intermediary

**Decision:** gateway and processor send to otel-collector, which fans out to Tempo and
Prometheus. They do NOT send directly to Tempo.

**Why:**
- Fan-out: one OTLP endpoint receives both traces and metrics and routes them to the
  appropriate backends
- Decoupling: swap Tempo for something else without changing the Java code
- Batching: the `batch` processor groups spans before forwarding, reducing connections
  to Tempo

**Alternative rejected:** direct OTLP to Tempo + direct Prometheus metrics from the app.
This works but means each service needs two exporter configurations and the routing
logic lives in each service rather than in one place.

## Prometheus scrape model vs OTLP push for metrics

**Decision:** otel-collector exposes a Prometheus scrape endpoint (`/metrics` on :8889).
Prometheus scrapes it. Grafana reads from Prometheus.

**Why:** the production stack already has Mimir (Prometheus-compatible). Metrics arriving
as a scrape are immediately compatible with Mimir's ingestion model. The OTel collector's
`prometheus` exporter converts OTel metric names and attributes to Prometheus convention
automatically (dots → underscores, counter → `_total` suffix).

**Trade-off:** scrape interval (15s) means metrics have 15s latency. For the lab this
is fine. In production with Mimir you would use the `otlp` exporter from the collector
to push directly to Mimir's OTLP endpoint instead.

## Grafana on port 3001

**Decision:** lab Grafana runs on host port 3001, not 3000.

**Why:** the tutorial's `tutorial-miniops-app` already uses port 3000. Running both
simultaneously (tutorial + lab) would conflict. 3001 is the simplest resolution.

## IBM MQ developer image

**Decision:** `icr.io/ibm-messaging/mq:latest` with `LICENSE=accept`.

The IBM Container Registry (ICR) hosts a free developer edition of IBM MQ. No IBM Cloud
account or authentication required for pulling — `LICENSE=accept` is the only gate.

Default credentials created by the image:
- Queue manager: `QM1`
- Channel: `DEV.APP.SVRCONN`
- Queue: `DEV.QUEUE.1`
- App user: `app` / `passw0rd`

These are insecure defaults intended only for development. Never use them in production.
