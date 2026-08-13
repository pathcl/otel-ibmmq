/*
 * otel_exit.c — IBM MQ ApiExitLocal for W3C traceparent/baggage propagation
 *
 * What this does:
 *   BeforePut: if the outgoing message has no traceparent property, generates
 *              one and sets it as an MQRFH2 <usr> string property.
 *   AfterGet:  reads traceparent from the received message and logs it.
 *              In production you would store it in thread-local storage so the
 *              application or another exit layer can read it.
 *
 * Build:
 *   see Makefile
 *
 * Deploy:
 *   copy otel_exit.so to /var/mqm/exits64/
 *   add ApiExitLocal stanza to /var/mqm/qmgrs/QM1/qm.ini (see bottom of file)
 *   restart queue manager
 *
 * What this does NOT do (compare with OTel SDK approach):
 *   - No baggage injection — business context (bsi.ep, bsi.cj) is unknown at
 *     the MQ API level; the application must still attach it.
 *   - No sampling decision — every MQPUT on every queue on this QM is intercepted.
 *   - No span export — this injects/extracts headers only; a separate mechanism
 *     (OTel SDK in the application, or an APM agent) must create and export spans.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <cmqc.h>   /* MQMD, MQPMO, MQGMO, MQ types and constants */
#include <cmqxc.h>  /* MQAXP, MQAXC, MQXEP — API exit structures  */

#define TRACEPARENT_LEN 55   /* "00-" + 32 + "-" + 16 + "-" + 2 = 55 */

/* ── helpers ─────────────────────────────────────────────────────────────── */

static void rand_hex(char *out, int bytes)
{
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < bytes; i++) {
        unsigned char b = (unsigned char)(rand() & 0xff);
        out[i * 2]     = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    out[bytes * 2] = '\0';
}

static void make_traceparent(char *out)
{
    char trace_id[33], span_id[17];
    rand_hex(trace_id, 16);   /* 128-bit trace ID */
    rand_hex(span_id, 8);     /* 64-bit span ID   */
    sprintf(out, "00-%s-%s-01", trace_id, span_id);
}

static void mqcharv_from_str(PMQCHARV cv, const char *s)
{
    cv->VSPtr    = (PMQCHAR)s;
    cv->VSLength = MQVS_NULL_TERMINATED;
    cv->VSCCSID  = MQCCSI_APPL;
}

/* ── MQPUT before hook — inject traceparent if absent ───────────────────── */

void MQENTRY BeforePut(
    PMQAXP   pExitParms,
    PMQAXC   pExitContext,
    PMQHCONN pHconn,
    PMQHOBJ  pHobj,
    PMQMD    pMsgDesc,
    PMQPMO   pPutMsgOpts,
    PMQLONG  pBufferLength,
    PMQPTR   pBuffer,
    PMQLONG  pCompCode,
    PMQLONG  pReason)
{
    MQLONG  CC = MQCC_OK, RC = MQRC_NONE;
    MQCHARV propName;
    MQPD    pd   = {MQPD_DEFAULT};
    MQIMPO  impo = {MQIMPO_DEFAULT};
    MQSMPO  smpo = {MQSMPO_DEFAULT};
    MQLONG  type, propLen;
    char    existing[TRACEPARENT_LEN + 1];
    char    traceparent[TRACEPARENT_LEN + 1];
    MQHMSG  hmsg = pPutMsgOpts->OriginalMsgHandle;

    /* No message handle — application did not set properties; nothing to do. */
    if (hmsg == MQHM_NONE)
        goto done;

    /* Check whether traceparent is already present (application or upstream exit set it). */
    mqcharv_from_str(&propName, "traceparent");
    MQINQMP(*pHconn, hmsg, &impo, &propName, &pd,
            &type, sizeof(existing) - 1, existing, &propLen, &CC, &RC);

    if (CC == MQCC_OK) {
        /* Already present — do not overwrite; preserve the upstream trace. */
        goto done;
    }

    /* Not present — generate and inject a new traceparent. */
    make_traceparent(traceparent);
    mqcharv_from_str(&propName, "traceparent");

    MQSETMP(*pHconn, hmsg, &smpo, &propName, &pd,
            MQTYPE_STRING, (MQLONG)strlen(traceparent), traceparent, &CC, &RC);

    if (CC == MQCC_OK) {
        fprintf(stderr, "[otel-exit] injected traceparent: %s\n", traceparent);
    } else {
        fprintf(stderr, "[otel-exit] MQSETMP failed CC=%ld RC=%ld\n",
                (long)CC, (long)RC);
    }

done:
    /* Never fail the PUT — a tracing exit must not break message flow. */
    *pCompCode = MQCC_OK;
    *pReason   = MQRC_NONE;
}

/* ── MQGET after hook — extract traceparent ─────────────────────────────── */

void MQENTRY AfterGet(
    PMQAXP   pExitParms,
    PMQAXC   pExitContext,
    PMQHCONN pHconn,
    PMQHOBJ  pHobj,
    PMQMD    pMsgDesc,
    PMQGMO   pGetMsgOpts,
    PMQLONG  pBufferLength,
    PMQPTR   pBuffer,
    PMQLONG  pDataLength,
    PMQLONG  pCompCode,
    PMQLONG  pReason)
{
    MQLONG  CC, RC;
    MQCHARV propName;
    MQPD    pd   = {MQPD_DEFAULT};
    MQIMPO  impo = {MQIMPO_DEFAULT};
    MQLONG  type, propLen;
    char    traceparent[TRACEPARENT_LEN + 1];
    MQHMSG  hmsg = pGetMsgOpts->MsgHandle;

    if (hmsg == MQHM_NONE)
        return;

    mqcharv_from_str(&propName, "traceparent");
    MQINQMP(*pHconn, hmsg, &impo, &propName, &pd,
            &type, sizeof(traceparent) - 1, traceparent, &propLen, &CC, &RC);

    if (CC == MQCC_OK) {
        traceparent[propLen] = '\0';
        fprintf(stderr, "[otel-exit] extracted traceparent: %s\n", traceparent);
        /*
         * Production use: store traceparent in thread-local storage here.
         * The application (or OTel SDK) reads it from TLS to link its span
         * to the upstream trace without needing JmsCarrier.
         *
         * pthread_setspecific(tls_key, strdup(traceparent));
         */
    }
    /* Not present = PROPCTL may have stripped MQRFH2; log and continue. */
}

/* ── Exit entry point — called once when the exit loads ─────────────────── */

void MQENTRY OtelExitInit(
    PMQAXP  pExitParms,
    PMQAXC  pExitContext,
    PMQLONG pCompCode,
    PMQLONG pReason)
{
    MQLONG CC, RC;

    srand((unsigned int)time(NULL));

    /* Register before-MQPUT: inject traceparent */
    MQXEP(pExitParms->Hconfig, MQXR_BEFORE, MQXF_PUT,
          (PMQFUNC)BeforePut, &CC, &RC);
    if (CC != MQCC_OK) goto fail;

    /* Register after-MQGET: extract traceparent */
    MQXEP(pExitParms->Hconfig, MQXR_AFTER, MQXF_GET,
          (PMQFUNC)AfterGet, &CC, &RC);
    if (CC != MQCC_OK) goto fail;

    fprintf(stderr, "[otel-exit] loaded — intercepting MQPUT/MQGET on QM1\n");

    *pCompCode = MQCC_OK;
    *pReason   = MQRC_NONE;
    return;

fail:
    fprintf(stderr, "[otel-exit] MQXEP registration failed CC=%ld RC=%ld\n",
            (long)CC, (long)RC);
    *pCompCode = MQCC_FAILED;
    *pReason   = RC;
}

/*
 * qm.ini stanza (append to /var/mqm/qmgrs/QM1/qm.ini, then restart QM):
 *
 *   ApiExitLocal:
 *     Name=OtelPropagator
 *     Module=/var/mqm/exits64/otel_exit
 *     Function=OtelExitInit
 *     Sequence=1
 */
