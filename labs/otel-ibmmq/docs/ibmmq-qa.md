# IBM MQ — Questions & Answers

Running log of questions asked during learning. Tags:
- `#ibmmq` — IBM MQ concepts, configuration, operations
- `#o11y` — observability, tracing, baggage, context propagation

---

## What is MQRFH2? `#ibmmq`

MQRFH2 stands for "Rules and Formatting Header version 2." It is a structured
binary header that IBM MQ prepends to the message body to carry named key-value
properties. The MQMD (Message Descriptor) has fixed fields — you cannot add
arbitrary properties to it. MQRFH2 is the only IBM MQ mechanism for carrying
named properties alongside a message.

---

## How many IBM MQ header types exist? `#ibmmq`

| Header | Format field value | What it carries |
|--------|--------------------|----------------|
| MQMD | always present | Fixed envelope: MsgId, CorrelId, timestamp, persistence, expiry |
| MQRFH | `MQHRF   ` | Version 1 — older, rarely used |
| MQRFH2 | `MQHRF2  ` | Version 2 — JMS properties, OTel headers, `<usr>` folder |
| MQDLH | `MQDEAD  ` | Dead Letter Header — added when a message lands on the DLQ |
| MQCIH | `MQCICS  ` | CICS bridge — mainframe integration only |
| MQIIH | `MQIMS   ` | IMS bridge — mainframe integration only |
| MQXQH | `MQXMIT  ` | Transmission queue header — added when routing between queue managers |

For OTel context propagation, only MQRFH2 matters.

---

## How do you tell if MQRFH2 is present on a message? `#ibmmq` `#o11y`

Two ways using `amqsbcg`:

**1. MQMD Format field:**
```
Format : 'MQHRF2  '   ← MQRFH2 present, properties intact
Format : 'MQSTR   '   ← plain string, MQRFH2 absent
```

**2. First bytes of the message body:**
```
00000000:  5246 4820 ...   'RFH ......'   ← MQRFH2 struct starts here
```
If the body starts with your payload bytes, there is no MQRFH2.

---

## Why must MQRFH2 be used — is there an alternative? `#o11y`

No alternative for carrying named properties through IBM MQ. You could embed
properties in the body (JSON, custom format) but then every consumer must parse
your custom format and OTel's standard carrier adapter would not work. MQRFH2 is
the IBM MQ standard — the JMS API handles it transparently. OTel's inject/extract
operates against JMS message properties, which map to MQRFH2 automatically.

---

## Is MQRFH2 specific to a particular IBM MQ version? `#ibmmq`

MQRFH2 as a format has existed since IBM MQ 5.3 (~2002). `PROPCTL`, which is
required to preserve MQRFH2 across queue hops, was introduced in IBM MQ 7.0.

IBM MQ 7.x is entirely out of IBM support (all versions ended support by 2018).
**IBM MQ 9.x LTS is the only version you should be running in production.**
9.3 is the current Long Term Support release.

The OpenTelemetry Java SDK has no IBM MQ version requirement of its own — it
operates through the JMS API, which is stable across all 9.x releases.

---

## What is PROPCTL and why does every queue need it? `#ibmmq` `#o11y`

`PROPCTL` (property control) is a queue attribute that determines whether the
MQRFH2 header is delivered to the consuming application on MQGET.

| Value | Behaviour |
|-------|-----------|
| `ALL` | Consumer receives the full MQRFH2 including the `<usr>` folder |
| `COMPAT` | Consumer receives MQRFH2 only if the message was originally put with one |
| `NONE` | MQRFH2 is stripped before delivery — consumer sees no properties |

Every queue in the propagation path must have `PROPCTL(ALL)` — including the DLQ.
If any single queue has the wrong value, MQRFH2 is silently stripped at that hop
and all downstream services lose their trace context.

Set the queue manager default to cover all new queues automatically:
```
ALTER QMGR PROPCTL(ALL)
```

Then audit existing queues:
```
DISPLAY QLOCAL(*) PROPCTL
```

---

## Do we have to configure PROPCTL on all queues? `#ibmmq` `#o11y`

Yes — every queue the message touches. Set `ALTER QMGR PROPCTL(ALL)` first
to cover new queues, then fix pre-existing queues individually. Do not forget
the DLQ — that is where you need context most when debugging failures.

If messages cross queue manager boundaries via channels, channels also need
`PROPCTL(ALL)`.

---

## Why stop the validator to browse a message? What role does it play? `#ibmmq`

The validator is the first consumer in the pipeline — it listens on `DEV.QUEUE.1`
and picks up messages the instant they arrive. Stopping it creates a window where
the message sits on the queue long enough to browse with `amqsbcg`.

Better alternatives that do not require stopping a service:
- **Dedicated browse queue** — configure the gateway to mirror messages to a queue
  no service consumes from. Browse at leisure.
- **IBM MQ web console** — https://localhost:9443 provides a persistent browse UI
  with no timing pressure.
- **DLQ inspection** — trigger a deliberate failure, browse `DEV.DEAD.LETTER.QUEUE`.
  More realistic — this is what SREs do in production.

---

## What are the hard requirements for baggage and context propagation over IBM MQ? `#ibmmq` `#o11y`

Eight blockers — missing any one of them silently breaks propagation:

### IBM MQ infrastructure (MQ admin owns this)

| # | Requirement | What breaks without it |
|---|-------------|----------------------|
| 1 | `PROPCTL(ALL)` on every queue including DLQ | MQRFH2 stripped silently at that queue; all downstream services see no context |
| 2 | `PROPCTL(ALL)` on every channel between queue managers | Same as above but at the network boundary between QMs |
| 3 | Message format must not be `MQFMT_STRING` | MQRFH2 discarded regardless of PROPCTL; no recovery possible |

### Application code (your team owns this)

| # | Requirement | What breaks without it |
|---|-------------|----------------------|
| 4 | Both W3C propagators registered (`W3CTraceContextPropagator` + `W3CBaggagePropagator`) | Missing baggage propagator = traces link but all baggage values are null downstream |
| 5 | Carrier adapter wired to JMS message properties | `inject()`/`extract()` have no way to read or write the JMS message |
| 6 | `inject()` called on every outbound message before `send()` | No context written to the message; consumer always starts an orphan trace |
| 7 | `extract()` called on every received message | Context present in message but never read; consumer starts an orphan trace |
| 8 | Consumer span created with `.setParent(extractedCtx)` | Context extracted but link never formed; span is still an orphan |

### What is NOT a hard requirement

| Thing | Why optional |
|-------|-------------|
| IBM MQ activity tracing | Queue manager internal tracing; unrelated to OTel properties |
| OTel Java agent | Manual SDK achieves the same result |
| Instana agent | Writes the same JMS properties; PROPCTL still required regardless |
| OTel Collector | Required to export spans, not for propagation itself |
| Same language across services | W3C headers are plain strings; any language reads them |
| Same OTel SDK version | Wire format is standardised; versions are interoperable |

Full detail in `baggage-ibmmq-checklist.md` § Hard requirements.

---

## Reference books and documentation `#ibmmq`

### IBM Redbooks (free PDF at redbooks.ibm.com)

| Title | Number | Best for |
|-------|--------|----------|
| IBM MQ V8 Features and Enhancements | SG24-8218 | Most recent comprehensive Redbook. Core architecture, security, clustering. Start here. |
| IBM WebSphere MQ V7.1 and V7.5 Features and Enhancements | SG24-8087 | Conceptual intro alongside the V8 book. Good on message-oriented middleware fundamentals. |
| WebSphere MQ V6 Fundamentals | SG24-7128 | The foundational "how MQ works" book. Archived but core concepts (queues, channels, MQI) are still valid. |
| WebSphere MQ Security in an Enterprise Environment | SG24-6814 | SSL/TLS, channel auth, message-level security. Architecture concepts are durable despite age. |
| High Availability in WebSphere Messaging Solutions | SG24-7839 | Multi-instance queue managers, HA patterns, clustering for availability. |

> IBM has not published a V9-specific full Redbook. SG24-8218 (V8) is the most
> recent and the core concepts carry directly to V9.

### O'Reilly

**Java Message Service, 2nd Edition** — Mark Richards, Richard Monson-Haefel, David Chappell  
ISBN: 978-0-596-52204-9 | O'Reilly, 2009

No O'Reilly book is dedicated solely to IBM MQ. This JMS book uses IBM MQ as
a primary provider example throughout. Covers JMS 1.1, point-to-point,
pub/sub, transactions. Understanding JMS is understanding how Java applications
talk to IBM MQ — this is the right book.

### Official IBM documentation

**IBM MQ 9.3:** https://www.ibm.com/docs/en/ibm-mq/9.3.x  
Covers installation, administration, security, development (MQI, JMS, REST API),
monitoring, and troubleshooting. Also available as PDF bundles for offline reading.

---

## The producer says it's injecting context but traces are still orphaned — how do you diagnose? `#ibmmq` `#o11y`

IBM MQ can silently strip MQRFH2 between PUT and GET. From the outside this
looks identical to a producer that never injected anything. `amqsbcg` is the
wedge — browse the message on the queue before the consumer reads it.

### Step 1 — stop the consumer, send a message, browse

```bash
# Stop the consumer to create a browse window
docker stop <validator-container>

# Send a real message (use your gateway or JMS producer, not amqsput)
curl -X POST http://localhost:8081/order -H "X-bsi-ep: acme"

# Browse the queue — message is still sitting there
docker exec <mq-container> /opt/mqm/samp/bin/amqsbcg DEV.QUEUE.1 QM1

# Restart consumer
docker start <validator-container>
```

### Step 2 — read the Format field

**MQRFH2 present — producer is doing its job:**
```
Format : 'MQHRF2  '
...
<usr><traceparent>00-abc...</traceparent><baggage>bsi.ep=acme</baggage></usr>
```
The producer injected correctly. IBM MQ is stripping MQRFH2 after PUT, before
the consumer's MQGET. → Go to Step 3.

**MQRFH2 absent — producer is the problem:**
```
Format : 'MQSTR   '
```
`inject()` was never called, the carrier SETTER is a no-op, or the producer
is a native-MQ application that set `MQFMT_STRING` explicitly. → Fix the
producer or add an API exit.

### Step 3 — audit PROPCTL on every queue in the path

```
DISPLAY QLOCAL(*) PROPCTL
DISPLAY QMGR PROPCTL
```

A single queue with `PROPCTL(NONE)` anywhere in the chain drops MQRFH2
silently — no error, no DLQ, the message is delivered but stripped.
If messages cross queue managers, also check channels:

```
DISPLAY CHL(*) PROPCTL
```

### Decision table

| `amqsbcg` shows | Consumer sees | Root cause |
|-----------------|--------------|------------|
| `MQHRF2` + `<usr>` present | orphan trace | PROPCTL wrong on queue or channel |
| `MQHRF2` present, `<usr>` empty | orphan trace | Carrier SETTER is a no-op; properties written to wrong field |
| `MQSTR` | orphan trace | Producer not injecting, or MQFMT_STRING set explicitly |
| `MQHRF2` + `<usr>` present | connected trace | Everything working — check your Tempo query |

---

## What are IBM MQ exits and how do they relate to context propagation? `#ibmmq` `#o11y`

IBM MQ exits are user-written routines that IBM MQ calls automatically at
specific points in message processing. They run inside the application's process
without the application knowing.

### Relevant exit types

| Exit type | When it fires | Typical use |
|-----------|--------------|-------------|
| **API exit** | Before/after every `MQPUT`, `MQGET`, `MQOPEN`, etc. | Add/read MQRFH2 properties transparently |
| **Channel exit** | During message transmission between queue managers | Encrypt, filter, or stamp messages at network boundary |
| **Message exit** | When a message is about to cross a channel | Re-stamp or validate headers between QMs |

### Why this matters for producers that cannot inject context

An **API exit on MQPUT** can inspect every outgoing message and inject
`traceparent` + `baggage` into MQRFH2 if they are not already present.
The producer application code never changes. This solves the fire-and-forget
problem when the producer is a legacy app, a C/COBOL native-MQ application,
or a vendor system you do not own.

Instana and Dynatrace both ship an IBM MQ API exit that does exactly this —
every `MQPUT` is intercepted, context is injected if absent, and the consumer
side's `extract()` works normally.

### OTel Java agent — the JVM equivalent

For Java producers specifically, the **OpenTelemetry Java agent** achieves the
same result without an MQ exit. It instruments JMS calls via bytecode
injection at the JVM level:

- intercepts `MessageProducer.send()` and injects `traceparent`/`baggage` automatically
- intercepts `MessageConsumer.receive()` and extracts them automatically
- requires zero code changes to the application

The difference from an MQ exit: the Java agent works only for JVM processes.
An MQ API exit works for any producer language (C, COBOL, RPG, Java, .NET).

### What the lab uses

The lab does manual `inject()`/`extract()` in application code — REQ 6, 7, 8
in the hard requirements. This is equivalent to what the OTel Java agent does
automatically, but written out explicitly so the mechanism is visible.
Using the agent or an MQ exit would make REQ 6-8 automatic and remove the
risk of a developer forgetting to call them.

---

## Is the IBM MQ container image compatible with ARM64 / Apple Silicon? `#ibmmq`

Yes, since **IBM MQ 9.3.3.0** (released June 2023). The `icr.io/ibm-messaging/mq`
image publishes a multi-arch manifest — Docker and Podman automatically pull the
correct layer for the host architecture. No `platform:` override or separate tag
is needed.

Reference: [IBM MQ 9.3.3.0 container image now available for Apple Silicon](https://community.ibm.com/community/user/blogs/richard-coppen/2023/06/30/ibm-mq-9330-container-image-now-available-for-appl)

### One caveat

The **IBM MQ XR component** (MQTT and AMQP based messaging) is not available on
the ARM64 image. This lab uses JMS only — no MQTT, no AMQP — so this limitation
does not apply.

### What this means for the lab

`docker-compose.yml` uses `icr.io/ibm-messaging/mq:latest`. On an ARM64 host
(Apple M1/M2/M3) Docker pulls the ARM64 layer natively. On an amd64 host it
pulls the amd64 layer. No configuration change is required for either platform.

---

## What does the TraceQL syntax look like for querying by entry point? `#o11y`

```
{ span.bsi.ep = "checkout" }
```

Unscoped (matches span or resource attributes):
```
{ .bsi.ep = "checkout" }
```

`span["bsi.ep"]` is not valid TraceQL — it returns HTTP 400.

---

## OTel Java agent vs manual SDK (JmsCarrier) — which should we use and why? `#o11y` `#ibmmq`

### What the OTel Java agent gives you for free

- **Auto-instrumented JMS spans** — the agent intercepts `MessageProducer.send()` and
  `MessageConsumer.receive()` via bytecode and creates producer/consumer spans with
  standard `messaging.*` attributes automatically.
- **W3C propagation out of the box** — it injects and extracts `traceparent` / `baggage`
  into JMS message properties without a hand-written `JmsCarrier`.
- **Breadth** — a single `-javaagent:opentelemetry-javaagent.jar` JVM flag also
  auto-instruments JDBC, HTTP clients, thread pools, and hundreds of other libraries.

### Why it does not help this lab

| Concern | Detail |
|---|---|
| Custom baggage still needs SDK code | The agent propagates whatever is already in W3C Baggage, but it has no knowledge of the `X-bsi-*` HTTP header convention. Gateway and upstream still need manual SDK code to collect those headers, derive baggage keys (`X-bsi-ep` → `bsi.ep`), and build the `Baggage` object. The agent handles the MQ hop, not the HTTP-to-baggage translation. |
| Double instrumentation | The agent creates its own JMS spans. Manual spans (`gateway.send`, `validator.handle`, etc.) would become children of the agent's spans or conflict with them — requiring either fighting the agent or stripping out the manual spans and losing custom naming and attribute control. |
| Less pedagogical clarity | The agent is bytecode magic. The explicit `JmsCarrier` code shows exactly how context crosses the MQ wire, which is the point of the lab. |
| PROPCTL is still your problem | The agent does not fix IBM MQ stripping MQRFH2 headers. `PROPCTL(ALL)` is still required on the queue manager side for the agent's inject/extract to survive the broker hop. |

### When the agent wins

Existing JMS apps with **zero OTel code** and no custom propagation logic. Drop in
the jar, get traces for free — no application changes required. This is the JVM-side
equivalent of an IBM MQ API exit: instrumentation without touching the application.

### Verdict for this lab

The manual SDK approach (`JmsCarrier` + explicit span builders) gives more control,
clearer pedagogy, and is actually less work here — SDK code is required anyway for
the `bsi.*` attribute logic. Adding the agent would introduce a layer without
removing any existing code.

---

## What are traceparent and baggage in IBM MQ's data model — headers or properties? `#ibmmq` `#o11y`

Neither term maps directly. In IBM MQ's data model they are **message properties**
— specifically JMS string properties stored in the `<usr>` folder of MQRFH2.

When `JmsCarrier.SETTER` calls `message.setStringProperty(key, value)`, JMS writes
the key-value pair into `<usr>`. The full structure of a message carrying OTel context:

```
MQMD  (fixed binary envelope — MsgId, CorrelId, Format=MQHRF2, ...)
  └── MQRFH2
        <mcd><Msd>jms_text</Msd></mcd>
        <jms><Dst>queue:///DEV.QUEUE.1</Dst><Tms>1723500000000</Tms></jms>
        <usr>
          <traceparent>00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01</traceparent>
          <tracestate></tracestate>
          <baggage>bsi.ep=checkout,bsi.ch=android,bsi.cj=MoneyTransfer</baggage>
        </usr>
        └── message body: "order | checkout android MoneyTransfer"
```

The word "header" in IBM MQ refers to the MQRFH2 structure itself, not the
individual fields inside it. Each transport maps OTel context to its own native
mechanism:

| Transport | traceparent/baggage live in |
|---|---|
| HTTP | `traceparent:` and `baggage:` headers |
| Kafka | record headers (byte key/value pairs) |
| IBM MQ | `<usr>` folder string properties inside MQRFH2 |
| gRPC | metadata entries |

The OTel SDK never knows which transport it is talking to — it only knows about
carriers and key-value pairs. `JmsCarrier` is the adapter that makes the translation
MQ-specific.

---

## Does the OTel Collector participate in context propagation across IBM MQ? `#o11y`

No. Context propagation is entirely in-band with the message — `traceparent` and
`baggage` travel as string properties inside the MQRFH2 `<usr>` folder, directly
from producer to consumer. The Collector never sees the MQ messages.

The Collector's role is **telemetry export** — receiving the spans that each service
creates via OTLP and forwarding them to Tempo. Without it, traces would be
assembled locally but never visible in Grafana.

```
gateway   ─┐
validator  ├─→ OTLP → OTel Collector → Tempo → Grafana   (visibility)
enricher   │
processor  ┘

gateway → <usr> traceparent in MQ message → validator                (propagation)
```

These are two independent paths. Removing the Collector breaks visibility; it has
no effect on whether the trace context survives the MQ hop.

The Collector is also technically optional — services could send OTLP directly to
Tempo. The Collector adds batching, retry, and the ability to fan out to multiple
backends without changing service configuration.

---

## What are entry and exit spans, and how do they map to inject/extract? `#o11y`

Spans are classified by the direction of the call at a service boundary:

| SpanKind | Direction | Role in propagation |
|---|---|---|
| `SERVER` / `CONSUMER` | Incoming (entry) | **Extract** context from the carrier |
| `CLIENT` / `PRODUCER` | Outgoing (exit) | **Inject** context into the carrier |

The rule: **extract at entry, inject at exit.**

In this lab every boundary follows that pattern:

```
upstream (CLIENT exit)   → inject HTTP headers  → gateway  (SERVER entry) extracts
gateway  (PRODUCER exit) → inject MQ message    → validator(CONSUMER entry) extracts
validator(PRODUCER exit) → inject MQ message    → enricher (CONSUMER entry) extracts
```

In Java this maps directly to span kind:

```java
// EXIT — you own the outgoing carrier, so you inject
Span producerSpan = tracer.spanBuilder("gateway.send")
    .setSpanKind(SpanKind.PRODUCER)
    .startSpan();
propagator.inject(Context.current(), message, JmsCarrier.SETTER);

// ENTRY — you receive the carrier, so you extract
Context extracted = propagator.extract(Context.root(), message, JmsCarrier.GETTER);
Span consumerSpan = tracer.spanBuilder("validator.handle")
    .setSpanKind(SpanKind.CONSUMER)
    .setParent(extracted)
    .startSpan();
```

REQ 5 and REQ 6 in `break-requirements.sh` break the exit side (no inject).
REQ 7 and REQ 8 break the entry side (no extract / no setParent).

---

## ApiExitLocal — when would you use it and how does it compare to the OTel SDK? `#ibmmq` `#o11y`

`ApiExitLocal` is a C shared library loaded by the queue manager that intercepts
every MQ API call — `MQPUT`, `MQGET`, `MQOPEN`, `MQCLOSE` — before and after it
completes. Configured in `qm.ini`:

```ini
ApiExitLocal:
  Name=OtelPropagator
  Module=/opt/mqm/exits/otel_propagator.so
  Function=OtelApiExit
  Sequence=1
```

### When it wins over the OTel SDK

- **You own the infrastructure but not the application code** — legacy COBOL, C batch
  jobs, or vendor systems that cannot be modified. The exit instruments every `MQPUT`
  and `MQGET` regardless of the producer language.
- **Mixed estate** — some producers are JMS (instrumented), some are native MQ C API
  (not instrumented). The exit enforces a consistent policy: every message carries
  `traceparent`, no per-team SDK adoption required.

### Comparison

| | ApiExitLocal | OTel SDK |
|---|---|---|
| Language | C only | any |
| Code changes required | no | yes — every service |
| Trace breaks if one service skips it | no — exit covers all | yes |
| Baggage support | implement from scratch | W3C spec handled by SDK |
| Debuggability | very hard — crash = QM process down | standard OTel tooling |
| Portability | MQ-specific | any transport |
| PROPCTL still needed | yes | yes |

### "Implement from scratch" means

At the C API level there is no OTel SDK available. To inject `traceparent` you must:
generate a valid 16-byte trace ID, generate an 8-byte span ID, format the
`00-{traceId}-{spanId}-{flags}` string, parse incoming `traceparent` to extract the
parent, write it back as an MQRFH2 property using the MQ C API, handle sampling
flags, and do the same for the `baggage` `key=value,key=value` format. The SDK
does all of this for you.

### Volume concern

The exit fires on **every** `MQPUT` and `MQGET` across the entire queue manager —
admin tools, health checks, batch jobs, IBM MQ internals. Without explicit filtering
logic (also written in C) you generate traces for everything on the QM. The SDK
approach is intentional — you instrument only the services and queues you care about.

---

## Does ApiExitLocal remove the need to instrument producers for baggage? `#ibmmq` `#o11y`

No. `ApiExitLocal` can inject `traceparent` automatically — it intercepts `MQPUT`
and writes the trace ID into the `<usr>` folder. But `baggage` is a different problem.

Baggage carries business context:

```
bsi.ep=checkout,bsi.ch=android,bsi.cj=MoneyTransfer
```

The exit has no access to this information. It runs at the MQ API level and sees
only raw `MQPUT` calls and message buffers — not the HTTP request that originated
the transaction, not the application's in-memory state, not which entry point or
customer journey this message belongs to. That information only exists in the
application.

So even with `ApiExitLocal` handling `traceparent` automatically, you still need
the application to attach baggage — which means instrumenting the producers anyway.

In practice `ApiExitLocal` alone gives you connected traces but empty business
context. You can see that spans are linked across services but cannot answer which
entry point triggered a failure or which customer journey is generating DLQ traffic.
Those questions require baggage, and baggage requires the application to participate.

---

## How do you inspect the `<usr>` folder in amqsbcg output? `#ibmmq` `#o11y`

Each MQRFH2 folder (`<mcd>`, `<jms>`, `<usr>`) appears as a single line under the
`RFH data :` block in `amqsbcg` output. Use `grep` to isolate it:

```bash
docker compose -f labs/otel-ibmmq/docker-compose.yml exec ibmmq \
  bash -c '/opt/mqm/samp/bin/amqsbcg DEV.DEAD.LETTER.QUEUE QM1' | grep '<usr>'
```

The raw output structure:

```
RFH :
  StrucId        : 'RFH '
  Version        : 2
  StrucLength    : 312
  ...

RFH data :
  <mcd><Msd>jms_text</Msd></mcd>
  <jms><Dst>queue:///DEV.DEAD.LETTER.QUEUE</Dst><Tms>1723500000000</Tms></jms>
  <usr><traceparent>00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01</traceparent><tracestate></tracestate><baggage>bsi.ep=checkout,bsi.ch=android,bsi.cj=blocked</baggage></usr>
```

For a more readable format, break the XML tags onto separate lines:

```bash
docker compose -f labs/otel-ibmmq/docker-compose.yml exec ibmmq \
  bash -c '/opt/mqm/samp/bin/amqsbcg DEV.DEAD.LETTER.QUEUE QM1' \
  | grep '<usr>' \
  | sed 's/></>\n</g'
```

Output:

```xml
<usr>
<traceparent>00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01</traceparent>
<tracestate></tracestate>
<baggage>bsi.ep=checkout,bsi.ch=android,bsi.cj=blocked</baggage>
</usr>
```

The DLQ is the most reliable queue to inspect — messages accumulate there and are
not consumed, so there is no timing pressure. On active pipeline queues
(`DEV.QUEUE.1`–`DEV.QUEUE.3`) messages are drained in milliseconds; stop
`traffic-gen` first to create a browse window.

---

## Is ApiExitLocal where APM vendors plug in their IBM MQ tracing agents? `#ibmmq` `#o11y`

Yes. `ApiExitLocal` is the standard IBM MQ extension point that APM vendors use to
ship IBM MQ instrumentation without touching application code.

Examples of what ships as an `ApiExitLocal`:

- **Instana** — their IBM MQ sensor is an API exit. It intercepts `MQPUT`/`MQGET`,
  injects and extracts Instana trace headers into MQRFH2 properties, and reports
  spans back to the Instana agent running on the host.
- **Dynatrace** — same pattern. The OneAgent includes an MQ API exit that instruments
  all MQ traffic on the queue manager automatically.
- **AppDynamics** — also ships an API exit for IBM MQ correlation.

The pattern is always the same:

```
application → MQPUT → ApiExitLocal intercepts → injects vendor header → message on queue
                                                                               ↓
application ← MQGET ← ApiExitLocal intercepts ← extracts vendor header ← message delivered
```

Vendors have already implemented the header format, sampling, and context propagation
logic in their C library. You configure it in `qm.ini`, deploy the `.so` file, and
every `MQPUT`/`MQGET` on that queue manager is instrumented automatically.

The baggage limitation still applies regardless of vendor: the exit can carry trace
IDs automatically but has no knowledge of business context (`bsi.ep`, `bsi.cj`).
Vendors typically solve this by correlating their own trace IDs on the APM backend
rather than embedding business attributes in the message itself.

---

## What does an ApiExitLocal look like in practice? `#ibmmq` `#o11y`

A reference implementation is in `api-exit/otel_exit.c`. The key sections:

### Entry point — registered in qm.ini, called once at load

```c
void MQENTRY OtelExitInit(PMQAXP pExitParms, PMQAXC pExitContext,
                          PMQLONG pCompCode, PMQLONG pReason)
{
    MQXEP(pExitParms->Hconfig, MQXR_BEFORE, MQXF_PUT,
          (PMQFUNC)BeforePut, &CC, &RC);   /* intercept every MQPUT */

    MQXEP(pExitParms->Hconfig, MQXR_AFTER, MQXF_GET,
          (PMQFUNC)AfterGet, &CC, &RC);    /* intercept every MQGET */
}
```

### BeforePut — inject traceparent if absent

```c
void MQENTRY BeforePut(..., PMQPMO pPutMsgOpts, ...)
{
    MQHMSG hmsg = pPutMsgOpts->OriginalMsgHandle;

    /* check if traceparent already present — don't overwrite upstream context */
    MQINQMP(*pHconn, hmsg, &impo, &propName, ...);

    if (not present) {
        make_traceparent(traceparent);          /* generate 00-{traceId}-{spanId}-01 */
        MQSETMP(*pHconn, hmsg, ..., traceparent);  /* write into <usr> folder */
    }

    /* NEVER fail the PUT — tracing must not break message flow */
    *pCompCode = MQCC_OK;
}
```

### AfterGet — extract traceparent

```c
void MQENTRY AfterGet(..., PMQGMO pGetMsgOpts, ...)
{
    MQHMSG hmsg = pGetMsgOpts->MsgHandle;
    MQINQMP(*pHconn, hmsg, ..., traceparent, ...);

    if (found) {
        /* store in thread-local storage so the application can read it */
        pthread_setspecific(tls_key, strdup(traceparent));
    }
}
```

### qm.ini configuration

```ini
ApiExitLocal:
  Name=OtelPropagator
  Module=/var/mqm/exits64/otel_exit
  Function=OtelExitInit
  Sequence=1
```

### Build

```bash
cd api-exit
make
make install   # copies to /var/mqm/exits64/
# restart QM1 to load the exit
```

### What this does not do vs the OTel SDK

| | ApiExitLocal | OTel SDK (this lab) |
|---|---|---|
| Injects traceparent | yes — automatically | yes — explicitly via JmsCarrier |
| Injects baggage (bsi.ep etc.) | no — no application context | yes — application builds it |
| Creates spans | no — headers only | yes |
| Exports to Collector | no | yes |
| Works for non-Java producers | yes | no — SDK is language-specific |

The exit handles the wire format; it cannot replace the SDK for span creation,
baggage population, or telemetry export.

---

## What is the difference between ApiExitCommon and ApiExitLocal? `#ibmmq`

Both are API exit stanzas but they live at different levels of IBM MQ's configuration
hierarchy and have different scope.

IBM MQ has three distinct configuration levels:

```
/var/mqm/mqs.ini                ← system level — all queue managers on this host
/var/mqm/qmgrs/QM1/qm.ini      ← queue manager level — this QM only
MQSC commands (runmqsc)         ← object level — queues, channels, topics
```

| Stanza | File | Scope |
|---|---|---|
| `ApiExitCommon` | `mqs.ini` | every queue manager on the host |
| `ApiExitLocal` | `qm.ini` | this queue manager only |

If a host runs QM1, QM2, and QM3:
- An `ApiExitCommon` in `mqs.ini` intercepts `MQPUT`/`MQGET` on all three
- An `ApiExitLocal` in `QM1/qm.ini` intercepts only QM1's traffic

### Where exits fit vs other IBM MQ configuration

```
mqs.ini
  └── ApiExitCommon        ← exit applied to all QMs on this host

qm.ini
  └── ApiExitLocal         ← exit applied to this QM only
  └── Log                  ← logging config
  └── TCP                  ← listener port
  └── Channels             ← channel defaults

MQSC (runmqsc)
  └── ALTER QLOCAL PROPCTL ← queue attribute
  └── ALTER CHANNEL        ← channel config
  └── DEFINE TOPIC         ← pub/sub
```

These are not queue configuration — they are queue manager runtime configuration
that affects how the MQ API behaves for every application connected to the QM.
Queue configuration (PROPCTL, MAXDEPTH, etc.) is separate and done via MQSC.

### When to use which

- **`ApiExitCommon`** — shared MQ platform where you want to enforce tracing across
  every queue manager without touching each one's `qm.ini`. One entry covers the
  whole host.
- **`ApiExitLocal`** — instrument only specific queue managers. A QM running payment
  processing gets the tracing exit; a QM running admin tooling does not.

This lab uses `ApiExitLocal` in `qm.ini` because we have one queue manager (QM1)
and want explicit control over what gets instrumented.

---

## What is the role of the queue manager? `#ibmmq`

The queue manager (QM) is the core runtime process of IBM MQ — everything goes
through it.

### What it owns and manages

```
Queue Manager (QM1)
  ├── Queues       DEV.QUEUE.1, DEV.QUEUE.2, DEV.QUEUE.3, DEV.DEAD.LETTER.QUEUE
  ├── Channels     DEV.APP.SVRCONN  (applications connect via this)
  ├── Listeners    port 1414        (accepts incoming TCP connections)
  ├── Auth records who can connect, who can put/get on which queue
  └── Exits        ApiExitLocal — loaded and run by the QM on every API call
```

### What it does at runtime

- Applications do not connect to a queue — they connect to the **queue manager**,
  then address a queue by name
- The QM receives `MQPUT` calls, stores the message durably (on disk if persistent),
  and holds it until a consumer calls `MQGET`
- It enforces message delivery guarantees: ordering, persistence, transactions
- It enforces `PROPCTL` on each queue — stripping or preserving MQRFH2 on delivery
- It runs API exits before/after every `MQPUT`/`MQGET`
- It moves messages between queue managers via channels (MCA — Message Channel Agents)

### In this lab

```
gateway     → MQCONN(QM1) → MQPUT(DEV.QUEUE.1)
validator   → MQCONN(QM1) → MQGET(DEV.QUEUE.1) → MQPUT(DEV.QUEUE.2)
enricher    → MQCONN(QM1) → MQGET(DEV.QUEUE.2) → MQPUT(DEV.QUEUE.3)
processor   → MQCONN(QM1) → MQGET(DEV.QUEUE.3)
dlq-handler → MQCONN(QM1) → MQGET(DEV.DEAD.LETTER.QUEUE)
```

All five services connect to the same QM1. The queue manager is the single point
through which every message passes — which is exactly why `PROPCTL` and
`ApiExitLocal` are configured there rather than in each application.

---

## Why would Instana use ApiExitLocal — does it help with baggage and context propagation? `#ibmmq` `#o11y`

For baggage and context propagation specifically, it is overkill. Instana's API
exit solves a different problem: **connecting traces across MQ when you cannot
touch the application code**. It injects and extracts Instana's own trace headers
automatically, which is useful for getting end-to-end visibility in a legacy estate.

But it does not help with W3C baggage propagation for three reasons:

- **Baggage still requires the application** — the exit cannot carry `bsi.ep`,
  `bsi.cj`, or any business context because that information only exists inside
  the application. The exit sees raw `MQPUT`/`MQGET` calls, not HTTP requests or
  application state.
- **Proprietary header format** — Instana uses its own trace headers, not W3C
  `traceparent`. It only works end-to-end if every service in the chain also runs
  an Instana agent. Mixed environments (some OTel, some Instana) break the chain.
- **Vendor-locked backend** — connected traces appear in Instana's backend, not in
  Tempo or any OTel-compatible system.

### When Instana's exit is actually useful

- Uninstrumented legacy apps (COBOL, C) you cannot modify
- Already all-in on Instana as the APM backend
- Need trace connectivity only — no business baggage required

### When it is not useful

- You want W3C-standard `traceparent`/`baggage`
- You need business context (`bsi.ep`, `bsi.cj`) on spans
- Your backend is OTel-compatible (Tempo, Jaeger, Grafana)
- You control the application code and can add the OTel SDK

For any greenfield service you control, the OTel SDK approach is the right answer.
The exit is an enterprise legacy integration tool, not a context propagation strategy.

---

## Instana supports OpenTelemetry — can we use it alongside Tempo? `#o11y`

Yes, and that changes the picture significantly. Instana added OTLP ingestion, so
the OTel Collector can fan out the same span stream to both backends:

```
Services (OTel SDK)
    │
    │ OTLP
    ▼
OTel Collector
    ├──► Tempo      (Grafana queries)
    └──► Instana    (alerting, dashboards, Instana-specific features)
```

In this setup services use the OTel SDK — inject/extract W3C `traceparent`, build
baggage, stamp `bsi.ep` on every span. Both Tempo and Instana receive the same spans
with full business context. Instana's API exit becomes irrelevant for any service
running the OTel SDK — the SDK already handles inject/extract, adding the exit would
be double instrumentation.

### Mixed estate reality

In a large enterprise some services have the OTel SDK, others are legacy apps that
cannot be modified:

```
Legacy COBOL app  →  Instana API exit  →  traceparent only, no baggage
Java service      →  OTel SDK          →  traceparent + baggage on every span
                                               │
                                         OTel Collector
                                               ├──► Tempo
                                               └──► Instana
```

Both ends appear in Instana, correlated via trace ID. But the COBOL spans have no
`bsi.ep` (the exit cannot supply it) while the Java spans do. Metric queries by
business dimension only work for the instrumented side.

### Practical conclusion

OTel SDK + Collector is the right foundation. Instana as a backend is just another
Collector exporter — add it with one extra `exporters:` block in
`otel-collector/config.yaml`. The API exit is a fallback for the parts of the
estate you cannot reach with the SDK.

---

## Why would we generate a traceparent inside otel_exit.c? `#ibmmq` `#o11y`

Only when the producer has no OTel SDK and never calls `inject()`.

Without the exit, a legacy producer (COBOL, C, uninstrumented Java) puts a message
with no `traceparent`. The consumer's `extract()` finds nothing and starts an orphan
trace — the downstream pipeline runs but is invisible and disconnected from any origin:

```
COBOL app → MQPUT (no traceparent) → validator extract() → finds nothing → orphan trace
                                      enricher  extract() → finds nothing → orphan trace
                                      processor extract() → finds nothing → orphan trace
```

With the exit generating a `traceparent` at the MQPUT boundary:

```
COBOL app → MQPUT → exit injects traceparent → validator extract() → finds T1 → linked
                                                enricher  extract() → finds T1 → linked
                                                processor extract() → finds T1 → linked
```

The downstream pipeline becomes one connected trace instead of three orphans. You can
see what happened after the message entered the queue, even if you cannot see what
triggered the MQPUT.

### The important caveat

The traceparent generated by the exit is a new root trace — it starts at the MQ
boundary, not at the business origin. Nothing before `MQPUT` is connected. You get
pipeline visibility but not end-to-end visibility.

### For this lab

Irrelevant. Gateway already calls `inject()` via `JmsCarrier`. The exit code checks
for an existing `traceparent` and skips if found — it would never generate one here
because the SDK always gets there first. The generate path only activates for
producers that arrive at the queue with an empty `<usr>` folder.
