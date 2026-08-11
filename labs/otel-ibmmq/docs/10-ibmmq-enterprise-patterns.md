# IBM MQ Enterprise Patterns

IBM MQ is a message broker focused on **guaranteed delivery** in regulated, high-stakes
environments — banking, insurance, telecoms, government. The core promise: a message put
on a queue will be delivered exactly once, even if the broker restarts, the network drops,
or the consumer crashes.

---

## Why IBM MQ

| Property | IBM MQ | Kafka | RabbitMQ |
|---|---|---|---|
| Delivery guarantee | Exactly-once | At-least-once | At-least-once |
| XA transactions | Yes (across MQ + DB) | No | Limited |
| Message ordering | Per-queue, per-group | Per-partition | Per-queue |
| Persistence | Always | Configurable | Configurable |
| Protocol | AMQP, JMS, REST, MQI | Custom | AMQP, MQTT |

The XA transaction story is the main reason banks use it. A teller deducting from an
account and sending a confirmation message are a single atomic operation — either both
commit or neither do.

---

## Core Concepts

**Queue Manager** — the MQ server. Owns queues, enforces permissions, manages persistence.

**Queue** — a named buffer. Messages land here and wait until a consumer reads them.
IBM MQ queues survive restarts by default.

**Channel** — a network connection between two queue managers. This is how distributed
MQ topologies work: Queue Manager A in London connects to Queue Manager B in New York
via a channel.

**Message** — payload + MQMD (Message Descriptor) header containing: message ID,
correlation ID, reply-to queue, expiry, priority, persistence flag.

---

## Patterns

### 1. Point-to-Point

```
Producer → QUEUE → Consumer
```

One producer, one consumer. The simplest case. MQ holds the message until the consumer
is ready — the consumer can be offline for hours. Used for: job queues, order processing,
payment requests.

---

### 2. Pipeline

```
QUEUE.1 → ServiceA → QUEUE.2 → ServiceB → QUEUE.3 → ServiceC
```

Each stage enriches or validates then forwards. Common in: loan approval
(collect → validate → score → decide), trade settlement (capture → validate → match → confirm).

**Implemented in this lab:** `gateway → validator → enricher → processor` across
`DEV.QUEUE.1`, `DEV.QUEUE.2`, `DEV.QUEUE.3`.

---

### 3. Request-Reply

```
Requester → REQUEST.QUEUE → Responder → REPLY.QUEUE → Requester
```

The requester puts a `ReplyToQueue` header on the message. The responder reads it and
sends the reply there. The requester correlates via `CorrelationId`. Used to make async
MQ look synchronous to the caller without blocking threads.

---

### 4. Publish-Subscribe

```
Publisher → TOPIC → Subscriber A
                  → Subscriber B
                  → Subscriber C
```

IBM MQ topics: all subscribers get a copy. Subscribers can be durable (won't miss
messages while offline) or non-durable. Used for: market data feeds, configuration
broadcasts, audit events.

---

### 5. Content-Based Router

```
Inbound → Router → QUEUE.REGION.EU
                 → QUEUE.REGION.US
                 → QUEUE.REGION.APAC
```

The router inspects a field (region, message type, priority) and decides the destination
queue. Keeps downstream services simple — they only handle one type of message. Ubiquitous
in retail banking (route by account type or product line).

---

### 6. Dead Letter Queue

```
Consumer → fails to process → SYSTEM.DEAD.LETTER.QUEUE
```

MQ has a system-level DLQ. Messages go there when: the destination queue is full, the
message expired, or the application explicitly rejects it. A DLQ handler inspects failed
messages and either retries, alerts, or archives them.

**Implemented in this lab:** `validator` rejects messages with `bsi.cj` in `BLOCKED_CJS` (`bad-cj`, `blocked`) to
`DEV.DEAD.LETTER.QUEUE`; `dlq-handler` consumes and marks spans ERROR.

---

### 7. Backout Queue

```
Consumer crashes → MQ returns message → after N retries → BACKOUT.QUEUE
```

MQ tracks how many times a message has been returned (`BackoutCount`). When it exceeds
`BackoutThreshold`, MQ automatically moves it to the backout queue. No application code
needed — this is MQ-native poison message handling.

---

### 8. Competing Consumers

```
QUEUE → Consumer Instance 1
      → Consumer Instance 2
      → Consumer Instance 3
```

MQ distributes messages across all listening consumers. Scale out by adding instances.
Used for: bulk batch processing, parallel API calls, worker pools.

**Implemented in this lab:** `processor` runs with `deploy.replicas: 2`, both instances
drain `DEV.QUEUE.3`. Both share `SERVICE_NAME=processor` so they appear as one node in
the service graph.

---

### 9. Message Groups

```
ORDER-001 part 1/3 ─┐
ORDER-001 part 2/3 ─┼─→ QUEUE → Consumer (processes all 3 in order)
ORDER-001 part 3/3 ─┘
```

IBM MQ groups related messages with `MQMF_MSG_IN_GROUP`. A consumer can lock the entire
group, guaranteeing ordered, atomic processing. Used when a large payload is split into
chunks: EDI files, batch records, chunked document uploads.

---

### 10. Wire Tap

```
Main flow: ServiceA → QUEUE → ServiceB
                   ↘
                    AUDIT.QUEUE → Audit Logger
```

Every message gets a copy forwarded to an audit queue, transparent to the main flow.
Used for regulatory logging (PCI-DSS, SOX require message-level audit trails), debugging,
and real-time analytics.

---

### 11. Claim Check

```
Producer → stores payload in DB/S3
         → puts token on QUEUE
Consumer → reads token → fetches payload from DB/S3
```

Avoids putting large payloads (50 MB XML, PDF documents) on the queue. The queue message
carries only a reference key. Used heavily in healthcare (HL7 documents), insurance
claims, and document processing workflows.

---

### 12. Transactional Outbox (XA)

```
BEGIN XA TRANSACTION
  UPDATE accounts SET balance = balance - 100 WHERE id = 123
  MQ PUT payment_confirmation TO PAYMENT.QUEUE
COMMIT  ← both commit atomically, or neither does
```

The IBM MQ differentiator in regulated industries. Database write and message send are
one atomic unit — no "message sent but DB rolled back" or vice versa. Requires XA-capable
JDBC driver and MQ connection factory configured for XA.

---

## Patterns in this lab

| Pattern | Services | Queues |
|---|---|---|
| Pipeline | gateway → validator → enricher → processor | DEV.QUEUE.1 → 2 → 3 |
| Dead Letter Queue | validator → dlq-handler | DEV.DEAD.LETTER.QUEUE |
| Competing Consumers | processor × 2 | DEV.QUEUE.3 |

## Patterns worth adding

| Pattern | Value | Complexity |
|---|---|---|
| Content-Based Router | Route by tenant to tenant-specific queues; richer service graph | Low |
| Wire Tap | Copy every message to an audit queue; demonstrates fan-out observability | Low |
| Request-Reply | Synchronous-style call over MQ; shows correlation ID in traces | Medium |
| Claim Check | Offload payload to object storage; realistic for large messages | Medium |
