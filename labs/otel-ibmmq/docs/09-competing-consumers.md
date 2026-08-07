# 09 — Competing Consumers Pattern

## What it is

Multiple instances of the same service all drain the same IBM MQ queue. IBM MQ
distributes messages across them — whichever instance calls `consumer.receive()`
first gets the message. This is how enterprises handle throughput without changing
application code: add more consumer instances.

## Our setup

Two `processor` instances drain `DEV.QUEUE.3`:

```
enricher → DEV.QUEUE.3 → processor-1  ┐
                       → processor-2  ┘ same SERVICE_NAME="processor"
```

Docker Compose starts both via `deploy.replicas: 2` in `docker-compose.yml`:

```yaml
processor:
  build: ./processor
  environment:
    SERVICE_NAME: processor         # both instances share the same name
    IBM_MQ_QUEUE: DEV.QUEUE.3
  deploy:
    replicas: 2
```

## Why they appear as one node in the service graph

Tempo's service-graphs processor groups spans by `service.name`. Both `processor-1`
and `processor-2` send spans with `service.name=processor`, so they collapse into a
single node. The edge `enricher → processor` shows the **combined** request rate of
both instances. This is correct — from a topology perspective they are the same
logical service.

## Verifying load distribution

Run a burst of messages and check which container handled each one:

```bash
for i in $(seq 1 20); do
  curl -s -X POST http://localhost:8080/send \
    -H "X-Tenant-ID: acme" -H "X-User-ID: user$i" > /dev/null
done

docker compose -f labs/otel-ibmmq/docker-compose.yml logs processor \
  | grep "Processed" | awk '{print $1}' | sort | uniq -c
```

You will see messages split roughly 50/50 between `processor-1` and `processor-2`.
IBM MQ does not guarantee equal distribution — it's first-come-first-served.

## Scaling at runtime

Add a third instance without restarting the stack:

```bash
docker compose -f labs/otel-ibmmq/docker-compose.yml up -d --scale processor=3
```

Remove the extra instance:

```bash
docker compose -f labs/otel-ibmmq/docker-compose.yml up -d --scale processor=2
```

IBM MQ handles the change transparently — existing connections drain normally.

## What this does NOT show

Competing consumers is an **infrastructure-level** pattern. In the service graph it
is invisible by design: the node graph shows one `processor` node regardless of how
many instances are running. The effect is visible only in:

- Higher request rate on the `enricher → processor` edge
- IBM MQ queue depth dropping faster under load (check at https://localhost:9443)
- `messages_processed_total` counter climbing at 2× the rate

## Relationship to the other patterns

The three patterns stack:

```
Pipeline (07)     → adds stages (more nodes/edges in the graph)
DLQ (08)          → adds an error path (new node + error arcs)
Competing (09)    → increases throughput of one stage (invisible in graph, visible in metrics)
```

This combination — a validated, enriched pipeline with DLQ safety and scaled final
processing — is representative of how IBM MQ is deployed in production at large
financial institutions.
