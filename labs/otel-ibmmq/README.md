# Lab: OTel Baggage Propagation over IBM MQ/JMS

Demonstrates propagating business context (`bsi.ep`, `bsi.ch`, `bsi.cj`) across an
IBM MQ async boundary using the OpenTelemetry SDK. Traces land in Tempo, metrics in
Prometheus — both visible in Grafana, with a custom Scenes plugin showing an
entry-point-filtered service graph with error-rate arc segments.

Two scenarios are available:

| Scenario | Description | Entry point |
|----------|-------------|-------------|
| **middle** (default) | IBM MQ sits mid-chain — a Go `upstream` service owns the trace root and injects `traceparent` + baggage before calling gateway | `http://localhost:8081/order` |
| **origin** | Gateway is the trace root — no upstream service; baggage comes from HTTP headers | `http://localhost:8080/send` |

## Stack

| Component            | Image / runtime                                  |
|----------------------|--------------------------------------------------|
| IBM MQ               | `icr.io/ibm-messaging/mq:9.4.5.0-r1` — multi-arch; native ARM64 since 9.3.3.0 ([blog](https://community.ibm.com/community/user/blogs/richard-coppen/2023/06/30/ibm-mq-9330-container-image-now-available-for-appl)) |
| OTel Collector       | `otel/opentelemetry-collector-contrib`          |
| Tempo                | `grafana/tempo:2.10.7`                          |
| Prometheus           | `prom/prometheus:latest`                        |
| Grafana (lab)        | `grafana/grafana:latest` — port **3001**        |
| Grafana (plugin dev) | `grafana/grafana:latest` — port **3000** (`start.sh up all` only) |
| upstream             | Go 1.22, built locally (middle scenario only)   |
| gateway              | Java 21, built locally — PRODUCER               |
| validator            | Java 21, built locally — pipeline stage 1       |
| enricher             | Java 21, built locally — pipeline stage 2       |
| processor            | Java 21, built locally — CONSUMER               |
| dlq-handler          | Java 21, built locally — dead-letter handler    |
| traffic-gen          | Go, built locally — sends synthetic load        |
| otel-mq-app          | Grafana Scenes plugin, built locally            |

## Start

```bash
# Lab only — IBM MQ pipeline + Grafana on port 3001 (default)
./start.sh

# Full stack — also starts tutorial Grafana on port 3000 + webpack dev server
./start.sh up all

# Origin scenario — gateway is the trace root, no upstream service
./start.sh up origin
```

First run builds the Java images (Maven downloads ~300 MB of deps). Subsequent
starts are fast. IBM MQ takes ~60 seconds to initialise — all Java services
retry automatically.

## Send a message

**Middle scenario** — enter at the upstream service:

```bash
curl -X POST http://localhost:8081/order \
  -H "X-bsi-ep: checkout" \
  -H "X-bsi-ch: android" \
  -H "X-bsi-cj: MoneyTransfer"
```

The upstream service creates the root span, sets `bsi.ep`/`bsi.ch`/`bsi.cj` baggage,
injects W3C headers (`traceparent`, `baggage`) into its HTTP call to gateway,
and gateway forwards them unchanged into IBM MQ.

**Origin scenario** — enter at the gateway:

```bash
curl -X POST http://localhost:8080/send \
  -H "X-bsi-ep: checkout" \
  -H "X-bsi-ch: android" \
  -H "X-bsi-cj: MoneyTransfer"
```

Send messages with different entry points to generate varied traffic:

```bash
for ep in checkout payment account; do
  curl -s -X POST http://localhost:8081/order \
    -H "X-bsi-ep: $ep" \
    -H "X-bsi-ch: web" \
    -H "X-bsi-cj: MoneyTransfer"
  echo "$ep: sent"
done
```

Trigger the DLQ path (validator blocks `bsi.cj=blocked`):

```bash
curl -X POST http://localhost:8081/order \
  -H "X-bsi-ep: checkout" \
  -H "X-bsi-ch: android" \
  -H "X-bsi-cj: blocked"
```

## Observe

| URL | What you see |
|-----|--------------|
| http://localhost:3001 | Grafana — "OTel IBM MQ Baggage Lab" dashboard |
| http://localhost:3001/explore | Tempo trace search — filter by `bsi.ep` |
| http://localhost:9090 | Prometheus — query `traces_service_graph_request_total` |
| https://localhost:9443 | IBM MQ web console (`admin` / `passw0rd`) |
| http://localhost:3000 | Grafana — `otel-mq-app` Scenes plugin (`start.sh up all` only) |

**Trace search** — in Grafana Explore → Tempo, use TraceQL:

```
{ span.bsi.ep = "checkout" }
{ span.bsi.cj = "MoneyTransfer" && resource.service.name = "processor" }
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

## Stop

```bash
./start.sh down          # stop the lab
./start.sh down all      # stop lab + tutorial Grafana + webpack
./start.sh down origin   # stop the origin scenario
```

To also remove the Tempo data volume:

```bash
docker compose -f labs/otel-ibmmq/docker-compose.yml \
               -f labs/otel-ibmmq/docker-compose.upstream.yml \
               down -v
```

## API Exit (optional)

`api-exit/` contains a reference implementation of an IBM MQ `ApiExitLocal` in C
that intercepts `MQPUT`/`MQGET` to inject/extract `traceparent` automatically —
useful for understanding how APM vendors instrument IBM MQ without touching
application code. See [ibmmq-qa.md](docs/ibmmq-qa.md) for context.

**Install into the running lab:**

```bash
./labs/otel-ibmmq/api-exit/install.sh
```

This compiles `otel_exit.so` inside the container, patches `qm.ini` with the
`ApiExitLocal` stanza, restarts the container, and re-applies `PROPCTL(ALL)`.
Changes persist in the Docker volume across restarts but are lost on `down -v`.

**Watch the exit output:**

```bash
docker logs -f <container-name> 2>&1 | grep otel-exit
```

**Remove when done:**

```bash
./labs/otel-ibmmq/api-exit/uninstall.sh
```

Strips the stanza from `qm.ini`, removes the `.so`, and restarts clean.

## Tests

```bash
# Verify all hard requirements pass (30 checks)
./labs/otel-ibmmq/tests/verify-hard-requirements.sh

# Break each requirement one at a time and confirm the expected failure
./labs/otel-ibmmq/tests/break-requirements.sh
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
| [ibmmq-tutorial.md](docs/ibmmq-tutorial.md) | Hands-on lab journal: commands run, errors hit, and what the output taught us |
| [ibmmq-qa.md](docs/ibmmq-qa.md) | Running Q&A log tagged #ibmmq and #o11y — reference books included |
| [baggage-ibmmq-checklist.md](docs/baggage-ibmmq-checklist.md) | Middle-of-chain SRE checklist: SDK setup, PROPCTL, extract/inject pattern, silent bugs |
| [ibmmq-propagation-healthcheck.md](docs/ibmmq-propagation-healthcheck.md) | Quick reference for infra and app teams to verify context propagation is working |
