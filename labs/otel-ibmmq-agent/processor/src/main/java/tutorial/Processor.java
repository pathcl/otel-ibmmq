package tutorial;

import com.ibm.mq.jms.MQConnectionFactory;
import com.ibm.msg.client.wmq.WMQConstants;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;

import javax.jms.*;
import java.util.logging.Logger;

/**
 * Agent-mode processor: agent handles all JMS tracing. The only OTel code is
 * the custom business metric (messages_processed_total) which the agent cannot
 * auto-generate — it requires knowledge of the bsi.ep dimension.
 *
 * GlobalOpenTelemetry.get() is safe to call at startup because the agent
 * registers itself before main() runs.
 */
public class Processor implements MessageListener {

    private static final Logger log = Logger.getLogger(Processor.class.getName());

    private final LongCounter messagesProcessed;

    public Processor(LongCounter messagesProcessed) {
        this.messagesProcessed = messagesProcessed;
    }

    @Override
    public void onMessage(Message message) {
        try {
            // Baggage.current() is live here — the agent extracted it from the message.
            String ep   = Baggage.current().getEntryValue("bsi.ep");
            String body = message instanceof TextMessage t ? t.getText() : "(non-text)";

            messagesProcessed.add(1, Attributes.builder()
                .put("bsi.ep", ep != null ? ep : "unknown")
                .build());

            log.info("Processed: " + body + " | ep=" + ep);
        } catch (JMSException e) {
            log.severe("JMS error in onMessage: " + e.getMessage());
        }
    }

    public static void main(String[] args) throws Exception {
        String mqHost     = env("IBM_MQ_HOST", "localhost");
        int    mqPort     = Integer.parseInt(env("IBM_MQ_PORT", "1414"));
        String mqQueueMgr = env("IBM_MQ_QUEUE_MANAGER", "QM1");
        String mqChannel  = env("IBM_MQ_CHANNEL", "DEV.APP.SVRCONN");
        String mqQueue    = env("IBM_MQ_QUEUE", "DEV.QUEUE.3");
        String mqUser     = env("IBM_MQ_USER", "app");
        String mqPassword = env("IBM_MQ_PASSWORD", "passw0rd");

        // The agent is already initialised before main() runs — GlobalOpenTelemetry.get()
        // returns the agent's OpenTelemetry instance, not a no-op.
        LongCounter counter = GlobalOpenTelemetry.get()
            .getMeter("tutorial.processor")
            .counterBuilder("messages.processed")
            .setDescription("Total JMS messages processed by entry point")
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
        MessageConsumer consumer = session.createConsumer(session.createQueue(mqQueue));
        consumer.setMessageListener(new Processor(counter));

        connection.start();
        log.info("Processor listening on " + mqQueue + " (agent mode)");

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

    private static String env(String key, String defaultValue) {
        String val = System.getenv(key);
        return val != null ? val : defaultValue;
    }
}
