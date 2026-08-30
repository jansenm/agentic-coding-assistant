How to build the documentation
==============================

The documentation toolchain is Sphinx with pinned extensions
(see :doc:`../decisions/001-sphinx-documents`).

Steps
-----

1. Create the virtualenv and install the pinned toolchain::

      cd docs
      python3 -m venv .venv
      .venv/bin/pip install -r requirements.txt

2. Build the HTML output::

      .venv/bin/sphinx-build -b html source build/html

3. Or start the live-reload devserver instead, and keep it running while
   you write::

      make livehtml SPHINXAUTOBUILD=.venv/bin/sphinx-autobuild

   The site is served at ``http://127.0.0.1:8000`` and rebuilds on every
   save.

Conventions
-----------

- ADRs live in ``source/decisions`` with an ``id``, ``status`` and ``date``
  and are registered in that directory's hidden toctree.
- Diagrams are Mermaid (``.. mermaid::``).