# 08 — Dead Letter Queue Pattern

## What it is

A Dead Letter Queue (DLQ) is a holding queue for messages that cannot be processed
successfully. Every production IBM MQ deployment has one — it is the single most
important operational safety net in enterprise messaging.

Without a DLQ, a poison message (bad format, missing field, unknown tenant) would
either cause the consumer to crash in a loop or be silently dropped. The DLQ makes
the failure explicit and inspectable.

## Our DLQ setup

```
validator
    │  message fails validation (tenant.id missing or in blocklist)
    │  PRODUCER → DEV.DEAD.LETTER.QUEUE  (IBM MQ Docker default queue)
    ▼
dlq-handler     SERVICE_NAME=dlq-handler
    │  CONSUMER ← DEV.DEAD.LETTER.QUEUE
    │  records rejection counter by tenant + reason
    │  marks span as ERROR (lights up arc__error in node graph)
    └── in production: retry, escalate, or persist for audit
```

`DEV.DEAD.LETTER.QUEUE` is created automatically by the IBM MQ Developer Docker image.
No additional MQ configuration is needed.

## How to trigger it

```bash
# "bad-tenant" is in the validator's BLOCKED_TENANTS set
curl -X POST http://localhost:8080/send \
  -H "X-Tenant-ID: bad-tenant" -H "X-User-ID: tester"

# Missing tenant.id also routes to DLQ (but gateway currently requires the header —
# remove the 400 check in Gateway.java to test this path end-to-end)
```

## OTel instrumentation in the validator reject path

The validator creates two spans for a rejected message: the CONSUMER span that
received it and a PRODUCER span that sends it to the DLQ. Both are marked ERROR.

```java
// In Validator.reject():
consumerSpan.setStatus(StatusCode.ERROR, reason);   // "tenant blocked: bad-tenant"

Span producerSpan = tracer.spanBuilder("validator.reject")
    .setSpanKind(SpanKind.PRODUCER)
    .startSpan();
producerSpan.setStatus(StatusCode.ERROR, reason);

// Attach the rejection reason as a JMS property so the DLQ handler can read it
// without needing to re-extract baggage (baggage may not carry the reason).
out.setStringProperty("dlq_reason", reason);
```

The DLQ handler then:

```java
// In DlqHandler.handle():
String reason = message.getStringProperty("dlq_reason");
span.setStatus(StatusCode.ERROR, reason);
span.recordException(new RuntimeException("DLQ: " + reason));  // appears in Tempo trace

rejectedCounter.add(1, Attributes.builder()
    .put("tenant.id",  tenantId)
    .put("dlq.reason", reason)
    .build());
```

## What this looks like in Tempo

A rejected trace has:
1. `gateway.send` span (PRODUCER, OK)
2. `validator.handle` span (CONSUMER, **ERROR** — "tenant blocked: bad-tenant")
3. `validator.reject` span (PRODUCER, **ERROR**)
4. `dlq-handler.handle` span (CONSUMER, **ERROR** + recorded exception)

The error propagates as a recorded exception in the `dlq-handler.handle` span,
visible under "Events" in Tempo's trace view.

## Metrics

`dlq-handler` emits `messages.rejected_total` with labels `tenant.id` and `dlq.reason`.
Query in Prometheus:

```promql
sum by (tenant_id, dlq_reason) (increase(messages_rejected_total[1h]))
```

## What a production DLQ handler does

In the lab, messages are logged and discarded. In production the handler typically does
one of three things depending on the failure reason:

| Reason | Action |
|--------|--------|
| Transient (MQ unavailable, timeout) | Retry with exponential backoff → DEV.QUEUE.1 |
| Business rule violation (unknown tenant) | Escalate to manual review queue |
| Poison message (unparseable format) | Persist to database for audit, alert ops team |

The key invariant: **messages never disappear silently**. Every rejection is traced,
counted, and stored somewhere inspectable.
