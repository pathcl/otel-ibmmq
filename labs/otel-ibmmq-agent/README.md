# IBM MQ + OTel — Java Agent scenario

Companion to `labs/otel-ibmmq`. Same pipeline, same IBM MQ infrastructure,
same Grafana dashboards — but the Java services use the **OTel Java agent**
for tracing instead of manual SDK code.

## What changes vs the manual-SDK lab

| | Manual SDK (`labs/otel-ibmmq`) | Agent (`labs/otel-ibmmq-agent`) |
|---|---|---|
| SDK init | `OtelConfig.java` in every service | `OTEL_*` env vars, agent handles it |
| JMS inject/extract | `JmsCarrier` + explicit `propagator.inject()`/`extract()` | Agent intercepts `MessageProducer.send()` and `MessageListener.onMessage()` |
| Span creation | Explicit `tracer.spanBuilder(...)` per service | Auto-created by agent |
| Baggage → span attrs | `baggage.asMap().forEach(span::setAttribute)` | `OTEL_JAVA_EXPERIMENTAL_SPAN_ATTRIBUTES_COPY_FROM_BAGGAGE_INCLUDE` (or custom SpanProcessor) |
| Custom metrics | SDK `Meter` with `OtelConfig` | `GlobalOpenTelemetry.get().getMeter(...)` — safe because agent pre-registers before `main()` |
| Message loop | `consumer.receive()` poll loop | `MessageListener.onMessage()` — required for the agent to propagate context into the callback |

## What the agent does NOT change

- IBM MQ infra: `PROPCTL(ALL)` still required on all queues
- Gateway still needs application code to read `X-bsi-*` HTTP headers and build W3C Baggage
  (the agent knows nothing about your `X-bsi-*` header convention)
- Validator still needs `Baggage.current().getEntryValue("bsi.cj")` for the BLOCKED_CJS check
- `messages_processed_total{bsi_ep}` and `messages_rejected_total{bsi_ep,dlq_reason}` still
  require explicit SDK metric code — the agent doesn't auto-create business metrics

## Run

```bash
cd labs/otel-ibmmq-agent

# Origin mode (gateway is the trace root)
docker compose up --build

# Middle-of-chain mode (upstream is the trace root)
docker compose -f docker-compose.yml -f docker-compose.upstream.yml up --build
```

First build downloads the OTel Java agent jar (~60 MB) once; Docker caches it.

Send traffic:
```bash
# Origin mode
curl -X POST http://localhost:8080/send \
  -H 'X-bsi-ep: checkout' -H 'X-bsi-ch: web' -H 'X-bsi-cj: MoneyTransfer'

# Middle-of-chain mode
curl -X POST http://localhost:8081/order \
  -H 'X-bsi-ep: checkout' -H 'X-bsi-ch: web' -H 'X-bsi-cj: MoneyTransfer'

# DLQ path (bsi.cj in blocklist)
curl -X POST http://localhost:8080/send \
  -H 'X-bsi-ep: account' -H 'X-bsi-ch: web' -H 'X-bsi-cj: bad-cj'
```

Grafana: http://localhost:3001 | Tempo: http://localhost:3200 | Prometheus: http://localhost:9090

## Trace shape

### Origin mode (gateway as root)

```
gateway → DEV.QUEUE.1 → validator → DEV.QUEUE.2 → enricher → DEV.QUEUE.3 → processor
```

The agent creates spans named after the JMS operation + queue, e.g.:
- `DEV.QUEUE.1 publish` (PRODUCER, gateway)
- `DEV.QUEUE.1 receive` (CONSUMER, validator)
- `DEV.QUEUE.2 publish` (PRODUCER, validator forward)
- …

Span names follow the OTel JMS semantic conventions (`{queue} {operation}`),
not the custom names used in the manual SDK lab (`gateway.send`, `validator.handle`).

### Middle-of-chain mode

```
upstream.order (root, Go SDK)
  └── gateway → MQ → validator → enricher → processor
```

The upstream service uses the manual Go SDK (unchanged). Its `traceparent` header
arrives at the gateway, which stores it in the JMS scope. The agent then injects it
into the message, linking the entire chain.

## Baggage → span attributes

W3C Baggage (`bsi.ep`, `bsi.ch`, `bsi.cj`) propagates through IBM MQ automatically
via the agent. To promote baggage entries to span attributes (needed for Tempo dimensions
and the service graph `bsi_ep` label), two approaches are available.

### Approach 1: experimental env var (default)

Set in `docker-compose.yml` for each service:
```yaml
OTEL_JAVA_EXPERIMENTAL_SPAN_ATTRIBUTES_COPY_FROM_BAGGAGE_INCLUDE: bsi.ep,bsi.ch,bsi.cj
```

Copies the listed baggage keys to span attributes on every span start.
Marked experimental — has been stable since agent 1.28 but may be renamed in future.

### Approach 2: custom SpanProcessor extension (stable)

A tiny extension jar in `baggage-processor/` achieves the same result using stable APIs:

1. **Build the extension:**
   ```bash
   cd baggage-processor
   mvn package -DskipTests
   ```

2. **Add to each service Dockerfile** (after the `COPY --from=build` lines):
   ```dockerfile
   COPY baggage-processor/target/baggage-processor-1.0.jar baggage-extension.jar
   ```

3. **Change `JAVA_TOOL_OPTIONS`** in `docker-compose.yml`:
   ```yaml
   JAVA_TOOL_OPTIONS: -javaagent:/app/otel-agent.jar -Dotel.javaagent.extensions=/app/baggage-extension.jar
   ```

4. **Remove** `OTEL_JAVA_EXPERIMENTAL_SPAN_ATTRIBUTES_COPY_FROM_BAGGAGE_INCLUDE` from each service env.

Running both approaches simultaneously is safe — `setAttribute` is idempotent.

## How the agent handles JMS

The JMS instrumentation works through bytecode injection at JVM startup:

```
MessageProducer.send(message)
  → agent intercepts before send
  → reads Context.current() (includes traceparent + baggage)
  → injects into message as JMS string properties → MQRFH2 <usr> folder
  → original send() completes

MessageListener.onMessage(message)
  → agent intercepts before callback
  → extracts traceparent + baggage from message properties
  → creates CONSUMER span as child of extracted traceparent
  → makes context (span + baggage) current
  → calls onMessage() — Baggage.current() and Span.current() are live here
  → ends span when onMessage() returns
```

This is why services use `MessageListener` and not a `consumer.receive()` poll loop:
the agent propagates context into `onMessage()` callbacks; after a synchronous `receive()`
returns, the extracted context scope has already been closed.

## PROPCTL is still required

The agent handles inject/extract but cannot prevent IBM MQ from stripping MQRFH2.
`PROPCTL(ALL)` must still be set on every queue in the pipeline, including the DLQ.

The IBM MQ Docker Developer image (`icr.io/ibm-messaging/mq:9.4.5.0-r1`) sets
`PROPCTL(ALL)` automatically on the `DEV.*` queues. No manual MQSC needed for this lab.
