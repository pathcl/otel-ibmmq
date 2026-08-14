package tutorial;

import com.ibm.mq.jms.MQConnectionFactory;
import com.ibm.msg.client.wmq.WMQConstants;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;

import javax.jms.*;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.logging.Logger;

/**
 * Agent-mode gateway: no explicit span creation, no JmsCarrier, no OtelConfig.
 *
 * The OTel Java agent instruments:
 *   - The JDK HttpServer HttpHandler.handle() → HTTP SERVER span (auto)
 *   - MessageProducer.send() → JMS PRODUCER span (auto), injects traceparent + baggage
 *
 * The gateway's only OTel responsibility is building W3C Baggage from X-bsi-* headers
 * and making it current so the agent reads it when it intercepts send().
 */
public class Gateway {

    private static final Logger log = Logger.getLogger(Gateway.class.getName());

    private final Connection jmsConnection;
    private final String queueName;

    public Gateway(Connection jmsConnection, String queueName) {
        this.jmsConnection = jmsConnection;
        this.queueName = queueName;
    }

    private static String headerToBaggageKey(String header) {
        return header.substring(2).toLowerCase().replace('-', '.');
    }

    void handle(HttpExchange exchange) throws IOException {
        if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
            exchange.sendResponseHeaders(405, -1);
            return;
        }

        // The agent extracts W3C propagation headers (traceparent, baggage) from the
        // incoming HTTP request and makes them available via Context.current().
        // We supplement with X-bsi-* headers that are not part of the W3C baggage standard.
        Map<String, String> values = new LinkedHashMap<>();
        Baggage.current().asMap().forEach((k, e) -> values.put(k, e.getValue()));
        exchange.getRequestHeaders().forEach((name, vals) -> {
            if (name.toLowerCase().startsWith("x-") && !vals.isEmpty()) {
                values.putIfAbsent(headerToBaggageKey(name), vals.get(0));
            }
        });

        String requiredKey = env("REQUIRED_BAGGAGE_KEY", "bsi.ep");
        if (!requiredKey.isEmpty() && (!values.containsKey(requiredKey) || values.get(requiredKey).isBlank())) {
            byte[] msg = (requiredKey + " required (send X-" + requiredKey.replace('.', '-').toUpperCase() + " header)\n").getBytes();
            exchange.sendResponseHeaders(400, msg.length);
            exchange.getResponseBody().write(msg);
            return;
        }

        // Build enriched baggage and make it current for the duration of the JMS send.
        // The agent reads Context.current() when it intercepts send() and injects
        // traceparent + baggage into the message MQRFH2 <usr> folder.
        Baggage.Builder bb = Baggage.builder();
        values.forEach(bb::put);

        try (Scope s = bb.build().storeInContext(Context.current()).makeCurrent()) {
            Session session = jmsConnection.createSession(false, Session.AUTO_ACKNOWLEDGE);
            Queue queue = session.createQueue(queueName);
            // Agent instruments this send(): creates PRODUCER span, injects traceparent + baggage.
            session.createProducer(queue).send(session.createTextMessage("order | " + values));
            session.close();

            byte[] body = ("sent | " + values + "\n").getBytes();
            exchange.sendResponseHeaders(200, body.length);
            exchange.getResponseBody().write(body);
            log.info("Message sent | " + values);
        } catch (JMSException e) {
            log.severe("JMS error: " + e.getMessage());
            exchange.sendResponseHeaders(500, -1);
        }
    }

    public static void main(String[] args) throws Exception {
        String mqHost         = env("IBM_MQ_HOST", "localhost");
        int    mqPort         = Integer.parseInt(env("IBM_MQ_PORT", "1414"));
        String mqQueueManager = env("IBM_MQ_QUEUE_MANAGER", "QM1");
        String mqChannel      = env("IBM_MQ_CHANNEL", "DEV.APP.SVRCONN");
        String mqQueue        = env("IBM_MQ_QUEUE", "DEV.QUEUE.1");
        String mqUser         = env("IBM_MQ_USER", "app");
        String mqPassword     = env("IBM_MQ_PASSWORD", "passw0rd");

        MQConnectionFactory cf = new MQConnectionFactory();
        cf.setHostName(mqHost);
        cf.setPort(mqPort);
        cf.setQueueManager(mqQueueManager);
        cf.setChannel(mqChannel);
        cf.setTransportType(WMQConstants.WMQ_CM_CLIENT);

        Connection connection = connectWithRetry(cf, mqUser, mqPassword);
        connection.start();

        Gateway gateway = new Gateway(connection, mqQueue);

        HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);
        server.createContext("/send", exchange -> {
            try {
                gateway.handle(exchange);
            } catch (Exception e) {
                log.severe("Unhandled error: " + e.getMessage());
            } finally {
                exchange.close();
            }
        });
        server.start();
        log.info("Gateway listening on :8080 (agent mode)");
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
