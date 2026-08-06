# Lab: OTel Baggage Propagation over IBM MQ/JMS

Demonstrates propagating business context (tenant ID, user ID) across an IBM MQ
async boundary using the OpenTelemetry SDK. Traces land in Tempo, metrics in
Prometheus — both visible in Grafana.

## Stack

| Component      | Image                                    |
|----------------|------------------------------------------|
| IBM MQ         | icr.io/ibm-messaging/mq:latest           |
| OTel Collector | otel/opentelemetry-collector-contrib     |
| Tempo          | grafana/tempo:latest                     |
| Prometheus     | prom/prometheus:latest                   |
| Grafana        | grafana/grafana:latest (port **3001**)   |
| gateway        | Java 21, built locally                   |
| processor      | Java 21, built locally                   |

## Start

```bash
cd labs/otel-ibmmq
docker-compose up --build
```

First run builds the Java images (Maven downloads ~300MB of deps). Subsequent starts
are fast. IBM MQ takes ~60 seconds to initialise — the Java services retry automatically.

## Send a message

```bash
curl -X POST http://localhost:8080/send \
  -H "X-Tenant-ID: acme" \
  -H "X-User-ID: user42"
```

Send a few messages with different tenant IDs:

```bash
for tenant in acme globex initech; do
  curl -s -X POST http://localhost:8080/send \
    -H "X-Tenant-ID: $tenant" \
    -H "X-User-ID: user1" | echo "$tenant: $(cat)"
done
```

## Observe

| URL                        | What you see                                      |
|----------------------------|---------------------------------------------------|
| http://localhost:3001      | Grafana — dashboard "OTel IBM MQ Baggage Lab"     |
| http://localhost:3001/explore | Tempo trace search — filter by `tenant.id`     |
| http://localhost:9090      | Prometheus — query `messages_processed_total`     |
| http://localhost:9443      | IBM MQ web console (admin / passw0rd)             |

In Grafana Explore → Tempo, use TraceQL:
```
{span["tenant.id"] = "acme"}
```

You will see a trace with two spans: `gateway.send` (PRODUCER) → `processor.handle`
(CONSUMER), both carrying `tenant.id=acme`.

## Documentation

Every design decision is explained in `docs/`:

| File | Topic |
|------|-------|
| [01-architecture.md](docs/01-architecture.md) | Component map and data flows |
| [02-sdk-vs-agent.md](docs/02-sdk-vs-agent.md) | Why manual SDK over Java agent |
| [03-jms-carrier.md](docs/03-jms-carrier.md) | TextMapSetter/Getter, IBM MQ constraints |
| [04-observability-stack.md](docs/04-observability-stack.md) | Tempo, Prometheus, Collector decisions |
| [05-baggage-design.md](docs/05-baggage-design.md) | What goes in baggage vs span attributes |

## Stop

```bash
docker-compose down
```

Add `-v` to also remove the Tempo data volume.
