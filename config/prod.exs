# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

import Config

# Production (release) overrides. Nothing belongs here yet: the release
# configuration lives in `mix.exs` (ADR 048) and the runtime-only flag in
# `runtime.exs`. This file exists because `config/config.exs` imports
# every environment's file unconditionally.
