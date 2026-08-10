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
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;

import javax.jms.*;
import java.util.logging.Logger;

public class Processor {

    private static final Logger log = Logger.getLogger(Processor.class.getName());

    private final OpenTelemetry otel;
    private final Tracer tracer;
    private final LongCounter messagesProcessed;

    public Processor(OpenTelemetry otel) {
        this.otel   = otel;
        this.tracer = otel.getTracer("tutorial.processor");

        Meter meter = otel.getMeter("tutorial.processor");
        this.messagesProcessed = meter.counterBuilder("messages.processed")
            .setDescription("Total JMS messages processed by tenant")
            .setUnit("{message}")
            .build();
    }

    void process(Message message) throws JMSException {
        // Extract propagated context (traceparent + baggage) from JMS message properties.
        // Context.root() is used deliberately — we want a clean context, not whatever the
        // receive-loop thread happens to have. The trace link is established via setParent().
        Context extractedCtx = otel.getPropagators().getTextMapPropagator()
            .extract(Context.root(), message, JmsCarrier.GETTER);

        Span span = tracer.spanBuilder("processor.handle")
            .setSpanKind(SpanKind.CONSUMER)
            .setParent(extractedCtx)
            .startSpan();

        try (Scope scope = extractedCtx.with(span).makeCurrent()) {
            Baggage baggage = Baggage.fromContext(extractedCtx);

            span.setAttribute("messaging.system", "ibmmq");
            // Set all baggage entries as span attributes — no hardcoded key names.
            baggage.asMap().forEach((key, entry) -> span.setAttribute(key, entry.getValue()));

            // tenant.id drives the metric dimension (business logic).
            String tenantId = baggage.getEntryValue("tenant.id");
            String userId   = baggage.getEntryValue("user.id");

            // Record metric with tenant dimension — this is what powers the Grafana dashboard.
            messagesProcessed.add(1, Attributes.builder()
                .put("tenant.id", tenantId != null ? tenantId : "unknown")
                .build()
            );

            String body = message instanceof TextMessage t ? t.getText() : "(non-text)";
            log.info("Processed: " + body + " | tenant=" + tenantId + " user=" + userId);
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
        String mqQueue           = env("IBM_MQ_QUEUE", "DEV.QUEUE.1");
        String mqUser            = env("IBM_MQ_USER", "app");
        String mqPassword        = env("IBM_MQ_PASSWORD", "passw0rd");
        String serviceName       = env("SERVICE_NAME", "processor");

        OpenTelemetry otel = OtelConfig.init(serviceName, collectorEndpoint);

        MQConnectionFactory cf = new MQConnectionFactory();
        cf.setHostName(mqHost);
        cf.setPort(mqPort);
        cf.setQueueManager(mqQueueManager);
        cf.setChannel(mqChannel);
        cf.setTransportType(WMQConstants.WMQ_CM_CLIENT);

        Connection connection = connectWithRetry(cf, mqUser, mqPassword);
        connection.start();

        Processor processor = new Processor(otel);

        Session         session  = connection.createSession(false, Session.AUTO_ACKNOWLEDGE);
        Queue           queue    = session.createQueue(mqQueue);
        MessageConsumer consumer = session.createConsumer(queue);

        log.info("Processor listening on queue: " + mqQueue);

        while (true) {
            Message msg = consumer.receive();
            if (msg != null) {
                try {
                    processor.process(msg);
                } catch (Exception e) {
                    log.severe("Error processing message: " + e.getMessage());
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

    private static String env(String key, String defaultValue) {
        String val = System.getenv(key);
        return val != null ? val : defaultValue;
    }
}
