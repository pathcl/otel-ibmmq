# Baggage & Context Propagation — IBM MQ Middle-of-Chain Checklist

Scenario: your team owns a service that receives from one IBM MQ queue and
forwards to another. You did not write the upstream producer or the downstream
consumer. Traces and business context (`tenant.id`, `user.id`) must flow
through your service without being silently dropped.

## How it works

Two separate things travel over IBM MQ:

```
traceparent: 00-<traceId-128bit>-<parentSpanId-64bit>-01
baggage:     tenant.id=acme,user.id=user42
```

They are **separate propagators** and must both be registered. IBM MQ has no
HTTP headers — context travels as JMS message properties stored in the MQRFH2
`<usr>` folder. A carrier adapter (`JmsCarrier`) maps between OTel's TextMap
API and `message.setStringProperty` / `message.getStringProperty`.

The correct middle-of-chain pattern is always: **extract → consumer span →
scope → producer span → inject → send**.

```java
// 1. Extract — always from Context.root(), never Context.current()
Context extractedCtx = otel.getPropagators().getTextMapPropagator()
    .extract(Context.root(), message, JmsCarrier.GETTER);

// 2. Consumer span linked to upstream
Span consumerSpan = tracer.spanBuilder("your-service.handle")
    .setSpanKind(SpanKind.CONSUMER)
    .setParent(extractedCtx)
    .startSpan();

try (Scope ignored = extractedCtx.with(consumerSpan).makeCurrent()) {

    // 3. Read baggage — it lives in the context, not in the span
    Baggage baggage = Baggage.fromContext(extractedCtx);
    String tenantId = baggage.getEntryValue("tenant.id");

    // 4. Copy to span attributes explicitly (baggage ≠ span attributes)
    if (tenantId != null) consumerSpan.setAttribute("tenant.id", tenantId);

    // 5. Forward: producer span + inject while scope is active
    Span producerSpan = tracer.spanBuilder("your-service.forward")
        .setSpanKind(SpanKind.PRODUCER)
        .startSpan();

    try (Scope s2 = Context.current().with(producerSpan).makeCurrent()) {
        TextMessage out = session.createTextMessage(payload);
        otel.getPropagators().getTextMapPropagator()
            .inject(Context.current(), out, JmsCarrier.SETTER);
        producer.send(out);
    } finally {
        producerSpan.end();
    }

} finally {
    consumerSpan.end();
}
```

---

## Checklist

### 1. SDK setup

- [ ] `W3CBaggagePropagator` is in the composite propagator alongside
      `W3CTraceContextPropagator`
- [ ] Both are registered on `OpenTelemetrySdk` via `setPropagators()`
- [ ] The same `OpenTelemetry` instance is used for extract and inject

```java
.setPropagators(ContextPropagators.create(
    TextMapPropagator.composite(
        W3CTraceContextPropagator.getInstance(),
        W3CBaggagePropagator.getInstance()   // ← easy to forget
    )
))
```

Missing `W3CBaggagePropagator` is the most common silent bug: traces link
correctly but `baggage.getEntryValue("tenant.id")` returns `null` everywhere.

---

### 2. IBM MQ infrastructure (requires MQ admin)

> **IBM MQ tracing is not a prerequisite.** IBM MQ's built-in activity tracing
> (`strmqtrc`, `MQIACT`) records internal queue manager events in IBM-proprietary
> format and is unrelated to OTel. The queue manager never reads, writes, or
> interprets `traceparent` or `baggage` — it stores them as opaque string
> properties in MQRFH2 and delivers them unchanged. You do not need IBM MQ
> tracing enabled for OTel context propagation to work. The only IBM MQ
> configuration that matters is `PROPCTL`.

- [ ] `PROPCTL(ALL)` on your **input queue** — without it, upstream properties
      are stripped before your service receives the message
- [ ] `PROPCTL(ALL)` on your **output queue** — without it, your injected
      properties are stripped before delivery to the next consumer
- [ ] `PROPCTL(ALL)` on any **channel** between queue managers in the path
- [ ] Message format is **not** `MQFMT_STRING` — that format discards the
      MQRFH2 header where properties are stored

Verify with the MQ admin console or `runmqsc`:

```
DISPLAY QLOCAL(YOUR.QUEUE.NAME) PROPCTL
```

Must return `PROPCTL(ALL)`, not `NONE` or `COMPAT`.

Dump a raw message to confirm properties survive the hop:

```bash
amqsbcg YOUR.QUEUE.NAME QM1
```

Look for `traceparent` and `baggage` entries in the MQRFH2 `<usr>` folder.

---

### 3. Extract

- [ ] Base context is `Context.root()`, **not** `Context.current()`
      (`Context.current()` inherits whatever the listener thread happens to
      hold — that is not the upstream trace)
- [ ] The getter sanitizes property names the same way the setter did:
      `traceparent` → `traceparent`, `baggage` → `baggage` (W3C header names
      contain no hyphens or dots so they pass through unchanged)
- [ ] Confirm extraction worked before continuing:
      `Baggage.fromContext(extractedCtx).getEntryValue("tenant.id") != null`

---

### 4. Span creation and scope

- [ ] Consumer span uses `.setParent(extractedCtx)` — this links your span to
      the upstream producer span
- [ ] Scope is opened with `extractedCtx.with(consumerSpan).makeCurrent()`,
      **not** `consumerSpan.makeCurrent()` alone — the latter drops the baggage
      from `Context.current()`
- [ ] Baggage values are copied to span attributes explicitly:

```java
span.setAttribute("tenant.id", baggage.getEntryValue("tenant.id"));
```

Baggage travels in the `Context` object. It does **not** automatically appear
as span attributes — if you skip this step the span is invisible in Tempo
queries that filter by `tenant.id`.

- [ ] Do not construct a `Baggage.builder()` from scratch unless you are
      adding new entries — building fresh loses all upstream values. Instead:

```java
// Adding your team's entry while preserving upstream values
Baggage forwarded = Baggage.fromContext(extractedCtx).toBuilder()
    .put("your.team.key", "value")
    .build();
Context ctx = forwarded.storeInContext(extractedCtx.with(consumerSpan));
```

---

### 5. Inject

- [ ] `inject()` is called while a `Scope` is active that contains both the
      producer span and the upstream baggage
- [ ] `Context.current()` at inject time must hold the baggage — if you only
      called `producerSpan.makeCurrent()` without the extracted context, the
      baggage header is missing from the outbound message
- [ ] The outbound `Message` is a **new** object created with
      `session.createTextMessage(...)` — JMS properties on a received message
      may be read-only; reusing it causes a `JMSException` or silently drops
      the properties

---

### 6. Filtering baggage entries (if required)

If your team is only supposed to forward certain attributes and strip others:

```java
Baggage filtered = Baggage.builder()
    .put("tenant.id", baggage.getEntryValue("tenant.id"))  // keep
    .put("user.id",   baggage.getEntryValue("user.id"))    // keep
    // internal.key intentionally omitted — not forwarded downstream
    .build();
Context ctx = filtered.storeInContext(extractedCtx.with(consumerSpan));
```

Keep total baggage size under 8 KB. IBM MQ's MQRFH2 `<usr>` folder has no
hard limit but large headers add per-message overhead.

---

### 7. Verification without environment access

Ask the upstream team to run `amqsbcg` on the queue and share the MQRFH2
dump. Look for:

```
<usr>
  <traceparent>00-aabbcc...ff-0011223344556677-01</traceparent>
  <baggage>tenant.id=acme,user.id=user42</baggage>
</usr>
```

If `traceparent` is present but `baggage` is absent: `PROPCTL` is fine but
the upstream producer is missing `W3CBaggagePropagator` in its SDK config.

In Tempo, query by tenant to verify end-to-end:

```
{span["tenant.id"] = "acme"}
```

- Consumer span appears, linked to upstream → extract + parent linking correct
- Consumer span appears but **not linked** → traceparent extraction failed
  (check PROPCTL, check getter sanitize logic)
- Consumer span linked but downstream spans have no `tenant.id` → inject is
  missing or running outside active scope
- Nothing appears → PROPCTL strips all properties; confirm with `amqsbcg`

---

### 8. Silent bugs ranked by frequency

| Bug | Symptom in Tempo |
|-----|-----------------|
| Missing `W3CBaggagePropagator` | Traces link correctly; all `tenant.id` span attributes null |
| `PROPCTL(NONE)` on queue | Orphan traces — no `traceparent` extracted; new trace-id starts at your service |
| `Context.current()` used in extract | Span linked to receive-loop thread, not upstream producer |
| `inject()` called after `span.end()` | `traceparent` forwarded; `baggage` header absent |
| `producerSpan.makeCurrent()` without extracted context | `traceparent` forwarded; baggage dropped silently |
| Received message reused for forwarding | `JMSException` or properties silently absent on outbound message |
| `Baggage.builder()` from scratch | Your entries present downstream; all upstream entries lost |
| `PROPCTL(ALL)` on queue but not on channel | Works on single-QM; breaks when message crosses to remote QM |

---

## Hard requirements

The minimum conditions without which propagation does not work, regardless of
language, agent, or framework. Every item in this list is a blocker.

### IBM MQ infrastructure (owned by MQ admin)

**1. `PROPCTL(ALL)` on every queue in the path**

Every queue a message touches — input, output, DLQ — must have `PROPCTL(ALL)`.
One queue with `COMPAT` or `NONE` silently breaks the chain at that point.
There is no application-level workaround.

**2. `PROPCTL(ALL)` on every channel between queue managers**

If messages cross a queue manager boundary, the channel must also have
`PROPCTL(ALL)`. Setting it on queues only is not sufficient for multi-QM
deployments.

**3. Message format must not be `MQFMT_STRING`**

`MQFMT_STRING` tells IBM MQ to discard the MQRFH2 header — the structure
where all message properties live. If any producer or IBM MQ itself sets the
message format to `MQFMT_STRING`, `traceparent` and `baggage` are destroyed
before they reach the consumer. No other configuration can recover them.

### Application code (owned by your team)

**4. Both W3C propagators registered**

```java
TextMapPropagator.composite(
    W3CTraceContextPropagator.getInstance(),  // traceparent
    W3CBaggagePropagator.getInstance()        // baggage
)
```

Missing either one breaks that dimension completely. Missing the baggage
propagator is the most common silent failure — traces link correctly but all
baggage values are null everywhere downstream.

**5. A carrier adapter wired to JMS message properties**

Something must map OTel's `get(carrier, key)` / `set(carrier, key, value)` to
`message.getStringProperty()` / `message.setStringProperty()`. Without this,
`inject()` and `extract()` have no way to read from or write to the JMS
message. This is `JmsCarrier` in this lab; the Java agent provides its own
internally.

**6. `inject()` called on the outbound message before `send()`**

The producer must call `inject()` on every outbound message while a scope
containing both the active span and the baggage is current. One missed
`inject()` anywhere in the chain breaks propagation for every downstream
service.

**7. `extract()` called on every received message**

The consumer must call `extract()` on every received message before creating
spans. Without extraction there is no upstream context to link to — the
consumer starts an orphan trace regardless of what the producer injected.

**8. Consumer span created with `.setParent(extractedCtx)`**

Extraction alone is not enough. The span must explicitly use the extracted
context as its parent, otherwise the trace link is never formed even though
the context was correctly extracted.

### What is NOT a hard requirement

| Thing | Why it is optional |
|-------|--------------------|
| IBM MQ activity tracing | Queue manager internal tracing; unrelated to OTel properties |
| OTel Java agent | Manual SDK achieves the same result |
| Instana agent | Agent writes the same JMS properties; PROPCTL still required |
| OTel Collector | Required for exporting spans, not for propagation itself |
| Same language across services | W3C headers are plain strings; any language can read them |
| Same OTel SDK version across services | Wire format is standardised; versions are interoperable |

---

## Q&A

Questions that came up during implementation. Added as they arise.

---

### What is a carrier adapter?

A **carrier** is whatever object holds the key-value pairs being propagated —
an HTTP request, a JMS message, a Kafka record header. They all have the same
shape: a bag of string keys and string values.

The OTel SDK doesn't know anything about HTTP, JMS, or Kafka. It only knows
how to call two operations:

```
get(carrier, key)   → string
set(carrier, key, value)
```

A **carrier adapter** is the glue code that teaches the SDK how to do those
two operations on a specific transport. In this lab that's `JmsCarrier`:

```java
// Adapter for inject — OTel calls this to write a header
public static final TextMapSetter<Message> SETTER = (message, key, value) -> {
    message.setStringProperty(sanitize(key), value);
};

// Adapter for extract — OTel calls this to read a header
public static final TextMapGetter<Message> GETTER = new TextMapGetter<>() {
    public String get(Message message, String key) {
        return message.getStringProperty(sanitize(key));
    }
};
```

For HTTP the adapter is built into the SDK. For IBM MQ over JMS there is no
built-in one — `JmsCarrier` is the piece your team writes once and reuses
across every service in the pipeline.

---

### Why did we write JmsCarrier manually? Doesn't the Java agent cover this?

The Java agent does cover it. It auto-instruments `MessageProducer.send()` and
`MessageConsumer.receive()` via bytecode manipulation, and propagates both
`traceparent` and `baggage` with one flag:

```
-Dotel.propagators=tracecontext,baggage
```

No `JmsCarrier`, no `inject()`, no `extract()` calls needed in application
code. This lab chose the manual SDK path for three reasons:

**1. Learning value** — the agent makes propagation invisible. Writing
`JmsCarrier` explicitly shows the mechanism: the SDK calls `get`/`set` on an
abstract carrier; your adapter translates those to JMS-specific calls. Once
understood for JMS, the same pattern applies to Kafka record headers, AMQP
message properties, and gRPC metadata.

**2. `Context.root()` control** — in a long-running JMS listener thread,
`Context.current()` is not clean — it holds whatever the thread was doing
before. The agent uses its own strategy for this. The SDK lets you be explicit:

```java
// guaranteed clean base — not whatever the listener thread holds
Context extracted = propagator.extract(Context.root(), message, JmsCarrier.GETTER);
```

**3. Custom tenant-dimensioned metrics** — the agent creates messaging metrics
with fixed attribute names. Getting `messages.processed{tenant.id="acme"}` in
a shape that maps directly to a Grafana variable requires SDK:

```java
messagesProcessed.add(1, Attributes.builder()
    .put("tenant.id", tenantId)
    .build());
```

The agent and SDK are not mutually exclusive. A common production pattern:
attach the agent for automatic tracing of all JMS/HTTP traffic; add SDK calls
only for custom spans and tenant-dimensioned metrics.

`OTEL_JAVA_EXPERIMENTAL_SPAN_ATTRIBUTES_COPY_FROM_BAGGAGE_INCLUDE` is a Java
agent flag that automates the manual `span.setAttribute("tenant.id", ...)` step:

```bash
OTEL_JAVA_EXPERIMENTAL_SPAN_ATTRIBUTES_COPY_FROM_BAGGAGE_INCLUDE=tenant.id,user.id
```

With the agent and that flag, every span gets those attributes automatically as
long as the baggage keys are present in the context. It copies to all spans
indiscriminately (HTTP spans, DB spans, internal spans) — the manual SDK
approach lets you control which spans carry which attributes.

---

### Does the IBM MQ usage pattern affect how propagation is implemented?

Yes. The OTel API (`extract`, `inject`, span kind) stays the same. What
changes is how many upstream traces exist, how many outbound messages you
produce, and whether `inject` even makes sense.

| Pattern | Upstream traces | Key requirement |
|---------|----------------|-----------------|
| Point-to-point | 1 | Standard extract → inject |
| Pipeline (middle-of-chain) | 1 | `CONSUMER` + `PRODUCER` span pair per service |
| Pub/Sub (topics) | 1 | Nothing special; subscribers become siblings naturally |
| Competing consumers | 1 | Nothing special; only one instance processes each message |
| Request-Reply | 1 | Inject into the reply message too; use `CLIENT`/`SERVER` span kinds |
| Fan-in / Aggregation | N | Span links instead of a single parent; decide baggage merge strategy |
| Dead Letter Queue | 1 | Preserve `traceparent` in the rejected message; mark span ERROR |

**Fan-in** is the hardest case. When multiple upstream messages (each with a
different `trace-id`) are aggregated into one outbound message, forwarding one
`traceparent` silently orphans the others. Use span links:

```java
SpanBuilder builder = tracer.spanBuilder("aggregator.flush")
    .setSpanKind(SpanKind.INTERNAL)
    .setNoParent();

for (Context ctx : upstreamContexts) {
    builder.addLink(Span.fromContext(ctx).getSpanContext());
}
```

Baggage is also ambiguous in fan-in — if upstream-a has `tenant.id=acme` and
upstream-b has `tenant.id=globex`, decide which to forward before the team
meeting, not during incident response.

**DLQ** requires that the rejected message carries `traceparent` so the
DLQ handler's span appears on the original trace, not as an orphan. Inject
into the rejected message before sending it to the DLQ; mark the span ERROR.

---

### Do you need IBM MQ tracing enabled for baggage propagation to work?

No. IBM MQ's built-in activity tracing (`strmqtrc`, `MQIACT`) records internal
queue manager events in IBM-proprietary format. The queue manager never reads,
writes, or interprets `traceparent` or `baggage` — it stores them as opaque
string properties in MQRFH2 and delivers them unchanged.

The only IBM MQ configuration that matters for OTel context propagation is
`PROPCTL(ALL)` on the queues and channels in the path.

---

### What is PROPCTL and how do you enable it?

`PROPCTL` is an IBM MQ queue attribute that controls whether message properties
survive the put/get cycle. Properties are stored in the MQRFH2 header — the
same place `traceparent` and `baggage` live.

| Value | Behaviour |
|-------|-----------|
| `ALL` | All properties preserved, MQRFH2 passed through intact |
| `COMPAT` | Properties preserved only if MQRFH2 was already present on put — new properties added via `setStringProperty()` are stripped |
| `NONE` | All properties stripped, MQRFH2 discarded entirely |

The default on a new queue is `COMPAT`. That is the silent failure mode: your
code calls `setStringProperty("traceparent", ...)`, IBM MQ accepts the put
without error, but the property is gone by the time the consumer calls
`getStringProperty("traceparent")`.

**Enable via `runmqsc`:**

```bash
runmqsc QM1
```

```
ALTER QLOCAL(DEV.QUEUE.1) PROPCTL(ALL)
ALTER QLOCAL(DEV.QUEUE.2) PROPCTL(ALL)
ALTER QLOCAL(DEV.QUEUE.3) PROPCTL(ALL)
ALTER QLOCAL(DEV.DEAD.LETTER.QUEUE) PROPCTL(ALL)
```

**Verify:**

```
DISPLAY QLOCAL(DEV.QUEUE.1) PROPCTL
```

Expected: `PROPCTL(ALL)`.

**If messages cross queue managers**, set it on the channel too:

```
ALTER CHANNEL(TO.QM2) CHLTYPE(SDR) PROPCTL(ALL)
```

**Verify end-to-end with `amqsbcg`:**

```bash
amqsbcg DEV.QUEUE.1 QM1
```

Look for:

```
<usr>
  <traceparent>00-aabbccdd...</traceparent>
  <baggage>tenant.id=acme,user.id=user42</baggage>
</usr>
```

If the `<usr>` folder is absent, `PROPCTL` is still stripping properties.
If the folder is present but empty, the application is not calling
`setStringProperty()` before the put.

---

### How do you know if PROPCTL is enabled?

Four ways, from most direct to most indirect.

**1. `runmqsc` — authoritative, requires MQ admin access**

```bash
runmqsc QM1
```
```
DISPLAY QLOCAL(DEV.QUEUE.1) PROPCTL
```
```
AMQ8409I: Display Queue details.
   QUEUE(DEV.QUEUE.1)                         TYPE(QLOCAL)
   PROPCTL(ALL)
```

Check all queues at once:
```
DISPLAY QLOCAL(*) PROPCTL
```

Check channels between queue managers:
```
DISPLAY CHANNEL(*) PROPCTL
```

**2. IBM MQ web console — no command line needed**

`https://localhost:9443` → Manage → Queues → select queue → Properties →
Extended → Message property control. Must show `All`.

**3. `amqsbcg` — confirms properties survive the full put/get cycle**

`runmqsc` tells you what the config says. `amqsbcg` tells you what actually
arrives on the wire. These can differ if there is a channel with wrong
`PROPCTL` in between.

Put a test message, then dump it:

```bash
echo "test" | amqsput DEV.QUEUE.1 QM1
amqsbcg DEV.QUEUE.1 QM1
```

If properties survive you will see the `<usr>` folder in the MQRFH2 output:

```
<usr>
  <traceparent>00-aabbccdd...</traceparent>
  <baggage>tenant.id=acme,user.id=user42</baggage>
</usr>
```

If `PROPCTL` is wrong the `<usr>` folder is absent — no error, no warning,
properties are silently discarded.

**4. From OTel/Tempo — no MQ access needed**

If you cannot access the queue manager, the symptom in Tempo is unambiguous:
orphan traces starting at your service with a brand new `trace-id`, even
though the upstream producer is correctly injecting `traceparent`.

The distinction from other causes:

- `traceparent` and `baggage` both missing → `PROPCTL` is stripping everything
- Traces link correctly but `tenant.id` attributes are null everywhere →
  `PROPCTL` is fine; `W3CBaggagePropagator` is missing from the SDK config
- Traces link correctly, `tenant.id` present on some spans but not downstream
  → inject is running outside an active scope

---

### Is PROPCTL required even when using the OTel Java agent or Instana agent?

Yes, for both. The reason is the same in both cases.

The Java agent and Instana agent both work by bytecode instrumentation —
they intercept `MessageProducer.send()` and `MessageConsumer.receive()` at
the JVM level and write `traceparent` via `message.setStringProperty()`.
Once that property is written and the message enters IBM MQ's transport layer,
the agent has no further influence. IBM MQ enforces `PROPCTL` inside the queue
manager process — no JVM agent can affect it.

```
agent intercepts send()
  → calls setStringProperty("traceparent", "00-abc...")
  → message enters IBM MQ
  → IBM MQ checks PROPCTL on the destination queue   ← agent has no reach here
  → COMPAT/NONE: property stripped silently
  → ALL: property preserved
```

**Instana specifically** uses its own header format by default
(`X-INSTANA-T`, `X-INSTANA-S`, `X-INSTANA-L`) rather than W3C `traceparent`.
The header names differ but the transport mechanism is identical — JMS message
properties in MQRFH2. `PROPCTL(ALL)` is equally required. Instana's own
documentation lists it as a prerequisite for IBM MQ correlation.

The one exception: the **IBM MQ native Instana sensor** reads trace data
directly from the queue manager's activity trace output via IBM's own API,
bypassing JMS properties entirely. In that case `PROPCTL` is irrelevant. But
that integration gives queue manager level metrics and activity, not
distributed traces linked to your application spans.

`PROPCTL(ALL)` is an IBM MQ infrastructure requirement, not an application
or agent requirement. Any approach that propagates context through JMS message
properties needs it set on every queue and channel in the path.
