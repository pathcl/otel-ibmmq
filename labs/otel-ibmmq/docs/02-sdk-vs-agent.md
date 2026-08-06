# 02 — OTel SDK vs Java Agent

## Decision: use the OTel SDK manually, not the Java agent

### What the agent gives you

The OTel Java agent (`opentelemetry-javaagent.jar`) auto-instruments JMS by bytecode
manipulation at startup. You attach it with:

```
java -javaagent:opentelemetry-javaagent.jar -jar app.jar
```

It instruments `javax.jms.MessageProducer.send()` and `javax.jms.MessageConsumer.receive()`
without any code changes. Baggage propagation requires only:

```
-Dotel.propagators=tracecontext,baggage
```

### Why we chose the SDK instead

**1. Learning value**
The JmsCarrier (TextMapSetter/Getter) is the core mechanism behind all OTel transport
adapters — HTTP headers, Kafka record headers, AMQP message properties. Writing it
explicitly makes the propagation model visible rather than magic.

**2. Control over context boundaries**
In the processor, we use `Context.root()` as the extraction base rather than
`Context.current()`. This is a deliberate choice (see docs/03-jms-carrier.md). The
agent does not give you this control.

**3. No JVM startup flags in Dockerfiles**
The agent approach requires coordinating the agent jar version, JVM flags, and startup
scripts across containers. The SDK approach is self-contained in the application.

**4. Explicit metric definition**
The agent can auto-create messaging metrics (message count, duration) but with fixed
attribute names. The SDK lets us define `messages.processed` with a `tenant.id`
attribute that maps directly to our Grafana dashboard.

### When to use the agent instead

- Brownfield applications where adding SDK dependencies is not feasible
- When you want zero-code instrumentation across dozens of services quickly
- When using frameworks (Spring, Quarkus) that have their own OTel integrations

The agent and SDK are not mutually exclusive — you can use the agent for automatic
instrumentation and add SDK calls for custom spans and metrics.
