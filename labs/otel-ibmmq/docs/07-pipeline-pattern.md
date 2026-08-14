# 07 — Message Pipeline Pattern

## What it is

A pipeline (also called Chain of Responsibility in EIP) routes every message through an
ordered sequence of services before final processing. Each stage has a single responsibility
and hands off to the next via a dedicated IBM MQ queue.

In large enterprises this models real workflows: a payment arriving at a bank goes through
fraud screening, currency conversion, account validation, and posting before being settled.

## Our pipeline

```
HTTP request
    │
    ▼
gateway         SERVICE_NAME=gateway
    │  PRODUCER → DEV.QUEUE.1
    ▼
validator       SERVICE_NAME=validator
    │  CONSUMER ← DEV.QUEUE.1
    │  checks bsi.ep is present and not in blocklist
    ├── valid   → PRODUCER → DEV.QUEUE.2
    └── invalid → PRODUCER → DEV.DEAD.LETTER.QUEUE  (see 08-dlq-pattern.md)
    ▼
enricher        SERVICE_NAME=enricher
    │  CONSUMER ← DEV.QUEUE.2
    │  looks up entry-point region, generates processing_id
    │  PRODUCER → DEV.QUEUE.3
    ▼
processor       SERVICE_NAME=processor  (two instances — see 09-competing-consumers.md)
       CONSUMER ← DEV.QUEUE.3
```

IBM MQ's built-in `DEV.QUEUE.1`, `DEV.QUEUE.2`, `DEV.QUEUE.3` queues are used with
no additional MQ configuration.

## How OTel context flows through the pipeline

Each intermediate service acts as both CONSUMER and PRODUCER in the same trace:

```
gateway PRODUCER span
    └─ validator CONSUMER span  (parent = gateway PRODUCER)
           └─ validator PRODUCER span
                  └─ enricher CONSUMER span  (parent = validator PRODUCER)
                         └─ enricher PRODUCER span
                                └─ processor CONSUMER span  (parent = enricher PRODUCER)
```

The key in each intermediate service:

```java
// 1. Extract incoming context (traceparent + baggage) from the JMS message.
Context extractedCtx = otel.getPropagators().getTextMapPropagator()
    .extract(Context.root(), message, JmsCarrier.GETTER);

// 2. Create CONSUMER span as child of the extracted context.
Span consumerSpan = tracer.spanBuilder("validator.handle")
    .setSpanKind(SpanKind.CONSUMER)
    .setParent(extractedCtx)
    .startSpan();

try (Scope s = extractedCtx.with(consumerSpan).makeCurrent()) {
    // 3. Inside the consumer scope, create a PRODUCER span for the outgoing message.
    //    Its parent is the consumer span (current context).
    Span producerSpan = tracer.spanBuilder("validator.forward")
        .setSpanKind(SpanKind.PRODUCER)
        .startSpan();

    try (Scope ps = Context.current().with(producerSpan).makeCurrent()) {
        // 4. Inject the producer span's context into the outgoing JMS message.
        otel.getPropagators().getTextMapPropagator()
            .inject(Context.current(), outMessage, JmsCarrier.SETTER);
        producer.send(outMessage);
    } finally {
        producerSpan.end();
    }
}
```

`Context.root()` on extraction prevents thread-local context leakage between
messages processed sequentially in the receive loop.

## Why Tempo sees each hop as a separate edge

Tempo's `service-graphs` processor pairs spans by:
- Matching a PRODUCER span with a CONSUMER span in the same trace
- Using `service.name` from the span resource to label the edge

Because each queue hop is a new PRODUCER→CONSUMER pairing in a different service,
Tempo generates one edge per hop:

| Edge | PRODUCER service | CONSUMER service |
|------|-----------------|-----------------|
| 1 | gateway | validator |
| 2 | validator | enricher |
| 3 | enricher | processor |

## Enricher adds span attributes visible in Tempo

```java
consumerSpan.setAttribute("enriched.region", region);         // eu-west-1, us-east-1, ...
consumerSpan.setAttribute("enriched.processing_id", id);      // 8-char UUID prefix
```

Open any trace in Tempo → expand the `enricher.handle` span → these appear under
"Span Attributes". The enriched data also travels in the message body to the processor.

## Sending traffic

```bash
# Valid pipeline messages (middle scenario — upstream at :8081)
for ep in checkout payment account; do
  curl -X POST http://localhost:8081/order \
    -H "X-bsi-ep: $ep" -H "X-bsi-ch: web" -H "X-bsi-cj: MoneyTransfer"
done
```

## Verifying each stage

```bash
docker compose -f labs/otel-ibmmq/docker-compose.yml logs validator  | grep -E "Validated|rejected"
docker compose -f labs/otel-ibmmq/docker-compose.yml logs enricher   | grep "Enriched"
docker compose -f labs/otel-ibmmq/docker-compose.yml logs processor  | grep "Processed"
```
