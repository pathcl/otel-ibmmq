# Staff SRE Checklist: Baggage & Context Propagation over IBM MQ

**Audience**: Staff SRE preparing to instrument a system where IBM MQ sits in the
middle of a distributed trace chain, without direct access to the MQ environment
or the producer/consumer codebases.

**Goal**: Arrive at team meetings with a precise picture of what each team owns,
what they need to implement, and what the infrastructure team needs to verify —
so no time is spent on discovery that could have been done beforehand.

> **See also:** `baggage-ibmmq-checklist.md` — use that file when you are
> hands-on implementing or debugging a single JMS/Java mid-chain service.
> It has implementation steps, the extract/inject pattern, silent bugs table,
> and a running Q&A log. This file is for cross-team coordination before meetings.

---

## How to use this document

Work through **Section 1** alone before any meeting. Bring the output of
**Section 2** into the first meeting with each team. Use **Sections 3–5** to
assign work. Use **Section 6** to close the loop without needing environment
access yourself.

---

## Section 1 — Pre-meeting discovery (no environment access needed)

These questions can be answered from source code, CI pipelines, dependency
manifests, or a brief async message to each team's tech lead.

### 1.1 Architecture topology

- [ ] Draw the full message path: what systems sit upstream and downstream of IBM MQ?
- [ ] Is IBM MQ at the **start** of the chain, the **end**, or **mid-chain**?
      - Mid-chain = a system upstream of the producer already holds a trace context
      - This checklist assumes mid-chain; adjust if it is at the start
- [ ] How many distinct producer services send to MQ? List them.
- [ ] How many distinct consumer services read from MQ? List them.
- [ ] Are there intermediate stages (pipeline queues, enrichers, validators)?
      List each queue and the service that reads it.
- [ ] Are there Dead Letter Queues? Which service handles them?
- [ ] Does any message cross a **Queue Manager boundary** (cluster, federation,
      remote queue definition)?
- [ ] Is any MQ → external bridge in use (MQ Kafka Connect, MQ Bridge for HTTP,
      AMQP channel, MQTT channel)?

### 1.2 API and language identification

For each service in the message path, answer:

- [ ] Which **IBM MQ API** does it use?

  | API | How to identify |
  |-----|----------------|
  | JMS | `javax.jms.*` or `jakarta.jms.*` imports; `pom.xml` has `com.ibm.mq:com.ibm.mq.allclient` |
  | XMS (.NET) | `IBM.XMS` NuGet package |
  | Native MQI — Go | `github.com/ibm-messaging/mq-golang` in `go.mod` |
  | Native MQI — Python | `pymqi` in `requirements.txt` |
  | Native MQI — C/C++ | `#include <cmqc.h>` |
  | Native MQI — Node.js | `ibmmq` in `package.json` |
  | REST API | HTTP calls to `/ibmmq/rest/v2/…` |
  | AMQP 1.0 | AMQP client library (e.g. `qpid-proton`, `azure-servicebus`) |
  | MQTT | MQTT client library; check for `mqtt` or `paho` |

- [ ] Which **language and runtime** does each service run on?
- [ ] Is an **OTel SDK** already present in the service?
      Check `pom.xml`, `go.mod`, `requirements.txt`, `package.json`.
- [ ] Is the **OTel Java Agent** (`-javaagent:opentelemetry-javaagent.jar`) on
      the JVM startup flags for any Java service?

### 1.3 Existing observability

- [ ] Does any service already export traces? To which backend (Tempo, Jaeger,
      Zipkin, Datadog, …)?
- [ ] Is a shared OTel Collector deployed, or does each service export directly?
- [ ] Is Prometheus or any metrics backend receiving
      `traces_service_graph_request_total` metrics?
- [ ] Is W3C `traceparent` already present anywhere in message headers or
      JMS properties? (`grep -r "traceparent"` in each repo)
- [ ] Is W3C `baggage` already present? (`grep -r "baggage"`)

### 1.4 IBM MQ infrastructure configuration

Request these answers from the MQ admin team (they do not require you to have
access):

- [ ] What is the **PROPCTL** setting on each queue and channel?
      - `PROPCTL(ALL)` — properties (MQRFH2 `<usr>`) flow through unchanged ✓
      - `PROPCTL(FORCE)` — properties stripped; context propagation will fail ✗
      - `PROPCTL(COMPAT)` — depends on message format; verify per queue
- [ ] Are any queues defined with `MSGDLVSQ(FIFO)` or `MSGDLVSQ(PRIORITY)`?
      (Ordering affects competing-consumer tracing but not propagation itself.)
- [ ] Does any channel use **message conversion** (`CONVERT(YES)`)? This can
      strip MQRFH2 headers.
- [ ] For remote queues / clusters: does `PROPCTL` on the remote queue
      definition match the local setting?
- [ ] For DLQ: what format are messages in when they arrive on the DLQ?
      IBM MQ prepends an `MQDLH` header before the original message — the
      original MQRFH2 may be intact after it.

---

## Section 2 — Implementation complexity by API

Use this table to brief each team on what they are signing up for before the
implementation meeting.

| API | Carrier complexity | Auto-instrumentation | Estimated effort |
|-----|--------------------|---------------------|-----------------|
| JMS + OTel Java Agent | None — agent handles it | **Full** | < 1 day: add agent, configure exporter |
| JMS + manual OTel SDK | Low — `setStringProperty` / `getStringProperty` | None | 1–2 days |
| XMS (.NET) | Low — same as JMS | Partial (OTel .NET contrib) | 1–3 days |
| MQI — Node.js | Low — `GetMessageProperty` / `SetMessageProperty` | None | 1–2 days |
| MQI — Go | **High** — manual MQRFH2 binary parse + build | None | 3–5 days |
| MQI — Python | **High** — manual MQRFH2 binary parse + build | None | 3–5 days |
| MQI — C/C++ | **High** — MQRFH2 struct manipulation | None | 5–8 days |
| REST API | Low (HTTP headers) — but context lost on re-queue | Yes (HTTP instrumentation) | 1 day + risk assessment |
| AMQP 1.0 | Low — `application-properties` map | None | 1–2 days |
| MQTT 5 | Low — User Properties | None | 1–2 days |
| MQTT 3.1.1 | **Breaking** — requires payload modification | None | Reject; upgrade to MQTT 5 |

---

## Section 3 — Per-API implementation checklist

### 3A. JMS — OTel Java Agent (recommended if already on JVM)

This is the zero-code path. The agent intercepts `MessageProducer.send` and
`MessageConsumer.receive` / `onMessage` automatically.

**Producer team checklist:**
- [ ] Confirm JVM startup includes `-javaagent:opentelemetry-javaagent.jar`
- [ ] Set `OTEL_EXPORTER_OTLP_ENDPOINT` to point to the shared collector
- [ ] Set `OTEL_SERVICE_NAME` to a stable, meaningful service name
- [ ] Set `OTEL_PROPAGATORS=tracecontext,baggage` (W3C composite propagator)
- [ ] Confirm agent version ≥ 1.26 (JMS 2 auto-instrumentation stable from this version)
- [ ] Verify `PROPCTL(ALL)` on the target queue (agent cannot override this)

**Consumer team checklist:**
- [ ] Same agent + exporter + service name configuration
- [ ] Confirm `MessageListener.onMessage` or `MessageConsumer.receive` is used
      (both are instrumented; `receiveNoWait` is also covered)
- [ ] Verify the span created by the agent carries `tenant.id` and other
      baggage entries as span attributes (check in Tempo after first test)

**If baggage entries are NOT automatically added as span attributes:**
- [ ] Add a `SpanProcessor` that reads baggage and copies entries to span
      attributes (the agent does not do this by default):
  ```java
  // Add to agent extension or as SDK config
  Baggage.current().forEach((key, entry) ->
      span.setAttribute(key, entry.getValue()));
  ```

---

### 3B. JMS — Manual OTel SDK

Use when the Java agent is not an option (OSGi containers, restricted JVM flags,
existing SDK already initialised).

**Producer team checklist:**
- [ ] OTel SDK dependency present (`io.opentelemetry:opentelemetry-sdk`)
- [ ] `TracerProvider` initialised and registered as global
- [ ] Composite propagator configured: `W3CTraceContextPropagator` + `W3CBaggagePropagator`
- [ ] `TextMapSetter` implementation that calls `message.setStringProperty(key, value)`
- [ ] On produce: `propagator.inject(Context.current(), message, setter)` called
      **after** span is started and **before** `producer.send(message)`
- [ ] Span kind set to `PRODUCER`
- [ ] `messaging.system = "ibmmq"` and `messaging.destination.name = <queue>`
      set as span attributes

**Consumer team checklist:**
- [ ] `TextMapGetter` implementation that calls `message.getStringProperty(key)`
      and returns `null` (not empty string) when property is absent
- [ ] On consume: `propagator.extract(Context.current(), message, getter)` called
      **before** starting the child span
- [ ] Child span started with `.setParent(extractedContext)`
- [ ] Span kind set to `CONSUMER`
- [ ] `message.acknowledge()` or session commit happens **inside** the span scope

**Shared checklist:**
- [ ] JMS property names for `traceparent`, `tracestate`, `baggage` do not
      contain hyphens (JMS forbids hyphens in property names) — use a carrier
      that maps `traceparent` → `traceparent` (underscores are safe; hyphens
      are not). Verify the carrier implementation handles this.
      See [03-jms-carrier.md](03-jms-carrier.md).
- [ ] `PROPCTL(ALL)` verified on queue and channel
- [ ] Integration test: send one message end-to-end, confirm single trace in
      Tempo with producer and consumer spans linked

---

### 3C. XMS (.NET)

- [ ] OTel .NET SDK present (`OpenTelemetry`, `OpenTelemetry.Exporter.OpenTelemetryProtocol`)
- [ ] Check NuGet for an IBM MQ contrib instrumentation package; as of 2024 none
      is in `opentelemetry-dotnet-contrib` — manual carrier required
- [ ] `TextMapCarrier` implemented over `IMessage`:
  ```csharp
  // Setter
  (msg, key, val) => msg.SetStringProperty(key, val)
  // Getter
  (msg, key) => msg.GetStringProperty(key)
  ```
- [ ] Same extract-before-consume / inject-after-start pattern as JMS
- [ ] Property name constraints: same hyphen restriction as JMS applies to XMS

---

### 3D. Native MQI — Node.js

- [ ] `opentelemetry-api` and `opentelemetry-sdk-node` present in `package.json`
- [ ] `MQI.GetMessageProperty(hConn, hObj, msg, propertyName)` available in
      the `ibmmq` version in use (check docs for version)
- [ ] Carrier implementation:
  ```js
  const getter = { get: (msg, key) => mq.GetMessageProperty(hObj, msg, key) };
  const setter = { set: (msg, key, val) => mq.SetMessageProperty(hObj, msg, key, val) };
  ```
- [ ] `MQINQMP` / `MQSETMP` used for individual property get/set (prefer over
      full MQRFH2 parse)
- [ ] Confirm `MQGMO_PROPERTIES_IN_HANDLE` is set on `MQGMO` at get time so
      properties are accessible via the property handle API

---

### 3E. Native MQI — Go

High effort. No existing OTel contrib library. Requires custom MQRFH2 carrier.

**Pre-implementation questions to ask the Go team:**
- [ ] Do they use `github.com/ibm-messaging/mq-golang` (ibmmq package)?
- [ ] Which version? Property handle API (`MQSETMP`/`MQINQMP`) is available in
      recent versions and avoids full MQRFH2 binary parsing.
- [ ] Is the message format `MQFMT_RF_HEADER_2` or `MQFMT_STRING`?
      `MQFMT_STRING` messages have no MQRFH2 and cannot carry properties without
      format change — a breaking change to the message contract.

**If property handle API is available (preferred):**
- [ ] Use `MQSETMP` to set `traceparent`, `tracestate`, `baggage` as string
      properties on the message before `MQPUT`
- [ ] Use `MQINQMP` to read them after `MQGET` with `MQGMO_PROPERTIES_IN_HANDLE`
- [ ] Implement `TextMapCarrier` over these two calls

**If property handle API is not available (full MQRFH2 path):**
- [ ] Implement MQRFH2 parser: read fixed header (36 bytes), then iterate XML
      `<folder>…</folder>` blocks, extract `<usr>` folder key-value pairs
- [ ] Implement MQRFH2 builder: serialise updated `<usr>` folder back to binary,
      recalculate `StrucLength` field
- [ ] Implement `TextMapCarrier` over the parsed map
- [ ] Ensure `MQMD.Format` is set to `MQFMT_RF_HEADER_2` on outbound message
- [ ] Unit test the parser with a captured raw MQ message (hex dump from MQ
      admin team) before touching the real queue

**Shared Go checklist:**
- [ ] OTel SDK: `go.opentelemetry.io/otel`, `otlptracegrpc`, `sdk` added to `go.mod`
- [ ] Composite propagator registered:
  ```go
  otel.SetTextMapPropagator(
      propagation.NewCompositeTextMapPropagator(
          propagation.TraceContext{},
          propagation.Baggage{},
      ))
  ```
- [ ] `PROPCTL(ALL)` on queue — the Go service cannot set this itself

---

### 3F. Native MQI — Python

Same complexity as Go. No OTel contrib library.

- [ ] `pymqi` version supports `MQINQMP` / `MQSETMP` (check pymqi changelog)
      If not, full MQRFH2 parse required (see Go section above for approach)
- [ ] `opentelemetry-sdk` present in `requirements.txt`
- [ ] Composite propagator registered:
  ```python
  from opentelemetry.propagators.composite import CompositePropagator
  from opentelemetry.propagators.b3 import B3Format  # if needed
  from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
  from opentelemetry.baggage.propagation import W3CBaggagePropagator

  set_global_textmap(CompositePropagator([
      TraceContextTextMapPropagator(),
      W3CBaggagePropagator(),
  ]))
  ```
- [ ] Carrier implemented as a dict populated from `MQINQMP` calls

---

### 3G. AMQP 1.0 Channel

- [ ] IBM MQ AMQP channel is enabled and configured on the Queue Manager
      (request confirmation from MQ admin)
- [ ] Verify IBM MQ maps AMQP `application-properties` → MQRFH2 `<usr>` in
      both directions (this is the default; `PROPCTL(ALL)` still applies)
- [ ] AMQP client library in use identified (e.g. `qpid-proton`, `rhea` for
      Node, `azure-servicebus` SDK)
- [ ] Carrier implementation over `message.application_properties` dict:
  ```python
  # qpid-proton example
  carrier = message.properties or {}
  ctx = propagator.extract(carrier)
  propagator.inject(carrier)
  message.properties = carrier
  ```
- [ ] Check whether the AMQP library adds a `content-type` that forces the MQ
      channel to convert format (would strip MQRFH2)

---

### 3H. MQTT 5

- [ ] Confirm broker/channel supports MQTT 5 (not 3.1.1)
- [ ] MQTT client library supports User Properties (e.g. `paho-mqtt` ≥ 1.6,
      `aiomqtt` ≥ 1.0, `mqtt.js` ≥ 4.3)
- [ ] Carrier over User Properties:
  ```python
  # publish
  props = Properties(PacketTypes.PUBLISH)
  props.UserProperty = [("traceparent", tp), ("baggage", bag)]
  client.publish(topic, payload, properties=props)

  # subscribe callback
  carrier = dict(msg.properties.UserProperty)
  ctx = propagator.extract(carrier)
  ```
- [ ] IBM MQ maps MQTT 5 User Properties to MQRFH2 `<usr>` folder
      (verify with MQ admin; requires MQ 9.2+)

---

## Section 4 — Messaging pattern checklist

Beyond the API, each messaging pattern has its own propagation requirements.

### 4.1 Point-to-Point Queue

- [ ] Single extract on consume, single inject on produce
- [ ] Message format `MQFMT_RF_HEADER_2` preserved end-to-end
- [ ] No intermediate queue strips format (verify with MQ admin for each hop)

### 4.2 Pub/Sub Topic

- [ ] Each subscriber independently extracts from its copy of the message
- [ ] If subscriber also publishes: inject into each outbound message
      (same baggage, new `traceparent` with child span-id)
- [ ] Fan-out: N outbound messages → N child spans, all under the same parent

### 4.3 Pipeline (sequential queues)

- [ ] Every intermediate service in the pipeline must extract AND inject
      (not just the first and last)
- [ ] Verify no stage converts the message to `MQFMT_STRING` (drops MQRFH2)
- [ ] Map every stage: queue name → service → next queue → service
- [ ] Each stage owns its own span; the full chain appears as a trace waterfall

### 4.4 Competing Consumers

- [ ] Each consumer instance independently extracts — no coordination needed
- [ ] All consumer instances share the same `OTEL_SERVICE_NAME` so they appear
      as one logical service in the service graph
- [ ] Verify no consumer re-puts the message to the same queue on failure
      without carrying the original context (creates orphan spans)

### 4.5 Request-Reply

- [ ] Producer injects context into request message
- [ ] Responder extracts context from request, creates child span, injects
      context into reply message (use same trace, new child span)
- [ ] Confirm whether `JMSCorrelationID` is used for correlation — it is
      **not** a substitute for `traceparent` (different purposes)
- [ ] If reply-to queue is temporary (dynamic): verify MQRFH2 is preserved on
      temporary queues (default yes, but check `PROPCTL` on the model queue)

### 4.6 Dead Letter Queue

- [ ] DLQ handler must check for `MQDLH` header prepended by IBM MQ
      (24 bytes fixed; original message follows including original MQRFH2)
- [ ] Extract context from the **original** MQRFH2 (after `MQDLH`), not from
      the `MQDLH` fixed header itself
- [ ] DLQ handler span tagged with `error=true` and original failure reason
- [ ] On retry (re-put to original queue): inject **fresh** context (new span)
      so the retry appears as a distinct child, not as a replay of the failed span

### 4.7 Queue Manager Clustering / Federation

Request from MQ admin:
- [ ] `PROPCTL(ALL)` set on the remote queue definition (not just the local queue)
- [ ] No inter-QM channel with `CONVERT(YES)`
- [ ] For cluster queues: `PROPCTL` on the cluster queue definition

### 4.8 MQ → External Bridge

| Bridge | What to verify |
|--------|---------------|
| MQ Kafka Connect | `MQ.MESSAGE.BODY.JMS=true` config preserves MQRFH2 → Kafka headers |
| MQ Bridge for HTTP | Field mapping config explicitly maps `traceparent`, `baggage` |
| AMQP channel | `PROPCTL(ALL)` on the AMQP channel definition |
| Custom bridge service | Treat as a regular mid-chain service — apply Section 3 |

For any bridge that does **not** automatically map properties: insert a thin
mediator service that reads from MQ, extracts context, re-injects into the
target format, and forwards.

---

## Section 5 — Questions to bring to each meeting

### For the producer team

1. Which IBM MQ API and language do you use? (drives Section 3 path)
2. Is the OTel SDK already initialised in your service? If not, is there an
   approved SDK or agent?
3. Do you already set any message-level properties (e.g. correlation ID, tenant
   ID)? How? We need to co-locate context headers with those.
4. Is the message format fixed (schema, Avro, Protobuf)? Can we add MQRFH2
   properties alongside the body without breaking downstream consumers?
5. Who owns the deployment pipeline? How long does a config change
   (e.g. adding a JVM agent flag) take to reach production?

### For each pipeline / intermediate stage team

1. Do you both consume from one queue and produce to another, or only one of
   those?
2. Do you forward the message body unchanged, or rebuild it?
3. Do you copy any existing message properties across (correlation ID, etc.)?
   You will need to also copy `traceparent`, `tracestate`, `baggage`.
4. Do you use transactional sessions? If so, does the span end before or after
   commit?

### For the consumer team

1. Do you acknowledge messages immediately on receipt, or after processing?
   The span should end after acknowledge/commit, not before.
2. Do you ever re-put a message (e.g. retry logic)? With or without the
   original properties?
3. Do you have a DLQ? Who handles it?

### For the MQ admin team

1. What is `PROPCTL` set to on each queue in the message path?
2. Do any channels have `CONVERT(YES)` or format-stripping settings?
3. For remote queues / clusters: what is `PROPCTL` on the remote queue
   definition?
4. Is MQRFH2 format (`MQFMT_RF_HEADER_2`) in use today, or are queues
   receiving `MQFMT_STRING` messages?
5. For AMQP/MQTT channels: which MQ version is running?
   (MQTT 5 User Property mapping requires MQ 9.2+)
6. Can you provide a hex dump of a sample message from each queue?
   (Required for teams that need to build an MQRFH2 parser)

---

## Section 6 — Verification without environment access

You cannot run commands against the queues, but you can verify correctness
through artifacts each team can produce.

### 6.1 Trace verification

Ask each team to run:
```bash
curl -X POST <entry-point-url> \
  -H "X-Tenant-ID: sre-test" \
  -H "X-User-ID: sre-probe"
```
Then query Tempo / Jaeger with:
```
{ resource.service.name =~ ".+" && span.tenant.id = "sre-test" }
```

Expected: a **single trace** containing one span per service in the chain,
all with the same `trace-id`. Any break in the chain (missing `traceparent`
on an MQ hop) produces orphan spans with separate `trace-id`s.

### 6.2 Baggage verification

In the consumer (or any intermediate span), the following attributes must be
present:
```
tenant.id = "sre-test"
user.id   = "sre-probe"
```

If they are missing, the consumer is not reading baggage from context — it may
be extracting `traceparent` but not the `baggage` header (check that the
composite propagator includes `W3CBaggagePropagator`).

### 6.3 PROPCTL verification (MQ admin)

Ask the MQ admin to run:
```
DISPLAY QMGR PROPCTL
DISPLAY QLOCAL(*) PROPCTL
DISPLAY CHANNEL(*) PROPCTL
```
Expected output: `PROPCTL(ALL)` for the queue manager, every queue, and every
channel in the path. `PROPCTL(FORCE)` or `PROPCTL(COMPAT)` with `MQFMT_STRING`
messages = context will not flow.

If the queue manager default is not `ALL`, ask the MQ admin to set it so every
new queue inherits the correct value automatically:
```
ALTER QMGR PROPCTL(ALL)
```
Note: this only applies to queues created after the change. All existing queues
must be audited and fixed individually with `ALTER QLOCAL(<name>) PROPCTL(ALL)`.
Do not forget the DLQ — context is most valuable when debugging failures.

### 6.4 MQRFH2 format check

Ask the MQ admin or producer team to capture a raw message (MQ admin `amqsbcg`
tool) and confirm:
```
Message Descriptor:
  Format : 'MQHRF2  '   ← must be this, not 'MQSTR   '
```
`MQSTR` format means no MQRFH2, no properties, no context propagation possible
without a message format change.

### 6.5 Service graph check (if otel-mq-app or similar plugin available)

Once traces flow, the service graph should show an edge for each queue hop.
Missing edges = broken propagation on that hop. The error-rate arc segments
show if DLQ re-routing is inflating error rates.

---

## Section 7 — Risk matrix

| Scenario | Risk | Mitigation |
|----------|------|-----------|
| Any queue with `PROPCTL(FORCE)` | **Blocker** — all properties stripped | Change to `PROPCTL(ALL)`; requires MQ admin + change management |
| `MQFMT_STRING` messages | **Blocker** — no MQRFH2, no properties | Change producer to set `MQFMT_RF_HEADER_2`; breaking change for consumers that parse format |
| Native MQI (Go/Python/C) without property handle API | High effort — manual MQRFH2 binary parsing | Negotiate timeline; provide reference MQRFH2 parser; consider thin JMS wrapper service |
| MQTT 3.1.1 | **Blocker** — no header mechanism without payload modification | Upgrade to MQTT 5 or add a gateway service |
| DLQ handler missing extract/inject | Silent trace break on failures | Treat DLQ handler as a full mid-chain service — apply Section 3 |
| Inter-QM channel with `CONVERT(YES)` | Properties stripped on queue manager boundary | Set `CONVERT(NO)`; test with `amqsbcg` on receiving QM |
| Missing `W3CBaggagePropagator` in composite propagator | `traceparent` flows but baggage is lost | Check propagator config on every service; easy fix once identified |
| JMS property name with hyphen (`traceparent` → `trace-parent`) | Properties silently dropped by JMS broker | Use hyphen-free property names in carrier; map at carrier boundary |
| Span ends before message acknowledge / transaction commit | Span timing wrong; errors not captured | Move `span.end()` to finally block after commit/ack |

---

## Section 8 — Escalation triggers

Stop and escalate to the MQ platform team if:

- `PROPCTL` cannot be changed (change freeze, audit requirement) — you need an
  alternative propagation channel (e.g. embed context in message body as a
  header field, agreed with all teams)
- Message format is `MQFMT_STRING` and changing it would break a downstream
  consumer that is not part of this project scope
- An inter-QM boundary is owned by a third party (partner, vendor) who cannot
  guarantee `PROPCTL(ALL)`
- Any service uses MQTT 3.1.1 and cannot upgrade on the project timeline

In all four cases the fallback is a **context bridge service**: a dedicated
thin service that consumes from the upstream queue, extracts what context it
can (even just a correlation ID), creates a new root span with the correlation
ID as a link, and produces to the downstream queue. This gives partial
observability without end-to-end trace continuity.

---

## Appendix: Implementation complexity by API (quick reference)

```
Low effort ──────────────────────────────────── High effort

JMS + agent    JMS + SDK    XMS    Node MQI    Go/Python MQI    C MQI
< 1 day        1–2 days    1–3d    1–2 days      3–5 days       5–8 days
   │               │         │         │              │              │
   ▼               ▼         ▼         ▼              ▼              ▼
 zero code    carrier impl  same    property      MQRFH2        MQRFH2
              needed        as JMS  handle API    binary        struct
                                                  parser        manip.
```

---

## Related docs

- [03-jms-carrier.md](03-jms-carrier.md) — JMS carrier implementation details
- [12-baggage-propagation-checklist.md](12-baggage-propagation-checklist.md) — scenario-level checklist (middle vs origin)
- [11-faqs.md](11-faqs.md) — pattern and language impact Q&A
