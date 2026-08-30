About req_llm: API traits and lessons learned
=============================================

This project builds its agent loop directly on `req_llm <https://hexdocs.pm/req_llm/>`_
(see :doc:`../decisions/005-llm-client`). This page records the library's
behavioral traits we discovered while building against it — the answers to
"why does our code look like this?" It is **project-internal experience**,
not general req_llm documentation; when in doubt, the installed source in
``deps/req_llm/`` is authoritative.

Traits that shaped our code
---------------------------

Tool definitions are :class:`ReqLLM.Tool` structs
    Built via ``ReqLLM.Tool.new!`` with a NimbleOptions-style
    ``parameter_schema`` and a ``callback``. Execution is
    ``ReqLLM.Tool.execute/2``, which validates input against the schema
    before calling the callback. Our tool registry
    (:doc:`about-tools`) treats these structs as plain data.

Tool calls arrive in *two shapes*
    Assembled responses carry ``%ReqLLM.ToolCall{}`` structs with
    ``function: %{name, arguments-as-JSON-string}``. Stream events in
    ``ReqLLM.StreamResponse.events/1`` instead yield ``:tool_call``
    events whose ``data`` is a plain map: ``%{id, name, arguments}``
    with arguments already parsed. Our session normalizes both shapes
    in one place (``call_parts/1``) rather than letting the difference
    leak through the loop.

The stream is consumed once
    ``req_llm`` streams are single-consumption Enumerables: ``tokens/1``,
    ``events/1``, and the raw chunk stream are views over the same
    underlying data — consuming one consumes all. A consumer must pick
    one projection per response. (Also: early termination halts the
    underlying stream, so a consumer that stops requesting values never
    sees a terminal event.)

:func:`ReqLLM.stream_text/3` needs ``tools:`` explicitly
    Nothing else announces tool availability; a call without the
    ``:tools`` option silently renders the model tool-less (which looks
    like "the model refuses to use tools"). This cost us a full debug
    session — the lesson is to assert on the request, not only the
    response, when wiring tool-calling.

Key handling is provider-dependent
    ``ReqLLM.Keys`` resolves keys from options, application config, or
    environment variables; the ollama provider sends no Authorization
    header at all, so keyless providers must not receive an
    ``api_key:`` option. Our session derives this decision from the
    provider prefix of the model spec.

Not every model is in the LLMDB catalog
    Models unknown to the bundled database (e.g. ollama cloud models)
    work but emit an ``unverified model`` warning; suppress with
    ``config :req_llm, warn_unverified_models: false``. Capability and
    pricing metadata are unavailable for such models.

Tool results
    The canonical exchange format is :func:`ReqLLM.Context.append_tool_exchange/3`
    (validates id matching, reject duplicates/unknown/missing); simple
    scenarios can append ``Role: :tool`` messages directly via
    ``ReqLLM.Context.tool_result_message/4``. Our loop currently uses
    the simpler direct-append path.

Where these facts live in code
------------------------------

- ``lib/coding_agent/core/session.ex`` — stream consumption, both tool
  call shapes, keyless provider detection
- ``lib/coding_agent/core/tools.ex`` — tool construction and scope
- ``docs/source/decisions/005-llm-client.rst`` — why req_llm

This page is updated when integration work uncovers a new trait worth
remembering; each entry links back to the commit or ADR that established it.