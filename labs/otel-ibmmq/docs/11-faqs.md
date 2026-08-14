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
The lab uses Pipeline, DLQ, and Competing Consumers. The most important fix is the DLQ path: `validator` must propagate the original context when putting rejected messages to `DEV.DEAD.LETTER.QUEUE`, so that `bad-cj` and `blocked` traces appear as a single connected trace rather than two disconnected fragments.

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
All pipeline services (gateway, validator, enricher, processor, dlq-handler) are Java 21 using JMS — they get propagation via `JmsCarrier`, which maps OTel `TextMapSetter`/`TextMapGetter` to `message.setStringProperty` / `message.getStringProperty`. The Go services (upstream, traffic-gen) communicate with gateway over HTTP, not IBM MQ directly. A polyglot service using native MQI would interoperate automatically because W3C header names (`traceparent`, `baggage`) are plain strings that JMS and MQI both store in MQRFH2 `<usr>`.

---

### What are all the approaches for propagating OTel context across IBM MQ?

The three approaches in this lab are not exhaustive. The full landscape, ordered by where in the stack context is injected:

#### 1. Manual OTel SDK (`labs/otel-ibmmq`)
`JmsCarrier` implements `TextMapSetter`/`TextMapGetter`. Application code calls `propagator.inject()` before every send and `propagator.extract()` after every receive. Full control; most code to write.

#### 2. OTel Java Agent (`labs/otel-ibmmq-agent`)
`-javaagent:opentelemetry-javaagent.jar` instruments `MessageProducer.send()` and `MessageListener.onMessage()` via bytecode injection. No carrier code; services use `MessageListener` (not `consumer.receive()`) so the agent can propagate context into the callback.

#### 3. Spring JMS + Micrometer Tracing
Spring Boot 3 with `spring-boot-starter-actuator` propagates context automatically through `JmsTemplate` and `@JmsListener` via Spring's `ObservationRegistry`. No `JmsCarrier`, no javaagent. The most practical path for any existing Spring shop — sits between manual SDK and zero-code agent in terms of effort.

#### 4. Quarkus SmallRye Reactive Messaging
Quarkus's reactive JMS connector has built-in OTel support. Relevant if the team is already on Quarkus or moving to reactive programming.

#### 5. ApiExitLocal — queue manager C exit (`docs/16-api-exit.md`)
A C shared library loaded by the queue manager intercepts every `MQPUT`/`MQGET` for all connected applications, regardless of language. Injects `traceparent` for uninstrumented producers (COBOL, C, vendor systems). Cannot carry baggage. No application code changes.

#### 6. IBM MQ Channel Exit
Same concept as ApiExitLocal but operates at the *channel* level between queue managers in a cluster or hub-and-spoke topology. ApiExitLocal handles the application-to-QM boundary; a channel exit handles the QM-to-QM boundary. Relevant in large multi-QM enterprise deployments.

#### 7. IBM App Connect Enterprise (ACE)
If an ACE integration flow sits in the message path, ACE can propagate OTel context between its own flow nodes. Common in banks and insurers that already have ACE in the estate.

#### 8. IBM MQ REST API
IBM MQ 9.1+ exposes a REST endpoint for messaging (`POST /ibmmq/rest/v1/messaging/qmgr/{qmgr}/queue/{queue}/message`). HTTP callers send standard `traceparent` / `baggage` headers — no carrier code needed. Practical for REST-capable producers that cannot be instrumented.

#### 9. MQ → Kafka bridge
The IBM MQ Kafka Connect connector bridges messages from MQ to Kafka. Kafka's OTel ecosystem is significantly richer (first-class agent, SDK, and Quarkus support). Relevant when the organisation is already migrating toward event streaming or needs Kafka-native observability.

#### 10. Payload embedding
Embed `traceparent` in the message body (JSON envelope) instead of MQRFH2 headers. Removes the dependency on `PROPCTL(ALL)` entirely and works across any transport. Trade-off: all consumers must understand the envelope; non-standard and invisible to OTel auto-instrumentation.

#### 11. MQMD CorrelId as trace carrier
Use the 24-byte `CorrelId` field in the MQ Message Descriptor as a simplified trace identifier. Pre-dates W3C TraceContext; carries no baggage and no span flags. Still found in COBOL shops that need *some* correlation without OTel infrastructure.

| Approach | Who instruments | `traceparent` | `baggage` | Code changes | Notes |
|---|---|---|---|---|---|
| Manual SDK | Application | Yes | Yes | Yes | Full control |
| Java Agent | JVM bytecode | Yes | Yes | No | MessageListener required |
| Spring + Micrometer | Framework | Yes | Yes | Minimal | Best for Spring shops |
| Quarkus Reactive | Framework | Yes | Yes | Minimal | Reactive / Quarkus only |
| ApiExitLocal | Queue manager (C) | Yes | No | No | Covers uninstrumented producers |
| Channel Exit | QM-to-QM channel | Yes | No | No | Multi-QM topologies |
| ACE flow | Integration middleware | Yes | Partial | No | Requires ACE in path |
| MQ REST API | HTTP layer | Yes | Yes | No | REST-capable producers only |
| MQ → Kafka bridge | Architecture | Yes | Yes | Architecture change | Migration path |
| Payload embedding | Message body | Yes | Yes | Yes | Non-standard; transport-agnostic |
| CorrelId | MQMD field | Partial | No | No | Legacy; no W3C compliance |
