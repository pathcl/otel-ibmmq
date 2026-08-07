package tutorial;

import io.opentelemetry.context.propagation.TextMapGetter;
import io.opentelemetry.context.propagation.TextMapSetter;

import javax.jms.JMSException;
import javax.jms.Message;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.logging.Logger;

public class JmsCarrier {

    private static final Logger log = Logger.getLogger(JmsCarrier.class.getName());

    static String sanitize(String key) {
        return key.replace("-", "_").replace(".", "_");
    }

    public static final TextMapSetter<Message> SETTER = (message, key, value) -> {
        try {
            message.setStringProperty(sanitize(key), value);
        } catch (JMSException e) {
            log.warning("Failed to set JMS property '" + key + "': " + e.getMessage());
        }
    };

    public static final TextMapGetter<Message> GETTER = new TextMapGetter<>() {
        @Override
        public Iterable<String> keys(Message message) {
            try {
                List<String> keys = new ArrayList<>();
                var names = message.getPropertyNames();
                while (names.hasMoreElements()) {
                    keys.add((String) names.nextElement());
                }
                return keys;
            } catch (JMSException e) {
                return Collections.emptyList();
            }
        }

        @Override
        public String get(Message message, String key) {
            try {
                return message.getStringProperty(sanitize(key));
            } catch (JMSException e) {
                return null;
            }
        }
    };
}
