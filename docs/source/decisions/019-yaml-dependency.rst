.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

:orphan:

YAML parsing: yamerl directly, one dependency
=============================================

.. adr::
   :id: 019
   :status: Accepted
   :date: 2026-09-17
   :tags: dependencies, yaml, agents, security

.. note::
   Accepted 2026-09-17. ADR 002 treats every dependency as a security
   metric and requires an ADR for additions. ADR 017 adopted Markdown +
   YAML frontmatter for agent definitions, which needs a YAML parser.
   This records the choice and the reasoning behind it.

Context
-------

ADR 017 adopts the agents standard (YAML frontmatter), so a YAML parser
is required. ADR 002's constraints bind: the dependency tree must stay
pure Elixir/Erlang (no NIFs, no Node), small, and auditable.

Two candidates exist:

``yamerl``
   A YAML 1.2 / JSON parser in pure Erlang. BSD-2-Clause. The only
   candidate that actually parses.

``yaml_elixir``
   An Elixir wrapper around ``yamerl``. MIT. Pulls ``yamerl`` as its
   sole dependency.

The wrapper looked attractive (idiomatic API, more recent Hex releases),
so it was inspected rather than assumed. It is **378 lines total**, and
its core read path is ``:yamerl_constr.string/2`` followed by
node-to-Elixir conversion and error mapping. It pins ``yamerl ~> 0.10``
and does **not** work around any yamerl behaviour. So it adds a second
link to the trust chain while buying no parser-side benefit — the
decisive argument against it.

Measurements on the target machine (OTP 28 / Elixir 1.20):

- ``yamerl`` runs directly on OTP 28; no wrapper is needed for
  compatibility (the reason ``yaml_elixir`` would have been justified).
- ``yamerl`` is **not** part of the OTP distribution — only ``xmerl``
  (XML) ships with OTP. A YAML dependency is unavoidable.
- A ``!!fun`` tag (``tag:yamerl,2012:fun``, whose node module calls
  ``erl_eval:exprs`` — arbitrary code execution) is **rejected** by
  default: the module is not in the core schema
  (``yamerl_node_erlang_fun`` / ``yamerl_node_erlang_atom`` are opt-in
  via ``node_mods``, whose default is ``[]``).
- A YAML alias/"billion laughs" payload (459 bytes, 9×9 nesting) parsed
  in 10 ms — yamerl shares references rather than expanding them.

Decision
--------

Use **``yamerl`` directly** (``~> 0.10``), one dependency.

We own the small conversion from yamerl's proplist/record output to the
maps the loader wants (~40 lines), and we apply hard limits at that
boundary:

- **size cap** on the frontmatter before parsing (a definition file
  larger than the cap is a load error, not a parse);
- ``str_node_as_binary: true`` so scalars never become charlists;
- the default **core schema only** — never register
  ``yamerl_node_erlang_fun`` or ``yamerl_node_erlang_atom``, so a
  definition file can never execute code or intern atoms.

Consequences
------------

- One new dependency, pure Erlang, BSD-2, no NIF — ADR 002-compliant.
- No duplicated parsing code in the tree.
- yamerl's last Hex release is 0.10.0 (2022) while its repository is
  active; a fix upstream may not reach Hex. Accepted for now: the
  surface we use is small and the dangerous node modules are off. If a
  yamerl advisory ever appears, the loader is the single place to swap
  it.
- The loader, not the parser, is the policy point for frontmatter
  limits (size, schema); that discipline is documented in ADR 017.
