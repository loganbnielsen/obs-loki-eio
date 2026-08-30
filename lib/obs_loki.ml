(* ------------------------------------------------------------------ *)
(* HTTP client (cohttp-eio + Uri)                                      *)
(* ------------------------------------------------------------------ *)

let http_post ~net ~clock ~timeout ~headers ~url ~body =
  let push_url = Uri.with_path (Uri.of_string url) "/loki/api/v1/push" in
  let headers =
    Http.Header.of_list ([ ("Content-Type", "application/json") ] @ headers)
  in
  let body_src = Cohttp_eio.Body.of_string body in
  try
    Eio.Time.with_timeout_exn clock timeout (fun () ->
      Eio.Switch.run (fun sw ->
        match Https_eio.https_for_uri push_url with
        | Error error -> Error ("Loki push: " ^ Https_eio.error_to_string error)
        | Ok https ->
          let client = Cohttp_eio.Client.make ~https net in
          let (resp, resp_body) =
            Cohttp_eio.Client.post client ~sw ~headers ~body:body_src push_url
          in
          let code = Http.Status.to_int (Http.Response.status resp) in
          if code >= 200 && code < 300 then begin
            (* Drain body to avoid connection-level warnings. *)
            ignore (Eio.Buf_read.of_flow ~max_size:(64 * 1024) resp_body
                    |> Eio.Buf_read.take_all);
            Ok ()
          end else begin
            let raw =
              try
                Eio.Buf_read.of_flow ~max_size:(64 * 1024) resp_body
                |> Eio.Buf_read.take_all
              with _ -> ""
            in
            let truncated = String.sub raw 0 (min (String.length raw) 512) in
            let detail = if truncated = "" then "" else ": " ^ String.trim truncated in
            Error (Printf.sprintf "Loki returned HTTP %d%s" code detail)
          end))
  with
  | Eio.Time.Timeout -> Error (Printf.sprintf "Loki push timed out after %gs" timeout)
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn              -> Error ("Loki push: " ^ Printexc.to_string exn)

(* ------------------------------------------------------------------ *)
(* Encoding helpers                                                    *)
(* ------------------------------------------------------------------ *)

(* Values containing spaces, = or control chars are quoted. *)
let logfmt_val s =
  let needs_quotes = String.exists
    (fun c -> c = '=' || c = '"' || Char.code c <= 0x20 || Char.code c = 0x7f) s in
  if needs_quotes then Printf.sprintf "%S" s else s

let logfmt pairs =
  String.concat " "
    (List.map (fun (k, v) -> k ^ "=" ^ logfmt_val v) pairs)

let logfmt_key k =
  let valid = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '.' | '-' -> true
    | _ -> false
  in
  let s =
    String.map (fun c -> if valid c then c else '_') k
  in
  if s = "" then "field" else s

let logfmt_user_fields fields =
  let reserved = ["level"; "msg"; "span"; "status"; "trace_id"; "span_id"] in
  List.map (fun (k, v) ->
    let k = logfmt_key k in
    let k = if List.mem k reserved then "field_" ^ k else k in
    (k, v)
  ) fields

(* trace_id/span_id go in the line body, not structured metadata, so they stay searchable on both Loki 2.x and 3.x. *)
let trace_fields trace_id span_id =
  [("trace_id", trace_id); ("span_id", span_id)]

(* ------------------------------------------------------------------ *)
(* Payload construction (Yojson)                                       *)
(* ------------------------------------------------------------------ *)

let trace_id_hex (hi, lo) = Printf.sprintf "%016Lx%016Lx" hi lo
let span_id_hex id        = Printf.sprintf "%016Lx" id

let level_string = function
  | Obs_eio.Debug -> "debug"
  | Obs_eio.Info  -> "info"
  | Obs_eio.Warn  -> "warn"
  | Obs_eio.Error -> "error"

(* Loki expects timestamps as decimal-string nanoseconds. *)
let wall_now_ns clock = Int64.of_float (Eio.Time.now clock *. 1e9)
let unix_ns_string ns = Printf.sprintf "%Ld" ns

let stream_labels_json pairs =
  `Assoc (List.map (fun (k, v) -> (k, `String v)) pairs)

(* [timestamp_ns, log_line] 2-tuples — the Loki 2.x/3.x-compatible value format. *)
let loki_push_body ~stream_labels ~values =
  let stream_obj = stream_labels_json stream_labels in
  let values_json =
    `List (List.map (fun (ts, line) ->
      `List [ `String ts; `String line ]
    ) values)
  in
  let payload =
    `Assoc [
      "streams", `List [
        `Assoc [
          "stream", stream_obj;
          "values", values_json;
        ]
      ]
    ]
  in
  Yojson.Safe.to_string payload

(* ------------------------------------------------------------------ *)
(* Backend                                                             *)
(* ------------------------------------------------------------------ *)

type stream_label = Obs_eio.label_name

let stream_label = Obs_eio.label_name

let stream_label_to_string = Obs_eio.label_name_to_string

let validate_label_names label_names =
  let names = List.map stream_label_to_string label_names in
  if List.mem "service" names then
    invalid_arg "Obs_loki.create: label_names must not include reserved label \"service\"";
  let seen = Hashtbl.create (List.length names) in
  List.iter
    (fun name ->
      if Hashtbl.mem seen name then
        invalid_arg (Printf.sprintf "Obs_loki.create: duplicate stream label %S" name);
      Hashtbl.add seen name ())
    names;
  label_names

let validate_url url =
  let uri = Uri.of_string url in
  let scheme = Uri.scheme uri |> Option.map String.lowercase_ascii in
  (match scheme with
   | Some "http" | Some "https" -> ()
   | _ -> invalid_arg "Obs_loki.create: url must use http:// or https://");
  if Uri.host uri = None then
    invalid_arg "Obs_loki.create: url must include a host"

let selected_stream_labels ~warn_mutex ~warned_missing_labels ~context label_names =
  List.filter_map (fun label_name ->
    let name = stream_label_to_string label_name in
    match List.assoc_opt name context with
    | Some value -> Some (name, value)
    | None ->
      Mutex.lock warn_mutex;
      Fun.protect ~finally:(fun () -> Mutex.unlock warn_mutex) (fun () ->
        if not (Hashtbl.mem warned_missing_labels name) then begin
          Hashtbl.add warned_missing_labels name ();
          Printf.eprintf
            "[obs-loki] requested stream label %S missing from context\n%!"
            name
        end);
      None
  ) label_names

let create ~net ~clock ~url ?(timeout = 5.0) ?(headers = []) ?(label_names = []) () : Obs_eio.backend =
  if timeout <= 0. || classify_float timeout = FP_nan then
    invalid_arg "Obs_loki.create: timeout must be positive";
  validate_url url;
  let label_names = validate_label_names label_names in
  let warn_mutex = Mutex.create () in
  let warned_missing_labels = Hashtbl.create (List.length label_names) in
  let emit_span (e : Obs_eio.span_event) =
    let stream_labels =
      ("service", e.service) ::
      selected_stream_labels ~warn_mutex ~warned_missing_labels ~context:e.context label_names
    in
    let close_wall_ns = wall_now_ns clock in
    let trace_id = trace_id_hex e.trace_ctx.Obs_trace.trace_id in
    let span_id  = span_id_hex  e.trace_ctx.Obs_trace.span_id  in
    let trace    = trace_fields trace_id span_id in
    let values =
      if e.log_entries = [] then
        (* Span had no Obs_eio.log calls — emit a single span-completion line. *)
        let status = match e.status with `Ok -> "ok" | `Error s -> "error:" ^ s in
        let line = logfmt
          ([("level", "info"); ("span", e.name); ("status", status)] @ trace)
        in
        [ (unix_ns_string close_wall_ns, line) ]
      else
        List.map (fun (entry : Obs_eio.log_entry) ->
          let ts =
            Int64.sub close_wall_ns (Int64.sub e.end_ns entry.timestamp_ns)
            |> unix_ns_string
          in
          let line = logfmt
            ([ ("level", level_string entry.level);
               ("msg", entry.message);
               ("span", e.name) ] @ logfmt_user_fields entry.fields @ trace)
          in
          (ts, line)
        ) e.log_entries
    in
    let body = loki_push_body ~stream_labels ~values in
    (match http_post ~net ~clock ~timeout ~headers ~url ~body with
     | Ok ()      -> ()
     | Error msg  -> Printf.eprintf "[obs-loki] %s\n%!" msg)
  in
  { Obs_eio.emit_span; emit_metric = (fun _ -> ()); declare_metric = (fun _ -> ()) }
