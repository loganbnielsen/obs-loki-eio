# Changes

## Unreleased

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
