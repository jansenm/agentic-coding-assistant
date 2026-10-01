:orphan:

Webfetch: gated network reads
=============================

.. adr::
   :id: 013
   :status: Accepted
   :date: 2026-09-06
   :tags: security, tools, network

.. note::
   Accepted 2026-09-06. Motivated by live dogfooding: the agent could
   not complete documentation work because it had no network access
   ("it did not have webfetch") and burned many tool rounds compensating.

Context
-------

The agent reads the web the way opencode's `webfetch` does: fetch a
URL, hand the body to the model. But an agent with unrestricted
`Req.get` is a foot-gun: `file://` reads, redirect-to-internal-host
(SSRF), oversized bodies and non-HTML content types are all real
failure modes, and the tool runs *inside the user's network*.

Decision
--------

**1. Scheme allowlist** — `http` and `https` only. `file://`, `ftp://`,
custom schemes: rejected before any request is made. (A URL parser
mistake is the classic escape; the check runs on the parsed struct,
not string matching.)

**2. Redirects follow, each target re-validated** — `Req` follows
redirects internally; we set `redirect: :follow` with
`max_redirects: 5`. Scheme and host checks re-run on the FINAL url
(and Req re-validates scheme per hop for its own redirects list).
Private-address checking happens on the final effective URL; the
documented residual risk is DNS rebinding on intermediate hops (v1
accepts this; a strict mode resolving every hop is future work).

**3. Private-network block** — after resolution, `127.0.0.0/8`,
`10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `::1`, `fc00::/7`,
`fe80::/10` and `0.0.0.0` are refused. This is the SSRR guard: the
agent cannot probe the user's router/containers/cloud metadata
(169.254.169.254 is the AWS metadata endpoint — explicitly covered).

**4. Size and type caps** — response body capped at 128 KiB
(truncated with a note, like tool output capping); `content-type`
text/\* and HTML are returned as text; HTML gets a minimal tag strip
(`script`/`style` dropped, tags removed, entities decoded) — NOT a
markdown conversion (future work, needs a real HTML parser dep).
Binary content types (images, archives): rejected with the type in
the error, no body.

**5. Always-gated (ask)** — same class as `shell`: no policy path to
allow in v1. Every fetch pauses for a decision and shows the URL in
the approval dialog, so the user sees exactly what is being fetched.
`.coding-agent/permissions.toml` may make it `deny`, never `allow`.

**6. Timeout** — 15 s connect+total, `max_retries: 0` (a fetch the
agent retried blindly would burn tool rounds).

Consequences
------------

- The agent can read public documentation inline — the motivating
  dogfood case.
- The SSRF guard is resolver-level only at the final URL; DNS rebinding
  between check and connect is accepted for v1 (documented residual
  risk, revisit if the tool becomes allow-listable).
- No HTML-to-markdown conversion yet: the model sees de-tagged text.
  Ugly but faithful; a parser dep (`floki`) is the natural follow-up.
