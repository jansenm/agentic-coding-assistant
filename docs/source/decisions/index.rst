.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

Decision Records
================

Architectural decisions are recorded as lightweight ADRs using the
``sphinx-adr`` extension. Each record carries an ``id``, a ``status`` and a
``date``; the timeline below is generated from them.

.. adrlist::
   :sort: date-asc

Template
--------

.. code-block:: rst

   Decision title
   ==============
   .. adr::
      :id: NNNN
      :status: Proposed | Accepted | Deprecated | Superseded
      :date: YYYY-MM-DD

   Context, decision, consequences.