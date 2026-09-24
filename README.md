# obs-loki-eio

Loki HTTP push backend for [`obs-eio`](https://github.com/loganbnielsen/obs-eio).
Converts span events into structured logfmt log lines and pushes them to Loki's push
API when each span closes. `trace_id` and `span_id` are logfmt fields inside the log
line body (searchable via `| logfmt` in LogQL), not Loki 3's structured metadata — see
[Structured Metadata](#structured-metadata) below for why.

Extracted from the [Sun](https://github.com/loganbnielsen/sun) platform, where it
continues to be used as an external dependency.

## Build

```bash
eval $(opam env)
# Until obs-eio is in your switch from OPAM, pin the sibling checkout:
# opam pin add obs-eio ../obs-eio -yn
dune build
```

## Test

```bash
# Unit tests (mock server, no infrastructure)
dune runtest

# Also run live Loki round-trip tests
LOKI_URL=http://localhost:3100 dune test --force
```

## Public API

```ocaml
type t

val create
  :  sw:Eio.Switch.t
     (** Owns the background push fiber. *)
  -> net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> url:string
     (** Base URL, e.g. "http://localhost:3100". Push path appended automatically. *)
  -> ?timeout:float
     (** Request timeout in seconds. Default: 5.0. *)
  -> ?headers:(string * string) list
     (** Extra HTTP headers, e.g. auth/proxy headers such as X-Scope-OrgID. *)
  -> ?label_names:Obs_loki.stream_label list
     (** Context field names to promote to Loki stream labels (low-cardinality only).
         Missing context fields are logged to stderr and omitted. [service] is
         always included. Default: []. *)
  -> ?max_queued:int   (** Spans held while Loki is slow/down. Default: 10_000. *)
  -> ?max_batch:int    (** Spans per push. Default: 500. *)
  -> unit
  -> t

val backend : t -> Obs_eio.backend
val flush : ?timeout:float -> t -> unit   (* before a short-lived process exits *)
val dropped : t -> int                     (* spans dropped on queue overflow *)
```

HTTPS setup is delegated to `https-eio`, which provides the typed setup errors used by
`create`.

## Log Line Format

Each `Obs_eio.log` call within a span becomes one Loki log line in **logfmt** format:

```
level=info msg="processing payment" span=payment.process key=val
```

Spans that close without any `Obs_eio.log` calls emit a single completion line:

```
level=info span=payment.process status=ok
```

## Structured Metadata

Each pushed value is the plain 2-element `[timestamp_ns, log_line]` form, not Loki 3's
3-element structured-metadata tuple:

```json
["1749042259000000000", "level=info msg=hello span=op trace_id=abc... span_id=def..."]
```

`trace_id` and `span_id` are logfmt fields in the log line body instead. This is a
deliberate compatibility choice, not a gap: 3-element structured metadata is incompatible
with Loki 2.x (e.g. the loki-stack Helm chart), and putting the trace fields in the line
keeps them searchable — filterable, though not indexed or clickable the way Loki 3
structured metadata is — on both Loki 2.x and 3.x:

- **Filterable** — `{service="foo"} | logfmt | trace_id="abc..."` works in LogQL
- **Not indexed** — unlike structured metadata, these are plain line text to Loki
- **Not a dedicated Grafana Explore field** — they show up as parsed logfmt fields, not
  the structured-metadata column

Revisit this if the deployment target becomes Loki 3-only, or behind an explicit
compatibility flag.

## Stream Labels

Stream labels are always `{"service": "<service>"}` plus any selected context fields.
Keep labels low-cardinality — `env`, `region`, `tier` are good candidates; `payment_id`,
`request_id` are not.

```ocaml
let loki = Obs_loki.create ~sw ~net:env#net ~clock:env#clock
             ~url:"http://localhost:3100"
             ~label_names:[Obs_loki.stream_label_exn "env";
                           Obs_loki.stream_label_exn "region"] () in
let ot = Obs_eio.create ~service:"payments-worker"
           ~mono_clock:env#mono_clock ~backend:(Obs_loki.backend loki) () in
let ot = Obs_eio.with_context ot [("env", "prod"); ("region", "eu-west-1")] in
```

Resulting stream: `{service="payments-worker", env="prod", region="eu-west-1"}`

## Error Handling

`emit_span` never touches the network, so it never fails because of Loki. If a push
fails (unreachable, timeout, non-2xx), that batch is lost and the failure is printed to
stderr by the push fiber, with the error and the running drop count, at most once
every 10 seconds.

## Timestamps

Log line timestamps are wall-clock nanoseconds derived from the `clock` passed to
`create` and each entry's monotonic timestamp. The span-completion fallback line uses
the span close time.

## HTTPS

`https://` URLs are supported: the client authenticates against the system CA bundle
via `https-eio`/`ca-certs` and refuses to connect without certificate verification. TLS
setup failures are push failures (see Error Handling).

## Buffering and Backpressure

Asynchronous since 0.2. The 0.1 synchronous push put up to the request timeout on
every span close, so a slow or black-holed Loki made every log call in the
application slow. Sol measured 5 s per call (Sol OBS-048 / FND-0051). That is the
latency problem the 0.1 note said would justify a queue.

`emit_span` renders and enqueues. A fiber on the `sw` given to `create` pushes batches
of up to `max_batch` spans. The queue holds `max_queued` spans; beyond that the oldest
is dropped and counted (`dropped`). The lifecycle cost is `flush`: a process that
exits right after logging, such as a cron job, must call `flush` first, or its last
lines never leave.

## Local Development

A local Loki instance is only needed for the live round-trip tests
(`LOKI_URL=http://localhost:3100 dune test --force`); unit tests need nothing running.

```bash
docker run -d --name loki -p 3100:3100 grafana/loki:latest
```

Recommended LogQL queries once a service is pushing logs through this backend:

```logql
{service="payments-worker"} | logfmt
{service=~"loki-.*"} | logfmt | level="error"
{service="payments-worker"} | logfmt | trace_id="<id>"
```

## Out of Scope (v1)

- `emit_metric` — metrics go to `obs-prometheus-eio`, not Loki
- Retrying a failed batch — it is dropped and reported; the queue is for latency, not
  durability
