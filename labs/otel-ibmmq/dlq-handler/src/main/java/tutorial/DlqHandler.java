package tutorial;

import com.ibm.mq.jms.MQConnectionFactory;
import com.ibm.msg.client.wmq.WMQConstants;
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.Meter;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;

import javax.jms.*;
import java.util.logging.Logger;

public class DlqHandler {

    private static final Logger log = Logger.getLogger(DlqHandler.class.getName());

    private final OpenTelemetry otel;
    private final Tracer tracer;
    private final LongCounter rejectedCounter;

    public DlqHandler(OpenTelemetry otel) {
        this.otel   = otel;
        this.tracer = otel.getTracer("tutorial.dlq-handler");

        Meter meter = otel.getMeter("tutorial.dlq-handler");
        this.rejectedCounter = meter.counterBuilder("messages.rejected")
            .setDescription("Total messages routed to the dead letter queue")
            .setUnit("{message}")
            .build();
    }

    void handle(Message message) throws JMSException {
        // Messages arriving here were explicitly sent by the validator with full
        // traceparent + baggage, so we can link back to the original trace.
        Context extractedCtx = otel.getPropagators().getTextMapPropagator()
            .extract(Context.root(), message, JmsCarrier.GETTER);

        Span span = tracer.spanBuilder("dlq-handler.handle")
            .setSpanKind(SpanKind.CONSUMER)
            .setParent(extractedCtx)
            .startSpan();

        try (Scope ignored = extractedCtx.with(span).makeCurrent()) {
            Baggage baggage  = Baggage.fromContext(extractedCtx);
            String tenantId  = baggage.getEntryValue("tenant.id");
            String reason    = message.getStringProperty("dlq_reason");

            span.setAttribute("messaging.system", "ibmmq");
            span.setAttribute("dlq.reason", reason != null ? reason : "unknown");
            if (tenantId != null) span.setAttribute("tenant.id", tenantId);

            // Mark span as error — this lights up the arc__error arc on the node in
            // the Grafana node graph panel.
            span.setStatus(StatusCode.ERROR, reason != null ? reason : "dead letter");
            span.recordException(new RuntimeException("DLQ: " + reason));

            rejectedCounter.add(1, Attributes.builder()
                .put("tenant.id",  tenantId != null ? tenantId : "unknown")
                .put("dlq.reason", reason   != null ? reason   : "unknown")
                .build());

            String body = message instanceof TextMessage t ? t.getText() : "(non-text)";
            log.warning("DLQ | tenant=" + tenantId + " reason=" + reason + " body=" + body);

            // In a real system the handler would either:
            //   1. Retry after fixing the message (put back to DEV.QUEUE.1)
            //   2. Escalate to a human workflow queue (e.g. MANUAL.REVIEW.QUEUE)
            //   3. Persist to a database for audit
            // For this lab we log and discard.
        } finally {
            span.end();
        }
    }

    public static void main(String[] args) throws Exception {
        String collectorEndpoint = env("OTEL_COLLECTOR_ENDPOINT", "http://localhost:4317");
        String mqHost            = env("IBM_MQ_HOST", "localhost");
        int    mqPort            = Integer.parseInt(env("IBM_MQ_PORT", "1414"));
        String mqQueueManager    = env("IBM_MQ_QUEUE_MANAGER", "QM1");
        String mqChannel         = env("IBM_MQ_CHANNEL", "DEV.APP.SVRCONN");
        String mqDlqQueue        = env("IBM_MQ_DLQ", "DEV.DEAD.LETTER.QUEUE");
        String mqUser            = env("IBM_MQ_USER", "app");
        String mqPassword        = env("IBM_MQ_PASSWORD", "passw0rd");
        String serviceName       = env("SERVICE_NAME", "dlq-handler");

        OpenTelemetry otel = OtelConfig.init(serviceName, collectorEndpoint);

        MQConnectionFactory cf = new MQConnectionFactory();
        cf.setHostName(mqHost);
        cf.setPort(mqPort);
        cf.setQueueManager(mqQueueManager);
        cf.setChannel(mqChannel);
        cf.setTransportType(WMQConstants.WMQ_CM_CLIENT);

        Connection connection = connectWithRetry(cf, mqUser, mqPassword);
        connection.start();

        Session         session  = connection.createSession(false, Session.AUTO_ACKNOWLEDGE);
        MessageConsumer consumer = session.createConsumer(session.createQueue(mqDlqQueue));
        DlqHandler      handler  = new DlqHandler(otel);

        log.info("DLQ handler listening on " + mqDlqQueue);

        while (true) {
            Message msg = consumer.receive();
            if (msg != null) {
                try {
                    handler.handle(msg);
                } catch (Exception e) {
                    log.severe("Error: " + e.getMessage());
                }
            }
        }
    }

    private static Connection connectWithRetry(MQConnectionFactory cf, String user, String password)
            throws InterruptedException {
        int attempts = 30;
        while (attempts-- > 0) {
            try {
                return cf.createConnection(user, password);
            } catch (JMSException e) {
                log.info("Waiting for IBM MQ... " + attempts + " attempts left");
                Thread.sleep(3000);
            }
        }
        throw new RuntimeException("Could not connect to IBM MQ after retries");
    }

    private static String env(String key, String def) {
        String v = System.getenv(key);
        return v != null ? v : def;
    }
}
