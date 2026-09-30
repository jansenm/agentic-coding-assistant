# ExRatatui.Server busy-loops at 100% CPU when `poll_event/1` returns an error

We run an `ExRatatui.App` on the `:local` transport. Under some condition we
can't yet pin down, the server process pins a core at ~100% and the UI stalls.
`poll_event/1` itself is fine: on a live pty it blocks correctly for the
timeout and returns events.

Looking at the failure path, I think the loop is unguarded:

- `Server.handle_info(:poll, ...)` -> `handle_poll_result/2`
- `handle_poll_result({:error, _}, state)` returns `{:continue, state, false}`
- `process_poll_result/1` ends in `maybe_rearm_poll/1`, which does
  `send(self(), :poll)` with **no delay**.

So if `poll_event/1` returns an error instead of blocking for `poll_interval`,
the server re-polls immediately and spins. Compare the `nil` case (timeout):
that re-arms too, but it's safe because the NIF blocked. Any *persistent*
error -- crossterm's reader static already carries `source: None` (e.g. no tty
and no `/dev/tty`), or a tty read that starts failing after setup -- becomes an
unthrottled busy loop that can never recover, since crossterm's
`INTERNAL_EVENT_READER` caches the failed source for the NIF's lifetime.

## Evidence

From an `erl_crash.dump` taken with `kill -USR1` while the process was hot:

- `ExRatatui.Server` (`<0.871.0>`): `Reductions: 17355677608` -- 17.3 billion.
  Runner-up process: ~400M.
- `Current call: erts_internal:dirty_nif_finalizer/1`; the process sits on a
  `dirty_io_scheduler` with `Current Process Limited Stack Trace` ->
  `ExRatatui:poll_event/1` -> `ExRatatui.Server:handle_info/2`.
- `Message queue length: 0` -- not a message flood, just a tight self-rearm
  loop.
- The same code path is present on current `main`, so this isn't fixed by
  upgrading.

## Suggested fix

Treat a poll error as a distinct, backed-off case instead of re-arming at full
speed, e.g.:

```elixir
def handle_poll_result({:error, reason}, state) do
  state = %{state | consecutive_poll_errors: state.consecutive_poll_errors + 1}
  # log once, don't spin
  ...
end
```

and in `maybe_rearm_poll/1` either skip the re-arm after N consecutive errors,
or re-arm via `Process.send_after(self(), :poll, backoff_ms)` rather than
`send/2`. A single failed poll shouldn't be fatal, but it also shouldn't be
free.

## Environment

- Elixir 1.20.4 / OTP 28 (erts 16.4.0.4)
- Linux x86_64
- `ex_ratatui 0.13.1`, crossterm 0.29
- `:local` transport
- NIF built from source (same behavior with the shipped precompiled artifact)

## Note

No minimal, deterministic reproduction yet -- only the dump, so the trigger is
best phrased as "`poll_event` returns an error" rather than a specific cause.
The backoff/fuse is a real consequence of a documented error state regardless.
