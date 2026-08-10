package tutorial;

import com.ibm.mq.jms.MQConnectionFactory;
import com.ibm.msg.client.wmq.WMQConstants;
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;

import javax.jms.*;
import java.util.Map;
import java.util.UUID;
import java.util.logging.Logger;

public class Enricher {

    private static final Logger log = Logger.getLogger(Enricher.class.getName());

    // Simulates a static region lookup that would normally hit an internal registry.
    private static final Map<String, String> TENANT_REGIONS = Map.of(
        "acme",  "eu-west-1",
        "beta",  "us-east-1",
        "gamma", "ap-southeast-1"
    );

    private final OpenTelemetry otel;
    private final Tracer tracer;
    private final Session session;
    private final MessageProducer nextProducer;

    public Enricher(OpenTelemetry otel, Session session, String nextQueue) throws JMSException {
        this.otel         = otel;
        this.tracer       = otel.getTracer("tutorial.enricher");
        this.session      = session;
        this.nextProducer = session.createProducer(session.createQueue(nextQueue));
    }

    void handle(Message message) throws JMSException {
        Context extractedCtx = otel.getPropagators().getTextMapPropagator()
            .extract(Context.root(), message, JmsCarrier.GETTER);

        Span consumerSpan = tracer.spanBuilder("enricher.handle")
            .setSpanKind(SpanKind.CONSUMER)
            .setParent(extractedCtx)
            .startSpan();

        try (Scope ignored = extractedCtx.with(consumerSpan).makeCurrent()) {
            Baggage baggage = Baggage.fromContext(extractedCtx);

            consumerSpan.setAttribute("messaging.system", "ibmmq");
            // Set all baggage entries as span attributes — no hardcoded key names.
            baggage.asMap().forEach((key, entry) -> consumerSpan.setAttribute(key, entry.getValue()));

            // tenant.id drives the region enrichment lookup (business logic).
            String tenantId     = baggage.getEntryValue("tenant.id");
            String region       = TENANT_REGIONS.getOrDefault(tenantId, "unknown");
            String processingId = UUID.randomUUID().toString().substring(0, 8);

            // Enrichment attributes — visible in Tempo trace detail
            consumerSpan.setAttribute("enriched.region", region);
            consumerSpan.setAttribute("enriched.processing_id", processingId);

            forward(message, baggage, region, processingId);
            log.info("Enriched | tenant=" + tenantId + " region=" + region + " id=" + processingId);
        } finally {
            consumerSpan.end();
        }
    }

    private void forward(Message original, Baggage baggage, String region, String processingId)
            throws JMSException {
        Span producerSpan = tracer.spanBuilder("enricher.forward")
            .setSpanKind(SpanKind.PRODUCER)
            .startSpan();

        try (Scope ignored = Context.current().with(producerSpan).makeCurrent()) {
            producerSpan.setAttribute("messaging.system", "ibmmq");
            baggage.asMap().forEach((key, entry) -> producerSpan.setAttribute(key, entry.getValue()));

            String originalBody = original instanceof TextMessage t ? t.getText() : "(non-text)";
            String enrichedBody = originalBody
                + " | region=" + region
                + " | processing_id=" + processingId;

            TextMessage out = session.createTextMessage(enrichedBody);
            otel.getPropagators().getTextMapPropagator()
                .inject(Context.current(), out, JmsCarrier.SETTER);
            nextProducer.send(out);
        } finally {
            producerSpan.end();
        }
    }

    public static void main(String[] args) throws Exception {
        String collectorEndpoint = env("OTEL_COLLECTOR_ENDPOINT", "http://localhost:4317");
        String mqHost            = env("IBM_MQ_HOST", "localhost");
        int    mqPort            = Integer.parseInt(env("IBM_MQ_PORT", "1414"));
        String mqQueueManager    = env("IBM_MQ_QUEUE_MANAGER", "QM1");
        String mqChannel         = env("IBM_MQ_CHANNEL", "DEV.APP.SVRCONN");
        String mqInQueue         = env("IBM_MQ_IN_QUEUE", "DEV.QUEUE.2");
        String mqNextQueue       = env("IBM_MQ_NEXT_QUEUE", "DEV.QUEUE.3");
        String mqUser            = env("IBM_MQ_USER", "app");
        String mqPassword        = env("IBM_MQ_PASSWORD", "passw0rd");
        String serviceName       = env("SERVICE_NAME", "enricher");

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
        Enricher        enricher = new Enricher(otel, session, mqNextQueue);

        log.info("Enricher listening on " + mqInQueue + " → " + mqNextQueue);

        while (true) {
            Message msg = consumer.receive();
            if (msg != null) {
                try {
                    enricher.handle(msg);
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
