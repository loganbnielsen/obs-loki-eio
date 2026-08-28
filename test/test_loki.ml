(** obs-eio-loki integration tests.

    Mock-server tests run without any external infrastructure and verify
    the exact HTTP payload sent to Loki.

    Live Loki tests require [LOKI_URL] to be set (e.g. http://localhost:3100)
    and are marked [Slow].  They push spans and query back to confirm ingestion. *)

(* ------------------------------------------------------------------ *)
(* Mock Loki server (cohttp-eio)                                       *)
(* ------------------------------------------------------------------ *)

(* Mock Loki server on an ephemeral port: accepts one POST, captures the
   body, responds with [status_code], then stops. *)
let with_mock_loki_server env ?(status_code = 204) f =
  Eio.Switch.run @@ fun sw ->
  let body_p, body_r = Eio.Promise.create () in
  let stop, stop_r   = Eio.Promise.create () in
  let callback _conn _req body =
    let captured =
      let buf = Eio.Buf_read.of_flow body ~max_size:(256 * 1024) in
      Eio.Buf_read.take_all buf
    in
    (if not (Eio.Promise.is_resolved body_p) then
      Eio.Promise.resolve body_r captured);
    Cohttp_eio.Server.respond
      ~status:(Http.Status.of_int status_code)
      ~body:(Cohttp_eio.Body.of_string "")
      ()
  in
  let server = Cohttp_eio.Server.make ~callback () in
  let addr   = `Tcp (Eio.Net.Ipaddr.V4.loopback, 0) in
  let socket = Eio.Net.listen ~backlog:5 ~sw env#net addr in
  let port   = Eio.Net.listening_addr socket
    |> (function `Tcp (_, p) -> p | _ -> failwith "unexpected addr") in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run ~stop ~on_error:(fun _ -> ()) socket server;
    `Stop_daemon);
  let result = f ~port ~body_promise:body_p in
  Eio.Promise.resolve stop_r ();
  result

(* ------------------------------------------------------------------ *)
(* Helpers                                                             *)
(* ------------------------------------------------------------------ *)

let contains s sub =
  let ls = String.length s and lp = String.length sub in
  if lp = 0 then true
  else if ls < lp then false
  else begin
    let rec go i =
      if i > ls - lp then false
      else if String.sub s i lp = sub then true
      else go (i + 1)
    in
    go 0
  end

let local_url port = Printf.sprintf "http://127.0.0.1:%d" port

(* ------------------------------------------------------------------ *)
(* Mock server tests                                                   *)
(* ------------------------------------------------------------------ *)

let test_push_contains_service () =
  Eio_main.run @@ fun env ->
  with_mock_loki_server env (fun ~port ~body_promise ->
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"test-svc" ~mono_clock:env#mono_clock
               ~backend:loki in
    Obs_eio.with_span ot "op" (fun sp ->
      Obs_eio.log sp Obs_eio.Info "hello from test");
    let body = Eio.Promise.await body_promise in
    Alcotest.(check bool) "contains streams key"
      true (String.length body > 0 && String.sub body 0 1 = "{");
    Alcotest.(check bool) "service label present"
      true (contains body "\"service\":\"test-svc\""))

let test_log_message_in_payload () =
  Eio_main.run @@ fun env ->
  with_mock_loki_server env (fun ~port ~body_promise ->
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
    Obs_eio.with_span ot "work" (fun sp ->
      Obs_eio.log sp Obs_eio.Info ~fields:[("key", "val")] "my-unique-message");
    let body = Eio.Promise.await body_promise in
    Alcotest.(check bool) "log message present" true
      (contains body "my-unique-message");
    Alcotest.(check bool) "extra field present" true
      (contains body "val");
    Alcotest.(check bool) "trace_id present" true
      (contains body "trace_id");
    Alcotest.(check bool) "span_id present" true
      (contains body "span_id"))

let test_span_name_in_payload () =
  Eio_main.run @@ fun env ->
  with_mock_loki_server env (fun ~port ~body_promise ->
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
    Obs_eio.with_span ot "my-span-name" (fun _sp -> ());
    let body = Eio.Promise.await body_promise in
    Alcotest.(check bool) "span name in payload" true
      (contains body "my-span-name"))

let test_context_fields_become_labels () =
  Eio_main.run @@ fun env ->
  with_mock_loki_server env (fun ~port ~body_promise ->
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:(local_url port)
                 ~label_names:[Obs_loki.stream_label "env";
                               Obs_loki.stream_label "region"] () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
    let ot = Obs_eio.with_context ot [("env", "prod"); ("region", "eu-west-1")] in
    Obs_eio.with_span ot "op" (fun _sp -> ());
    let body = Eio.Promise.await body_promise in
    Alcotest.(check bool) "env label present" true
      (contains body "\"env\":\"prod\"");
    Alcotest.(check bool) "region label present" true
      (contains body "\"region\":\"eu-west-1\""))

let test_selected_label_missing_from_context_warns_and_is_omitted () =
  Eio_main.run @@ fun env ->
  with_mock_loki_server env (fun ~port ~body_promise ->
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:(local_url port)
                 ~label_names:[Obs_loki.stream_label "env";
                               Obs_loki.stream_label "region"] () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
    let ot = Obs_eio.with_context ot [("env", "prod")] in
    Obs_eio.with_span ot "op" (fun _sp -> ());
    let body = Eio.Promise.await body_promise in
    Alcotest.(check bool) "present label included" true
      (contains body "\"env\":\"prod\"");
    Alcotest.(check bool) "missing label omitted" false
      (contains body "\"region\""))

let test_stream_label_rejects_invalid_name () =
  match Obs_loki.stream_label "bad-label" with
  | _ -> Alcotest.fail "invalid Loki stream label should raise Invalid_argument"
  | exception Invalid_argument _ -> ()

let test_multiple_log_calls () =
  Eio_main.run @@ fun env ->
  with_mock_loki_server env (fun ~port ~body_promise ->
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
    Obs_eio.with_span ot "multi" (fun sp ->
      Obs_eio.log sp Obs_eio.Info  "first";
      Obs_eio.log sp Obs_eio.Warn  "second";
      Obs_eio.log sp Obs_eio.Error "third");
    let body = Eio.Promise.await body_promise in
    Alcotest.(check bool) "first present"  true (contains body "first");
    Alcotest.(check bool) "second present" true (contains body "second");
    Alcotest.(check bool) "third present"  true (contains body "third"))

let test_logfmt_field_keys_are_safe () =
  Eio_main.run @@ fun env ->
  with_mock_loki_server env (fun ~port ~body_promise ->
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
    Obs_eio.with_span ot "work" (fun sp ->
      Obs_eio.log sp Obs_eio.Info
        ~fields:[("bad key=", "v"); ("msg", "caller"); ("trace_id", "fake")]
        "real-message");
    let body = Eio.Promise.await body_promise in
    Alcotest.(check bool) "invalid chars are normalized"
      true (contains body "bad_key_=v");
    Alcotest.(check bool) "reserved msg is prefixed"
      true (contains body "field_msg=caller");
    Alcotest.(check bool) "reserved trace_id is prefixed"
      true (contains body "field_trace_id=fake");
    Alcotest.(check bool) "built-in message remains authoritative"
      true (contains body "msg=real-message"))

let test_log_entries_get_distinct_timestamps () =
  Eio_main.run @@ fun env ->
  with_mock_loki_server env (fun ~port ~body_promise ->
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
    Obs_eio.with_span ot "multi" (fun sp ->
      Obs_eio.log sp Obs_eio.Info "first";
      Eio.Time.sleep env#clock 0.001;
      Obs_eio.log sp Obs_eio.Info "second");
    let body = Eio.Promise.await body_promise in
    let timestamps =
      match Yojson.Safe.from_string body with
      | `Assoc fields ->
        (match List.assoc_opt "streams" fields with
         | Some (`List [`Assoc stream]) ->
           (match List.assoc_opt "values" stream with
            | Some (`List values) ->
              List.filter_map (function
                | `List [`String ts; `String _line] -> Some ts
                | _ -> None) values
            | _ -> [])
         | _ -> [])
      | _ -> []
    in
    match timestamps with
    | [first; second] ->
      Alcotest.(check bool) "per-entry timestamps differ" true (first <> second)
    | _ -> Alcotest.fail "expected two Loki values")

let test_loki_unreachable_does_not_raise () =
  Eio_main.run @@ fun env ->
  (* Point at a port nothing is listening on — should log to stderr and return. *)
  let loki = Obs_loki.create ~net:env#net ~clock:env#clock
               ~url:"http://127.0.0.1:19399" () in
  let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
  Obs_eio.with_span ot "op" (fun sp -> Obs_eio.log sp Obs_eio.Info "test")

(* Verify the JSON payload has the correct Loki push shape:
   {"streams":[{"stream":{...},"values":[[ts,line],...]}]} *)
let test_payload_json_shape () =
  Eio_main.run @@ fun env ->
  with_mock_loki_server env (fun ~port ~body_promise ->
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"shape-svc" ~mono_clock:env#mono_clock ~backend:loki in
    Obs_eio.with_span ot "check" (fun sp -> Obs_eio.log sp Obs_eio.Info "shape-test");
    let body = Eio.Promise.await body_promise in
    let json = Yojson.Safe.from_string body in
    (match json with
     | `Assoc fields ->
       (match List.assoc_opt "streams" fields with
        | Some (`List (stream :: _)) ->
          (match stream with
           | `Assoc s ->
             Alcotest.(check bool) "stream key present" true
               (List.mem_assoc "stream" s);
             Alcotest.(check bool) "values key present" true
               (List.mem_assoc "values" s);
             (match List.assoc_opt "values" s with
              | Some (`List (v :: _)) ->
                (match v with
                 | `List [ `String _ts; `String _line ] ->
                   Alcotest.(check bool) "value is [ts, line] tuple" true true
                 | _ ->
                   Alcotest.(check bool) "value is [ts, line] tuple" true false)
              | _ -> Alcotest.(check bool) "values is non-empty list" true false)
           | _ -> Alcotest.(check bool) "stream is object" true false)
        | _ -> Alcotest.(check bool) "streams is non-empty list" true false)
     | _ -> Alcotest.(check bool) "top-level is object" true false))

(* Verify that a non-2xx response is swallowed (logged to stderr, not raised). *)
let test_non_2xx_does_not_raise () =
  Eio_main.run @@ fun env ->
  with_mock_loki_server env ~status_code:500 (fun ~port ~body_promise:_ ->
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
    Obs_eio.with_span ot "op" (fun sp -> Obs_eio.log sp Obs_eio.Info "test"))

(* Verify that a non-2xx response with a short body is captured without error. *)
let test_non_2xx_short_body () =
  Eio_main.run @@ fun env ->
  with_mock_loki_server env ~status_code:400 (fun ~port ~body_promise:_ ->
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:(local_url port) () in
    let ot = Obs_eio.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
    Obs_eio.with_span ot "op" (fun sp -> Obs_eio.log sp Obs_eio.Warn "test"))

(* ------------------------------------------------------------------ *)
(* Live Loki tests (require LOKI_URL env var)                         *)
(* ------------------------------------------------------------------ *)

let loki_query_range ~net ~url ~query ~start_ns ~end_ns =
  let path =
    Printf.sprintf "/loki/api/v1/query_range?query=%s&start=%s&end=%s&limit=50"
      (Uri.pct_encode ~component:`Query_key query)
      (Printf.sprintf "%Ld" start_ns)
      (Printf.sprintf "%Ld" end_ns)
  in
  let uri = Uri.of_string (url ^ path) in
  let client = Cohttp_eio.Client.make ~https:None net in
  Eio.Switch.run @@ fun sw ->
  let hdrs = Http.Header.of_list [("Accept", "application/json")] in
  let _resp, body =
    Cohttp_eio.Client.call client ~sw ~headers:hdrs `GET uri
  in
  Eio.Buf_read.(parse_exn take_all) body ~max_size:(1024 * 1024)

let extract_log_lines json_str =
  match Yojson.Safe.from_string json_str with
  | `Assoc fields ->
    (match List.assoc_opt "data" fields with
     | Some (`Assoc data) ->
       (match List.assoc_opt "result" data with
        | Some (`List streams) ->
          List.concat_map (fun stream ->
            match stream with
            | `Assoc s ->
              (match List.assoc_opt "values" s with
               | Some (`List vals) ->
                 List.filter_map (function
                   | `List [`String _ts; `String line] -> Some line
                   | _ -> None) vals
               | _ -> [])
            | _ -> []
          ) streams
        | _ -> [])
     | _ -> [])
  | _ -> []

let test_live_ingestion () =
  match Sys.getenv_opt "LOKI_URL" with
  | None ->
    Printf.printf "[skip] LOKI_URL not set — skipping live Loki ingestion test\n%!"
  | Some loki_url ->
    Eio_main.run @@ fun env ->
    let unique_service = Printf.sprintf "loki-e2e-test-%d" (int_of_float (Unix.gettimeofday ())) in
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:loki_url () in
    let ot = Obs_eio.create ~service:unique_service
               ~mono_clock:env#mono_clock ~backend:loki in
    let start_ns = Int64.of_float (Unix.gettimeofday () *. 1e9) in
    Obs_eio.with_span ot "e2e-span" (fun sp ->
      Obs_eio.log sp Obs_eio.Info ~fields:[("check", "ingestion")] "loki-e2e-marker");
    Eio.Time.sleep env#clock 0.5;
    let end_ns = Int64.of_float (Unix.gettimeofday () *. 1e9) in
    let query = Printf.sprintf "{service=\"%s\"}" unique_service in
    let resp = loki_query_range ~net:env#net ~url:loki_url
                 ~query ~start_ns ~end_ns in
    let lines = extract_log_lines resp in
    Alcotest.(check bool) "at least one line ingested" true (lines <> []);
    Alcotest.(check bool) "marker present in ingested lines" true
      (List.exists (fun l -> contains l "loki-e2e-marker") lines)

let test_live_trace_id_round_trip () =
  match Sys.getenv_opt "LOKI_URL" with
  | None ->
    Printf.printf "[skip] LOKI_URL not set — skipping live trace-id round-trip test\n%!"
  | Some loki_url ->
    Eio_main.run @@ fun env ->
    let unique_service = Printf.sprintf "loki-trace-test-%d" (int_of_float (Unix.gettimeofday ())) in
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:loki_url () in
    let ot = Obs_eio.create ~service:unique_service
               ~mono_clock:env#mono_clock ~backend:loki in
    let captured_trace_id = ref "" in
    let start_ns = Int64.of_float (Unix.gettimeofday () *. 1e9) in
    Obs_eio.with_span ot "trace-test" (fun sp ->
      let ctx = Obs_eio.current_trace_ctx sp in
      let (hi, lo) = ctx.Obs_trace.trace_id in
      captured_trace_id := Printf.sprintf "%016Lx%016Lx" hi lo;
      Obs_eio.log sp Obs_eio.Info "trace-id-check");
    (* trace_id is a logfmt field in the line body, not a stream label, hence
       "| logfmt" in the query. Retries up to 5s for ingestion latency. *)
    let query = Printf.sprintf
      "{service=\"%s\"} | logfmt | trace_id=\"%s\""
      unique_service !captured_trace_id in
    let deadline = Unix.gettimeofday () +. 5.0 in
    let end_ns = ref Int64.zero in
    let lines = ref [] in
    while !lines = [] && Unix.gettimeofday () < deadline do
      Eio.Time.sleep env#clock 0.5;
      end_ns := Int64.of_float (Unix.gettimeofday () *. 1e9);
      let resp = loki_query_range ~net:env#net ~url:loki_url
                   ~query ~start_ns ~end_ns:!end_ns in
      lines := extract_log_lines resp
    done;
    Alcotest.(check bool) "trace_id present in log line" true
      (!lines <> [])

(* ------------------------------------------------------------------ *)
(* Test runner                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  let open Alcotest in
  run "obs_loki" [
    "payload", [
      test_case "service label in push body"       `Quick test_push_contains_service;
      test_case "log message in push body"         `Quick test_log_message_in_payload;
      test_case "span name in push body"           `Quick test_span_name_in_payload;
      test_case "context fields become labels"     `Quick test_context_fields_become_labels;
      test_case "missing selected label is omitted" `Quick test_selected_label_missing_from_context_warns_and_is_omitted;
      test_case "stream label validates names"      `Quick test_stream_label_rejects_invalid_name;
      test_case "multiple log calls all present"   `Quick test_multiple_log_calls;
      test_case "logfmt field keys are safe"       `Quick test_logfmt_field_keys_are_safe;
      test_case "log entries get distinct timestamps" `Quick test_log_entries_get_distinct_timestamps;
      test_case "unreachable Loki does not raise"  `Quick test_loki_unreachable_does_not_raise;
      test_case "payload JSON shape"               `Quick test_payload_json_shape;
      test_case "non-2xx response does not raise"  `Quick test_non_2xx_does_not_raise;
      test_case "non-2xx short body does not raise"`Quick test_non_2xx_short_body;
    ];
    "live", [
      test_case "log line ingested and queryable"  `Slow test_live_ingestion;
      test_case "trace_id survives push and query" `Slow test_live_trace_id_round_trip;
    ];
  ]
