package tutorial;

import io.micrometer.tracing.BaggageInScope;
import io.micrometer.tracing.Span;
import io.micrometer.tracing.Tracer;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.jms.core.JmsTemplate;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@RestController
public class GatewayController {

    @Autowired private JmsTemplate jms;
    @Autowired private Tracer tracer;

    @Value("${app.mq.queue}")
    private String queue;

    @Value("${REQUIRED_BAGGAGE_KEY:bsi.ep}")
    private String requiredKey;

    @PostMapping("/send")
    public ResponseEntity<String> send(@RequestHeader HttpHeaders headers) {
        // Micrometer's Spring MVC instrumentation has already extracted traceparent +
        // W3C Baggage from the incoming HTTP headers and made them current.
        // For the middle-of-chain scenario, upstream baggage is already present here.

        List<BaggageInScope> scopes = new ArrayList<>();

        // Add any X-* headers not already in upstream baggage (upstream wins).
        headers.entrySet().stream()
            .filter(e -> e.getKey().toLowerCase().startsWith("x-"))
            .forEach(e -> {
                if (!e.getValue().isEmpty()) {
                    String key = headerToBaggageKey(e.getKey());
                    if (tracer.getBaggage(key).get() == null) {
                        scopes.add(tracer.createBaggage(key).set(e.getValue().get(0)));
                    }
                }
            });

        try {
            String ep = tracer.getBaggage(requiredKey).get();
            if (ep == null || ep.isBlank()) {
                return ResponseEntity.badRequest().body("missing " + requiredKey);
            }

            // Tag the current HTTP span with the business context baggage values.
            Span current = tracer.currentSpan();
            if (current != null) {
                tagIfPresent(current, "bsi.ep");
                tagIfPresent(current, "bsi.ch");
                tagIfPresent(current, "bsi.cj");
            }

            Map<String, String> body = new LinkedHashMap<>();
            List.of("bsi.ep", "bsi.ch", "bsi.cj").forEach(k -> {
                String v = tracer.getBaggage(k).get();
                if (v != null) body.put(k, v);
            });

            // JmsTemplate.convertAndSend() is observed by Micrometer — it injects
            // traceparent + W3C Baggage into JMS message string properties automatically.
            jms.convertAndSend(queue, "order | " + body);
            return ResponseEntity.ok("accepted");
        } finally {
            scopes.forEach(BaggageInScope::close);
        }
    }

    private void tagIfPresent(Span span, String baggageKey) {
        String v = tracer.getBaggage(baggageKey).get();
        if (v != null) span.tag(baggageKey, v);
    }

    private static String headerToBaggageKey(String header) {
        // HttpHeaders normalises to lowercase; strip "x-" prefix, replace "-" with "."
        return header.substring(2).replace('-', '.');
    }
}
