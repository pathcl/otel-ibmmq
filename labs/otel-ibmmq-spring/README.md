# IBM MQ + OTel — Spring Boot 3 + Micrometer Tracing

Companion to `labs/otel-ibmmq` and `labs/otel-ibmmq-agent`. Same IBM MQ pipeline,
same infra — services use **Spring Boot 3 + Micrometer Tracing** instead of the
manual OTel SDK or javaagent.

## What changes vs the other labs

| | Manual SDK | Java Agent | Spring + Micrometer |
|---|---|---|---|
| SDK init | `OtelConfig.java` per service | `OTEL_*` env vars | `management.*` properties, fully autoconfigured |
| JMS inject/extract | `JmsCarrier` + explicit `propagator.inject/extract` | Agent intercepts bytecode | `JmsTemplate` / `@JmsListener` observed by Micrometer — no carrier code |
| Span creation | `tracer.spanBuilder(...)` | Agent auto-creates | Micrometer auto-creates per observation |
| Baggage → span attrs | `baggage.asMap().forEach(span::setAttribute)` | `OTEL_JAVA_EXPERIMENTAL_...` env var or custom SpanProcessor | `tracer.currentSpan().tag(key, value)` inside `@JmsListener` — span is live, no extension needed |
| Custom metrics | OTel SDK `Meter` | `GlobalOpenTelemetry.get().getMeter(...)` | `Counter.builder(...).register(meterRegistry).increment()` |
| Message loop | `consumer.receive()` poll | `MessageListener.onMessage()` | `@JmsListener` — Spring manages the container |
| OTLP port | 4317 (gRPC) | 4317 (gRPC) | 4318 (HTTP/protobuf) |

## Why no SpanProcessor?

The Java agent lab needed a SpanProcessor (or experimental env var) to copy baggage
→ span attributes because the agent auto-creates spans and application code cannot
reach them. In this lab, the Micrometer span is **live inside the `@JmsListener`
method body** — `tracer.currentSpan().tag(key, value)` sets the attribute directly.

## Run

```bash
cd labs/otel-ibmmq-spring

# Origin mode (gateway is the trace root)
docker compose up --build

# Middle-of-chain mode (upstream is the trace root)
docker compose -f docker-compose.yml -f docker-compose.upstream.yml up --build
```

Or via `start.sh` from the repo root:

```bash
./start.sh up spring           # origin scenario
./start.sh up spring middle    # middle-of-chain
./start.sh up spring origin    # origin (explicit)
```

Send traffic:

```bash
# Origin mode
curl -X POST http://localhost:8080/send \
  -H 'X-bsi-ep: checkout' -H 'X-bsi-ch: web' -H 'X-bsi-cj: MoneyTransfer'

# Middle-of-chain mode
curl -X POST http://localhost:8081/order \
  -H 'X-bsi-ep: checkout' -H 'X-bsi-ch: web' -H 'X-bsi-cj: MoneyTransfer'

# DLQ path
curl -X POST http://localhost:8080/send \
  -H 'X-bsi-ep: account' -H 'X-bsi-ch: web' -H 'X-bsi-cj: bad-cj'
```

Grafana: http://localhost:3001 | Tempo: http://localhost:3200 | Prometheus: http://localhost:9090

## How it works

### Context propagation (no carrier code)

Spring Boot 3 autoconfigures Micrometer with the OTel bridge when
`micrometer-tracing-bridge-otel` is on the classpath. Setting
`management.tracing.propagation.type: W3C` enables both
`W3CTraceContextPropagator` and `W3CBaggagePropagator`.

When `JmsTemplate.convertAndSend()` runs, Micrometer creates a PRODUCER
observation and injects `traceparent` + `baggage` into the JMS message as string
properties — the same MQRFH2 `<usr>` folder that the manual SDK lab uses, written
by Spring rather than by `JmsCarrier`.

When `@JmsListener.onMessage()` is called, Micrometer has already extracted the
context from the JMS message, created a CONSUMER observation, and made the span
and baggage current. `Baggage.current()` and `tracer.currentSpan()` are live.

### Baggage in the gateway

The gateway still needs application code to read `X-bsi-*` HTTP headers —
Micrometer knows nothing about this convention. `tracer.createBaggage(key).set(value)`
adds each header to the current observation's baggage scope before
`JmsTemplate.convertAndSend()` propagates it.

In the middle-of-chain scenario, upstream W3C Baggage is extracted from the
incoming HTTP request automatically by Spring MVC instrumentation. The gateway
supplements it with any `X-*` headers not already present (upstream wins).

### PROPCTL is still required

The OTel Collector for this lab accepts OTLP/HTTP on port 4318 (added alongside
the existing gRPC on 4317). IBM MQ `PROPCTL(ALL)` on all queues is still required —
`start.sh` applies it automatically after QM1 is ready.
