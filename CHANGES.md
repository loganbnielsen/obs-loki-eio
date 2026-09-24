# Changes

## 0.2.0

- **Asynchronous export (breaking).** `create` takes `~sw` and returns a `t`;
  `backend t` is the `Obs_eio` backend. Closing a span only enqueues its lines; a
  background fiber pushes them in batches (`?max_batch`, default 500). A slow or
  unreachable Loki no longer blocks the fiber that closed the span for up to the
  request timeout (Sol OBS-048 / FND-0051: a black-holed Loki made every log call
  take 5 s).
- The queue is bounded (`?max_queued`, default 10 000 spans). On overflow the oldest
  queued span is dropped and counted (`dropped t`).
- A failed push loses its batch and is reported on stderr (rate-limited to once per
  10 s). It no longer raises from `emit_span`, so `on_backend_error` no longer sees
  it.
- `flush ?timeout t` pushes everything queued and waits for in-flight pushes. Call it
  before a short-lived process exits.

## Unreleased (pre-0.2)

- `create` now rejects duplicate promoted stream labels and the reserved
  `service` label name up front, preventing duplicate keys in Loki stream
  label JSON.
- Missing promoted stream labels now warn once per backend instance instead
  of once per emitted span.

## 0.1.0

- Initial standalone OPAM package: `obs-eio` Loki push backend with logfmt span
  lines and HTTPS support.
- **Fixed (post-tag, found by independent review of the sibling `aws-eio` package's
  identical copy of this code):** the HTTPS wrapper (`Obs_loki_tls`) never seeded
  `Mirage_crypto_rng`, so every real TLS handshake failed with "The default
  generator is not yet initialized" — invisible to every test here since none of
  them exercised real TLS. Fixed with a domain-safe (`Atomic`+`Mutex`) cached seed,
  not a bare `Stdlib.Lazy.t` (documented unsafe across OCaml 5 domains).
- **Extracted (post-tag): `Obs_loki_tls` moved out to the standalone `https-eio`
  package.** The same wrapper turned out to be duplicated byte-for-byte in
  aws-eio's `Aws_tls`, obs-prometheus-eio's `Obs_prometheus_tls`, and Sun's in-tree
  `Kafka_service_tls`. `Obs_loki_tls` is deleted; `obs_loki.ml` now depends on
  `https-eio` directly, which also replaces the hand-rolled CA-bundle path list
  with the maintained `ca-certs` package. The TLS regression tests moved to
  `https-eio`'s own test suite.
