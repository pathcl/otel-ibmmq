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

## What does the TraceQL syntax look like for querying by tenant? `#o11y`

```
{ span.tenant.id = "acme" }
```

Unscoped (matches span or resource attributes):
```
{ .tenant.id = "acme" }
```

`span["tenant.id"]` is not valid TraceQL — it returns HTTP 400.
