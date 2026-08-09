# TODO

## Production-ready message inspection (improve from stop-validator workaround)

The current tutorial stops the validator container to create a browse window.
This is a learning workaround — not something you'd do in production.
Replace with one or more of these before the tutorial is production-ready:

- [ ] **Option A — Dedicated browse queue:** configure the gateway to mirror
      each message to `TEST.BROWSE` (no consumer). Messages accumulate, browse
      at leisure with no timing pressure and no service disruption.
- [ ] **Option B — MQ web console:** document how to use https://localhost:9443
      to browse messages via the IBM MQ web UI. Persistent, no race condition,
      no CLI required.
- [ ] **Option C — DLQ inspection:** trigger a deliberate failure, show the
      message landing on `DEV.DEAD.LETTER.QUEUE` with MQRFH2 intact. More
      realistic — this is what SREs actually do at 2am.
- [ ] Update Chapter 3 in ibmmq-tutorial.md to use whichever option is chosen
      and explain *why* the stop-validator approach is a learning shortcut

---

## IBM MQ Tutorial — Chapter 4: Break PROPCTL and watch orphan traces

Goal: hands-on exercise where the learner intentionally misconfigures PROPCTL,
sends traffic, observes orphan traces in Tempo, then restores the config and
watches traces reconnect. The "break it intentionally" moment from ibmmq-tutorial.md.

- [ ] Flip `DEV.QUEUE.1` to `PROPCTL(COMPAT)` via runmqsc
- [ ] Send a few messages via curl to upstream
- [ ] Browse DEV.QUEUE.1 with amqsbcg — confirm `<usr>` folder is absent
- [ ] Query Tempo — confirm orphan traces (PRODUCER and CONSUMER spans disconnected)
- [ ] Restore `PROPCTL(ALL)` on the queue
- [ ] Send another message — confirm connected trace reappears in Tempo
- [ ] Document the exact commands and Tempo screenshots in ibmmq-tutorial.md Chapter 4
- [ ] Add a "what broke and why" explanation for each failure mode observed
