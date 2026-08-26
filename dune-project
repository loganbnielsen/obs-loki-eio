(lang dune 3.0)
(name obs-loki-eio)
(version 0.1.0)
(generate_opam_files true)

(package
 (name obs-loki-eio)
 (synopsis "Loki HTTP push backend for obs-eio")
 (description "\
Converts obs-eio span events into structured logfmt log lines and pushes them to
Loki's push API when each span closes. Not a general-purpose Loki client: it is the
Loki backend for obs-eio's Obs_eio.backend interface.")
 (maintainers "lbendtlynielsen@gmail.com")
 (authors "lbendtly")
 (license "MIT")
 (homepage "https://github.com/loganbnielsen/obs-loki-eio")
 (bug_reports "https://github.com/loganbnielsen/obs-loki-eio/issues")
 (source (github loganbnielsen/obs-loki-eio))
 (depends
  (ocaml (>= 5.4.0))
  (obs-eio (>= 0.1.0))
  (eio (>= 1.3))
  (eio_main (and (>= 1.3) :with-test))
  (cohttp-eio (>= 6.2.0))
  (uri (>= 4.4.0))
  (http (>= 6.0.0))
  (yojson (>= 3.0.0))
  (https-eio (>= 0.1.0))
  (alcotest :with-test)
  (odoc :with-doc)))
