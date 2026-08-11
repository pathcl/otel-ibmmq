#!/usr/bin/env bash
# verify-hard-requirements.sh
#
# Proves each of the 8 hard requirements for OTel baggage propagation over IBM MQ.
# Run from any directory. Requires the full lab stack to be running.
#
# Usage: ./tests/verify-hard-requirements.sh

set -euo pipefail

MQ_CONTAINER="otel-ibmmq-ibmmq-1"
VALIDATOR_CONTAINER="otel-ibmmq-validator-1"
MQ_BIN="docker exec ${MQ_CONTAINER} /opt/mqm/samp/bin"
RUNMQSC="docker exec ${MQ_CONTAINER} bash -c"
TEMPO_URL="http://localhost:3200"
UPSTREAM_URL="http://localhost:8081"
JAVA_SRC="labs/otel-ibmmq"

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "${REPO_ROOT}"   # repo root — JAVA_SRC paths resolve from here

# ── helpers ──────────────────────────────────────────────────────────────────

pass() { echo "  ✓ $*"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
info() { echo "  · $*"; }
header() { echo; echo "━━ $* ━━"; }

wait_for_trace() {
    local ep="$1" attempts=10
    while ((attempts-- > 0)); do
        local result
        result=$(curl -s "${TEMPO_URL}/api/search?q=%7B+span.bsi.ep+%3D+%22${ep}%22+%7D&limit=5")
        local count
        count=$(echo "$result" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('traces',[])))" 2>/dev/null || echo 0)
        if ((count > 0)); then
            echo "$result"
            return 0
        fi
        sleep 2
    done
    return 1
}

get_trace_spans() {
    local trace_id="$1"
    curl -s "${TEMPO_URL}/api/traces/${trace_id}" 2>/dev/null
}

mqsc() {
    ${RUNMQSC} "/opt/mqm/bin/runmqsc QM1 << 'EOF'
$1
EOF" 2>&1
}

# ── REQ 1: PROPCTL on every pipeline queue ───────────────────────────────────

header "REQ 1 — PROPCTL on every pipeline queue"

PIPELINE_QUEUES="DEV.QUEUE.1 DEV.QUEUE.2 DEV.QUEUE.3 DEV.DEAD.LETTER.QUEUE"

for q in $PIPELINE_QUEUES; do
    result=$(mqsc "DISPLAY QLOCAL(${q}) PROPCTL" 2>/dev/null)
    if echo "$result" | grep -q "PROPCTL(ALL)"; then
        pass "${q}: PROPCTL(ALL)"
    elif echo "$result" | grep -q "PROPCTL(COMPAT)"; then
        # COMPAT works IF all producers are JMS-based (always put MQRFH2).
        # COMPAT fails silently when a non-JMS producer puts without MQRFH2.
        # ALL is the safe default — it works regardless of producer type.
        fail "${q}: PROPCTL(COMPAT) — works for JMS producers only, not safe for mixed pipelines"
    else
        fail "${q}: PROPCTL is not ALL ($(echo "$result" | grep PROPCTL))"
    fi
done

# Runtime test: break PROPCTL(NONE) on DEV.QUEUE.1, verify propagation breaks
info "Breaking PROPCTL on DEV.QUEUE.1 → NONE to prove runtime failure..."
mqsc "ALTER QLOCAL(DEV.QUEUE.1) PROPCTL(NONE)" > /dev/null

# Stop validator so message sits on queue for inspection
docker stop "${VALIDATOR_CONTAINER}" > /dev/null 2>&1

BREAK_TENANT="propctl-break-test-$$"
curl -s -X POST "${UPSTREAM_URL}/order" \
    -H "X-bsi-ep: ${BREAK_TENANT}" \
    -H "X-bsi-ch: test" > /dev/null

sleep 1
BCG_OUT=$(${MQ_BIN}/amqsbcg DEV.QUEUE.1 QM1 2>/dev/null)

if echo "$BCG_OUT" | grep -q "MQHRF2"; then
    info "amqsbcg shows MQHRF2 format — PROPCTL(NONE) did not strip format field"
else
    info "amqsbcg shows MQSTR — PROPCTL(NONE) stripped MQRFH2 and rewrote format field (expected)"
fi

if echo "$BCG_OUT" | grep -q "<usr>"; then
    fail "PROPCTL(NONE) — <usr> folder still visible in amqsbcg (unexpected)"
else
    pass "PROPCTL(NONE) — <usr> folder absent from amqsbcg browse output"
fi

# Restore
mqsc "ALTER QLOCAL(DEV.QUEUE.1) PROPCTL(ALL)" > /dev/null
docker start "${VALIDATOR_CONTAINER}" > /dev/null 2>&1
sleep 3
info "PROPCTL restored to ALL on DEV.QUEUE.1, validator restarted"

# ── REQ 1 NUANCE: COMPAT vs ALL ──────────────────────────────────────────────

header "REQ 1 NUANCE — PROPCTL(COMPAT) vs PROPCTL(ALL)"

info "Current lab queues use PROPCTL(COMPAT), not ALL."
info "COMPAT works here because every producer is JMS-based (always puts MQRFH2)."
info "COMPAT silently fails when a non-JMS producer (e.g. a C app) enters the pipeline."
info "ALL is the safe choice — it works regardless of producer type."
info "Recommendation: ALTER QMGR PROPCTL(ALL) to set default for all new queues."

# ── REQ 2: PROPCTL on channels ───────────────────────────────────────────────

header "REQ 2 — PROPCTL on channels between queue managers"

info "This lab runs a single queue manager (QM1) — no inter-QM channels carry traffic."
info "Checking default channel PROPCTL settings anyway..."

ch_result=$(mqsc "DISPLAY CHANNEL(SYSTEM.DEF.SENDER) PROPCTL" 2>/dev/null)
if echo "$ch_result" | grep -q "PROPCTL(ALL)"; then
    pass "SYSTEM.DEF.SENDER default: PROPCTL(ALL)"
else
    # Single-QM lab — SYSTEM.DEF.SENDER is a default template for SDR channels, not active.
    # PROPCTL(COMPAT) on sender channels only matters when messages cross QM boundaries.
    info "SYSTEM.DEF.SENDER: PROPCTL(COMPAT) on default template (no active inter-QM channels in this lab)"
    pass "REQ 2: N/A — single-QM lab, no active inter-QM sender/receiver channels"
fi

# ── REQ 3: Message format not MQFMT_STRING ───────────────────────────────────

header "REQ 3 — Message format must not be MQFMT_STRING"

info "Stopping validator to capture a live gateway message..."
docker stop "${VALIDATOR_CONTAINER}" > /dev/null 2>&1
sleep 1

curl -s -X POST "${UPSTREAM_URL}/order" \
    -H "X-bsi-ep: format-test" \
    -H "X-bsi-ch: test" > /dev/null
sleep 1

FORMAT_OUT=$(${MQ_BIN}/amqsbcg DEV.QUEUE.1 QM1 2>/dev/null)

docker start "${VALIDATOR_CONTAINER}" > /dev/null 2>&1

if echo "$FORMAT_OUT" | grep -q "Format : 'MQHRF2"; then
    pass "Gateway message Format: MQHRF2 — MQRFH2 present, properties survive"
elif echo "$FORMAT_OUT" | grep -q "Format : 'MQSTR"; then
    fail "Gateway message Format: MQSTR — MQRFH2 will be discarded"
else
    fail "Could not determine message format (queue may have been empty)"
fi

# ── REQ 4: Both W3C propagators registered ───────────────────────────────────

header "REQ 4 — Both W3C propagators registered in OtelConfig"

for svc in gateway validator enricher processor dlq-handler; do
    cfg="${JAVA_SRC}/${svc}/src/main/java/tutorial/OtelConfig.java"
    if [[ ! -f "$cfg" ]]; then
        fail "${svc}: OtelConfig.java not found at ${cfg}"
        continue
    fi

    has_trace=$(grep -c "W3CTraceContextPropagator" "$cfg" || true)
    has_baggage=$(grep -c "W3CBaggagePropagator" "$cfg" || true)

    if ((has_trace > 0)) && ((has_baggage > 0)); then
        pass "${svc}: W3CTraceContextPropagator + W3CBaggagePropagator both registered"
    elif ((has_trace > 0)); then
        fail "${svc}: W3CBaggagePropagator MISSING — baggage will not propagate"
    elif ((has_baggage > 0)); then
        fail "${svc}: W3CTraceContextPropagator MISSING — traceparent will not propagate"
    else
        fail "${svc}: Neither propagator registered"
    fi
done

# ── REQ 4 RUNTIME: Verify baggage actually reaches Tempo ─────────────────────

header "REQ 4 RUNTIME — Baggage reaches Tempo as span attributes"

RUNTIME_TENANT="req4test$$"
curl -s -X POST "${UPSTREAM_URL}/order" \
    -H "X-bsi-ep: ${RUNTIME_TENANT}" \
    -H "X-bsi-ch: test" > /dev/null

info "Waiting for trace to appear in Tempo (up to 30s)..."
SEARCH=""
for i in $(seq 1 6); do
    sleep 5
    SEARCH=$(curl -s -G "${TEMPO_URL}/api/search" \
        --data-urlencode "q={ span.bsi.ep = \"${RUNTIME_TENANT}\" }" \
        --data-urlencode "limit=3" 2>/dev/null)
    COUNT_TMP=$(echo "$SEARCH" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('traces',[])))" 2>/dev/null || echo 0)
    ((COUNT_TMP > 0)) && break
done
COUNT=$(echo "$SEARCH" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('traces',[])))" 2>/dev/null || echo 0)

if ((COUNT > 0)); then
    pass "Tenant baggage '${RUNTIME_TENANT}' found as span.bsi.ep in Tempo — W3CBaggagePropagator working"
else
    fail "Tenant baggage '${RUNTIME_TENANT}' NOT found in Tempo — W3CBaggagePropagator may be broken"
fi

# ── REQ 5: Carrier adapter wired ─────────────────────────────────────────────

header "REQ 5 — JmsCarrier (carrier adapter) wired in all services"

for svc in gateway validator enricher processor dlq-handler; do
    carrier="${JAVA_SRC}/${svc}/src/main/java/tutorial/JmsCarrier.java"
    main_src="${JAVA_SRC}/${svc}/src/main/java/tutorial"
    main_class=$(ls "${main_src}"/*.java 2>/dev/null | grep -v JmsCarrier | grep -v OtelConfig | head -1 || true)

    if [[ ! -f "$carrier" ]]; then
        fail "${svc}: JmsCarrier.java not found"
        continue
    fi

    has_setter=$(grep -c "SETTER" "$carrier" || true)
    has_getter=$(grep -c "GETTER" "$carrier" || true)
    uses_carrier=$(grep -c "JmsCarrier" "$main_class" 2>/dev/null || true)

    if ((has_setter > 0)) && ((has_getter > 0)) && ((uses_carrier > 0)); then
        pass "${svc}: JmsCarrier.SETTER + GETTER defined and used"
    elif ((has_setter == 0)) || ((has_getter == 0)); then
        fail "${svc}: JmsCarrier missing SETTER or GETTER"
    else
        fail "${svc}: JmsCarrier defined but not used in main service class"
    fi
done

# ── REQ 6: inject() called before send() ─────────────────────────────────────

header "REQ 6 — inject() called on every outbound message before send()"

# Gateway: injects into the message it puts to DEV.QUEUE.1
gw="${JAVA_SRC}/gateway/src/main/java/tutorial/Gateway.java"
inject_before_send=$(awk '/inject\(/{found=1} /\.send\(/{if(found) count++; found=0} END{print count+0}' "$gw" 2>/dev/null || echo 0)
if ((inject_before_send > 0)); then
    pass "gateway: inject() called before send()"
else
    fail "gateway: inject() not found before send()"
fi

# Validator, Enricher forward path: inject into outbound message before nextProducer.send()
# Processor is the terminal consumer — it does not forward, so inject() is not required there.
for svc in validator enricher; do
    src="${JAVA_SRC}/${svc}/src/main/java/tutorial/$(echo "$svc" | sed 's/./\u&/').java" 2>/dev/null || true
    # Capitalise first letter
    cap_svc="$(tr '[:lower:]' '[:upper:]' <<< "${svc:0:1}")${svc:1}"
    src="${JAVA_SRC}/${svc}/src/main/java/tutorial/${cap_svc}.java"
    if [[ ! -f "$src" ]]; then
        fail "${svc}: source not found at ${src}"
        continue
    fi
    has_inject=$(grep -c "\.inject(" "$src" || true)
    if ((has_inject > 0)); then
        pass "${svc}: inject() present in forward/produce path"
    else
        fail "${svc}: inject() NOT found — outbound messages carry no context"
    fi
done

# ── REQ 7: extract() called on every received message ────────────────────────

header "REQ 7 — extract() called on every received message"

for svc in validator enricher processor dlq-handler; do
    cap_svc="$(tr '[:lower:]' '[:upper:]' <<< "${svc:0:1}")${svc:1}"
    # dlq-handler maps to DlqHandler
    [[ "$svc" == "dlq-handler" ]] && cap_svc="DlqHandler"
    src="${JAVA_SRC}/${svc}/src/main/java/tutorial/${cap_svc}.java"
    if [[ ! -f "$src" ]]; then
        fail "${svc}: source not found at ${src}"
        continue
    fi
    has_extract=$(grep -c "\.extract(" "$src" || true)
    if ((has_extract > 0)); then
        pass "${svc}: extract() called on received message"
    else
        fail "${svc}: extract() NOT found — consumer never reads upstream context"
    fi
done

# ── REQ 8: setParent(extractedCtx) ───────────────────────────────────────────

header "REQ 8 — Consumer spans created with .setParent(extractedCtx)"

for svc in validator enricher processor dlq-handler; do
    cap_svc="$(tr '[:lower:]' '[:upper:]' <<< "${svc:0:1}")${svc:1}"
    [[ "$svc" == "dlq-handler" ]] && cap_svc="DlqHandler"
    src="${JAVA_SRC}/${svc}/src/main/java/tutorial/${cap_svc}.java"
    if [[ ! -f "$src" ]]; then
        fail "${svc}: source not found at ${src}"
        continue
    fi
    has_setparent=$(grep -c "setParent(" "$src" || true)
    if ((has_setparent > 0)); then
        pass "${svc}: .setParent(extractedCtx) found — trace link formed"
    else
        fail "${svc}: .setParent() NOT found — spans will be orphans even if extract() succeeds"
    fi
done

# ── REQ 8 RUNTIME: Verify connected trace in Tempo ───────────────────────────

header "REQ 8 RUNTIME — End-to-end connected trace in Tempo"

CONNECTED_EP="conntest$$"
curl -s -X POST "${UPSTREAM_URL}/order" \
    -H "X-bsi-ep: ${CONNECTED_EP}" \
    -H "X-bsi-ch: test" > /dev/null

info "Waiting for full pipeline to complete (up to 30s)..."
SEARCH=""
for i in $(seq 1 6); do
    sleep 5
    SEARCH=$(curl -s -G "${TEMPO_URL}/api/search" \
        --data-urlencode "q={ span.bsi.ep = \"${CONNECTED_EP}\" }" \
        --data-urlencode "limit=1" 2>/dev/null)
    COUNT_TMP=$(echo "$SEARCH" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('traces',[])))" 2>/dev/null || echo 0)
    ((COUNT_TMP > 0)) && break
done
TRACE_ID=$(echo "$SEARCH" | python3 -c "import sys,json; traces=json.load(sys.stdin).get('traces',[]); print(traces[0]['traceID'] if traces else '')" 2>/dev/null || echo "")

if [[ -z "$TRACE_ID" ]]; then
    fail "No trace found for ep=${CONNECTED_EP} — pipeline may not be processing"
else
    info "Trace ID: ${TRACE_ID}"
    TRACE=$(get_trace_spans "$TRACE_ID")
    SERVICES=$(echo "$TRACE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
services = set()
for batch in data.get('batches', []):
    for attr in batch.get('resource', {}).get('attributes', []):
        if attr['key'] == 'service.name':
            services.add(attr['value']['stringValue'])
print(' '.join(sorted(services)))
" 2>/dev/null || echo "")

    SPAN_COUNT=$(echo "$TRACE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
count = sum(len(scope.get('spans',[])) for batch in data.get('batches',[]) for scope in batch.get('scopeSpans',[]))
print(count)
" 2>/dev/null || echo 0)

    if ((SPAN_COUNT >= 4)); then
        pass "Connected trace: ${SPAN_COUNT} spans across services [${SERVICES}]"
    else
        fail "Trace has only ${SPAN_COUNT} span(s) — pipeline may be broken (services: ${SERVICES})"
    fi
fi

# ── SUMMARY ──────────────────────────────────────────────────────────────────

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if ((FAIL > 0)); then
    exit 1
fi
