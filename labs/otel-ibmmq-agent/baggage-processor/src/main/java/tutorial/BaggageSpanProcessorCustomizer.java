package tutorial;

import io.opentelemetry.sdk.autoconfigure.spi.AutoConfigurationCustomizer;
import io.opentelemetry.sdk.autoconfigure.spi.AutoConfigurationCustomizerProvider;

/**
 * Registers BaggageCopySpanProcessor with the OTel Java agent's autoconfigure system.
 * Discovered via META-INF/services at agent startup.
 */
public class BaggageSpanProcessorCustomizer implements AutoConfigurationCustomizerProvider {

    @Override
    public void customize(AutoConfigurationCustomizer customizer) {
        customizer.addTracerProviderCustomizer(
            (builder, config) -> builder.addSpanProcessor(new BaggageCopySpanProcessor())
        );
    }
}
