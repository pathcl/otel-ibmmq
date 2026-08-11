# IBM MQ — SRE Learning Journal

You are a Staff SRE. You know distributed systems, you know traces and metrics,
you know how to debug production. But IBM MQ is new territory. Your team owns a
pipeline that runs on it and you need to make it observable.

This journal walks you through IBM MQ from zero — not as abstract theory, but
through the lens of the question every SRE asks first: **what is actually
happening inside this system, and how do I know when it breaks?**

Companion docs:
- `ibmmq-101.md` — mental model and reference
- `baggage-ibmmq-checklist.md` — OTel propagation checklist
- `15-ibmmq-complete-guide.md` — full deep reference

---

## Chapter 1 — First contact: what is this thing?

You join the team. IBM MQ is running in production. Services are putting
messages in, other services are getting them out. You have never touched it.

First instinct as an SRE: look at the traffic. With HTTP you'd run `curl`. With
Kafka you'd run `kafka-console-consumer`. IBM MQ has its own tool: `amqsbcg`.

But before you can look at traffic, you need to understand the access model.
IBM MQ is not a network service you query from outside. It is a queue manager
process that you connect to. Everything goes through that connection.

### Get into the container

```bash
docker ps | grep mq
# copy the container id, e.g. 5606692e7d74

docker exec -it 5606692e7d74 bash
```

The sample binaries that let you interact with queues live at
`/opt/mqm/samp/bin/` — not in PATH by default. Add them:

```bash
export PATH=$PATH:/opt/mqm/samp/bin:/opt/mqm/bin
```

> **Gotcha #1:** `setmqenv -s` only adds `/opt/mqm/bin`. The sample binaries
> are in a separate directory. If `amqsput` is not found, this is why.

### See what queues exist

Connect to the queue manager and list everything:

```bash
runmqsc QM1
```

Inside `runmqsc`:

```
DISPLAY QLOCAL(*) CURDEPTH
```

This shows every local queue and how many messages are currently sitting in it.
As an SRE this is your first depth check — equivalent to checking queue lag in
Kafka. A growing `CURDEPTH` means consumers are falling behind.

Type `END` to exit.

### Create a safe queue for learning

The developer image comes with `DEV.QUEUE.1/2/3`. Do not use these for
experiments — the validator service in this lab actively consumes from
`DEV.QUEUE.1`, so any message you put there disappears immediately.

Create a dedicated queue:

```bash
runmqsc QM1 <<EOF
DEFINE QLOCAL(TEST.BROWSE) PROPCTL(ALL) REPLACE
EOF
```

`REPLACE` avoids `AMQ8150E` if the queue already exists.  
`PROPCTL(ALL)` — ignore this for now, it will matter in Chapter 3.

> **Gotcha #2:** If you get `AMQ8150E: IBM MQ object already exists`, you
> forgot `REPLACE`. IBM MQ does not upsert by default.

### Put your first message

```bash
echo "order-id:42 tenant:acme" | amqsput TEST.BROWSE QM1
```

```
Sample AMQSPUT0 start
target queue is TEST.BROWSE
Sample AMQSPUT0 end
```

The message is now sitting on the queue. Nothing has consumed it yet.

### Look at the raw message

```bash
amqsbcg TEST.BROWSE QM1
```

This is the most important command you will learn. It browses messages
non-destructively — nothing is consumed. You see the raw wire format.

Output:

```
****Message descriptor****

  StrucId  : 'MD  '  Version : 2
  Format : 'MQSTR   '
  Priority : 0  Persistence : 0
  MsgId : X'414D5120514D312020202020...'
  CorrelId : X'000000000000000000000000...'
  PutApplName    : 'amqsput'
  PutDate  : '20260809'    PutTime  : '16535984'

****   Message      ****

 length - 23 of 23 bytes

00000000:  6F72 6465 722D 6964 3A34 3220 74...   'order-id:42 tenant:acme'
```

You can see the body. But notice what is **missing**:

- Which trace does this message belong to?
- Which service put it here?
- Has this message been sitting for 2 seconds or 2 hours?
- If there are 500 messages on this queue, which one belongs to the acme tenant?

The message is anonymous. You know the bytes. You know when it was put
(`PutDate`/`PutTime`). That's it.

This is what operating IBM MQ looks like without observability.

---

## Chapter 2 — The question you cannot answer

Imagine this scenario: it's 2am. The on-call fires. DLQ has 47 messages piling
up. Your pipeline looks like this:

```
[upstream] → HTTP → [gateway] → IBM MQ → [validator] → [enricher] → [processor]
                                    ↓
                                 [DLQ handler]
```

You look at the logs:

```
validator:  ERROR processing message — NullPointerException at EnrichmentStep.java:142
enricher:   INFO  received message, forwarding
processor:  WARN  received message with missing tenant context
```

Three services, three log lines. You cannot tell:

- Did these three lines come from the **same message** or three different messages?
- Which **tenant** triggered the NullPointerException?
- How long did the failing message sit in the queue before validator picked it up?
- Is the error affecting acme, globex, or initech — or all of them?

You go to look at the message on the DLQ:

```bash
amqsbcg DEV.DEAD.LETTER.QUEUE QM1
```

You see bytes. A body. A timestamp. No tenant. No trace ID. No request ID.
Nothing that connects this message to the log lines you just read.

This is the core problem IBM MQ creates for observability: **the queue is an
async boundary that breaks your ability to correlate events across services.**

With HTTP you have a `traceparent` header that flows from service to service.
With IBM MQ, that header has nowhere to go — unless you explicitly carry it
inside the message.

---

## Chapter 3 — What context propagation adds to the message

OpenTelemetry solves this by injecting two W3C headers into the IBM MQ message
as named properties:

| Header | What it carries |
|--------|----------------|
| `traceparent` | The trace ID and span ID — connects all spans into one trace |
| `baggage` | Business context — tenant, user ID, order type |

These live in the **MQRFH2** header — a structured properties folder that IBM MQ
attaches to the message body. `amqsbcg` cannot produce this — it is a plain C
program that always sets `MQSTR` format. You need a real JMS producer with OTel
`inject()` called. This lab's gateway service does exactly that.

### See it on the wire

The trick is to pause the validator so it does not consume the message before
you can browse it. Stop it, send a message, browse, then restart:

```bash
# 1. Stop the validator
docker stop <validator-container-id>

# 2. Send a message through the upstream → gateway pipeline
curl -X POST http://localhost:8081/order \
  -H "X-bsi-ep: acme" \
  -H "X-bsi-ch: user42"

# 3. Browse the queue — message is sitting there, nobody consuming it
docker exec <mq-container-id> /opt/mqm/samp/bin/amqsbcg DEV.QUEUE.1 QM1

# 4. Restart the validator
docker start <validator-container-id>
```

> To find container IDs: `docker ps | grep -E 'validator|mq'`

### What you will see

Compare this with the `amqsput` output from Chapter 1:

**Chapter 1 — amqsput (no OTel):**

```
  Format : 'MQSTR   '          ← plain string, MQRFH2 discarded

****   Message      ****
 length - 14 of 14 bytes
00000000:  6865 6C6C 6F20 6672 6F6D 206C 6162   'hello from lab'
```

**Chapter 3 — gateway with OTel inject() (actual output from this lab):**

```
  Format : 'MQHRF2  '          ← MQRFH2 present, properties intact
  PutApplName : 'app.jar'      ← gateway service, not amqsput

****   Message      ****
 length - 326 of 326 bytes

00000000:  5246 4820 ...                        'RFH ......'   ← MQRFH2 header starts here
000000A0:  3C75 7372 3E3C 6261 6767 6167 653E   '<usr><baggage>'
000000B0:  74 65 6E61 6E74 2E69 643D 6163 6D65  'bsi.ep=acme,'
000000C0:  2C75 7365 722E 6964 3D75 7365 7234 32 'bsi.ch=user42'
000000D0:  3C2F 6261 6767 6167 653E             '</baggage>'
000000D0:  3C74 7261 6365 7061 7265 6E74 3E     '<traceparent>'
000000E0:  3030 2D35 3235 3261 6264 3862 3835   '00-5252abd8b85'
         ...                                    '544948008007c88d'
         ...                                    'e2aad-ebd9d88035'
         ...                                    'b29b9d-01'
         ...                                    '</traceparent></usr>'
00000130:  6F72 6465 7220 6672 6F6D ...         'order from tenant=acme'
```

The `<usr>` folder is readable directly in the hex dump. No special tool needed —
`amqsbcg` on the raw queue shows you everything OTel injected.

The message is no longer anonymous. Now you can answer:

- **Which trace?** — `5252abd8b85544948008007c88de2aad`. Query Tempo for it.
- **Which tenant?** — `acme`. Scope your investigation immediately.
- **Which user?** — `user42`. Cross-reference with your application logs.
- **Connected spans?** — every service that extracts this context and sets it as
  the parent will appear as a child span in the same trace.

### How this works mechanically

When the gateway (producer) puts a message, it calls:

```java
TextMapPropagator propagator = openTelemetry.getPropagators().getTextMapPropagator();
propagator.inject(Context.current(), jmsMessage, JmsCarrier.SETTER);
```

This writes `traceparent` and `baggage` as JMS message properties. JMS maps
these to MQRFH2 properties inside the `<usr>` folder. The format field in MQMD
becomes `MQHRF2` — not `MQSTR` — which tells IBM MQ to preserve the header.

When the validator (consumer) gets the message, it calls:

```java
Context extractedCtx = propagator.extract(Context.root(), jmsMessage, JmsCarrier.GETTER);
Span span = tracer.spanBuilder("validator.handle")
    .setParent(extractedCtx)
    .startSpan();
```

The span is now a child of the producer's span. The async boundary is bridged.

### Verify end-to-end in Tempo

Take the trace ID from the `<traceparent>` field you saw in `amqsbcg`. Go to
Grafana Explore → Tempo and query:

```
{ span.bsi.ep = "checkout" }
```

You will find the trace. The span tree will show:

```
upstream.order (root)
  └── gateway.send (PRODUCER)
        └── validator.handle
              └── enricher.handle
                    └── processor.handle (CONSUMER)
```

Five services, one trace, zero ambiguity. This is what context propagation
enables across an IBM MQ boundary.

---

## Chapter 4 — PROPCTL: the hidden gatekeeper

Now that you understand what context propagation looks like, you need to
understand how easily it can be silently destroyed.

IBM MQ queues have a property called `PROPCTL` (property control) that
determines whether the MQRFH2 header is delivered to the consuming application
when it does MQGET. There are three values:

| Value | Behaviour |
|-------|-----------|
| `ALL` | Consumer receives the full MQRFH2 including the `<usr>` folder |
| `COMPAT` | Consumer receives MQRFH2 only if the message was originally put with one (legacy default) |
| `NONE` | MQRFH2 is stripped before delivery — consumer sees no properties |

**Every queue in the propagation path needs `PROPCTL(ALL)`** — not just the
first one. If QUEUE.ENRICH has the wrong value, the enricher's MQGET delivers
no properties, OTel extract() returns empty context, and everything downstream
is an orphan trace. The message is still delivered. The system still runs.
Nothing in the logs tells you what happened.

**Set a queue manager default first** so every new queue inherits it:

```
runmqsc QM1
ALTER QMGR PROPCTL(ALL)
```

Then audit existing queues — anything already created before this change keeps
its old value:

```
DISPLAY QLOCAL(*) PROPCTL
```

Fix anything not showing `ALL`:

```
ALTER QLOCAL(QUEUE.IN) PROPCTL(ALL)
ALTER QLOCAL(QUEUE.ENRICH) PROPCTL(ALL)
ALTER QLOCAL(QUEUE.PROC) PROPCTL(ALL)
ALTER QLOCAL(DEV.DEAD.LETTER.QUEUE) PROPCTL(ALL)
```

Do not forget the DLQ. That is where you will need context the most.

If messages cross queue manager boundaries via channels, channels need
`PROPCTL(ALL)` too — same property, same fix.

### See it break

Check the current PROPCTL setting on a queue:

```bash
docker exec -i 5606692e7d74 /opt/mqm/bin/runmqsc QM1 <<EOF
DISPLAY QLOCAL(DEV.QUEUE.1) PROPCTL
EOF
```

Now set it to the wrong value:

```bash
docker exec -i 5606692e7d74 /opt/mqm/bin/runmqsc QM1 <<EOF
ALTER QLOCAL(DEV.QUEUE.1) PROPCTL(COMPAT)
EOF
```

Send a message through the pipeline:

```bash
curl -X POST http://localhost:8081/order \
  -H "X-bsi-ep: acme" \
  -H "X-bsi-ch: user42"
```

Go to Tempo. Search for the trace. You will find two disconnected traces instead
of one connected tree — the PRODUCER span and the CONSUMER span are now orphans.
The validator still processed the message. The system still worked. But you have
lost the ability to correlate events across the boundary.

Restore it:

```bash
docker exec -i 5606692e7d74 /opt/mqm/bin/runmqsc QM1 <<EOF
ALTER QLOCAL(DEV.QUEUE.1) PROPCTL(ALL)
EOF
```

Send another message. Tempo shows the connected trace again.

### The other way it breaks: MQFMT_STRING

`PROPCTL(ALL)` is necessary but not sufficient. There is a second way MQRFH2
gets destroyed: the **message format** field in MQMD.

If a producer sets `Format: 'MQSTR'`, IBM MQ treats the message as a plain
string and discards MQRFH2 — regardless of PROPCTL. This is what you saw in
Chapter 1 with `amqsput`: it is a plain C program that always sets MQSTR.

JMS producers should never set `MQFMT_STRING`. If a producer somewhere in the
pipeline does this — even accidentally — all OTel context is destroyed from
that point forward.

When debugging broken traces, check both:

```bash
# 1. Is PROPCTL correct on every queue in the pipeline?
runmqsc QM1
DISPLAY QLOCAL(*) PROPCTL

# 2. Is the Format field MQSTR on the messages you're seeing?
amqsbcg <queue> QM1
# look for: Format : 'MQSTR   '
```

---

## Chapter 5 — Operating with full context

With `PROPCTL(ALL)` on every queue and OTel inject/extract in every service,
your 2am scenario changes entirely.

DLQ has 47 messages. You browse one:

```bash
amqsbcg DEV.DEAD.LETTER.QUEUE QM1
```

You see:

```
<usr>
  traceparent : '00-9a3c2f1b4d8e7a6c5b2f0d1e3c9a7b4f-01a2b3c4d5e6f7a8-01'
  baggage     : 'bsi.ep=globex,bsi.ch=user91,order.type=high-value'
</usr>
```

You now know:
- **Tenant:** globex. Check if this is isolated to globex or affecting everyone.
- **Trace ID:** query Tempo immediately.

```
{ trace:id = "9a3c2f1b4d8e7a6c5b2f0d1e3c9a7b4f" }
```

Tempo shows the full span tree. The enricher span has `status: ERROR` with
`exception.message: Missing credit limit for high-value order`. The validator
and enricher ran fine. The enricher failed trying to look up credit limit — a
downstream service it depends on was returning 503.

You fix the right thing. The 47 messages are all `order.type=high-value` from
globex. You alert the globex account team. You do not touch acme or initech.

This is the difference observability makes when operating IBM MQ.

---

## Errors reference

Errors you will hit. What they mean. How to fix them.

| Error | Cause | Fix |
|-------|-------|-----|
| `amqsput: command not found` | `/opt/mqm/samp/bin` not in PATH | `export PATH=$PATH:/opt/mqm/samp/bin:/opt/mqm/bin` |
| `AMQ8150E: object already exists` | `DEFINE QLOCAL` without `REPLACE` | Add `REPLACE` to the command |
| `MQRC 2085 MQRC_UNKNOWN_OBJECT_NAME` | Queue does not exist | `DEFINE QLOCAL(<name>) PROPCTL(ALL) REPLACE` |
| `MQRC 2035 MQRC_NOT_AUTHORIZED` | No authority to open queue | Check channel auth or use `SET AUTHREC` |
| `MQRC 2053 MQRC_Q_FULL` | Queue depth limit reached | Increase `MAXDEPTH` or fix slow consumer |
| `the input device is not a TTY` | Used `-it` with stdin redirect | Use `-i` only: `docker exec -i` |
| Orphan traces in Tempo | PROPCTL not ALL, or MQFMT_STRING set | `DISPLAY QLOCAL(*) PROPCTL` — fix anything not ALL |

---

## Commands quick reference

```bash
# Get into the MQ container
docker exec -it <container-id> bash
export PATH=$PATH:/opt/mqm/samp/bin:/opt/mqm/bin

# Put a message (reads from stdin, Ctrl+D to end)
echo "payload" | amqsput <queue> QM1

# Get a message — DESTRUCTIVE, removes it from queue
amqsget <queue> QM1

# Browse messages — NON-DESTRUCTIVE, message stays
amqsbcg <queue> QM1

# Check queue depth for all queues
runmqsc QM1 <<EOF
DISPLAY QLOCAL(*) CURDEPTH
EOF

# Check PROPCTL on all queues — run this first when debugging broken traces
runmqsc QM1 <<EOF
DISPLAY QLOCAL(*) PROPCTL
EOF

# Fix PROPCTL on a queue
runmqsc QM1 <<EOF
ALTER QLOCAL(<queue>) PROPCTL(ALL)
EOF

# Create a safe learning queue (no service consumes from it)
runmqsc QM1 <<EOF
DEFINE QLOCAL(TEST.BROWSE) PROPCTL(ALL) REPLACE
EOF
```

---

## What to do next

| Goal | Action |
|------|--------|
| See MQRFH2 with OTel headers on the wire | Send a message via `curl`, browse `DEV.QUEUE.1` before validator consumes it |
| Understand the full message anatomy | Read `ibmmq-101.md` Stage 2 |
| Know every OTel requirement for IBM MQ | Read `baggage-ibmmq-checklist.md` |
| Debug a broken propagation in production | Follow `14-sre-baggage-checklist.md` |
| Go deep on IBM MQ internals | Read `15-ibmmq-complete-guide.md` |
