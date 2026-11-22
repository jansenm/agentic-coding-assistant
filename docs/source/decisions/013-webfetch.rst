.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

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

Amendment 2026-10-24 — what "text" means, and what the body is
---------------------------------------------------------------

Decision 4 admitted `application/json` by name and everything else as
`text/*`. Two things were wrong with that, both measured live:

* **The body was not the body.** `Req.get/2` runs its `decode_body`
  step with `decoders: [:json, :json_api]` by default, so an
  `application/json` response reached this module as a **Map**, not
  bytes. `to_text/2` passed it through (its catch-all returns the
  value) and `cap/2` ran `byte_size/1` on it — inside Req's callback,
  so the model got
  ``%ReqLLM.Error.Unknown.Unknown{error: "Callback execution failed: …
  not an iodata term"}``: no URL, no type, no tool name. The tool now
  passes `decode_body: false`. Every step after the request is defined
  on bytes (measure, slice, de-tag, spill), and the model wants the
  document, not an inspected term. A non-binary body is still guarded
  and refused with a sentence naming the content type — belt and
  braces, because the option is one line away from being removed.
* **The suffix IS the type.** RFC 6839 registers `+json` so that
  `application/problem+json` and `application/vnd.oai.openapi+json` are
  JSON documents; an exact-type list cannot express that. Measured:
  `https://llmcatalog.dev/openapi.json` answers
  `application/vnd.oai.openapi+json` and was refused as a binary file —
  the document the agent needed, rejected for its spelling. `text?/1`
  now also accepts the `+json` suffix. The refusal itself keeps naming
  the type; the allowlist was the problem, not the message.

