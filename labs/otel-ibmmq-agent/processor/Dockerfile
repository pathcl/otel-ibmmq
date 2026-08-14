FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app

ARG OTEL_AGENT_VERSION=2.9.0
RUN wget -q -O /tmp/otel-agent.jar \
    https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar

COPY pom.xml .
RUN mvn dependency:resolve -q
COPY src ./src
RUN mvn package -DskipTests -q

FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
COPY --from=build /tmp/otel-agent.jar otel-agent.jar
COPY --from=build /app/target/processor-1.0.jar app.jar
ENTRYPOINT ["java", "-jar", "app.jar"]
