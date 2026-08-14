package tutorial;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.tracing.Span;
import io.micrometer.tracing.Tracer;
import jakarta.jms.JMSException;
import jakarta.jms.TextMessage;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jms.annotation.JmsListener;
import org.springframework.stereotype.Component;

import java.util.logging.Logger;

@Component
public class DlqHandlerListener {

    private static final Logger log = Logger.getLogger(DlqHandlerListener.class.getName());

    @Autowired private Tracer tracer;
    @Autowired private MeterRegistry meterRegistry;

    @JmsListener(destination = "${app.mq.dlq}")
    public void onMessage(TextMessage message) throws JMSException {
        String ep     = tracer.getBaggage("bsi.ep").get();
        String reason = message.getStringProperty("dlq_reason");

        Span current = tracer.currentSpan();
        if (current != null) {
            if (ep != null) current.tag("bsi.ep", ep);
            String ch = tracer.getBaggage("bsi.ch").get();
            String cj = tracer.getBaggage("bsi.cj").get();
            if (ch != null) current.tag("bsi.ch", ch);
            if (cj != null) current.tag("bsi.cj", cj);
            if (reason != null) current.tag("dlq.reason", reason);
            current.error(new RuntimeException("DLQ: " + reason));
        }

        Counter.builder("messages.rejected")
            .description("Total messages routed to the dead letter queue")
            .tag("bsi.ep", ep != null ? ep : "unknown")
            .tag("dlq.reason", reason != null ? reason : "unknown")
            .register(meterRegistry)
            .increment();

        log.warning("dlq: ep=" + ep + " reason=" + reason + " body=" + message.getText());
    }
}
