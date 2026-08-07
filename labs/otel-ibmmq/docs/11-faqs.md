# FAQs

## Context propagation and baggage

### Does the IBM MQ usage pattern affect how OpenTelemetry baggage propagation is implemented?

Yes. The pattern changes both the relationship between spans and whether context must be explicitly forwarded.

**Pipeline / Point-to-Point**
Standard case: extract context at consume, inject into the outgoing message at produce. Baggage flows linearly downstream. No special handling required.

**Competing Consumers**
Each message is independent, so propagation is identical to point-to-point on a per-message basis. Multiple consumers draining the same queue do not interfere with each other's contexts.

**Dead Letter Queue**
The service that rejects a message (e.g. `validator`) must forward the original extracted context into the DLQ message — not create a new root context. If it creates a fresh context, the DLQ handler's span appears as a disconnected trace, breaking the link back to the originating tenant and request.

**Request-Reply**
The reply span should use a **span link** rather than a parent-child relationship. The request span may already be closed by the time the reply arrives, so a child span timestamped after its parent ended produces misleading traces in Grafana.

**Publish-Subscribe**
One producer span fans out to N consumer spans, all children of the same parent. Baggage propagates identically to each subscriber. No structural change to the inject/extract implementation.

**Wire Tap**
The audit copy is a side-effect of the main flow, not a continuation of it. Use a span link (same as Request-Reply). Parent-child would place the audit span inline in the pipeline, distorting latency attribution.

**Impact on this lab**
The lab uses Pipeline, DLQ, and Competing Consumers. The most important fix is the DLQ path: `validator` must propagate the original context when putting rejected messages to `DEV.DEAD.LETTER.QUEUE`, so that `bad-tenant` and `blocked` traces appear as a single connected trace rather than two disconnected fragments.

---

### Does the programming language affect the implementation?

Yes. The dividing line is whether the client uses the **JMS API** or the **native MQI API**.

**Java / Jakarta EE (JMS)**
The only language with auto-instrumentation. The OpenTelemetry Java agent instruments JMS 1.1 and 2.0 automatically. JMS message properties map directly to the `TextMapCarrier` interface, so `traceparent`, `tracestate`, and `baggage` are injected and extracted without writing any carrier code. You only need to configure the propagator to include baggage:

```java
OpenTelemetrySdk.builder()
    .setPropagators(ContextPropagators.create(
        TextMapPropagator.composite(
            W3CTraceContextPropagator.getInstance(),
            W3CBaggagePropagator.getInstance())))
```

**All other languages — native MQI**
Go, Python, Node.js, .NET, and C/C++ all use IBM MQ's native MQI bindings. None have OTel auto-instrumentation. In every case you implement a custom `TextMapCarrier` that reads and writes **MQRFH2 string properties**. The concept is identical across languages; only the syntax differs.

| Language | Client | Required work |
|---|---|---|
| Java (JMS) | `com.ibm.mq.jakarta.client` | Configure propagator — agent handles the rest |
| Java (MQI) | Same client, MQI API | Custom `MQRFH2` `TextMapCarrier` |
| Go | `ibmmq` | Custom `MQRFH2` `TextMapCarrier` |
| Python | `pymqi` | Custom `MQRFH2` `TextMapCarrier` |
| Node.js | `ibmmq` npm | Custom `MQRFH2` `TextMapCarrier` |
| .NET | `IBM.MQ` NuGet | Custom `MQRFH2` `TextMapCarrier` |
| C / C++ | MQI native | Custom `MQRFH2` struct |

**Other transports**
The IBM MQ REST API uses standard HTTP headers — any language gets context propagation for free. IBM MQ also supports AMQP 1.0; context travels in AMQP application-properties, with partial OTel support depending on the client library.

**Interoperability constraint**
All languages must agree on MQRFH2 as the carrier. IBM MQ stores JMS string properties as MQRFH2 internally, so a Java JMS producer and a Go MQI consumer are compatible at the wire level — but only if the Go consumer explicitly parses MQRFH2. Without that extraction step, the context is silently dropped even though it is physically present in the message. This is the most common failure in polyglot IBM MQ deployments.

**Impact on this lab**
All five services are Go using native MQI. One shared `mqcarrier` package implementing the MQRFH2 `TextMapCarrier` covers all of them. If a Java service were added, it would interoperate automatically because JMS property names and W3C header names (`traceparent`, `baggage`) are identical.
