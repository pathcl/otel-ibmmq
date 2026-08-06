# 03 — JMS Carrier: TextMapSetter and TextMapGetter

## What a carrier is

OTel's propagation API is transport-agnostic. A "carrier" is any object that can hold
key-value pairs. The propagator writes into it (inject) and reads from it (extract).

For HTTP the carrier is the headers map. For JMS the carrier is the message's string
properties, accessed via `message.setStringProperty()` and `message.getStringProperty()`.

## JMS property name constraints

JMS 2.0 spec §3.5.1 defines valid property names:
- Must start with a Java identifier character (letter, `$`, `_`)
- May contain letters, digits, `_`, `$`
- **Hyphens and dots are not allowed**

W3C OTel standard headers:
- `traceparent` — no hyphens, passes through unchanged
- `tracestate`  — no hyphens, passes through unchanged
- `baggage`     — no hyphens, passes through unchanged

These are fine as-is. The `sanitize()` method in JmsCarrier is defensive — it replaces
`-` and `.` with `_` for any future custom headers.

## IBM MQ specifics

IBM MQ stores JMS string properties in the **MQRFH2 header folder** (`usr` or `jms`
subfolders depending on the property). The total MQRFH2 header has a practical limit
of ~32KB (configurable via `MaxMsgLength`). For a lab this is irrelevant; in production
it matters when propagating many large baggage entries.

IBM MQ also has a concept of "JMS-defined" properties (prefixed `JMS`) and user-defined
properties. OTel headers fall into user-defined. No special handling needed.

## Why `Context.root()` in the processor, not `Context.current()`

```java
Context extractedCtx = otel.getPropagators().getTextMapPropagator()
    .extract(Context.root(), message, JmsCarrier.GETTER);
```

`Context.root()` is an empty context — no active span, no baggage.

Using `Context.current()` here would merge the extracted context on top of whatever
context the receive-loop thread happens to carry. In a blocking receive loop, that is
usually empty — but it's a thread-local assumption. Using `Context.root()` as the base
makes the extraction deterministic: the resulting context contains exactly what was in
the message, nothing more.

The trace link between gateway and processor is established by `setParent(extractedCtx)`,
which sets the extracted traceparent as the parent of the consumer span. Grafana Tempo
then shows the two spans as a single trace.

## Baggage vs span attributes

Baggage propagates in context automatically but does **not** appear in spans.
Span attributes are indexed in Tempo and searchable.

This is why the processor explicitly copies baggage values to span attributes:

```java
Baggage baggage = Baggage.fromContext(extractedCtx);
span.setAttribute("tenant.id", baggage.getEntryValue("tenant.id"));
```

If you skip this step, `tenant.id` travels through the system but disappears —
it never lands in Tempo and you cannot filter traces by it.
