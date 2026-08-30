:orphan:

Sphinx for documentation
========================

.. adr::
   :id: 001
   :status: Accepted
   :date: 2026-08-29
   :tags: documentation

Context
-------

The project needs documentation that doubles as the design record for the
architecture decisions made while building the assistant. Candidates were
Markdown-based tooling and Sphinx.

Decision
--------

Documentation is written in **reStructuredText with Sphinx**.

- Theme: **Furo**
- ADRs: **sphinx-adr** (``adr`` directive + ``adrlist`` timeline)
- Diagrams: **sphinxcontrib-mermaid**
- Convenience: **sphinx-copybutton**, **sphinxext-opengraph**
  (no social-card images for now)

Consequences
------------

- The toolchain lives in a dedicated virtualenv (``docs/.venv``) because the
  system Python is externally managed; pinned versions live in
  ``docs/requirements.txt`` for reproducible one-command bootstrapping.
- More extensions (e.g. additional diagram or theme support) can be added
  incrementally — each addition gets its own ADR when it is non-trivial.