# 01 — Architecture

## Problem

Demonstrate OTel baggage propagation across an IBM MQ/JMS async boundary, making
business context (tenant, user) visible in traces and metrics without modifying
every service's business logic.

## Component map

```
 ┌──────────────────────────────────────────────────────────────────┐
 │  docker-compose network                                          │
 │                                                                  │
 │  curl /send                                                      │
 │     │                                                            │
 │     ▼                                                            │
 │  ┌─────────┐  JMS + OTel headers   ┌────────────┐               │
 │  │ gateway │──────────────────────▶│   ibmmq    │               │
 │  │  :8080  │                       │ QM1        │               │
 │  └────┬────┘                       └─────┬──────┘               │
 │       │ OTLP/gRPC                        │ JMS receive           │
 │       │                          ┌───────▼──────┐               │
 │       │                          │  processor   │               │
 │       │                          └───────┬──────┘               │
 │       │                                  │ OTLP/gRPC             │
 │       ▼                                  ▼                       │
 │  ┌──────────────────────────────────────────┐                   │
 │  │           otel-collector :4317           │                   │
 │  └──────────────┬───────────────────────────┘                   │
 │                 │                  │                             │
 │         traces (OTLP)    metrics (Prometheus scrape)            │
 │                 │                  │                             │
 │          ┌──────▼──────┐   ┌───────▼──────┐                    │
 │          │  tempo:3200 │   │ prometheus   │                    │
 │          └──────┬──────┘   └───────┬──────┘                    │
 │                 │                  │                             │
 │          ┌──────▼──────────────────▼──────┐                    │
 │          │         grafana :3001           │                    │
 │          └────────────────────────────────┘                    │
 └──────────────────────────────────────────────────────────────────┘
```

## Data flows

**Trace flow**
1. gateway creates a span (`gateway.send`, kind=PRODUCER)
2. gateway injects `traceparent` + `baggage` headers into JMS message properties
3. IBM MQ delivers the message
4. processor extracts the headers, creates a child span (`processor.handle`, kind=CONSUMER)
5. Both spans arrive at otel-collector via OTLP/gRPC
6. otel-collector forwards to Tempo via OTLP/gRPC
7. Grafana queries Tempo and shows the full trace with bsi.ep on both spans

**Metric flow**
1. processor increments `messages.processed` counter (label: `bsi.ep`)
2. OTel SDK exports the counter to otel-collector via OTLP/gRPC every 60s
3. otel-collector exposes the metric on :8889 in Prometheus format
4. Prometheus scrapes :8889 every 15s
5. Grafana queries Prometheus for `messages_processed_total` broken down by tenant

## Port map

| Service        | Host port | Purpose                        |
|----------------|-----------|--------------------------------|
| gateway        | 8080      | HTTP entry point for curl      |
| ibmmq          | 1414      | MQ client connections          |
| ibmmq          | 9443      | MQ console (optional)          |
| otel-collector | 4317      | OTLP/gRPC receiver             |
| otel-collector | 8889      | Prometheus scrape target       |
| tempo          | 3200      | Grafana datasource             |
| prometheus     | 9090      | Query UI + Grafana datasource  |
| grafana        | 3001      | Dashboard UI (3001 ≠ 3000 to   |
|                |           | avoid conflict with tutorial   |
|                |           | Grafana on 3000)               |
