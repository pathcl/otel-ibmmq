package tutorial;

import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.context.Context;
import io.opentelemetry.sdk.trace.ReadWriteSpan;
import io.opentelemetry.sdk.trace.ReadableSpan;
import io.opentelemetry.sdk.trace.SpanProcessor;

/**
 * Copies all W3C Baggage entries from the parent context to span attributes on every
 * span start. This is the stable alternative to the experimental env var:
 *   OTEL_JAVA_EXPERIMENTAL_SPAN_ATTRIBUTES_COPY_FROM_BAGGAGE_INCLUDE
 *
 * The experimental env var copies a fixed list of keys; this processor copies all keys
 * and can be extended with filtering or value transformation logic if needed.
 *
 * Registered via BaggageSpanProcessorCustomizer, which is discovered by the agent
 * through META-INF/services/io.opentelemetry.sdk.autoconfigure.spi.AutoConfigurationCustomizerProvider.
 */
public class BaggageCopySpanProcessor implements SpanProcessor {

    @Override
    public void onStart(Context parentContext, ReadWriteSpan span) {
        Baggage.fromContext(parentContext).asMap()
            .forEach((key, entry) -> span.setAttribute(key, entry.getValue()));
    }

    @Override
    public boolean isStartRequired() {
        return true;
    }

    @Override
    public void onEnd(ReadableSpan span) {}

    @Override
    public boolean isEndRequired() {
        return false;
    }
}
