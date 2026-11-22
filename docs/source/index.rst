.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

Documentation
=============

This documentation follows the `Diátaxis <https://diataxis.fr/>`_ framework:
four quadrants, each answering a different question.

While the assistant is young, three quadrants are populated:

- **Explanation** — why the system is designed the way it is (architecture,
  memory model, technology constraints).
- **Reference** — the facts: configuration files and keys, environment
  variables, and (as they land) commands and tools.
- **Decision records** — the project's decision log. Orthogonal to the
  Diátaxis quadrants: ADRs document *why a decision was made*, not how to
  use or learn the product.

The **tutorials** and **how-to** sections fill in as the program matures;
placeholders document the intent of each section.

.. toctree::
   :maxdepth: 2
   :caption: Tutorials:

   tutorials/index

.. toctree::
   :maxdepth: 2
   :caption: How-to guides:

   howtos/index

.. toctree::
   :maxdepth: 2
   :caption: Explanation:

   explanation/index

.. toctree::
   :maxdepth: 2
   :caption: Reference:

   reference/index

.. toctree::
   :maxdepth: 1
   :caption: Decisions:

   decisions/index

.. toctree::
   :caption: Appendix:

   glossary