# 01 — Architecture

## Problem

Demonstrate OTel baggage propagation across an IBM MQ/JMS async boundary, making
business context (entry point, channel, customer journey — `bsi.ep`, `bsi.ch`,
`bsi.cj`) visible in traces and metrics without modifying every service's
business logic.

## Component map

```
 ┌──────────────────────────────────────────────────────────────────┐
 │  docker-compose network                                          │
 │                                                                  │
 │  curl /order (upstream :8081) or curl /send (gateway :8080)      │
 │     │                                                            │
 │     ▼                                                            │
 │  ┌──────────┐  HTTP + W3C headers  ┌─────────┐                  │
 │  │ upstream │────────────────────▶│ gateway │                  │
 │  │  :8081   │  (middle scenario)   │  :8080  │                  │
 │  └──────────┘                      └────┬────┘                  │
 │                                         │ JMS PUT DEV.QUEUE.1   │
 │                                         ▼                        │
 │                                   ┌──────────┐                  │
 │                                   │  ibmmq   │ QM1              │
 │                                   └────┬─────┘                  │
 │                               ┌────────┴─────────┐              │
 │                        valid  │                   │ bsi.cj       │
 │                               ▼                   │ blocked      │
 │                         ┌─────────┐               ▼              │
 │                         │validator│         ┌───────────┐        │
 │                         └────┬────┘         │dlq-handler│        │
 │                              │              └─────┬─────┘        │
 │                              ▼ DEV.QUEUE.2        │ OTLP/gRPC   │
 │                         ┌─────────┐               │              │
 │                         │ enricher│               │              │
 │                         └────┬────┘               │              │
 │                              │ DEV.QUEUE.3        │              │
 │                              ▼                    │              │
 │                         ┌─────────┐               │              │
 │                         │processor│               │              │
 │                         └────┬────┘               │              │
 │       all services           │ OTLP/gRPC          │              │
 │       export spans           └──────┬─────────────┘             │
 │                                     ▼                            │
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
1. upstream (middle scenario) or gateway (origin scenario) creates the root span
2. gateway injects `traceparent` + `baggage` (`bsi.ep`, `bsi.ch`, `bsi.cj`) into JMS message properties
3. IBM MQ delivers the message to validator
4. validator, enricher, and processor each extract headers and create child spans
5. If `bsi.cj` is in the blocklist, validator routes to DLQ; dlq-handler creates an ERROR span
6. All services export spans to otel-collector via OTLP/gRPC
7. otel-collector forwards to Tempo; Grafana queries Tempo showing the full 4–5 span trace

**Metric flow**
1. processor increments `messages.processed` counter (label: `bsi.ep`)
2. OTel SDK exports the counter to otel-collector via OTLP/gRPC every 60s
3. otel-collector exposes the metric on :8889 in Prometheus format
4. Prometheus scrapes :8889 every 15s
5. Grafana queries Prometheus for `messages_processed_total` broken down by `bsi.ep`

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
