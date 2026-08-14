# 16 — ApiExitLocal: Queue Manager–Level Context Propagation

## What it is

`ApiExitLocal` is a C shared library loaded by the IBM MQ queue manager that
intercepts every `MQPUT` and `MQGET` call — from **every application** connected
to that queue manager, regardless of language or whether the application has any
OTel code.

It is configured in `qm.ini` (not in application code) and runs in the same
process as the queue manager. From the application's perspective, nothing changes.

This lab's implementation lives in `api-exit/otel_exit.c`.

## When to use it

| Situation | Use ApiExitLocal |
|---|---|
| You own the infrastructure but not the application code | Yes |
| Producers are COBOL, C, or vendor systems you cannot modify | Yes |
| Mixed estate: some services have OTel SDK, some don't | Yes — fills the gap for uninstrumented producers |
| All services are Java and you control them | No — use SDK or agent instead |
| You need baggage (`bsi.ep`, `bsi.cj`) on spans | No — exit cannot supply it |

The canonical enterprise use case: a legacy batch job runs `MQPUT` with no OTel
code. Without an exit, every consumer downstream starts an orphan trace. With the
exit, the consumer's `extract()` finds a `traceparent` and links the trace — even
though the producer never knew OTel existed.

## What it does and does not do

### Does: inject `traceparent` at MQPUT

```
Legacy app → MQPUT (no traceparent)
                 ↓
         ApiExitLocal BeforePut:
           checks if traceparent already present
           if absent: generates 00-{traceId}-{spanId}-01
           writes to MQRFH2 <usr> folder
                 ↓
         message arrives on queue with traceparent
                 ↓
validator → extract() → finds traceparent → linked consumer span
```

If the producer already has an OTel SDK (as in this lab), the exit finds the
existing `traceparent` and skips. It only generates one for uninstrumented producers.

### Does: extract `traceparent` at MQGET (thread-local storage)

The exit reads the `traceparent` from each delivered message and stores it in
thread-local storage. The consuming application can retrieve it from TLS if it
implements the integration layer — or ignore it if it has the OTel SDK (which
reads directly from the JMS message properties).

### Does NOT: inject or carry baggage

```
bsi.ep=checkout,bsi.ch=android,bsi.cj=MoneyTransfer
```

This value exists only in the application's memory — in the HTTP request the
gateway received, or in the business logic that chose the entry point. The exit
intercepts a raw `MQPUT` call and sees only the message buffer. It has no access
to the application's state, so it cannot write baggage.

**Consequence**: with ApiExitLocal alone, connected traces are possible but the
`bsi.ep` / `bsi.ch` / `bsi.cj` span attributes are absent. Service graph metrics
(`traces_service_graph_request_total{bsi_ep}`) will have an empty `bsi_ep` label
for every span from uninstrumented producers.

### Does NOT: create spans or export to Collector

The exit writes headers into messages. It does not create OTel spans and does not
communicate with the OTel Collector. Traces appear only when the consuming service
has an OTel SDK that creates a CONSUMER span using the extracted `traceparent`.

## Comparison: three instrumentation approaches

| | Manual SDK | Java Agent | ApiExitLocal |
|---|---|---|---|
| Who instruments | Application | JVM bytecode | Queue manager |
| Works for COBOL/C | No | No | Yes |
| `traceparent` propagation | Yes | Yes | Yes |
| `baggage` propagation | Yes | Yes | No |
| Span creation | Yes | Yes | No |
| Custom metrics | Yes | Via SDK API | No |
| Requires code changes | Yes | No | No |
| PROPCTL still required | Yes | Yes | Yes |

## Running the exit alongside the lab

The exit is layered **on top of** whichever lab mode is running. It does not replace
the SDK or agent — it runs at the queue manager level simultaneously.

### Step 1 — Start the lab (either mode)

```bash
./start.sh up           # sdk lab
# or
./start.sh up agent     # agent lab
```

### Step 2 — Install the exit into the running MQ container

```bash
./labs/otel-ibmmq/api-exit/install.sh
```

The script:
1. Installs `gcc` in the IBM MQ container if not present
2. Compiles `otel_exit.c` against IBM MQ headers inside the container
3. Patches `qm.ini` with the `ApiExitLocal` stanza (idempotent)
4. Restarts the IBM MQ container so QM1 picks up the exit
5. Re-applies `PROPCTL(ALL)` on all pipeline queues

Changes survive container restarts. They are lost only if the Docker volume is
destroyed (`docker compose down -v`).

### Step 3 — Verify the exit loaded

```bash
docker compose -f labs/otel-ibmmq/docker-compose.yml exec ibmmq bash -c \
  'echo "DISPLAY QMGR APIEXITL" | runmqsc QM1'
```

Expected output includes `APIEXITL(OtelPropagator)`.

To watch exit log output in real time:
```bash
docker logs -f <ibmmq-container-name> 2>&1 | grep otel-exit
```

### Step 4 — Test with an uninstrumented producer

To observe what the exit provides, stop the gateway (which has the OTel SDK) and
send directly via `amqsput` (a native MQ tool with no OTel code):

```bash
# Stop the SDK gateway so it doesn't inject first
docker compose -f labs/otel-ibmmq/docker-compose.yml stop gateway

# Put a message directly with no OTel SDK
docker compose -f labs/otel-ibmmq/docker-compose.yml exec ibmmq bash -c \
  'echo "raw message from legacy producer" | /opt/mqm/samp/bin/amqsput DEV.QUEUE.1 QM1'

# Check the exit injected traceparent
docker compose -f labs/otel-ibmmq/docker-compose.yml exec ibmmq bash -c \
  '/opt/mqm/samp/bin/amqsbcg DEV.QUEUE.1 QM1' | grep '<usr>'
```

You should see `<usr><traceparent>00-...</traceparent></usr>` with an empty or
absent `<baggage>` — the exit generated the trace ID, but has no baggage to inject.

Restart the gateway when done:
```bash
docker compose -f labs/otel-ibmmq/docker-compose.yml start gateway
```

## Uninstall

```bash
./labs/otel-ibmmq/api-exit/uninstall.sh
```

Or manually: remove the `ApiExitLocal` stanza from `qm.ini` and restart the
container.

## Building manually (outside the container)

If you have IBM MQ client headers installed on your host (`/opt/mqm/inc`):

```bash
cd labs/otel-ibmmq/api-exit
make
make install   # copies to /var/mqm/exits64/ — requires root or mqm group membership
```

Edit `qm.ini` to add the stanza, then restart QM1.

## How the C code works

The exit registers two hooks:

```
OtelExitInit (load time)
  → MQXEP(BeforePut)  — intercepts every MQPUT before it completes
  → MQXEP(AfterGet)   — intercepts every MQGET after it completes
```

**BeforePut** checks for an existing `traceparent` property on the message handle.
If absent, it generates a valid W3C traceparent string
(`00-{16-byte traceId}-{8-byte spanId}-01`) and writes it as a JMS string property
using `MQSETMP` — which lands in the MQRFH2 `<usr>` folder.

**AfterGet** reads the `traceparent` from the delivered message and stores it in
thread-local storage, making it available to the application if needed.

The critical safety rule: **the exit never fails the MQPUT**. If anything goes
wrong (memory allocation failure, property write error), it logs and returns
`MQCC_OK`. A tracing failure must never break message flow.

See `api-exit/otel_exit.c` for the full implementation.
