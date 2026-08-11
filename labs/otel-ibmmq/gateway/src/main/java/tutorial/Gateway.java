package tutorial;

import com.ibm.mq.jms.MQConnectionFactory;
import com.ibm.msg.client.wmq.WMQConstants;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;
import io.opentelemetry.context.propagation.TextMapGetter;

import javax.jms.*;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.logging.Logger;

public class Gateway {

    private static final Logger log = Logger.getLogger(Gateway.class.getName());

    private final OpenTelemetry otel;
    private final Tracer tracer;
    private final Connection jmsConnection;
    private final String queueName;

    public Gateway(OpenTelemetry otel, Connection jmsConnection, String queueName) {
        this.otel = otel;
        this.tracer = otel.getTracer("tutorial.gateway");
        this.jmsConnection = jmsConnection;
        this.queueName = queueName;
    }

    // Derives the W3C Baggage key from an HTTP header name.
    // Strips the leading "x-" or "X-" prefix, lowercases everything, and
    // replaces "-" with "." so that X-Tenant-ID becomes tenant.id.
    private static String headerToBaggageKey(String header) {
        return header.substring(2).toLowerCase().replace('-', '.');
    }

    void handle(HttpExchange exchange) throws IOException {
        if (!"POST".equalsIgnoreCase(exchange.getRequestMethod())) {
            exchange.sendResponseHeaders(405, -1);
            return;
        }

        // Extract incoming trace context (traceparent + W3C baggage from upstream).
        Context parentCtx = otel.getPropagators().getTextMapPropagator()
            .extract(Context.current(), exchange, new TextMapGetter<HttpExchange>() {
                @Override
                public Iterable<String> keys(HttpExchange carrier) {
                    return carrier.getRequestHeaders().keySet();
                }
                @Override
                public String get(HttpExchange carrier, String key) {
                    return carrier.getRequestHeaders().getFirst(key);
                }
            });

        // Collect context values: upstream baggage first (takes precedence),
        // then any X-* request headers that are not already present.
        // Java HttpServer lowercases header names, so we match on "x-".
        Map<String, String> values = new LinkedHashMap<>();
        Baggage.fromContext(parentCtx).asMap()
            .forEach((k, e) -> values.put(k, e.getValue()));
        exchange.getRequestHeaders().forEach((name, vals) -> {
            if (name.toLowerCase().startsWith("x-") && !vals.isEmpty()) {
                values.putIfAbsent(headerToBaggageKey(name), vals.get(0));
            }
        });

        // Optional required key — configurable via REQUIRED_BAGGAGE_KEY env var.
        // Default is tenant.id; set to empty string to accept any non-empty X-* set.
        String requiredKey = env("REQUIRED_BAGGAGE_KEY", "tenant.id");
        if (!requiredKey.isEmpty() && (!values.containsKey(requiredKey) || values.get(requiredKey).isBlank())) {
            byte[] msg = (requiredKey + " required (send X-" + requiredKey.replace('.', '-').toUpperCase() + " header)\n").getBytes();
            exchange.sendResponseHeaders(400, msg.length);
            exchange.getResponseBody().write(msg);
            return;
        }

        // Build a fresh baggage from the merged values and attach to parent context.
        // In middle-of-chain mode the upstream entries dominate (putIfAbsent above);
        // in origin mode the X-* headers seed everything.
        var bb = Baggage.builder();
        values.forEach(bb::put);
        Context ctx = bb.build().storeInContext(parentCtx);

        Span span = tracer.spanBuilder("gateway.send")
            .setSpanKind(SpanKind.PRODUCER)
            .setParent(ctx)
            .startSpan();

        try (Scope scope = ctx.with(span).makeCurrent()) {
            span.setAttribute("messaging.system", "ibmmq");
            span.setAttribute("messaging.destination.name", queueName);
            values.forEach((k, v) -> span.setAttribute(k, v));

            Session session = jmsConnection.createSession(false, Session.AUTO_ACKNOWLEDGE);
            Queue queue    = session.createQueue(queueName);
            TextMessage message = session.createTextMessage("order | " + values);

            otel.getPropagators().getTextMapPropagator()
                .inject(Context.current(), message, JmsCarrier.SETTER);

            session.createProducer(queue).send(message);
            session.close();

            byte[] body = ("sent | " + values + "\n").getBytes();
            exchange.sendResponseHeaders(200, body.length);
            exchange.getResponseBody().write(body);
            log.info("Message sent | " + values);
        } catch (JMSException e) {
            span.recordException(e);
            log.severe("JMS error: " + e.getMessage());
            exchange.sendResponseHeaders(500, -1);
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
        String serviceName       = env("SERVICE_NAME", "gateway");

        OpenTelemetry otel = OtelConfig.init(serviceName, collectorEndpoint);

        MQConnectionFactory cf = new MQConnectionFactory();
        cf.setHostName(mqHost);
        cf.setPort(mqPort);
        cf.setQueueManager(mqQueueManager);
        cf.setChannel(mqChannel);
        cf.setTransportType(WMQConstants.WMQ_CM_CLIENT);

        Connection connection = connectWithRetry(cf, mqUser, mqPassword);
        connection.start();

        Gateway gateway = new Gateway(otel, connection, mqQueue);

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
        log.info("Gateway listening on :8080");
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
