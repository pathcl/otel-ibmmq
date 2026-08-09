# IBM MQ 101 — Getting Started

A practical on-ramp. Where to start, what to touch first, what to ignore
until it matters. Deep reference lives in `15-ibmmq-complete-guide.md`.

---

## The mental model

IBM MQ is a **post office**, not a database.

You put a letter in a box, someone else picks it up later. The queue manager
is the post office building. Queues are the individual boxes. The message is
the letter — envelope and all.

Everything else — channels, MQRFH2, PROPCTL, clustering — is the post office
getting more complex as it scales to handle more letters, more buildings, and
letters that must survive if the building burns down.

The fundamental difference from other messaging systems:

| System | What happens if the consumer is down |
|--------|--------------------------------------|
| HTTP | Request fails immediately |
| Redis pub/sub | Message is lost |
| Kafka | Message sits in the log, replayed when consumer reconnects |
| IBM MQ | Message sits on the queue, delivered exactly once when consumer reconnects |

Exactly-once delivery with persistence across restarts is the core value
proposition. It is hard to get right. IBM MQ does it correctly.

---

## The four objects

Everything in IBM MQ is built from four things:

| Object | What it is |
|--------|------------|
| **Queue Manager** | The process that owns queues, enforces delivery, handles persistence |
| **Queue** | A named buffer — `QLOCAL` (local), `QREMOTE` (pointer to another QM), `QALIAS` (rename), `QMODEL` (template for dynamic queues) |
| **Channel** | A network pipe between two queue managers — always a `SENDER`/`RECEIVER` pair |
| **Message** | MQMD (envelope metadata) + optional MQRFH2 (properties/headers) + body |

Everything else is configuration of these four things.

---

## Stage 1 — Touch it first

The fastest way to demystify IBM MQ. You already have it running in this lab.

**Get a shell inside the MQ container with the MQ environment loaded:**

```bash
docker exec -it <mq-container> bash -c '. /opt/mqm/bin/setmqenv -s && bash'
```

The sample binaries (`amqsput`, `amqsget`, `amqsbcg`) live at
`/opt/mqm/samplebin/` and are not in `PATH` by default. Sourcing
`setmqenv` adds them. If you exec without it you will get
`command not found`.

**Connect to the queue manager:**

```bash
runmqsc QM1
```

**List all queues:**

```
DISPLAY QLOCAL(*)
```

**Create a test queue (`REPLACE` avoids `AMQ8150E` if it already exists):**

```
DEFINE QLOCAL(TEST.QUEUE) REPLACE PROPCTL(ALL)
```

The developer image pre-creates `DEV.QUEUE.1/2/3` — you can use those
directly instead of defining a new one.

**Put a message:**

```bash
echo "hello" | amqsput DEV.QUEUE.1 QM1
```

**Get it back (destructive — removes the message):**

```bash
amqsget DEV.QUEUE.1 QM1
```

**Dump the raw bytes including MQRFH2:**

```bash
amqsbcg DEV.QUEUE.1 QM1
```

`amqsbcg` is the single most educational command in IBM MQ. It shows exactly
what a message looks like on the wire — MQMD header, MQRFH2 properties folder,
body bytes. Once you have seen the raw structure the documentation makes sense.

---

## Stage 2 — Understand the message anatomy

Every IBM MQ message has two layers:

```
┌─────────────────────────────────────┐
│  MQMD  (Message Descriptor)         │  always present
│  MsgId, CorrelId, Format, Expiry…   │
├─────────────────────────────────────┤
│  MQRFH2  (Rules & Formatting Hdr)   │  present when PROPCTL(ALL)
│  <usr> folder: your properties      │  traceparent, baggage live here
│  <mcd> folder: message domain       │
├─────────────────────────────────────┤
│  Body                               │  your payload
└─────────────────────────────────────┘
```

**MQMD** is always present and carries envelope metadata — message ID,
correlation ID, timestamp, persistence flag, and format.

**MQRFH2** is optional and carries named properties. This is where OTel stores
`traceparent` and `baggage`. It is only preserved if `PROPCTL(ALL)` is set on
the queue — see `baggage-ibmmq-checklist.md`.

**MQFMT_STRING** is the dangerous format value. Setting it tells IBM MQ the
body is a plain string and the MQRFH2 header should be discarded. If any
producer sets this format, all properties are destroyed regardless of PROPCTL.

**Try it:** put a message, run `amqsbcg`, find the MQMD fields, find the body.
Then set `PROPCTL(ALL)` on the queue, put a JMS message with properties, dump
it again. You will see the `<usr>` folder appear.

---

## Stage 3 — Understand delivery guarantees

This is where IBM MQ differs from most messaging systems:

**Persistence** — controlled per message via MQMD:
- `MQPER_PERSISTENT` — written to disk, survives queue manager restart
- `MQPER_NOT_PERSISTENT` — in-memory only, lost on restart

**Transactions** — a single `COMMIT` can atomically put to queue A and get
from queue B. If the process dies mid-way, neither operation completes.

```java
// Put and get in one transaction — both happen or neither happens
session = connection.createSession(true, Session.SESSION_TRANSACTED);
consumer.receive();       // get from input queue
producer.send(message);  // put to output queue
session.commit();         // both committed atomically
```

**XA transactions** — extend this across a database. Commit the queue put and
the database insert in the same transaction. IBM MQ supports XA correctly;
this is rare and valuable.

**Exactly-once delivery** — persistent messages with transactions give you
exactly-once. This is the hard guarantee that makes IBM MQ the choice for
financial and regulated workloads.

---

## Stage 4 — Learn what breaks

IBM MQ failure modes are finite and well-documented. The ones that matter most:

| Failure | Symptom | Fix |
|---------|---------|-----|
| `PROPCTL` not `ALL` | Properties silently stripped; OTel sees orphan traces | `ALTER QLOCAL(...) PROPCTL(ALL)` |
| `MQFMT_STRING` on message | MQRFH2 discarded; all properties lost | Remove format override in producer code |
| Channel not started | Messages accumulate in transmission queue; consumer never receives | `START CHANNEL(channel-name)` |
| Queue depth limit hit | Producer receives `MQRC_Q_FULL` (2053) | Increase `MAXDEPTH` or fix slow consumer |
| DLQ full | Messages lost permanently | Monitor DLQ depth; process or clear it |

**Break things intentionally in the lab:**

```bash
# Set PROPCTL wrong — watch OTel traces become orphans
runmqsc QM1
ALTER QLOCAL(DEV.QUEUE.1) PROPCTL(COMPAT)

# Send a message and query Tempo — you will see a new orphan trace-id
# Then restore it
ALTER QLOCAL(DEV.QUEUE.1) PROPCTL(ALL)
```

---

## Useful commands — quick reference

```bash
# Enter container with MQ environment loaded (do this first)
docker exec -it <mq-container> bash -c '. /opt/mqm/bin/setmqenv -s && bash'

# Connect to queue manager (inside container)
runmqsc QM1
```

Inside `runmqsc`:

```
# Queue operations
DISPLAY QLOCAL(*)                               # list all local queues
DISPLAY QLOCAL(DEV.QUEUE.1) ALL                # full detail on one queue
ALTER QLOCAL(DEV.QUEUE.1) PROPCTL(ALL)         # enable property preservation
DEFINE QLOCAL(MY.QUEUE) PROPCTL(ALL) REPLACE   # create (REPLACE avoids AMQ8150E)

# Channel operations
DISPLAY CHANNEL(*)                              # list all channels
DISPLAY CHSTATUS(*)                             # channel connection status
START CHANNEL(MY.CHANNEL)

# Queue manager status
DISPLAY QMSTATUS                                # QM health
DISPLAY QLOCAL(*) CURDEPTH                     # current depth of all queues
```

Sample program commands (bash, not runmqsc — requires setmqenv sourced):

```bash
echo "payload" | amqsput DEV.QUEUE.1 QM1       # put a message
amqsget DEV.QUEUE.1 QM1                        # get (destructive)
amqsbcg DEV.QUEUE.1 QM1                        # dump raw bytes (non-destructive)
```

---

## What to ignore until you need it

| Topic | When it becomes relevant |
|-------|--------------------------|
| RDQM / HA clustering | Designing for production resilience |
| XA transactions | Coordinating MQ puts with database commits |
| MQ Appliance | Hardware deployments only |
| MQ on z/OS | Mainframe — different enough to be a separate product |
| AMS (Advanced Message Security) | Compliance and encryption requirements |
| MQ Console REST API | Building ops tooling |

---

## Where to go next

| Resource | What it covers |
|----------|---------------|
| `docs/15-ibmmq-complete-guide.md` | Full reference: all APIs, HA, security, internals, Kafka comparison |
| `docs/baggage-ibmmq-checklist.md` | OTel context propagation over IBM MQ — checklist and Q&A |
| `docs/03-jms-carrier.md` | How JMS properties map to MQRFH2 and why a carrier adapter is needed |
| [MQRC reason codes](https://www.ibm.com/docs/en/ibm-mq/9.3?topic=codes-reason-mqrc) | Bookmark this — you will use it constantly when debugging |
| [MQMD structure](https://www.ibm.com/docs/en/ibm-mq/9.3?topic=messages-mqmd-message-descriptor) | The message envelope — understand this before anything else in the docs |

## The fastest path to useful

1. Run `amqsbcg` on a message in this lab right now
2. Set `PROPCTL(COMPAT)` on a queue, watch OTel traces become orphans, restore it
3. Read `15-ibmmq-complete-guide.md` Parts 1–4 (mental model, objects, message anatomy, channels)
4. Put a message, kill the consumer mid-transaction, verify the message is still on the queue

At that point you understand more than most developers who use IBM MQ daily.
