# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Session.Scratch do
  @moduledoc """
  The per-session scratch directory (ADR 022): the host directory that the
  sandbox binds over `/tmp`, so `/tmp` is persistent **within a session**
  but still gone after a reboot.

  The path rule lives here, once:

    * ``System.tmp_dir!()/coding-agent/<session-id>/`` — Elixir's
      ``System.tmp_dir!/0`` already honours a set ``$TMPDIR`` and falls
      back to ``/tmp``, exactly the ADR's rule, so we do not re-read the
      environment.

  The directory is created lazily by ``Bwrap.wrap/2`` on the first
  confined call and removed by the session lifecycle verbs
  (``Store.delete/1``, ``Store.prune``, ``Store.rename/2``) — never by an
  OS timer. A session resumed after a reboot finds it empty, which is
  precisely ``/tmp`` semantics.
  """

  @app "coding-agent"

  @doc "The parent directory of all session scratch dirs (`<tmp>/coding-agent`)."
  @spec base_dir() :: String.t()
  def base_dir, do: Path.join(System.tmp_dir!(), @app)

  @doc "The scratch directory for a session id."
  @spec path(String.t()) :: String.t()
  def path(id) when is_binary(id), do: Path.join(base_dir(), id)

  @doc """
  The scratch directory implied by a tool scope, or `nil` when the scope
  carries no session id (the no-op default and bare test scopes) — in
  which case the sandbox keeps its ephemeral tmpfs `/tmp`.

  One rule for the three profile builders (`Shell`, `Git`, `Tools`).
  """
  @spec from_scope(map()) :: String.t() | nil
  def from_scope(%{session_id: id}) when is_binary(id) and id != "", do: path(id)
  def from_scope(_scope), do: nil

  @doc """
  Creates the scratch directory (mode 0700) if it does not exist.
  Idempotent — safe to call on every confined invocation.
  """
  @spec ensure(String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure(dir) when is_binary(dir) do
    with :ok <- File.mkdir_p(dir) do
      # best effort: privacy within /tmp is nice but a chmod failure on an
      # exotic filesystem must not fail the tool call
      _ = File.chmod(dir, 0o700)
      {:ok, dir}
    end
  end

  @doc "Removes a session's scratch directory (best effort)."
  @spec remove(String.t()) :: :ok
  def remove(dir) when is_binary(dir) do
    _ = File.rm_rf(dir)
    :ok
  end

  @doc """
  Moves a session's scratch directory when the session is renamed. A
  missing source is fine (scratch is created lazily, so most sessions
  have none).
  """
  @spec move(String.t(), String.t()) :: :ok
  def move(old_dir, new_dir) when is_binary(old_dir) and is_binary(new_dir) do
    case File.rename(old_dir, new_dir) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end
end
