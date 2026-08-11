# OpenTelemetry Baggage Propagation Checklist — IBM MQ

Reference for hackathons and implementation sprints. Work top-to-bottom; each section
unblocks the next. Items marked **[decision]** require a team agreement before coding.

**Which scenario applies to you?**

| Scenario | Where to start |
|---|---|
| Your IBM MQ system is the entry point (no upstream) | Section 1 → in order |
| IBM MQ sits in the middle of a larger chain | Section 0 first, then continue from Section 1 |
| IBM MQ is the final leg (upstream feeds into it) | Section 0 first, then Section 1 |

---

## 0. Joining an existing trace chain — read this first if you are not the entry point

You have two protocol bridges instead of one. Context arrives in an upstream carrier
(HTTP, gRPC, Kafka, etc.), must cross into MQRFH2, and may need to cross back out again
downstream. Each crossing is an independent drop point.

### 0a. Discovery — answer these before writing code

- [ ] **[decision]** What propagation format does the upstream system use?

  | Format | Headers | Common source |
  |---|---|---|
  | W3C TraceContext + Baggage | `traceparent`, `tracestate`, `baggage` | OpenTelemetry default |
  | B3 multi-header | `X-B3-TraceId`, `X-B3-SpanId`, `X-B3-Sampled` | Zipkin, older Spring Cloud Sleuth, Istio |
  | B3 single-header | `b3` | Same as above, compact form |
  | AWS X-Ray | `X-Amzn-Trace-Id` | Any AWS-instrumented service |
  | Datadog | `x-datadog-trace-id`, `x-datadog-parent-id` | Datadog APM |
  | Jaeger | `uber-trace-id` | Older Jaeger-native setups |

  If you don't know: ask the upstream team, or proxy one live request and log all headers.

- [ ] **[decision]** Does upstream propagate **Baggage** or only TraceContext?
  - Many teams configure TraceContext propagation but omit Baggage entirely
  - If upstream doesn't propagate baggage, you cannot receive keys they set — you'll need to extract them from the payload instead

- [ ] **[decision]** What baggage keys are already in flight upstream?
  - List them; do not redefine or overwrite keys owned by another service
  - You can add new keys, but you cannot change the value of keys set upstream

- [ ] **[decision]** Does anything downstream of your MQ system expect context?
  - If yes: you also have an outbound bridge (MQRFH2 → downstream carrier)
  - Identify what format the downstream expects

- [ ] **[decision]** What happens if upstream provides no context (legacy or uncooperative system)?
  - Option A: start a fresh root trace at your MQ boundary (traces are disconnected but clean)
  - Option B: extract a correlation ID from the message payload, set it as baggage and a span attribute — provides a join key even without a real trace link

### 0b. Inbound bridge — upstream protocol → MQRFH2

- [ ] Add the upstream propagation format to your composite propagator alongside W3C

  ```go
  // Go — upstream uses B3, your system uses W3C internally
  import "go.opentelemetry.io/contrib/propagators/b3"

  otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
      b3.New(),                    // reads upstream B3 headers
      propagation.TraceContext{},  // reads/writes W3C for internal use
      propagation.Baggage{},
  ))
  ```

- [ ] At the first service that receives the upstream request, extract context from the upstream carrier **before** starting any span

  ```go
  // Go — HTTP inbound
  ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))
  ctx, span := tracer.Start(ctx, "inbound-bridge receive")
  defer span.End()
  ```

- [ ] Verify extraction is working before continuing: log the extracted trace ID and confirm it matches the upstream trace ID
  - A mismatch means the format is wrong; a zero trace ID means nothing was extracted

- [ ] Do not re-set baggage keys that upstream already set — only add new keys your system owns

- [ ] Inject into MQRFH2 as normal (Section 4) — the extracted context, including upstream baggage, flows through automatically

### 0c. Outbound bridge — MQRFH2 → downstream protocol (if applicable)

- [ ] The MQ consumer extracts from MQRFH2 (Section 5 as normal)
- [ ] Before calling the downstream system, inject into the downstream carrier

  ```go
  // Go — downstream is HTTP
  req, _ := http.NewRequest("POST", downstreamURL, body)
  otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
  ```

  ```go
  // Go — downstream is Kafka
  otel.GetTextMapPropagator().Inject(ctx, kafkaHeaderCarrier(kafkaMsg.Headers))
  ```

- [ ] If downstream uses a different format (e.g., downstream is Datadog-instrumented), add that propagator to the composite so inject writes the expected headers

### 0d. Sampling respect

- [ ] If the upstream `traceparent` has `sampled=0`, your system should respect it — do not force-sample a trace the upstream decided to drop
- [ ] OTel SDKs respect this by default through the `ParentBased` sampler; verify your sampler configuration has not overridden this

---

## 1. Prerequisites — agree before writing code

- [ ] **[decision]** Identify which API each service uses: JMS or native MQI
  - JMS (Java/Jakarta): auto-instrumentation available — skip to section 4, configure propagator only
  - Native MQI (Go, Python, Node.js, .NET, C): manual carrier required — follow all sections
- [ ] **[decision]** Agree on baggage keys and their semantics (e.g. `bsi.ep`, `request.id`)
  - Keys must be lowercase, no spaces (W3C Baggage spec)
  - Decide which service is the **authority** that sets each key (usually the entry point)
- [ ] **[decision]** Confirm MQRFH2 is enabled on all relevant queues
  - IBM MQ strips MQRFH2 headers if the queue's `PROPCTL` attribute is set to `NONE`
  - Default is `COMPAT` (preserves RFH2); verify with `DISPLAY QLOCAL(<name>) PROPCTL`
- [ ] OTel SDK installed in every service (`opentelemetry-api`, `opentelemetry-sdk`)
- [ ] OTLP exporter configured and pointing at a collector or backend
- [ ] **Propagator includes both TraceContext AND Baggage** — this is the most common omission

  ```go
  // Go
  otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
      propagation.TraceContext{},
      propagation.Baggage{},
  ))
  ```
  ```java
  // Java
  OpenTelemetrySdk.builder().setPropagators(ContextPropagators.create(
      TextMapPropagator.composite(
          W3CTraceContextPropagator.getInstance(),
          W3CBaggagePropagator.getInstance())))
  ```
  ```python
  # Python
  from opentelemetry.propagators.composite import CompositePropagator
  from opentelemetry.propagators.b3 import B3Format  # or W3C
  set_global_textmap(CompositePropagator([TraceContextTextMapPropagator(), BaggagePropagator()]))
  ```

---

## 2. Carrier implementation (native MQI only — skip if JMS)

- [ ] Write a `TextMapCarrier` that reads/writes **MQRFH2 string properties**
  - `Get(key)` → read named string property from MQRFH2
  - `Set(key, value)` → write named string property to MQRFH2
  - `Keys()` → enumerate all property names in MQRFH2
- [ ] Handle missing MQRFH2 gracefully on `Get` — return empty string, do not panic
  - Messages from systems that don't inject context will have no MQRFH2; extraction should yield a new root context, not an error
- [ ] Set `MQMD.Format = MQFMT_RF_HEADER_2` when attaching MQRFH2 to an outbound message
  - If this is not set, IBM MQ silently ignores the header and downstream consumers see no properties
- [ ] Verify the carrier in isolation with a unit test before wiring it into any service
  - Inject a known context → serialize to MQRFH2 → deserialize → extract → assert span context and baggage round-trip correctly

---

## 3. Baggage at the boundary

> **Middle-of-chain teams:** you do not set baggage here — upstream already set it and it
> arrives via the inbound bridge (Section 0b). Skip the "create baggage" steps below.
> Your job is only to read upstream baggage and set it as span attributes (last bullet).

- [ ] **Entry-point teams only:** identify the service that first receives external requests (HTTP gateway, REST endpoint, file ingestor)
- [ ] **Entry-point teams only:** at that boundary, create baggage from available request context

  ```go
  // Go — gateway reading tenant from HTTP header
  b := baggage.New()
  m, _ := baggage.NewMember("bsi.ep", r.Header.Get("X-bsi-ep"))
  b, _ = b.SetMember(m)
  ctx = baggage.ContextWithBaggage(ctx, b)
  ```

- [ ] **Entry-point teams only:** set agreed baggage keys as span attributes on the entry span (makes them searchable in traces)
- [ ] **All teams:** do **not** set a baggage key your service does not own — only the authority service (the true entry point) sets each key; all others forward it unchanged
- [ ] **All teams:** at every service, read baggage from context and set each member as a span attribute

  ```go
  // Go — works the same whether you set the baggage or received it from upstream
  b := baggage.FromContext(ctx)
  span.SetAttributes(attribute.String("bsi.ep", b.Member("bsi.ep").Value()))
  ```

---

## 4. Producer side — inject on every PUT

- [ ] Before each `MQPUT` / `JMSProducer.send`, call inject with the current context

  ```go
  // Go
  rfh2 := newMQRFH2()  // your MQRFH2 builder
  otel.GetTextMapPropagator().Inject(ctx, &MQCarrier{rfh2})
  // attach rfh2 to message before PUT
  ```

- [ ] Create a producer span that wraps the PUT operation
  - Span name convention: `<queue-name> send` (follows OTel messaging semantic conventions)
  - Set `messaging.system = "ibmmq"`, `messaging.destination = <queue-name>`, `messaging.operation = "send"`
- [ ] Read baggage from context and set each member as a span attribute on the producer span
- [ ] Inject **after** the producer span is started so the injected `traceparent` reflects the producer span, not its parent

---

## 5. Consumer side — extract on every GET

- [ ] After each `MQGET` / `JMSConsumer.receive`, extract context before starting any span

  ```go
  // Go
  carrier := &MQCarrier{rfh2FromMessage}
  ctx = otel.GetTextMapPropagator().Extract(context.Background(), carrier)
  ctx, span := tracer.Start(ctx, "<queue-name> receive", ...)
  defer span.End()
  ```

- [ ] Create a consumer span as a child of the extracted context
  - Span name convention: `<queue-name> receive`
  - Set `messaging.system`, `messaging.destination`, `messaging.operation = "receive"`
- [ ] Read baggage members from the extracted context and set as span attributes

  ```go
  b := baggage.FromContext(ctx)
  span.SetAttributes(attribute.String("bsi.ep", b.Member("bsi.ep").Value()))
  ```

- [ ] Pass the enriched `ctx` to all downstream logic in this service — do not discard it

---

## 6. Pattern-specific decisions

- [ ] **Dead Letter Queue**
  - **[decision]** The service that rejects a message (moves it to DLQ) must inject the **current** context (with rejection span active) into the DLQ message — not a fresh context
  - The DLQ handler extracts that context and creates a child span, so the full trace reads: `gateway → validator (rejection span) → dlq-handler`
  - If the DLQ handler creates a new root context, the DLQ path appears as a disconnected trace

- [ ] **Request-Reply**
  - **[decision]** The reply span should use a **span link** to the request span, not a parent-child relationship
  - The request span is likely already ended by the time the reply is processed; a child timestamped after its parent ended is misleading in trace UIs
  - Store the request `SpanContext` (trace ID + span ID) in a message property or the reply-to queue name; reconstruct a link at reply-processing time

- [ ] **Pub/Sub (Topics)**
  - Standard extract on each subscriber — all subscribers become children of the same publisher span
  - No special handling; baggage propagates identically to each copy

- [ ] **Wire Tap**
  - Same as Request-Reply: use a **span link** on the audit consumer span, not parent-child
  - The audit path is a side-effect; embedding it as a child distorts latency attribution in the main trace

- [ ] **Competing Consumers**
  - No special handling — each message is independent
  - Each consumer instance extracts its own context; they do not share span context

---

## 7. Verification

### Entry-point scenario

- [ ] **Smoke test — single message, end-to-end**
  - Send one message through the full MQ pipeline
  - Open the trace in Tempo / Jaeger — confirm all service spans share one root trace ID
  - Confirm baggage values appear as span attributes in every downstream span

- [ ] **DLQ path test**
  - Send a message that will be rejected (bad tenant, invalid payload)
  - Open the trace — confirm the DLQ handler span is a child of the rejecting service's span, not a new root

- [ ] **Baggage integrity test**
  - Set a baggage key at the entry point
  - Verify it arrives unchanged in the deepest downstream service
  - Check for accidental URL-encoding or truncation

### Middle-of-chain scenario

- [ ] **Upstream trace continuity test**
  - Trigger a request from the upstream system and capture the trace ID it generates
  - Open the same trace ID in your observability backend — confirm your MQ spans appear as children within that trace, not as a separate root trace

- [ ] **Baggage pass-through test**
  - Confirm a baggage key set upstream (e.g. `bsi.ep`) arrives as a span attribute in your MQ services without being modified
  - If the key is missing: check whether upstream propagates Baggage at all (Section 0a) — it may only propagate TraceContext

- [ ] **Outbound bridge test (if MQ feeds a downstream system)**
  - Trigger a full end-to-end request: upstream → your MQ system → downstream
  - Open the trace in the downstream system's observability backend — confirm the downstream spans share the same root trace ID as the upstream spans
  - If disconnected: the outbound bridge in Section 0c is not injecting context into the downstream carrier

### Both scenarios

- [ ] **Interop test (if mixed languages)**
  - Java JMS producer → Go MQI consumer: Go consumer must parse MQRFH2; confirm `traceparent` is extracted
  - Go MQI producer → Java JMS consumer: JMS consumer reads MQRFH2 as message properties; confirm context is received

- [ ] **Missing context test**
  - Send a message with no MQRFH2 header (simulating a legacy or uncooperative upstream)
  - Confirm the consumer starts a new root span rather than erroring or crashing

---

## 8. Common pitfalls — check these if something is broken

| Symptom | Likely cause |
|---|---|
| Baggage absent even though TraceContext propagates | Propagator configured with `TraceContext` only — `Baggage` not added to the composite |
| Traces fragmented (DLQ spans disconnected) | DLQ producer creates a fresh context instead of forwarding the extracted one |
| MQRFH2 properties not visible to consumer | `MQMD.Format` not set to `MQFMT_RF_HEADER_2`, or queue `PROPCTL=NONE` |
| Consumer always starts a new root trace | `Extract` called after `Start` — extract must happen before the span is created |
| Context lost between Java and Go services | Go consumer not parsing MQRFH2; Java JMS auto-instrumentation injected into RFH2 but Go ignores it |
| Reply spans show negative or zero duration | Using parent-child for Request-Reply — switch to span links |
| Baggage values missing on replayed DLQ messages | MQRFH2 stripped by DLQ queue's `PROPCTL` setting — verify queue configuration |
| Clock skew causes spans to appear in wrong order | Container or VM time drifted from host — sync with `chronyc makestep` |
| MQ spans appear as root even though upstream sent context | Upstream uses B3 or X-Ray; only W3C propagator configured — add upstream format to composite |
| Baggage keys from upstream are empty in MQ services | Upstream propagates TraceContext but omits Baggage — extract keys from payload instead |
| Downstream system shows disconnected traces from MQ | Outbound bridge missing — MQ consumer not injecting context into downstream carrier |
| Upstream baggage key has wrong value in MQ services | Middle service is re-setting a key owned by upstream — remove the Set call, only forward |
