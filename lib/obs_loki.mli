(** Loki HTTP push backend for obs-eio.

    Emits one structured logfmt line per [Obs_eio.log] call made within a span,
    plus one span-completion line for spans with no [Obs_eio.log] calls.

    {b Export is asynchronous (0.2).} Closing a span renders its lines and
    enqueues them; a background fiber on the [sw] passed to {!create} pushes
    them in batches. A slow or unreachable Loki never blocks the fiber that
    closed the span. The queue is bounded ([max_queued] spans): on overflow the
    oldest queued span is dropped and counted ({!dropped}). A failed push loses
    that batch and is reported on stderr, at most once every 10 s. Call
    {!flush} before a short-lived process exits, or the last lines may never
    leave. [https://] URLs are supported via the system CA bundle.

    Log lines use wall-clock timestamps derived from each entry's monotonic
    timestamp and the close-time wall clock. The span-completion fallback line
    uses the close-time wall clock.

    Each pushed value is the Loki 2.x/3.x-compatible 2-element
    [\[timestamp_ns, log_line\]] form, not Loki 3's 3-element structured
    metadata — [trace_id]/[span_id] are carried as logfmt fields in the line
    body instead (query with [| logfmt] in LogQL), so lines stay searchable
    on Loki 2.x deployments (e.g. the loki-stack Helm chart) too.

    Stream labels are always [{service}] plus any context fields selected by
    [label_names].  Keep labels low-cardinality (env, region, tier);
    high-cardinality values (request_id, payment_id) belong in the log line.

    {[
      let loki =
        Obs_loki.create ~sw ~net:env#net ~clock:env#clock
          ~url:"http://localhost:3100"
          ~label_names:[Obs_loki.stream_label_exn "env";
                        Obs_loki.stream_label_exn "region"] () in
      let ot =
        Obs_eio.create ~service:"payments-worker"
          ~mono_clock:env#mono_clock ~backend:(Obs_loki.backend loki) in
      let ot = Obs_eio.with_context ot [("env", "prod"); ("region", "us-east-1")] in
      Obs_eio.with_span ot "payment.process" (fun sp ->
        Obs_eio.log sp Obs_eio.Info ~fields:[("payment_id", "p_123")] "processing")
    ]} *)

type stream_label = Obs_eio.label_name
(** Validated context field name that can be promoted to a Loki stream label. *)

val stream_label : string -> (stream_label, string) result
(** [stream_label name] validates [name] with [Obs_eio.label_name] and returns
    a typed Loki stream-label selector, or [Error _] on invalid names. *)

val stream_label_exn : string -> stream_label
(** Like [stream_label], but raises [Invalid_argument] instead of returning
    [Error]. Intended for static label-name literals (a source-code
    constant, as in the example above), not runtime data. *)

type t
(** A running Loki exporter. *)

val create
  :  sw:Eio.Switch.t
     (** Owns the background push fiber. Lines still queued when [sw] ends are
         lost unless {!flush} ran first. *)
  -> net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> url:string
     (** Base URL of the Loki instance, e.g. ["http://localhost:3100"].
         Must be an [http://] or [https://] URL with a host. The push path
         [/loki/api/v1/push] is appended automatically. *)
  -> ?timeout:float
     (** Request timeout in seconds. Must be positive. Default: [5.0]. *)
  -> ?headers:(string * string) list
     (** Extra HTTP headers, e.g. auth/proxy headers such as [X-Scope-OrgID]. *)
  -> ?label_names:stream_label list
     (** Context field names to promote to Loki stream labels. Missing context
         fields are logged to stderr once per backend instance and omitted.
         [service] is always included. Names must be unique and must not
         include [service]; invalid values raise [Invalid_argument].
         Default: []. *)
  -> ?max_queued:int
     (** Spans held while Loki is slow or down; the oldest is dropped beyond
         this. Must be positive. Default: [10_000]. *)
  -> ?max_batch:int
     (** Spans per push. Must be positive. Default: [500]. *)
  -> unit
  -> t

val backend : t -> Obs_eio.backend
(** The [Obs_eio] backend to compose into a handle. *)

val flush : ?timeout:float -> t -> unit
(** Push everything queued now, and wait for pushes already in flight, for at
    most [timeout] seconds (default [5.0]) -- a hard bound: a push still running
    at the deadline is abandoned and its lines reported lost. Returns early once
    nothing is left. Call it before a process exits. *)

val dropped : t -> int
(** Spans dropped so far because the queue was full. *)
