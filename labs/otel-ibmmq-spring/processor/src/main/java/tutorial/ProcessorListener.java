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
public class ProcessorListener {

    private static final Logger log = Logger.getLogger(ProcessorListener.class.getName());

    @Autowired private Tracer tracer;
    @Autowired private MeterRegistry meterRegistry;

    @JmsListener(destination = "${app.mq.queue}")
    public void onMessage(TextMessage message) throws JMSException {
        String ep = tracer.getBaggage("bsi.ep").get();

        Span current = tracer.currentSpan();
        if (current != null) {
            if (ep != null) current.tag("bsi.ep", ep);
            String ch = tracer.getBaggage("bsi.ch").get();
            String cj = tracer.getBaggage("bsi.cj").get();
            if (ch != null) current.tag("bsi.ch", ch);
            if (cj != null) current.tag("bsi.cj", cj);
        }

        // Micrometer counter — no explicit SDK Meter setup required
        Counter.builder("messages.processed")
            .description("Total JMS messages processed by entry point")
            .tag("bsi.ep", ep != null ? ep : "unknown")
            .register(meterRegistry)
            .increment();

        log.info("processed: " + message.getText());
    }
}
