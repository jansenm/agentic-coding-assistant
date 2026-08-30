:orphan:

Project naming: internal app name first, display name later
===========================================================

.. adr::
   :id: 009
   :status: Accepted
   :date: 2026-08-29
   :tags: naming, layout

Context
-------

The scaffold needs a Mix application name, but the product name resists
every early candidate:

- Domain-descriptive names (agent, assistant, elixir combinations) are
  ungoogleable or collide with existing AI products.
- *familiar* (kept-agent concept) collides with the Spanish common word
  and existing packages; *pyx* collides with an agentic-product company.
- Keeper-of-familiars names: *warlock* (hex.pm taken), *summoner*
  (taken in AI context), *hexenmeister* (free but forecastable inclusion
  controversy: "witch master" for a successful project), *cunning*
  (strong folklore fit, weaker as a project name).

Decision
--------

Separate the names, permanently:

- **Internal Mix app / module prefix: ``coding_agent``** — plain,
  descriptive, says exactly what the application is. Note: the hex.pm
  package ``coding_agent`` (an OpenRouter harness, inactive since June
  2026) is *not* ours and must not be published to hex under that name;
  publication, if ever, happens under the final display name.
- **Display name: deferred** until the tool exists; naming continues in
  parallel (keeper-of-familiars direction is a good lead; a placeholder
  user-facing string ships in the TUI title bar).
- The Mix module prefix and the branding are decoupled from day one, so
  renaming later touches no code semantics.

Consequences
------------

- The repository, app and modules read ``coding_agent`` /
  ``CodingAgent.*``; no placeholder churn.
- Renaming the app later is a mechanical, single-purpose change that
  this ADR explicitly permits.
- The display-name decision keeps the folklore-direction options open
  (cunning folk, theurgy) without blocking implementation.