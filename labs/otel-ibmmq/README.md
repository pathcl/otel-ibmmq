# Lab: OTel Baggage Propagation over IBM MQ/JMS

Demonstrates propagating business context (tenant ID, user ID) across an IBM MQ
async boundary using the OpenTelemetry SDK. Traces land in Tempo, metrics in
Prometheus — both visible in Grafana, with a custom Scenes plugin showing a
tenant-filtered service graph with error-rate arc segments.

Two scenarios are available:

| Scenario | Description | Entry point |
|----------|-------------|-------------|
| **middle** (default) | IBM MQ sits mid-chain — a Go `upstream` service owns the trace root and injects `traceparent` + baggage before calling gateway | `http://localhost:8081/order` |
| **origin** | Gateway is the trace root — no upstream service; tenant/user come from HTTP headers | `http://localhost:8080/send` |

## Stack

| Component            | Image / runtime                                  |
|----------------------|--------------------------------------------------|
| IBM MQ               | `icr.io/ibm-messaging/mq:latest`                |
| OTel Collector       | `otel/opentelemetry-collector-contrib`          |
| Tempo                | `grafana/tempo:2.10.7`                          |
| Prometheus           | `prom/prometheus:latest`                        |
| Grafana (lab)        | `grafana/grafana:latest` — port **3001**        |
| Grafana (plugin dev) | `grafana/grafana:latest` — port **3000**        |
| upstream             | Go 1.22, built locally (middle scenario only)   |
| gateway              | Java 21, built locally — PRODUCER               |
| validator            | Java 21, built locally — pipeline stage 1       |
| enricher             | Java 21, built locally — pipeline stage 2       |
| processor            | Java 21, built locally — CONSUMER               |
| dlq-handler          | Java 21, built locally — dead-letter handler    |
| traffic-gen          | Go, built locally — sends synthetic load        |
| otel-mq-app          | Grafana Scenes plugin, built locally            |

## Start

Use `start.sh` from the repository root. It builds the plugin, starts all
containers, and launches the webpack dev server for the plugin.

```bash
# Middle-of-chain (default) — upstream → gateway → IBM MQ pipeline
./start.sh

# Same as above, explicit
./start.sh up middle

# Origin — gateway is the trace root, no upstream service
./start.sh up origin
```

First run builds the Java images (Maven downloads ~300 MB of deps). Subsequent
starts are fast. IBM MQ takes ~60 seconds to initialise — all Java services
retry automatically.

## Send a message

**Middle scenario** — enter at the upstream service:

```bash
curl -X POST http://localhost:8081/order \
  -H "X-Tenant-ID: acme" \
  -H "X-User-ID: user42"
```

The upstream service creates the root span, sets `tenant.id`/`user.id` baggage,
injects W3C headers (`traceparent`, `baggage`) into its HTTP call to gateway,
and gateway forwards them unchanged into IBM MQ.

**Origin scenario** — enter at the gateway:

```bash
curl -X POST http://localhost:8080/send \
  -H "X-Tenant-ID: acme" \
  -H "X-User-ID: user42"
```

Send a few messages with different tenant IDs (traffic-gen does this automatically
once running, but manual sends give you control over timing):

```bash
for tenant in acme globex initech; do
  curl -s -X POST http://localhost:8081/order \
    -H "X-Tenant-ID: $tenant" \
    -H "X-User-ID: user1"
  echo "$tenant: sent"
done
```

## Observe

| URL | What you see |
|-----|--------------|
| http://localhost:3000 | Grafana — `otel-mq-app` Scenes plugin (service graph, tenant debug) |
| http://localhost:3001 | Grafana — "OTel IBM MQ Baggage Lab" dashboard |
| http://localhost:3001/explore | Tempo trace search — filter by `tenant.id` |
| http://localhost:9090 | Prometheus — query `traces_service_graph_request_total` |
| https://localhost:9443 | IBM MQ web console (`admin` / `passw0rd`) |

**Trace search** — in Grafana Explore → Tempo, use TraceQL:

```
{span["tenant.id"] = "acme"}
```

**Middle scenario** trace shape:

```
upstream.order (root)
  └── gateway.send (PRODUCER)
        └── validator.handle
              └── enricher.handle
                    └── processor.handle (CONSUMER)
```

**Origin scenario** trace shape:

```
gateway.send (root, PRODUCER)
  └── validator.handle
        └── enricher.handle
              └── processor.handle (CONSUMER)
```

**Service graph plugin** (port 3000) — the Home tab shows a node graph with
error-rate arc segments (green = success, red = error). The Tenant Debug tab
filters edges and nodes to a single tenant via a `$tenant` variable.

## Stop

```bash
# Stop the default (middle) scenario
./start.sh down

# Stop the origin scenario
./start.sh down origin
```

To also remove the Tempo data volume, stop manually with:

```bash
docker compose -f labs/otel-ibmmq/docker-compose.yml \
               -f labs/otel-ibmmq/docker-compose.upstream.yml \
               down -v
```

## Documentation

Every design decision is explained in `docs/`:

| File | Topic |
|------|-------|
| [01-architecture.md](docs/01-architecture.md) | Component map and data flows |
| [02-sdk-vs-agent.md](docs/02-sdk-vs-agent.md) | Why manual SDK over Java agent |
| [03-jms-carrier.md](docs/03-jms-carrier.md) | TextMapSetter/Getter, IBM MQ constraints |
| [04-observability-stack.md](docs/04-observability-stack.md) | Tempo, Prometheus, Collector decisions |
| [05-baggage-design.md](docs/05-baggage-design.md) | What goes in baggage vs span attributes |
| [06-servicegraph-plugin.md](docs/06-servicegraph-plugin.md) | Grafana Scenes plugin walkthrough |
| [07-pipeline-pattern.md](docs/07-pipeline-pattern.md) | Sequential pipeline via IBM MQ |
| [08-dlq-pattern.md](docs/08-dlq-pattern.md) | Dead-letter queue and error handling |
| [09-competing-consumers.md](docs/09-competing-consumers.md) | Competing consumers pattern |
| [10-ibmmq-enterprise-patterns.md](docs/10-ibmmq-enterprise-patterns.md) | 12 enterprise IBM MQ patterns |
| [11-faqs.md](docs/11-faqs.md) | FAQs: pattern and language impact on propagation |
| [12-baggage-propagation-checklist.md](docs/12-baggage-propagation-checklist.md) | Checklist for middle-of-chain and origin scenarios |
| [13-context-extraction.md](docs/13-context-extraction.md) | How gateway extracts traceparent + baggage from upstream HTTP headers |
| [14-sre-baggage-checklist.md](docs/14-sre-baggage-checklist.md) | Staff SRE checklist: all APIs, patterns, and questions before team meetings |
| [15-ibmmq-complete-guide.md](docs/15-ibmmq-complete-guide.md) | Complete IBM MQ reference: concepts, APIs, HA, security, internals, gotchas |
| [ibmmq-101.md](docs/ibmmq-101.md) | IBM MQ on-ramp: mental model, four core objects, message anatomy, delivery guarantees, what to ignore |
| [baggage-ibmmq-checklist.md](docs/baggage-ibmmq-checklist.md) | Middle-of-chain SRE checklist: SDK setup, PROPCTL, extract/inject pattern, silent bugs |
