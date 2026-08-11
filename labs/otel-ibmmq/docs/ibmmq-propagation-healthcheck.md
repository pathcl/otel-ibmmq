# IBM MQ Context Propagation — Health Check

Quick reference for verifying that W3C `traceparent` and `baggage` headers
are flowing end-to-end through an IBM MQ pipeline.

- **Section 1** — MQ admin / infrastructure team
- **Section 2** — Application / development team
- **Section 3** — End-to-end smoke test (either team)

> **Lab reference implementation:** `labs/otel-ibmmq/`  
> Queue manager: `QM1` | Queues: `DEV.QUEUE.*` | Tempo: `http://localhost:3200`

---

## Section 1 — Infrastructure team (MQ admin)

Run these MQSC commands against every queue manager in the message path.

### 1.1 Queue manager default

```mqsc
DISPLAY QMGR PROPCTL
```

| Result | Meaning |
|--------|---------|
| `PROPCTL(ALL)` | New queues inherit correct default |
| `PROPCTL(COMPAT)` | Safe only if every producer is JMS-based |
| `PROPCTL(NONE)` | All MQRFH2 stripped by default — fix immediately |

Fix:
```mqsc
ALTER QMGR PROPCTL(ALL)
```

---

### 1.2 All local queues

```mqsc
DISPLAY QLOCAL(*) PROPCTL
```

Every queue in the pipeline — including the DLQ — must show `PROPCTL(ALL)`.

Fix any queue that does not:
```mqsc
ALTER QLOCAL(<queue-name>) PROPCTL(ALL)
```

---

### 1.3 Channels (cross-QM environments only)

```mqsc
DISPLAY CHL(*) PROPCTL
```

Any channel showing `PROPCTL(NONE)` drops MQRFH2 at the network boundary
between queue managers.

Fix:
```mqsc
ALTER CHL(<channel-name>) CHLTYPE(<type>) PROPCTL(ALL)
```

---

### 1.4 Browse a live message

Stop the consumer briefly, send one message through the normal producer path,
then browse:

```bash
/opt/mqm/samp/bin/amqsbcg <QUEUE> <QMGR>
```

**MQRFH2 present — infrastructure is configured correctly:**
```
Format : 'MQHRF2  '
...
<usr>
  <traceparent>00-...</traceparent>
  <baggage>bsi.ep=acme,bsi.ch=user42</baggage>
</usr>
```

**MQRFH2 absent — producer is not injecting or format is wrong:**
```
Format : 'MQSTR   '
```
→ Hand to the application team (Section 2).

> **Lab:** `docker exec otel-ibmmq-ibmmq-1 /opt/mqm/samp/bin/amqsbcg DEV.QUEUE.1 QM1`

---

## Section 2 — Application team

### 2.1 Static audit — five wiring points

Run from the service source root. All five must have at least one match.

```bash
# Both W3C propagators registered
grep -r "W3CTraceContextPropagator" src/
grep -r "W3CBaggagePropagator"      src/

# Carrier adapter wired to JMS message properties
grep -r "TextMapSetter\|TextMapGetter" src/

# inject() called before every send
grep -r "\.inject(" src/

# extract() called on every receive
grep -r "\.extract(" src/

# Consumer span linked to extracted context
grep -r "setParent" src/
```

| Check | Missing means |
|-------|--------------|
| `W3CTraceContextPropagator` | Spans never connect across any boundary |
| `W3CBaggagePropagator` | Traces connect but all baggage values are null downstream |
| `TextMapSetter` / `TextMapGetter` | inject/extract have nowhere to write or read |
| `.inject(` | No context written to outbound messages |
| `.extract(` | Context in message but never read |
| `setParent` | Context read but span not linked — still an orphan |

---

### 2.2 Live smoke test

Send a message with a unique tenant identifier and verify it appears in Tempo
across all expected services.

```bash
TENANT="healthcheck-$(date +%s)"
GATEWAY_URL="http://<gateway-host>:<port>"
TEMPO_URL="http://<tempo-host>:3200"

# Send
curl -s -X POST "${GATEWAY_URL}/send" \
  -H "X-bsi-ep: ${TENANT}" \
  -H "X-bsi-ch: healthcheck"

# Wait for spans to flush (adjust to your batch export interval)
sleep 15

# Query Tempo
curl -s -G "${TEMPO_URL}/api/search" \
  --data-urlencode "q={ span.bsi.ep = \"${TENANT}\" }" \
  --data-urlencode "limit=5"
```

Count distinct services in the result:

```bash
python3 - <<'EOF'
import sys, json, urllib.request, urllib.parse

tenant  = sys.argv[1]
tempo   = sys.argv[2]

q  = urllib.parse.urlencode({"q": f'{{ span.bsi.ep = "{tenant}" }}', "limit": "5"})
r  = urllib.request.urlopen(f"{tempo}/api/search?{q}")
data = json.loads(r.read())

traces = data.get("traces", [])
if not traces:
    print("FAIL — no traces found")
    sys.exit(1)

tid = traces[0]["traceID"]
r2  = urllib.request.urlopen(f"{tempo}/api/traces/{tid}")
trace = json.loads(r2.read())

svcs = {
    a["value"]["stringValue"]
    for b in trace.get("batches", [])
    for a in b.get("resource", {}).get("attributes", [])
    if a["key"] == "service.name"
}
print(f"Services in trace ({len(svcs)}): {', '.join(sorted(svcs))}")
EOF
"${TENANT}" "${TEMPO_URL}"
```

**Expected:** all services in the pipeline appear in a single trace.

> **Lab expected output:**
> ```
> Services in trace (5): enricher, gateway, processor, upstream, validator
> ```

---

## Section 3 — End-to-end decision table

| `amqsbcg` Format | Tempo result | Root cause | Owner |
|-----------------|-------------|-----------|-------|
| `MQHRF2` + `<usr>` present | All services in one trace | ✓ Working | — |
| `MQHRF2` + `<usr>` present | Trace stops before a queue | `PROPCTL(NONE)` on that queue | Infra |
| `MQHRF2` + empty `<usr>` | Orphan traces | Carrier SETTER is a no-op; properties written to wrong field | App |
| `MQSTR` | Orphan traces | Producer not calling `inject()`, or `MQFMT_STRING` set | App |
| `MQSTR` | Orphan traces | Native-MQ producer with no OTel instrumentation | App / Infra (API exit) |
| `MQHRF2` present | Zero traces in Tempo | OTel Collector not receiving spans; check exporter config | App / Infra |
| Any | Partial trace (some services missing) | One service missing `extract()` or `setParent()` | App |

---

## Quick command reference

```bash
# MQ admin — full audit in one pass
runmqsc <QMGR> << 'EOF'
DISPLAY QMGR PROPCTL
DISPLAY QLOCAL(*) PROPCTL
DISPLAY CHL(*) PROPCTL
EOF

# Browse queue (non-destructive)
/opt/mqm/samp/bin/amqsbcg <QUEUE> <QMGR>

# App team — wiring grep (run from service src root)
grep -rE "W3CBaggagePropagator|W3CTraceContextPropagator|TextMapSetter|TextMapGetter|\.inject\(|\.extract\(|setParent" src/

# Tempo query by tenant
curl -s -G http://<tempo>:3200/api/search \
  --data-urlencode 'q={ span.bsi.ep = "<tenant>" }' \
  --data-urlencode "limit=5"
```
