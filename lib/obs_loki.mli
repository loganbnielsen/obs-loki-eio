(** Loki HTTP push backend for obs-eio.

    Emits one structured logfmt line per [Obs_eio.log] call made within a span,
    plus one span-completion line for spans with no [Obs_eio.log] calls. Lines
    are pushed synchronously to Loki's push API when the span closes — one
    HTTP POST per span, which can block the closing fiber up to the configured
    request timeout. There is no buffering, batching, or backpressure; this
    is the 0.1 behavior, not a temporary gap. If Loki is unreachable or
    returns a non-2xx response, the error is printed to stderr and the call
    returns normally — the observability backend never crashes or blocks the
    application beyond that one push. [https://] URLs are supported via the
    system CA bundle (see [error_to_string]'s [`No_system_ca_bundle]).

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
        Obs_loki.create ~net:env#net ~clock:env#clock
          ~url:"http://localhost:3100"
          ~label_names:[Obs_loki.stream_label "env";
                        Obs_loki.stream_label "region"] () in
      let ot =
        Obs_eio.create ~service:"payments-worker"
          ~mono_clock:env#mono_clock ~backend:loki in
      let ot = Obs_eio.with_context ot [("env", "prod"); ("region", "us-east-1")] in
      Obs_eio.with_span ot "payment.process" (fun sp ->
        Obs_eio.log sp Obs_eio.Info ~fields:[("payment_id", "p_123")] "processing")
    ]} *)

type stream_label = Obs_eio.label_name
(** Validated context field name that can be promoted to a Loki stream label. *)

val stream_label : string -> stream_label
(** [stream_label name] validates [name] with [Obs_eio.label_name] and returns a
    typed Loki stream-label selector. Raises [Invalid_argument] on invalid
    names. *)

val create
  :  net:_ Eio.Net.t
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
         fields are logged to stderr and omitted. [service] is always included.
         Names must be unique and must not include [service]; invalid values
         raise [Invalid_argument]. Default: []. *)
  -> unit
  -> Obs_eio.backend
