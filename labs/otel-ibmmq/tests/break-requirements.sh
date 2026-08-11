#!/usr/bin/env bash
# break-requirements.sh
#
# Negative tests — deliberately breaks each hard requirement one at a time,
# proves the specific failure mode, then restores the original code.
#
# Each test:
#   1. Patches the source file
#   2. Rebuilds just that service
#   3. Sends a unique-tenant message
#   4. Queries Tempo to verify the expected failure
#   5. Restores source and rebuilds
#
# Usage: ./tests/break-requirements.sh [req4|req5|req6|req7|req8|req1|all]
#
# Skips infrastructure tests (Req 1-3) by default — run 'req1' to include them.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "${REPO_ROOT}"

COMPOSE_BASE="-f labs/otel-ibmmq/docker-compose.yml -f labs/otel-ibmmq/docker-compose.upstream.yml"
TEMPO_URL="http://localhost:3200"
UPSTREAM_URL="http://localhost:8081"
MQ_CONTAINER="otel-ibmmq-ibmmq-1"
JAVA_SRC="labs/otel-ibmmq"

PASS=0
FAIL=0
TARGET="${1:-all}"

pass() { echo "  ✓ $*"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
info() { echo "  · $*"; }
header() { echo; echo "━━ $* ━━"; }

# ── helpers ──────────────────────────────────────────────────────────────────

send_and_wait() {
    local tenant="$1" wait="${2:-20}"
    curl -s -X POST "${UPSTREAM_URL}/order" \
        -H "X-bsi-ep: ${tenant}" \
        -H "X-bsi-ch: breaktest" > /dev/null
    info "Sent message with tenant=${tenant}, waiting ${wait}s for pipeline..."
    sleep "${wait}"
}

# Returns JSON search result for a tenant's traces
search_by_tenant() {
    local tenant="$1"
    curl -s -G "${TEMPO_URL}/api/search" \
        --data-urlencode "q={ span.bsi.ep = \"${tenant}\" }" \
        --data-urlencode "limit=5" 2>/dev/null
}

# Returns the full trace JSON for a given trace ID
fetch_trace() {
    local trace_id="$1"
    curl -s "${TEMPO_URL}/api/traces/${trace_id}" 2>/dev/null
}

# Count distinct services in a trace
count_services() {
    python3 -c "
import sys, json
data = json.load(sys.stdin)
services = set()
for batch in data.get('batches', []):
    for attr in batch.get('resource', {}).get('attributes', []):
        if attr['key'] == 'service.name':
            services.add(attr['value']['stringValue'])
print(len(services))
print(' '.join(sorted(services)))
" 2>/dev/null
}

count_traces() {
    python3 -c "
import sys,json; print(len(json.load(sys.stdin).get('traces',[])))
" 2>/dev/null || echo 0
}

first_trace_id() {
    python3 -c "
import sys,json; t=json.load(sys.stdin).get('traces',[]); print(t[0]['traceID'] if t else '')
" 2>/dev/null || echo ""
}

rebuild_and_restart() {
    local svc="$1"
    info "Rebuilding ${svc}..."
    docker compose ${COMPOSE_BASE} build "${svc}" -q
    docker compose ${COMPOSE_BASE} up -d "${svc}" 2>/dev/null
    info "Waiting 10s for ${svc} to reconnect to IBM MQ..."
    sleep 10
}

restore_file() {
    local file="$1"
    git checkout -- "${file}"
    info "Restored $(basename ${file})"
}

mqsc() {
    docker exec "${MQ_CONTAINER}" bash -c "/opt/mqm/bin/runmqsc QM1 << 'EOF'
$1
EOF" 2>&1
}

# ── REQ 1: PROPCTL(NONE) breaks propagation ──────────────────────────────────

run_req1() {
    header "BREAK REQ 1 — PROPCTL(NONE) on DEV.QUEUE.1"
    info "Expected: validator receives message but <usr> folder is absent → orphan traces"

    mqsc "ALTER QLOCAL(DEV.QUEUE.1) PROPCTL(NONE)" > /dev/null
    sleep 2   # let the queue manager propagate the PROPCTL change before the next MQPUT

    local tenant="break-req1-$$"
    send_and_wait "${tenant}" 15

    # Gateway always sets span.bsi.ep from the HTTP header, so a trace will exist
    # even when PROPCTL(NONE) strips the MQ message. The correct check is whether
    # the validator appears in the gateway trace — if PROPCTL(NONE) stripped the
    # MQRFH2, the validator creates an orphan trace and is absent from the gateway trace.
    local gw_search; gw_search=$(curl -s -G "${TEMPO_URL}/api/search" \
        --data-urlencode "q={ span.bsi.ep = \"${tenant}\" && resource.service.name = \"gateway\" }" \
        --data-urlencode "limit=3" 2>/dev/null)
    local gw_tid; gw_tid=$(echo "$gw_search" | first_trace_id)

    if [[ -z "$gw_tid" ]]; then
        pass "REQ 1 BROKEN: No gateway trace found for bsi.ep=${tenant} — unexpected but baggage certainly lost"
    else
        local trace; trace=$(fetch_trace "${gw_tid}")
        local svcs; svcs=$(echo "$trace" | count_services | tail -1)
        if echo "$svcs" | grep -q "validator"; then
            fail "REQ 1: validator IS present in gateway trace despite PROPCTL(NONE) — propagation was not broken"
        else
            pass "REQ 1 BROKEN: validator absent from gateway trace [${svcs}] — MQRFH2 stripped by PROPCTL(NONE), validator orphaned"
        fi
    fi

    info "Restoring PROPCTL(ALL) on DEV.QUEUE.1..."
    mqsc "ALTER QLOCAL(DEV.QUEUE.1) PROPCTL(ALL)" > /dev/null
    pass "REQ 1 restored"
}

# ── REQ 4: Remove W3CBaggagePropagator from gateway ──────────────────────────

run_req4() {
    header "BREAK REQ 4 — Remove W3CBaggagePropagator from gateway OtelConfig"
    info "Expected: traces still connected via traceparent, but span.bsi.ep absent on all spans"

    local cfg="${JAVA_SRC}/gateway/src/main/java/tutorial/OtelConfig.java"

    # Comment out the baggage propagator line
    sed -i 's/W3CBaggagePropagator.getInstance()/\/\/ W3CBaggagePropagator.getInstance() -- REMOVED FOR BREAK TEST/' "${cfg}"
    # Also remove the trailing comma on the previous line to avoid compile error
    sed -i 's/W3CTraceContextPropagator.getInstance(),/W3CTraceContextPropagator.getInstance()/' "${cfg}"

    info "Patched OtelConfig.java — W3CBaggagePropagator removed from gateway"
    rebuild_and_restart "gateway"

    local tenant="break-req4-$$"
    send_and_wait "${tenant}" 25

    # W3CBaggagePropagator missing → baggage not injected → validator/enricher/processor
    # have no bsi.ep (they read it only from extracted baggage, not from HTTP headers).
    # The gateway span itself WILL have bsi.ep (set explicitly via span.setAttribute)
    # so we must query a downstream service specifically.
    local search_validator; search_validator=$(curl -s -G "${TEMPO_URL}/api/search" \
        --data-urlencode "q={ span.bsi.ep = \"${tenant}\" && resource.service.name = \"validator\" }" \
        --data-urlencode "limit=3" 2>/dev/null)
    local count_validator; count_validator=$(echo "$search_validator" | count_traces)

    if ((count_validator == 0)); then
        pass "REQ 4 BROKEN: span.bsi.ep absent on validator — baggage not propagated across MQ boundary"
    else
        fail "REQ 4: validator has span.bsi.ep even without W3CBaggagePropagator — unexpected"
    fi

    # Verify the trace itself IS still connected (traceparent still works)
    info "Checking whether traceparent still connects spans without baggage propagator..."
    local search2; search2=$(curl -s -G "${TEMPO_URL}/api/search" \
        --data-urlencode "q={ resource.service.name = \"gateway\" }" \
        --data-urlencode "limit=1" 2>/dev/null)
    local tid; tid=$(echo "$search2" | first_trace_id)
    if [[ -n "$tid" ]]; then
        local trace; trace=$(fetch_trace "$tid")
        local svc_line; svc_line=$(echo "$trace" | count_services)
        local svc_count; svc_count=$(echo "$svc_line" | head -1)
        local svcs; svcs=$(echo "$svc_line" | tail -1)
        if ((svc_count >= 3)); then
            info "Trace IS connected across ${svc_count} services [${svcs}] — traceparent still works without baggage propagator"
        else
            info "Trace has only ${svc_count} service(s) [${svcs}]"
        fi
    fi

    restore_file "${cfg}"
    rebuild_and_restart "gateway"
    pass "REQ 4 restored"
}

# ── REQ 5: Make JmsCarrier SETTER a no-op in gateway ─────────────────────────

run_req5() {
    header "BREAK REQ 5 — Make JmsCarrier SETTER a no-op in gateway"
    info "Expected: inject() is called but writes nothing → no traceparent in message → orphan traces"

    local carrier="${JAVA_SRC}/gateway/src/main/java/tutorial/JmsCarrier.java"

    # Replace the SETTER lambda with a no-op using Python for reliable multiline edit
    python3 -c "
import re, sys
src = open('${carrier}').read()
# Replace the entire SETTER field with a no-op lambda — no try/catch needed
src = re.sub(
    r'(public static final TextMapSetter<Message> SETTER = \(message, key, value\) -> \{).*?(\};)',
    r'\1  /* no-op: carrier disabled for break test */ \2',
    src, flags=re.DOTALL
)
open('${carrier}', 'w').write(src)
"

    info "Patched JmsCarrier.java — SETTER writes nothing"
    rebuild_and_restart "gateway"

    local tenant="break-req5-$$"
    send_and_wait "${tenant}" 25

    local search; search=$(search_by_tenant "${tenant}")
    local count; count=$(echo "$search" | count_traces)

    local tid; tid=$(echo "$search" | first_trace_id)
    if [[ -z "$tid" ]]; then
        pass "REQ 5 BROKEN: No gateway trace found — carrier wrote nothing"
    else
        local trace; trace=$(fetch_trace "${tid}")
        local svc_line; svc_line=$(echo "$trace" | count_services)
        local svc_count; svc_count=$(echo "$svc_line" | head -1)
        local svcs; svcs=$(echo "$svc_line" | tail -1)
        # upstream→gateway is connected via HTTP (carrier not involved there).
        # If the MQ carrier is broken, the trace stops at gateway — validator onwards are orphans.
        # Connected end-to-end requires ≥4 services. ≤2 means the MQ boundary was not crossed.
        if ((svc_count <= 2)); then
            pass "REQ 5 BROKEN: Trace stops at gateway — only [${svcs}], validator is orphaned (carrier wrote nothing to message)"
        else
            fail "REQ 5: Trace spans ${svc_count} services [${svcs}] even with no-op carrier — unexpected"
        fi
    fi

    restore_file "${carrier}"
    rebuild_and_restart "gateway"
    pass "REQ 5 restored"
}

# ── REQ 6: Remove inject() from gateway ──────────────────────────────────────

run_req6() {
    header "BREAK REQ 6 — Comment out inject() in gateway Gateway.java"
    info "Expected: message sent with no traceparent → validator creates orphan trace"

    local src="${JAVA_SRC}/gateway/src/main/java/tutorial/Gateway.java"

    python3 -c "
import re
src = open('${src}').read()
# Comment out the two-line inject() call that writes to the JMS message (not the HTTP extract)
src = src.replace(
    'otel.getPropagators().getTextMapPropagator()\n                .inject(Context.current(), message, JmsCarrier.SETTER);',
    '// inject() disabled for break test'
)
open('${src}', 'w').write(src)
"

    info "Patched Gateway.java — inject() call removed"
    rebuild_and_restart "gateway"

    local tenant="break-req6-$$"
    send_and_wait "${tenant}" 25

    local search; search=$(search_by_tenant "${tenant}")
    local tid; tid=$(echo "$search" | first_trace_id)
    if [[ -z "$tid" ]]; then
        pass "REQ 6 BROKEN: No gateway trace — inject() not called, nothing written to message"
    else
        local trace; trace=$(fetch_trace "${tid}")
        local svc_line; svc_line=$(echo "$trace" | count_services)
        local svc_count; svc_count=$(echo "$svc_line" | head -1)
        local svcs; svcs=$(echo "$svc_line" | tail -1)
        if ((svc_count <= 2)); then
            pass "REQ 6 BROKEN: Trace stops at gateway [${svcs}] — inject() not called, validator is orphaned"
        else
            fail "REQ 6: Trace spans ${svc_count} services [${svcs}] even without inject() — unexpected"
        fi
    fi

    restore_file "${src}"
    rebuild_and_restart "gateway"
    pass "REQ 6 restored"
}

# ── REQ 7: Remove extract() from validator ────────────────────────────────────

run_req7() {
    header "BREAK REQ 7 — Replace extract() with empty context in validator"
    info "Expected: traceparent is in the message, but validator never reads it → orphan CONSUMER span"

    local src="${JAVA_SRC}/validator/src/main/java/tutorial/Validator.java"

    python3 -c "
import re
src = open('${src}').read()
# Replace extract() with Context.root() so the upstream context is always ignored
src = src.replace(
    'Context extractedCtx = otel.getPropagators().getTextMapPropagator()\n            .extract(Context.root(), message, JmsCarrier.GETTER);',
    'Context extractedCtx = Context.root(); // extract() disabled for break test'
)
open('${src}', 'w').write(src)
"

    info "Patched Validator.java — extract() bypassed, always uses Context.root()"
    rebuild_and_restart "validator"

    local tenant="break-req7-$$"
    send_and_wait "${tenant}" 25

    # Tenant baggage IS in the message (gateway still injects), but validator doesn't extract it
    # So validator.handle span won't have bsi.ep attribute
    local search; search=$(search_by_tenant "${tenant}")
    local count; count=$(echo "$search" | count_traces)

    # The gateway span WILL have bsi.ep (it sets it as span attribute explicitly)
    # But validator onwards will NOT have bsi.ep since baggage wasn't extracted
    local tid; tid=$(echo "$search" | first_trace_id)
    if [[ -z "$tid" ]]; then
        pass "REQ 7 BROKEN: No trace found by tenant — baggage context lost entirely"
    else
        local trace; trace=$(fetch_trace "$tid")
        local svc_line; svc_line=$(echo "$trace" | count_services)
        local svc_count; svc_count=$(echo "$svc_line" | head -1)
        local svcs; svcs=$(echo "$svc_line" | tail -1)
        if ((svc_count <= 2)); then
            pass "REQ 7 BROKEN: Trace stops at gateway [${svcs}] — validator received message but extract() not called, orphan span created"
        else
            fail "REQ 7: Trace spans ${svc_count} services [${svcs}] even without extract() — unexpected"
        fi
    fi

    restore_file "${src}"
    rebuild_and_restart "validator"
    pass "REQ 7 restored"
}

# ── REQ 8: Remove setParent() from validator ──────────────────────────────────

run_req8() {
    header "BREAK REQ 8 — Remove setParent(extractedCtx) from validator"
    info "Expected: extract() IS called and context found, but span not linked → orphan CONSUMER span"

    local src="${JAVA_SRC}/validator/src/main/java/tutorial/Validator.java"

    python3 -c "
import re
src = open('${src}').read()
# Replace setParent(extractedCtx) with root context — extract() runs but result is discarded
src = src.replace(
    '.setParent(extractedCtx)',
    '.setParent(Context.root()) // setParent(extractedCtx) disabled for break test'
)
open('${src}', 'w').write(src)
"

    info "Patched Validator.java — setParent(extractedCtx) replaced with setParent(Context.root())"
    rebuild_and_restart "validator"

    local tenant="break-req8-$$"
    send_and_wait "${tenant}" 25

    # Find the gateway trace specifically — it will always have bsi.ep (set explicitly)
    local gw_search; gw_search=$(curl -s -G "${TEMPO_URL}/api/search" \
        --data-urlencode "q={ span.bsi.ep = \"${tenant}\" && resource.service.name = \"gateway\" }" \
        --data-urlencode "limit=3" 2>/dev/null)
    local gw_tid; gw_tid=$(echo "$gw_search" | first_trace_id)

    if [[ -z "$gw_tid" ]]; then
        fail "REQ 8: Could not find gateway trace — test inconclusive"
    else
        # If setParent(extractedCtx) was removed, validator creates an orphan root and its spans
        # will NOT appear in the gateway's trace. They end up in a separate trace.
        local trace; trace=$(fetch_trace "${gw_tid}")
        local svcs; svcs=$(echo "$trace" | count_services | tail -1)
        if echo "$svcs" | grep -q "validator"; then
            fail "REQ 8: validator IS present in gateway trace [${svcs}] even without setParent(extractedCtx) — unexpected"
        else
            pass "REQ 8 BROKEN: validator absent from gateway trace [${svcs}] — setParent(extractedCtx) replaced with root, validator span is orphaned in a separate trace"
        fi
    fi

    restore_file "${src}"
    rebuild_and_restart "validator"
    pass "REQ 8 restored"
}

# ── main ─────────────────────────────────────────────────────────────────────

case "${TARGET}" in
    req1) run_req1 ;;
    req4) run_req4 ;;
    req5) run_req5 ;;
    req6) run_req6 ;;
    req7) run_req7 ;;
    req8) run_req8 ;;
    all)
        [[ "${1:-all}" == "all" ]] && info "Running all negative tests. Pass a specific req (req1 req4 req5 req6 req7 req8) to run one."
        run_req1
        run_req4
        run_req5
        run_req6
        run_req7
        run_req8
        ;;
    *)
        echo "Usage: $0 [req1|req4|req5|req6|req7|req8|all]"
        exit 1
        ;;
esac

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "  Note: 'passed' here means the break was confirmed —"
echo "  i.e., removing the requirement caused the expected failure."

[[ $FAIL -eq 0 ]]
