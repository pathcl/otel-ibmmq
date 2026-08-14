package tutorial;

import io.micrometer.tracing.Span;
import io.micrometer.tracing.Tracer;
import jakarta.jms.JMSException;
import jakarta.jms.TextMessage;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jms.annotation.JmsListener;
import org.springframework.jms.core.JmsTemplate;
import org.springframework.stereotype.Component;

import java.util.Set;
import java.util.logging.Logger;

@Component
public class ValidatorListener {

    private static final Logger log = Logger.getLogger(ValidatorListener.class.getName());
    private static final Set<String> BLOCKED_CJS = Set.of("bad-cj", "fraud", "blocked");

    @Autowired private JmsTemplate jms;
    @Autowired private Tracer tracer;

    @Value("${app.mq.next-queue}")
    private String nextQueue;

    @Value("${app.mq.dlq}")
    private String dlq;

    @Value("${REQUIRED_BAGGAGE_KEY:bsi.ep}")
    private String requiredKey;

    @JmsListener(destination = "${app.mq.in-queue}")
    public void onMessage(TextMessage message) throws JMSException {
        // Micrometer has extracted traceparent + W3C Baggage from the JMS message
        // properties and made them current — no JmsCarrier needed.

        String ep = tracer.getBaggage("bsi.ep").get();
        String ch = tracer.getBaggage("bsi.ch").get();
        String cj = tracer.getBaggage("bsi.cj").get();

        Span current = tracer.currentSpan();
        if (current != null) {
            if (ep != null) current.tag("bsi.ep", ep);
            if (ch != null) current.tag("bsi.ch", ch);
            if (cj != null) current.tag("bsi.cj", cj);
        }

        // Validate required baggage key present
        String primaryValue = tracer.getBaggage(requiredKey).get();
        if (primaryValue == null || primaryValue.isBlank()) {
            reject(message.getText(), "missing " + requiredKey, current);
            return;
        }

        // Check denylist
        if (cj != null && BLOCKED_CJS.contains(cj)) {
            reject(message.getText(), "blocked cj: " + cj, current);
            return;
        }

        // Forward — JmsTemplate propagates traceparent + baggage automatically
        jms.convertAndSend(nextQueue, message.getText());
    }

    private void reject(String body, String reason, Span current) {
        if (current != null) {
            current.tag("validation.rejected", "true");
            current.tag("validation.reason", reason);
            current.error(new RuntimeException(reason));
        }
        jms.send(dlq, session -> {
            var msg = session.createTextMessage(body);
            msg.setStringProperty("dlq_reason", reason);
            return msg;
        });
        log.warning("rejected: " + reason);
    }
}
