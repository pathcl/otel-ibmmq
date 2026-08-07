package tutorial;

import com.ibm.mq.jms.MQConnectionFactory;
import com.ibm.msg.client.wmq.WMQConstants;
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;

import javax.jms.*;
import java.util.Set;
import java.util.logging.Logger;

public class Validator {

    private static final Logger log = Logger.getLogger(Validator.class.getName());

    // Tenants explicitly blocked — simulates a denylist check against an internal registry.
    private static final Set<String> BLOCKED_TENANTS = Set.of("bad-tenant", "blocked");

    private final OpenTelemetry otel;
    private final Tracer tracer;
    private final Session session;
    private final MessageProducer nextProducer;
    private final MessageProducer dlqProducer;

    public Validator(OpenTelemetry otel, Session session, String nextQueue, String dlqQueue)
            throws JMSException {
        this.otel         = otel;
        this.tracer       = otel.getTracer("tutorial.validator");
        this.session      = session;
        this.nextProducer = session.createProducer(session.createQueue(nextQueue));
        this.dlqProducer  = session.createProducer(session.createQueue(dlqQueue));
    }

    void handle(Message message) throws JMSException {
        // Extract traceparent + baggage from the incoming JMS message.
        // Context.root() ensures we don't inherit whatever the receive-loop thread holds.
        Context extractedCtx = otel.getPropagators().getTextMapPropagator()
            .extract(Context.root(), message, JmsCarrier.GETTER);

        Span consumerSpan = tracer.spanBuilder("validator.handle")
            .setSpanKind(SpanKind.CONSUMER)
            .setParent(extractedCtx)
            .startSpan();

        try (Scope ignored = extractedCtx.with(consumerSpan).makeCurrent()) {
            Baggage baggage  = Baggage.fromContext(extractedCtx);
            String tenantId  = baggage.getEntryValue("tenant.id");
            String userId    = baggage.getEntryValue("user.id");

            consumerSpan.setAttribute("messaging.system", "ibmmq");
            if (tenantId != null) consumerSpan.setAttribute("tenant.id", tenantId);
            if (userId   != null) consumerSpan.setAttribute("user.id", userId);

            if (tenantId == null || tenantId.isBlank()) {
                reject(message, "missing tenant.id", consumerSpan);
            } else if (BLOCKED_TENANTS.contains(tenantId)) {
                reject(message, "tenant blocked: " + tenantId, consumerSpan);
            } else {
                forward(message, tenantId, userId);
                log.info("Validated OK | tenant=" + tenantId);
            }
        } finally {
            consumerSpan.end();
        }
    }

    private void forward(Message original, String tenantId, String userId) throws JMSException {
        Span producerSpan = tracer.spanBuilder("validator.forward")
            .setSpanKind(SpanKind.PRODUCER)
            .startSpan();

        try (Scope ignored = Context.current().with(producerSpan).makeCurrent()) {
            producerSpan.setAttribute("messaging.system", "ibmmq");
            producerSpan.setAttribute("tenant.id", tenantId);

            TextMessage out = session.createTextMessage(
                original instanceof TextMessage t ? t.getText() : "(non-text)");
            otel.getPropagators().getTextMapPropagator()
                .inject(Context.current(), out, JmsCarrier.SETTER);
            nextProducer.send(out);
        } finally {
            producerSpan.end();
        }
    }

    private void reject(Message original, String reason, Span consumerSpan) throws JMSException {
        consumerSpan.setAttribute("validation.rejected", true);
        consumerSpan.setAttribute("validation.reason", reason);
        consumerSpan.setStatus(StatusCode.ERROR, reason);

        Span producerSpan = tracer.spanBuilder("validator.reject")
            .setSpanKind(SpanKind.PRODUCER)
            .startSpan();

        try (Scope ignored = Context.current().with(producerSpan).makeCurrent()) {
            producerSpan.setAttribute("messaging.system", "ibmmq");
            producerSpan.setAttribute("dlq.reason", reason);
            producerSpan.setStatus(StatusCode.ERROR, reason);

            String body = original instanceof TextMessage t ? t.getText() : "(non-text)";
            TextMessage out = session.createTextMessage(body);
            out.setStringProperty("dlq_reason", reason);
            otel.getPropagators().getTextMapPropagator()
                .inject(Context.current(), out, JmsCarrier.SETTER);
            dlqProducer.send(out);
        } finally {
            producerSpan.end();
        }
        log.warning("Message rejected → DLQ | reason=" + reason);
    }

    public static void main(String[] args) throws Exception {
        String collectorEndpoint = env("OTEL_COLLECTOR_ENDPOINT", "http://localhost:4317");
        String mqHost            = env("IBM_MQ_HOST", "localhost");
        int    mqPort            = Integer.parseInt(env("IBM_MQ_PORT", "1414"));
        String mqQueueManager    = env("IBM_MQ_QUEUE_MANAGER", "QM1");
        String mqChannel         = env("IBM_MQ_CHANNEL", "DEV.APP.SVRCONN");
        String mqInQueue         = env("IBM_MQ_IN_QUEUE", "DEV.QUEUE.1");
        String mqNextQueue       = env("IBM_MQ_NEXT_QUEUE", "DEV.QUEUE.2");
        String mqDlqQueue        = env("IBM_MQ_DLQ", "DEV.DEAD.LETTER.QUEUE");
        String mqUser            = env("IBM_MQ_USER", "app");
        String mqPassword        = env("IBM_MQ_PASSWORD", "passw0rd");
        String serviceName       = env("SERVICE_NAME", "validator");

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
        MessageConsumer consumer = session.createConsumer(session.createQueue(mqInQueue));
        Validator       validator = new Validator(otel, session, mqNextQueue, mqDlqQueue);

        log.info("Validator listening on " + mqInQueue
            + " → valid:" + mqNextQueue + " | rejected:" + mqDlqQueue);

        while (true) {
            Message msg = consumer.receive();
            if (msg != null) {
                try {
                    validator.handle(msg);
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
