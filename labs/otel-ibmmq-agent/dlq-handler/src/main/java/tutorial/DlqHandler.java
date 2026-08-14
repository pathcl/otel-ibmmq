package tutorial;

import com.ibm.mq.jms.MQConnectionFactory;
import com.ibm.msg.client.wmq.WMQConstants;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;

import javax.jms.*;
import java.util.logging.Logger;

/**
 * Agent-mode DLQ handler: agent auto-creates the CONSUMER span linked to the
 * validator's reject path. The handler decorates Span.current() with error status
 * and records the custom rejection metric.
 */
public class DlqHandler implements MessageListener {

    private static final Logger log = Logger.getLogger(DlqHandler.class.getName());

    private final LongCounter rejectedCounter;

    public DlqHandler(LongCounter rejectedCounter) {
        this.rejectedCounter = rejectedCounter;
    }

    @Override
    public void onMessage(Message message) {
        try {
            String ep     = Baggage.current().getEntryValue("bsi.ep");
            String reason = message.getStringProperty("dlq_reason");
            if (reason == null) reason = "unknown";

            // Decorate the agent-created CONSUMER span as ERROR.
            Span.current().setAttribute("dlq.reason", reason);
            Span.current().setStatus(StatusCode.ERROR, reason);
            Span.current().recordException(new RuntimeException("DLQ: " + reason));

            rejectedCounter.add(1, Attributes.builder()
                .put("bsi.ep",     ep != null ? ep : "unknown")
                .put("dlq.reason", reason)
                .build());

            String body = message instanceof TextMessage t ? t.getText() : "(non-text)";
            log.warning("DLQ | ep=" + ep + " reason=" + reason + " body=" + body);
        } catch (JMSException e) {
            log.severe("JMS error in onMessage: " + e.getMessage());
        }
    }

    public static void main(String[] args) throws Exception {
        String mqHost     = env("IBM_MQ_HOST", "localhost");
        int    mqPort     = Integer.parseInt(env("IBM_MQ_PORT", "1414"));
        String mqQueueMgr = env("IBM_MQ_QUEUE_MANAGER", "QM1");
        String mqChannel  = env("IBM_MQ_CHANNEL", "DEV.APP.SVRCONN");
        String mqDlqQueue = env("IBM_MQ_DLQ", "DEV.DEAD.LETTER.QUEUE");
        String mqUser     = env("IBM_MQ_USER", "app");
        String mqPassword = env("IBM_MQ_PASSWORD", "passw0rd");

        LongCounter counter = GlobalOpenTelemetry.get()
            .getMeter("tutorial.dlq-handler")
            .counterBuilder("messages.rejected")
            .setDescription("Total messages routed to the dead letter queue")
            .setUnit("{message}")
            .build();

        MQConnectionFactory cf = new MQConnectionFactory();
        cf.setHostName(mqHost);
        cf.setPort(mqPort);
        cf.setQueueManager(mqQueueMgr);
        cf.setChannel(mqChannel);
        cf.setTransportType(WMQConstants.WMQ_CM_CLIENT);

        Connection connection = connectWithRetry(cf, mqUser, mqPassword);

        Session session = connection.createSession(false, Session.AUTO_ACKNOWLEDGE);
        MessageConsumer consumer = session.createConsumer(session.createQueue(mqDlqQueue));
        consumer.setMessageListener(new DlqHandler(counter));

        connection.start();
        log.info("DLQ handler listening on " + mqDlqQueue + " (agent mode)");

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
