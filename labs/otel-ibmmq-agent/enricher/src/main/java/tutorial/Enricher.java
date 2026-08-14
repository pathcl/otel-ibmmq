package tutorial;

import com.ibm.mq.jms.MQConnectionFactory;
import com.ibm.msg.client.wmq.WMQConstants;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.api.trace.Span;

import javax.jms.*;
import java.util.Map;
import java.util.UUID;
import java.util.logging.Logger;

/**
 * Agent-mode enricher: zero explicit OTel instrumentation for tracing.
 *
 * The agent wraps onMessage(), extracts traceparent + baggage from the message,
 * creates a CONSUMER span, and makes context current. Business logic reads
 * Baggage.current() for the bsi.ep → region lookup and decorates Span.current()
 * with enrichment attributes. The downstream send() is also auto-instrumented.
 */
public class Enricher implements MessageListener {

    private static final Logger log = Logger.getLogger(Enricher.class.getName());

    private static final Map<String, String> EP_REGIONS = Map.of(
        "checkout", "eu-west-1",
        "payment",  "us-east-1",
        "account",  "ap-southeast-1"
    );

    private final Session session;
    private final MessageProducer nextProducer;

    public Enricher(Session session, String nextQueue) throws JMSException {
        this.session      = session;
        this.nextProducer = session.createProducer(session.createQueue(nextQueue));
    }

    @Override
    public void onMessage(Message message) {
        try {
            String ep           = Baggage.current().getEntryValue("bsi.ep");
            String region       = ep != null ? EP_REGIONS.getOrDefault(ep, "unknown") : "unknown";
            String processingId = UUID.randomUUID().toString().substring(0, 8);

            // Decorate the agent-created CONSUMER span with enrichment attributes.
            Span.current().setAttribute("enriched.region", region);
            Span.current().setAttribute("enriched.processing_id", processingId);

            String body = message instanceof TextMessage t ? t.getText() : "(non-text)";
            String enrichedBody = body + " | region=" + region + " | processing_id=" + processingId;

            // Agent instruments this send(): PRODUCER span, child of the CONSUMER span.
            nextProducer.send(session.createTextMessage(enrichedBody));
            log.info("Enriched | ep=" + ep + " region=" + region + " id=" + processingId);
        } catch (JMSException e) {
            log.severe("JMS error in onMessage: " + e.getMessage());
        }
    }

    public static void main(String[] args) throws Exception {
        String mqHost      = env("IBM_MQ_HOST", "localhost");
        int    mqPort      = Integer.parseInt(env("IBM_MQ_PORT", "1414"));
        String mqQueueMgr  = env("IBM_MQ_QUEUE_MANAGER", "QM1");
        String mqChannel   = env("IBM_MQ_CHANNEL", "DEV.APP.SVRCONN");
        String mqInQueue   = env("IBM_MQ_IN_QUEUE", "DEV.QUEUE.2");
        String mqNextQueue = env("IBM_MQ_NEXT_QUEUE", "DEV.QUEUE.3");
        String mqUser      = env("IBM_MQ_USER", "app");
        String mqPassword  = env("IBM_MQ_PASSWORD", "passw0rd");

        MQConnectionFactory cf = new MQConnectionFactory();
        cf.setHostName(mqHost);
        cf.setPort(mqPort);
        cf.setQueueManager(mqQueueMgr);
        cf.setChannel(mqChannel);
        cf.setTransportType(WMQConstants.WMQ_CM_CLIENT);

        Connection connection = connectWithRetry(cf, mqUser, mqPassword);

        Session session = connection.createSession(false, Session.AUTO_ACKNOWLEDGE);
        MessageConsumer consumer = session.createConsumer(session.createQueue(mqInQueue));
        consumer.setMessageListener(new Enricher(session, mqNextQueue));

        connection.start();
        log.info("Enricher listening on " + mqInQueue + " (agent mode)");

        Thread.currentThread().join();
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
