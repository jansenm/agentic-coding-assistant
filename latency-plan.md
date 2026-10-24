# Turn latency and round count — the investigation plan

**Status:** planning. No code changed yet.

**Observation.** Working in opencode (same machine, same repo, same model
class) turns feel faster than in this harness, without an obvious gain in
quality. The complaint has two halves that must be measured separately:

- **more rounds** — the harness invites more model calls per turn;
- **slower rounds** — each call takes longer once it is made.

They compose: `time = rounds × seconds_per_round`. A 2× round count and a
2× per-round cost look identical from the outside, and a fix for one looks
like a failure if the other dominates. Everything below is sorted by
which side of that product it belongs to.

> **What is verified vs. hypothesised.** Facts marked *(verified)* were
> read out of this tree today, with `file:line`. Everything else is a
> hypothesis with a falsifier. Do not promote a hypothesis to a fact
> before Phase 1.

---

## 1. The two quantities, as a shape

The request this harness sends has a single volatile block in front of
everything:

```
[ system: base + agent + env + todos + "Tool rounds this turn: N / 100" + caps ]
[ user ] [ assistant tool_calls ] [ tool ] [ assistant ] [ tool ] ...
```

Every cache a provider offers is a *prefix* cache. A counter in the
first message means no prefix ever repeats — see H1.

---

## 2. What is already known about this tree *(verified)*

| Fact                                                                                                                                                                                       | Where                                                                                                     |
|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| The per-call blocks (env, todos, budget, capabilities) are appended to **the first message** — the system prompt                                                                           | `lib/coding_agent/core/session/prompt.ex:513` (`append_system_block/2`); call site `session.ex:2746-2749` |
| The budget block always renders `Tool rounds this turn: <rounds> / <max>` plus the projected token count, so its text changes on every request                                             | `prompt.ex:385-402`, `prompt.ex:422-423`                                                                  |
| `%Usage{}` has no `cached_tokens` field; ReqLLM reports it, `Usage.add/2` drops it                                                                                                         | `session/usage.ex:24`; `deps/req_llm/lib/req_llm/usage.ex:18`                                             |
| Tool calls in a round run **sequentially** (`Enum.reduce`), though the prompt invites parallel calls                                                                                       | `session/tool_runner.ex:45-75`; `priv/coding-agent/prompts/default.txt`                                   |
| `read_file` with neither `offset` nor `limit` returns the **whole file**; the prompt says "Read the full file before editing it"                                                           | `tools/read_file.ex:17,61`; `default.txt`                                                                 |
| `edit` is exact-match only: `String.replace/4` after an exact `occurrences/1` count; 0 matches is a hard error, 2+ is ambiguous. No normalization fallback                                 | `tools/edit.ex:101-156`                                                                                   |
| A primary session sees **15** tools: 7 read-only, 7 gated, 1 delegation                                                                                                                    | `tools.ex:60-107`                                                                                         |
| `ollama_cloud` rides the **OpenAI-compatible** path: shipped layer 0 sets `provider = "openai"`, `base_url = https://ollama.com/v1`, `backend = "ollama"`; an empty user table does not erase it (deep merge) | `priv/coding-agent/config.toml`; `user_config.ex:144-153` |
| One round is atomic: if any call in it needs approval, **every** result is held until the human answers                                                                                    | `session.ex:2247-2271`                                                                                    |
| Default round budget is 100; the stored TUI session carried 200                                                                                                                            | `config.ex:33`; store                                                                                     |
| The `compact` tool exists, but was **never called**: 0 calls across 5 135 tool calls in seven stored sessions, while auto-compaction ran 23 times                                          | `prompt.ex:428-435`                                                                                       |
| Tool output already spills to the scratch instead of re-running a command                                                                                                                  | `core/spill.ex` (ADR 038)                                                                                 |
| The one long real session in the local store: 133 tool calls — `shell` 106, `read_file` 16, `edit` 6, `git` 4, `todowrite` 1 — and **134 assistant messages**, i.e. ~1 tool call per round | `~/.local/state/coding_agent/store.db`                                                                    |
| The same session's cumulative input is **644 M tokens** — irreconcilable with 134 visible assistant messages, so either history was compacted away or the accounting is wrong              | store (`Usage.input_tokens`)                                                                              |

Caveat on the last two rows: that session is old (its stored base prompt
predates the current todo/compact sections), so treat its mix as
indicative, not as the current baseline. The 644 M number is a separate
question worth its own finding either way.

---

## 3. Hypotheses

Ranked by expected effect × cost to test. Each has a falsifier, because
the plan is to kill hypotheses, not to collect them.

### H1 — the system message changes every round, so the prefix cache mostly misses *(latency)*

**Claim.** `Tool rounds this turn: N / 100` is in the system message.
Round 2 differs from round 1 inside the *first* message — before every
other message in the request — so the provider's prefix cache misses and
the whole transcript is re-prefilled on every call. Cost grows
quadratically within a turn, latency linearly, and the input bill is paid
at the uncached rate.

**Signature.** Round N of a turn is slower than round 1; cache-hit ratio
far below the ~80 % a stable prefix gives. In opencode, later rounds of a
turn are flat or faster.

**Falsifier.** Cache-hit ratio is already high (provider ignores the
tail of the system message, or no caching on that route), or per-round
latency is flat as the transcript grows.

**Confidence.** Confirmed by controlled experiment (below) — this is no
longer a hypothesis.

**Confirmed (2026-10-24): 99 % → 0 % from one line.** Direct probe of the
harness's own call path (`Session.Request.build/3` → `ReqLLM.stream_text/3`
→ `StreamResponse.usage/1`), 9 049-token prompt, `max_tokens: 4`, same
prefix every time:

| request | input | cached | hit |
|---|---|---|---|
| stable system message (warm) | 9 049 | 8 960 | 99 % |
| **+ one line in the system message: `Tool rounds this turn: 2 / 100`** | 9 059 | **0** | **0 %** |
| stable system message again | 9 049 | 8 960 | 99 % |

One line in the *first* message costs the entire prefix, and removing it
restores the cache immediately — so nothing else in the request is
responsible. The provider is not ignoring the block's position, it is
keying on the exact bytes.

**Size threshold, or the test measures nothing.** At 2 549 tokens the same
probe reported `cached: 0` on every call; at 9 049 it hits. Any A/B has to
clear a few thousand tokens before a 0 means anything.

**What it does not prove.** The block also carries the live token counts
(`~110k / 1000k`, soft/hard distances), which move every round on their
own — deleting only the round counter would leave the prefix just as
volatile. The whole block is the problem, which is what F1's band shape
addresses.

**Measured (2026-10-24).** Ollama Cloud's OpenAI-compatible response
carries `usage.prompt_tokens_details.cached_tokens` — verified with one
request — and ReqLLM already normalizes exactly that field. The harness
discards it in `%Usage{}`; nothing new has to be fetched. The account
endpoint (`https://ollama.com/api/usage?range=24h`, hourly buckets with
`cached_input_tokens` and `usage_usd`) reported over a 24 h window:
86.7 M input tokens, **22.8 M cached (26 %)**, 743 requests. A
stable-prefix agent loop re-sends the whole transcript every round, so a
healthy ratio is 80 %-plus. The finding is therefore not "the cache never
hits" but "it hits for a quarter of the tokens when it should hit for
most of them" — and the experiment above says why: every round is a fresh
cache entry, so only the turns that repeat a byte-identical block can hit
at all.

**Caveat on that number — and what it implies.** The account endpoint is
per *key*, not per client, and the harness and opencode share one key
today. The 26 % is therefore a **blend**: opencode's share is presumably
the better-cached part, so the harness's own ratio is **at most 26 %**,
and the gap to 80 % is wider than the blend suggests. The harness's
credential lookup is `<PROVIDER>_API_KEY` then `auth.toml [<provider>]`
(`user_config.ex:206-219`), so one key per client is a config act, not a
code change — and once split, a `totals` delta across a single turn with
one client running gives the true ratio before any instrumentation lands.
The current hour's bucket is live, so this works at turn granularity.

**If the route reports nothing.** Still worth knowing as a fallback for
other providers: send the same long prefix twice, once with the last line
changed and once without. If the unchanged pair is much faster on the
second call and the changed pair is not, the provider caches on prefix
regardless of what the response says.

**Design tension.** The block exists for a reason (ADR 040: the model
should act at a step boundary before the hard line forces it). The fix is
not "delete it" — see F1.

### H2 — tool calls are serialized *(latency)*

**Claim.** The prompt tells the model it may batch independent calls; the
runner executes them one after another, each a confined child (`bwrap`,
`head -c | dd`). Four independent reads cost four spawns instead of one.

**Signature.** A round with k tool calls takes ≈ k × per-call time;
`tool_ms` dominates `llm_ms` on exploration rounds.

**Falsifier.** Tool time is a small fraction of round time, or the model
rarely emits more than one call per round (then H4 is the interesting
one).

**Confidence.** High as a mechanism; unknown as a share of the total.
**Cost to test.** Per-tool timing in `ToolRunner.execute/3`.

### H3 — the tool mix is shell-heavy and every shell is a confined child *(latency)*

**Claim.** ~80 % of the stored session's calls were `shell`. Each pays
sandbox setup, and large stdin is the N107 path (EPIPE) — a failed call is
also a retried call.

**Signature.** Per-call wall time for `shell` ≫ `read_file`; occasional
EPIPE failures on big payloads.

**Falsifier.** `shell` and `read_file` have similar per-call cost.

**Confidence.** Medium. **Cost to test.** Same instrumentation as H2, plus
a grep of the store for `Broken pipe`.

### H4 — one tool call per round, because a batched round is all-or-nothing *(rounds)*

**Claim.** The stored session shows 134 assistant messages / 133 calls.
The atomic round (any approval-needed call holds *all* results) teaches
the model that batching buys nothing until the human answers. The result
is one observation per LLM call, which is the most expensive way to
explore a repo.

**Signature.** Calls-per-round ≈ 1.0 over many sessions; every
exploration step is its own round.

**Falsifier.** Calls-per-round is > 1.5 in current sessions (the old
session is not representative), or rounds per task are the same in
opencode at the same model.

**Confidence.** Medium-high for the old session; unknown for today.
**Cost to test.** Query the store (already scripted) over the current
sessions.

**Note.** Partial delivery is not an option on the wire — an assistant
message with 3 calls needs 3 results in the same exchange. The available
levers are prompt-shaped (don't mix reads with approval-needing calls) or
transport-shaped (defer the gate, not the results).

### H5 — exact-match `edit` burns two rounds per failure *(rounds)*

**Claim.** Whitespace or indentation drift after a re-read produces
`old_string not found`; the model re-reads and retries. opencode's edit
matches through trimmed / whitespace-normalized / indentation-flexible /
block-anchor strategies, so the same drift is a non-event there.

**Signature.** Non-zero `old_string not found` / `ambiguous` counts in
the store; a visible read→edit→read→edit pattern.

**Falsifier.** Counts are zero across current sessions (the old session
shows 0, so this may not be *this* user's factor — but it is a per-model
constant worth removing before it becomes one).

**Confidence.** Medium. **Cost to test.** Grep the store.

### H6 — the prompt teaches context management, and the policy is self-reinforcing *(rounds + latency)*

**Claim.** Three coupled instructions: "read the full file", "keep durable
facts in a todo's `notes`", "the soft line is near — compact or end the
turn". Full-file reads inflate the context; the soft line fires earlier;
the summary is lossy; the model re-reads what the summary dropped. The
`compact` lever itself is unused (0/5 135), so what remains is the churn.

**Signature.** Compaction inside short turns; the same file read twice
with nothing changed in between; a todo list carried as context on every
request.

**Falsifier.** Fewer than one compaction per several turns, and no
repeated reads.

**Confidence.** Medium. **Cost to test.** Compaction count per turn from
the store; duplicate-read detection.

### H7 — the prompt family is wrong for the model *(rounds, quality)*

**Claim.** `Prompt.family/1` matches only `claude`; every other model,
including the DeepSeek in the stored session, gets `default.txt`, which
the module describes as the strict calibration "tuned for local models".
Round count is a known symptom of a prompt written for a weaker model
being fed to a stronger one.

**Signature.** Rounds per task class differ between the two model
families on the same task.

**Falsifier.** Both families show the same rounds per task.

**Confidence.** Medium-low as a *round* cause, real as a *quality*
variable. **Cost to test.** One A/B, after Phase 0.

### H8 — the read-tool surface is ambiguous *(rounds)*

**Claim.** `list_dir`, `glob`, `grep`, `shell` and `read_file` overlap at
the edges; the prompt needs four lines to say which to prefer. Wrong-tool
calls are errors, and an error is a round.

**Signature.** `error:` results naming a wrong-tool condition; repeated
`glob` + `grep` pairs for the same target.

**Falsifier.** No wrong-tool errors in the store.

**Confidence.** Low-medium. **Cost to test.** Grep the store.

---

## 4. Signature → hypothesis

| You see | Look first at |
|---|---|
| Round 6 slower than round 2, in one turn | H1 |
| One tool call per assistant message | H4, then H8 |
| `tool_ms` ≫ `llm_ms` inside a round | H2, then H3 |
| `old_string not found` in the transcript | H5 |
| Compaction inside a turn shorter than 20 rounds | H6 |
| Same rounds, different quality | H7 |
| Cache hits in opencode but not here | H1 |

---

## 5. Phase 0 — instrument, change nothing else

One commit, no behavior change. Without this, every later fix is an
anecdote.

**Precondition: one API key per client.** While opencode and this harness
share a key, every account number is a blend of both, and the A/B in
Phase 1 is unmeasurable from outside. The harness resolves
`OLLAMA_CLOUD_API_KEY` first, then `auth.toml [ollama_cloud]`
(`user_config.ex:206-219`); opencode's key lives in its own config. Two
keys on ollama.com, one per client, and the usage endpoint becomes a
per-client instrument.

1. **`%Usage{}` gains `cached_tokens`** (and, if ReqLLM exposes it,
   `cache_write_tokens`). Aggregate in `Usage.add/2`, render in the
   sidebar footer next to the token totals. This is the datum that
   decides H1 — and it is already on the wire:
   `usage.prompt_tokens_details.cached_tokens`, mapped by
   `ReqLLM.Usage.normalize/1` (`deps/req_llm/lib/req_llm/usage/normalize.ex:87`).
   *Note:* the native Ollama endpoint reports the same number as
   `prompt_eval_cached_count`, which ReqLLM does **not** map — one more
   reason to keep the OpenAI-compatible route.
   **Landed 2026-10-24:** `%Usage{cached_tokens}` + `Usage.cache_hit_ratio/1`
   + a `cached in` sidebar row (hidden while the count is 0: "not
   reported" and "always missed" are indistinguishable, so the panel
   never claims a measured 0 %). The streaming path carries it too —
   `default_decode_stream_event/2` maps
   `prompt_tokens_details.cached_tokens` into the meta chunk
   (`defaults.ex:1657`), so it is the same number the turn already
   fetched.
2. **Per-round timing.** Record `llm_ms` and `tool_ms` for each round and
   keep them in session state (or broadcast an `{:round_metrics, ...}`
   event). No network, no disk, no new dependency.
3. **Round metrics in the transcript or a `/stats` command**: rounds this
   turn, per-round input/cached/output, tool calls, tool wall time, cache
   hit ratio. A `/stats` slash command fits the TUI convention better
   than a debug log and stays out of the model's context.
4. **Cost — landed 2026-10-24, and not the way this item first proposed.**
   A local `[pricing."<provider>:<model>"]` table was rejected: it is
   wrong for the next model, wrong for the cached rate, and wrong for the
   hours the provider bills at peak rates — ollama.com publishes exactly
   that two-tier schedule (`deepseek-v4.1-flash` at $0.30/$0.006/$1.20 per
   Mtok in peak hours, half off-peak). The catalog's per-model `cost` is
   no help either: it has no `ollama` provider at all, input/output only,
   and one rate.

   What the harness shows now is the provider's own accounting
   (`CodingAgent.Core.Costs`): `GET /api/usage?range=24h` sampled once per
   turn, and the **delta** of `usage_usd` is money actually spent —
   peak pricing, discounts and per-model rates already inside it. The
   first sample is only a baseline, so a fresh session shows no cost. A
   second read, `GET /api/balance`, gives the remaining credits for the
   period ($7.17 of $60 at the time of writing, which is why this was not
   an "eventually" item).

   Both are derived from the **host** of the provider's `base_url` — no
   config field, no new credential; a local daemon is silent. Portability
   is a capability, not an endpoint: a provider whose billing API stops
   following its wire (OpenRouter) earns a `usage = "<dialect>"` field
   shaped like `discover`, when that second implementation exists.
   Granularity is per turn, not per round; the account is per key, so the
   number is the session's only with a dedicated key.

**Exit criterion:** one real turn yields a table of rounds with a hit
ratio and a time split. Do not proceed on vibes.

---

## 6. Phase 1 — the A/B, before any fix

Same task, same repo state, same model, same starting context. Three
task classes, because they stress different mechanisms:

| Class | Task | Stresses |
|---|---|---|
| A | a question answerable from 2-3 files | rounds per observation (H4, H8) |
| B | one-file edit + run the tests | edit exactness (H5), shell cost (H3) |
| C | multi-file exploration, then a change | cache (H1), compaction (H6) |

Measure per class: rounds, total wall time, per-round wall time, cache hit
ratio, tool calls per round, tool time share, edit failures, compactions.
Quality proxy: tests pass, diff size, whether the answer needed a
follow-up.

Record both harnesses. If opencode's per-round numbers are not
recoverable from its own session store, use wall-clock timing on the CLI
as the fallback — a coarse number still discriminates a 2× effect.

**Exit criterion:** a ranked cause list with numbers, or a finding that
the effect does not reproduce (which is also a result).

**Caveats to state in the comparison:** opencode is being run *in its own
repo* here, with a prompt tuned for it; a task in a third repo is the
fairer setting.

---

## 7. Phase 2 — fixes, in this order

Each fix is its own commit with a before/after table from Phase 0's
metrics. Stop after any fix that reaches the target.

### F1 — make the prefix stable (H1)

Preferred shape: **the block speaks in bands, not numbers.** Below
`warn_at` send nothing; inside the band send "you are approaching the
soft line"; past `soft` send the current advice. The round counter and the
exact token count leave the prompt. The model keeps the decision it was
given in ADR 040 (act at a step boundary) while the prefix stays
byte-stable for most of a turn.

Fallback if the band text proves too coarse: keep the numbers, move the
block to a trailing message after the history (provider-dependent; some
reject a second system message, so this needs a capability check, not a
guess).

**Target:** cache hit ratio > 80 % after round 1; per-round latency flat.
**Must not regress:** ADR 040's behavior — the model should still act
before the hard line. Measure compaction-forced-mid-turn count.

### F2 — parallel tool calls in the auto subset (H2)

Run the calls the gate classified `auto` concurrently, capped (4, like the
subagent cap), keeping the round atomic. Constraints to respect:

- the gate classifies the whole round first — it already does;
- start/finish events are currently ordered per call (review F2); parallel
  execution needs ids on the events or a stated unordered contract;
- a user stop between calls still has to be honored, so the runner needs a
  between-call interrupt check, not just a per-tool one;
- approval-needed calls stay serial — they park anyway.

**Target:** `tool_ms` on a 4-read round drops to ≈ 1 call, not 4.

### F3 — reduce the edit-retry tax (H5)

A strictly ordered fallback chain (exact → line-trimmed → whitespace-
normalized → indentation-flexible → block-anchor), each stage requiring
exactly one match, refusing otherwise, and reporting which strategy
matched. The fail-closed rule stays; ambiguity under normalization is
still an error. This is the one place where copying opencode's replacer
design is cheaper than inventing one.

**Target:** zero `old_string not found` on a task set that currently
produces them; never a wrong-location edit in the test suite.

### F4 — trim the coaching, keep the data (H6)

Drop the per-request prose about step boundaries and `compact`; keep the
band advice (F1). Reconsider "read the full file before editing" — the
rule is right for correctness and expensive for context; a read of the
target region plus surrounding context, with a follow-up read when the
edit fails, may dominate. Measure duplication reads and compaction count.

**Target:** compactions per turn halve; repeated reads disappear.

### F5 — batch by policy, not by hope (H4)

A prompt rule — "do not mix a call that needs approval with observation
calls" — plus the measurement. Cheap, reversible, measurable. Only after
F1/F2, because a batched round is only faster once the round itself is
cheap.

### F6 — later, separately

Tool-surface collapse (H8), a prompt family for non-Claude models (H7),
and the 644 M accounting anomaly. These are real, but they are not the
first thing to prove.

---

## 8. Risks, and what cancels the plan

- **The effect does not reproduce.** Then the report was about task mix or
  model, and the findings are the metrics work (Phase 0) plus H7. Say so
  and stop.
- **The provider does not cache on this route.** H1's mechanism is dead;
  F1 still removes pointless prompt churn, but check `cached_tokens`
  before spending a day on it.
- **Per-round timing itself is noisy.** Wall time is dominated by how much
  the model writes; record output tokens alongside `llm_ms` and compare at
  similar output size, or a terse round will look like a fast one.
- **Instrumentation changes behavior.** No extra provider calls, no disk
  writes per round.
- **The 644 M input count is a double count.** Then the sidebar's cost and
  token display are wrong, and that is a separate finding — file it before
  F1, because it may mean the harness has *already* been paying for cache
  misses it never saw.

---

## 9. Open questions for the owner

1. ~~Does the ollama-cloud route fill `prompt_tokens_details.cached_tokens`?~~
   **Answered (2026-10-24): yes.** The OpenAI-compatible response carries
   it (verified), ReqLLM maps it, the harness drops it. The route is also
   confirmed: layer 0 in `priv/coding-agent/config.toml` sets
   `provider = "openai"` + `base_url = https://ollama.com/v1`, and the
   empty user table does not erase it.
   **Also answered:** both clients do share one key, so the 26 % is a
   blend and the harness's own ratio is at most that.
2. May the budget block become band-only (F1), or is the exact count part
   of ADR 040's contract?
3. `/stats` as a slash command, or metrics in the session export only?
4. Is "one tool call per round" acceptable to you as a style, or is
   batching a goal in itself?

---

## 10. Non-goals

Startup time, `mix test` wall time (≈ 98 s, its own topic), the sandbox's
process-spawn cost as a general question, a benchmarking harness, and any
rewrite of the turn loop. This plan is about *this* asymmetry: the same
work costing more turns, or slower turns, than a peer harness.
