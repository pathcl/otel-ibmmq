# 05 — Baggage Design

## What goes in baggage

Baggage is for **business context that must be available at every hop** without being
passed explicitly as a parameter. Good candidates:

| Key        | Why baggage                                         |
|------------|-----------------------------------------------------|
| `bsi.ep` | Every service needs it for isolation and filtering  |
| `bsi.ch`   | Useful for user-level debugging across services     |

## What does NOT belong in baggage

| Data            | Reason                                              |
|-----------------|-----------------------------------------------------|
| Secrets / tokens | Baggage travels in plaintext headers — never safe  |
| Large payloads  | JMS MQRFH2 and HTTP header size limits apply       |
| Mutable state   | Baggage propagates a snapshot; it's not a channel  |
| Request body    | Too large, and belongs in the payload not context  |

## Why not use span attributes for propagation

Span attributes are written to the telemetry backend (Tempo). They are NOT propagated
to downstream services. A span attribute set in the gateway is visible in Tempo on the
gateway span — but the processor has no way to read it without querying Tempo.

Baggage travels in the active context and crosses service boundaries. Span attributes
do not. This is why both are needed:

1. Set baggage at the entry point (gateway)
2. Let it propagate automatically to every downstream service
3. At each service, copy baggage values to span attributes so they land in Tempo

## OTel metric label naming

The OTel SDK uses `bsi.ep` (dot notation) as the attribute key:

```java
messagesProcessed.add(1, Attributes.builder()
    .put("bsi.ep", ep)
    .build()
);
```

The OTel collector's Prometheus exporter converts this to `bsi_ep` (underscore).
The Prometheus metric becomes `messages_processed_total{bsi_ep="checkout"}`.

The Grafana dashboard query uses `bsi_ep` (underscore) to match:

```promql
increase(messages_processed_total[$__rate_interval])
```

with legend `tenant={{ bsi_ep }}`.

## Future: additional dimensions

If you add `country` and `request.priority` to baggage (as discussed in
`caching-servicegraph.md`), follow the same pattern:

1. Set in baggage at the entry point
2. Copy to span attributes in each service that processes the message
3. For metrics, add as a label only if cardinality is manageable
   (`country` is fine, `endpoint` is not — see caching-servicegraph.md)
