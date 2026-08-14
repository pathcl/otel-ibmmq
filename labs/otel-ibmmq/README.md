# Lab: OTel Baggage Propagation over IBM MQ/JMS

Demonstrates propagating business context (`bsi.ep`, `bsi.ch`, `bsi.cj`) across an
IBM MQ async boundary. Traces land in Tempo, metrics in Prometheus — both visible
in Grafana, with a custom Scenes plugin showing an entry-point-filtered service
graph with error-rate arc segments.

Three instrumentation approaches are available, each in its own directory:

| Mode | Directory | How context propagates |
|------|-----------|------------------------|
| `sdk` (default) | `labs/otel-ibmmq/` | `JmsCarrier` + explicit `propagator.inject/extract` |
| `agent` | `labs/otel-ibmmq-agent/` | OTel Java agent — bytecode instrumentation, no carrier code |
| `spring` | `labs/otel-ibmmq-spring/` | Spring Boot 3 + Micrometer Tracing — `@JmsListener`, `JmsTemplate` |

Two scenarios are available for each mode:

| Scenario | Description | Entry point |
|----------|-------------|-------------|
| **middle** (default) | Upstream Go service owns the trace root; injects `traceparent` + baggage into gateway over HTTP | `http://localhost:8081/order` |
| **origin** | Gateway is the trace root; baggage comes from HTTP headers | `http://localhost:8080/send` |

## Stack

| Component | Image / runtime |
|-----------|-----------------|
| IBM MQ | `icr.io/ibm-messaging/mq:9.4.5.0-r1` — multi-arch; native ARM64 since 9.3.3.0 |
| OTel Collector | `otel/opentelemetry-collector-contrib` — gRPC 4317, HTTP 4318 |
| Tempo | `grafana/tempo:2.10.7` |
| Prometheus | `prom/prometheus:latest` |
| Grafana (lab) | `grafana/grafana:latest` — port **3001** |
| Grafana (plugin dev) | `grafana/grafana:latest` — port **3000** (`start.sh up all` only) |
| upstream | Go 1.22, built locally (middle scenario only) |
| gateway / validator / enricher / processor / dlq-handler | Java 21, built locally |
| traffic-gen | Go, built locally |
| otel-mq-app | Grafana Scenes plugin, built locally |

## Start

All modes go through `start.sh` from the **repo root**:

```bash
# Manual SDK (default)
./start.sh up
./start.sh up origin

# OTel Java Agent
./start.sh up agent
./start.sh up agent origin

# Spring Boot 3 + Micrometer Tracing
./start.sh up spring
./start.sh up spring origin

# Full stack — also starts tutorial Grafana on port 3000 + webpack dev server
./start.sh up all
```

Mode and scenario can be given in any order after the command.
First run builds Java images (Maven downloads ~300 MB of deps). IBM MQ takes ~60 s
to initialise — all Java services retry automatically.

## Send a message

**Middle scenario** — enter at the upstream service:

```bash
curl -X POST http://localhost:8081/order \
  -H "X-bsi-ep: checkout" \
  -H "X-bsi-ch: android" \
  -H "X-bsi-cj: MoneyTransfer"
```

**Origin scenario** — enter at the gateway:

```bash
curl -X POST http://localhost:8080/send \
  -H "X-bsi-ep: checkout" \
  -H "X-bsi-ch: android" \
  -H "X-bsi-cj: MoneyTransfer"
```

Varied traffic across entry points:

```bash
for ep in checkout payment account; do
  curl -s -X POST http://localhost:8081/order \
    -H "X-bsi-ep: $ep" -H "X-bsi-ch: web" -H "X-bsi-cj: MoneyTransfer"
  echo "$ep: sent"
done
```

DLQ path (validator blocks `bsi.cj=blocked`):

```bash
curl -X POST http://localhost:8081/order \
  -H "X-bsi-ep: checkout" -H "X-bsi-ch: android" -H "X-bsi-cj: blocked"
```

## Observe

| URL | What you see |
|-----|--------------|
| http://localhost:3001 | Grafana — "OTel IBM MQ Baggage Lab" dashboard |
| http://localhost:3001/explore | Tempo trace search — filter by `bsi.ep` |
| http://localhost:9090 | Prometheus — query `traces_service_graph_request_total` |
| https://localhost:9443 | IBM MQ web console (`admin` / `passw0rd`) |
| http://localhost:3000 | Grafana — `otel-mq-app` Scenes plugin (`start.sh up all` only) |

TraceQL examples:

```
{ span.bsi.ep = "checkout" }
{ span.bsi.cj = "MoneyTransfer" && resource.service.name = "processor" }
```

## Stop

```bash
./start.sh down           # stop sdk lab
./start.sh down agent     # stop agent lab
./start.sh down spring    # stop spring lab
./start.sh down all       # stop lab + tutorial Grafana + webpack
```

To also remove the Tempo data volume:

```bash
docker compose -f labs/otel-ibmmq/docker-compose.yml down -v
```

## API Exit (optional)

`api-exit/` contains a reference implementation of an IBM MQ `ApiExitLocal` in C
that intercepts `MQPUT`/`MQGET` to inject `traceparent` for uninstrumented producers
(COBOL, C, vendor systems) — no application code changes required. It layers on top
of whichever lab mode is running. See [docs/16-api-exit.md](docs/16-api-exit.md).

```bash
./labs/otel-ibmmq/api-exit/install.sh    # compile + patch qm.ini + restart QM
./labs/otel-ibmmq/api-exit/uninstall.sh  # remove and restart clean
```

## Documentation

| File | Topic |
|------|-------|
| [01-architecture.md](docs/01-architecture.md) | Component map and data flows |
| [02-sdk-vs-agent.md](docs/02-sdk-vs-agent.md) | Manual SDK vs Java agent comparison |
| [03-jms-carrier.md](docs/03-jms-carrier.md) | TextMapSetter/Getter, IBM MQ constraints |
| [04-observability-stack.md](docs/04-observability-stack.md) | Tempo, Prometheus, Collector decisions |
| [05-baggage-design.md](docs/05-baggage-design.md) | What goes in baggage vs span attributes |
| [06-servicegraph-plugin.md](docs/06-servicegraph-plugin.md) | Grafana Scenes plugin walkthrough |
| [07-pipeline-pattern.md](docs/07-pipeline-pattern.md) | Sequential pipeline via IBM MQ |
| [08-dlq-pattern.md](docs/08-dlq-pattern.md) | Dead-letter queue and error handling |
| [09-competing-consumers.md](docs/09-competing-consumers.md) | Competing consumers pattern |
| [10-ibmmq-enterprise-patterns.md](docs/10-ibmmq-enterprise-patterns.md) | 12 enterprise IBM MQ patterns |
| [11-faqs.md](docs/11-faqs.md) | FAQs: pattern/language impact, all 11 propagation approaches |
| [12-baggage-propagation-checklist.md](docs/12-baggage-propagation-checklist.md) | Checklist for middle-of-chain and origin scenarios |
| [13-context-extraction.md](docs/13-context-extraction.md) | How gateway extracts traceparent + baggage from upstream |
| [14-sre-baggage-checklist.md](docs/14-sre-baggage-checklist.md) | Staff SRE checklist for team meetings |
| [15-ibmmq-complete-guide.md](docs/15-ibmmq-complete-guide.md) | Complete IBM MQ reference: APIs, HA, security, internals |
| [16-api-exit.md](docs/16-api-exit.md) | ApiExitLocal C exit: traceparent injection for uninstrumented producers |
| [ibmmq-101.md](docs/ibmmq-101.md) | IBM MQ on-ramp: mental model, four core objects, message anatomy |
| [ibmmq-tutorial.md](docs/ibmmq-tutorial.md) | Hands-on lab journal: commands, errors, and what the output taught us |
| [ibmmq-qa.md](docs/ibmmq-qa.md) | Running Q&A log tagged #ibmmq and #o11y |
| [baggage-ibmmq-checklist.md](docs/baggage-ibmmq-checklist.md) | Middle-of-chain SRE checklist: SDK setup, PROPCTL, silent bugs |
| [ibmmq-propagation-healthcheck.md](docs/ibmmq-propagation-healthcheck.md) | Quick reference to verify context propagation is working |
