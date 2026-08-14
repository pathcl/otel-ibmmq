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

import java.util.Map;
import java.util.UUID;

@Component
public class EnricherListener {

    private static final Map<String, String> EP_REGIONS = Map.of(
        "checkout", "eu-west-1",
        "payment",  "us-east-1",
        "account",  "ap-southeast-1"
    );

    @Autowired private JmsTemplate jms;
    @Autowired private Tracer tracer;

    @Value("${app.mq.next-queue}")
    private String nextQueue;

    @JmsListener(destination = "${app.mq.in-queue}")
    public void onMessage(TextMessage message) throws JMSException {
        String ep = tracer.getBaggage("bsi.ep").get();
        String region = EP_REGIONS.getOrDefault(ep != null ? ep : "", "unknown");
        String processingId = UUID.randomUUID().toString().substring(0, 8);

        Span current = tracer.currentSpan();
        if (current != null) {
            if (ep != null) current.tag("bsi.ep", ep);
            String ch = tracer.getBaggage("bsi.ch").get();
            String cj = tracer.getBaggage("bsi.cj").get();
            if (ch != null) current.tag("bsi.ch", ch);
            if (cj != null) current.tag("bsi.cj", cj);
            current.tag("enriched.region", region);
            current.tag("enriched.processing_id", processingId);
        }

        String enrichedBody = message.getText()
            + " | region=" + region
            + " | processing_id=" + processingId;

        jms.convertAndSend(nextQueue, enrichedBody);
    }
}
