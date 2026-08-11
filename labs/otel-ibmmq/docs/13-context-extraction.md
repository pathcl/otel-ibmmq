# How gateway.send extracts traceparent and baggage

This document walks through the three-step flow that links a `gateway.send` span
to the `upstream.order` span created by the Go service.

## The goal

When the upstream Go service calls `http://gateway:8080/send`, it attaches two
W3C headers to the HTTP request. Gateway must read those headers, restore the
OTel context they encode, and then:

1. Start `gateway.send` as a **child** of `upstream.order` (trace continuity).
2. Forward the original **baggage** (`bsi.ep`, `bsi.ch`) into IBM MQ
   without overwriting it.

---

## Step 1 — Upstream injects W3C headers

In `upstream/main.go`, after building the baggage and starting the root span,
the composite propagator serialises the context into outgoing HTTP headers:

```go
otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
```

`propagation.HeaderCarrier` is a thin wrapper that implements `TextMapCarrier`
over a `http.Header` map. The SDK writes two headers:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
baggage:     bsi.ep=acme,bsi.ch=user42
```

Those headers arrive verbatim on the gateway's `HttpExchange`.

---

## Step 2 — Gateway extracts the context

`Gateway.java` lines 45-55 use the OTel propagator in reverse — **extract**
instead of inject:

```java
Context parentCtx = otel.getPropagators().getTextMapPropagator()
    .extract(Context.current(), exchange, new TextMapGetter<HttpExchange>() {
        @Override
        public Iterable<String> keys(HttpExchange carrier) {
            return carrier.getRequestHeaders().keySet();
        }
        @Override
        public String get(HttpExchange carrier, String key) {
            return carrier.getRequestHeaders().getFirst(key);
        }
    });
```

The anonymous `TextMapGetter` is the only gateway-specific glue. Its two methods
tell the SDK how to read a header by name from a `HttpExchange`. The SDK does
the W3C parsing internally and returns a `Context` that contains:

| What | Where it comes from |
|------|---------------------|
| Parent span (trace-id + span-id) | `traceparent` header |
| Baggage entries | `baggage` header |

After this call `parentCtx` holds both, fully decoded.

---

## Step 3 — Use the extracted context

**Read baggage** (lines 59-69) — prefer upstream values; fall back to explicit
headers when gateway is the entry point (origin scenario):

```java
Baggage upstreamBaggage = Baggage.fromContext(parentCtx);
String ep = upstreamBaggage.getEntryValue("bsi.ep");
String ch   = upstreamBaggage.getEntryValue("bsi.ch");

if (ep == null || ep.isBlank()) {
    ep = exchange.getRequestHeaders().getFirst("X-bsi-ep");
}
```

**Decide which context to carry forward** (lines 82-90):

```java
Context ctx;
if (upstreamBaggage.getEntryValue("bsi.ep") != null) {
    ctx = parentCtx;               // middle: forward upstream baggage unchanged
} else {
    ctx = Baggage.builder()
        .put("bsi.ep", ep)
        .put("bsi.ch", ch)
        .build()
        .storeInContext(parentCtx); // origin: create fresh baggage from headers
}
```

**Start the child span** (lines 92-95):

```java
Span span = tracer.spanBuilder("gateway.send")
    .setSpanKind(SpanKind.PRODUCER)
    .setParent(ctx)   // ← links gateway.send to upstream.order
    .startSpan();
```

Because `ctx` carries the parent span from `parentCtx`, Tempo will render
`gateway.send` as a child of `upstream.order` in the same trace.

**Inject into JMS** (lines 107-109):

```java
otel.getPropagators().getTextMapPropagator()
    .inject(Context.current(), message, JmsCarrier.SETTER);
```

`Context.current()` now includes the active `gateway.send` span, so
`traceparent` in the JMS message points to `gateway.send`. The baggage
(`bsi.ep`, `bsi.ch`) is forwarded unchanged, making it available to
validator, enricher, and processor.

---

## End-to-end picture

```
upstream/main.go
  otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
      │
      │  HTTP headers
      │    traceparent: 00-<trace-id>-<upstream-span-id>-01
      │    baggage:     bsi.ep=acme,bsi.ch=user42
      ▼
Gateway.java handle()
  TextMapGetter reads HttpExchange headers
  .extract() → parentCtx
      ├─ parent span  = upstream.order
      └─ baggage      = {bsi.ep=acme, bsi.ch=user42}
                │
                ▼  .setParent(ctx)
          gateway.send  (child of upstream.order, same trace-id)
                │
                ▼  JmsCarrier.SETTER
          JMS message properties
              traceparent → gateway.send span
              baggage     → bsi.ep=acme,bsi.ch=user42
                │
                ▼
  validator → enricher → processor  (same trace, same baggage)
```

---

## Why TextMapGetter is needed

The OTel SDK is transport-agnostic: it does not know what an `HttpExchange` is.
`TextMapGetter` is the adapter that maps the SDK's generic "read header by key"
contract onto the concrete Java HTTP server type. The same pattern applies to
any carrier — JMS properties, Kafka headers, gRPC metadata — with a matching
getter/setter pair.

See [03-jms-carrier.md](03-jms-carrier.md) for how `JmsCarrier` does the same
for IBM MQ message properties.
