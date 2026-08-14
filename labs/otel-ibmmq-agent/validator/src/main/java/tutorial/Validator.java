package tutorial;

import com.ibm.mq.jms.MQConnectionFactory;
import com.ibm.msg.client.wmq.WMQConstants;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.StatusCode;

import javax.jms.*;
import java.util.Set;
import java.util.logging.Logger;

/**
 * Agent-mode validator: no OtelConfig, no JmsCarrier, no explicit span creation.
 *
 * The OTel Java agent wraps MessageListener.onMessage(), extracting traceparent + baggage
 * from the JMS message and making them current via Context before calling our code.
 * Inside onMessage(), Baggage.current() and Span.current() are the agent-created
 * CONSUMER span's context — set them directly to decorate the auto-created span.
 *
 * The agent also instruments both nextProducer.send() and dlqProducer.send(), creating
 * PRODUCER spans as children of the CONSUMER span automatically.
 */
public class Validator implements MessageListener {

    private static final Logger log = Logger.getLogger(Validator.class.getName());
    private static final Set<String> BLOCKED_CJS = Set.of("bad-cj", "blocked");

    private final Session session;
    private final MessageProducer nextProducer;
    private final MessageProducer dlqProducer;

    public Validator(Session session, String nextQueue, String dlqQueue) throws JMSException {
        this.session      = session;
        this.nextProducer = session.createProducer(session.createQueue(nextQueue));
        this.dlqProducer  = session.createProducer(session.createQueue(dlqQueue));
    }

    @Override
    public void onMessage(Message message) {
        // The agent has already extracted traceparent + baggage from the JMS message
        // and made them current. Baggage.current() and Span.current() are live here.
        try {
            Baggage baggage     = Baggage.current();
            String  requiredKey = env("REQUIRED_BAGGAGE_KEY", "bsi.ep");
            String  primary     = requiredKey.isEmpty() ? null : baggage.getEntryValue(requiredKey);
            String  cj          = baggage.getEntryValue("bsi.cj");

            if (!requiredKey.isEmpty() && (primary == null || primary.isBlank())) {
                reject(message, "missing " + requiredKey);
            } else if (cj != null && BLOCKED_CJS.contains(cj)) {
                reject(message, "bsi.cj blocked: " + cj);
            } else {
                forward(message);
                log.info("Validated OK | " + requiredKey + "=" + primary);
            }
        } catch (JMSException e) {
            log.severe("JMS error in onMessage: " + e.getMessage());
        }
    }

    private void forward(Message original) throws JMSException {
        String body = original instanceof TextMessage t ? t.getText() : "(non-text)";
        // Agent instruments this send(): PRODUCER span, child of the current CONSUMER span.
        nextProducer.send(session.createTextMessage(body));
    }

    private void reject(Message original, String reason) throws JMSException {
        // Decorate the agent-created CONSUMER span with rejection details.
        Span.current().setAttribute("validation.rejected", true);
        Span.current().setAttribute("validation.reason", reason);
        Span.current().setStatus(StatusCode.ERROR, reason);

        String body = original instanceof TextMessage t ? t.getText() : "(non-text)";
        TextMessage out = session.createTextMessage(body);
        out.setStringProperty("dlq_reason", reason);
        // Agent instruments this send(): PRODUCER span (ERROR) → DLQ.
        dlqProducer.send(out);
        log.warning("Message rejected → DLQ | reason=" + reason);
    }

    public static void main(String[] args) throws Exception {
        String mqHost      = env("IBM_MQ_HOST", "localhost");
        int    mqPort      = Integer.parseInt(env("IBM_MQ_PORT", "1414"));
        String mqQueueMgr  = env("IBM_MQ_QUEUE_MANAGER", "QM1");
        String mqChannel   = env("IBM_MQ_CHANNEL", "DEV.APP.SVRCONN");
        String mqInQueue   = env("IBM_MQ_IN_QUEUE", "DEV.QUEUE.1");
        String mqNextQueue = env("IBM_MQ_NEXT_QUEUE", "DEV.QUEUE.2");
        String mqDlqQueue  = env("IBM_MQ_DLQ", "DEV.DEAD.LETTER.QUEUE");
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
        consumer.setMessageListener(new Validator(session, mqNextQueue, mqDlqQueue));

        connection.start();
        log.info("Validator listening on " + mqInQueue + " (agent mode)");

        // Block main thread; message delivery happens on the JMS provider thread.
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
