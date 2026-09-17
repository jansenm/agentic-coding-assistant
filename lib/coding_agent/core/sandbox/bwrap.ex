defmodule CodingAgent.Core.Sandbox.Bwrap do
  @moduledoc """
  Bubblewrap confinement (ADR 015): one static profile, bound the process,
  not the command text.

  The profile:

    * whole filesystem read-only (`--ro-bind / /`), so `/etc`, `/usr` and
      every `$HOME` path not explicitly opened cannot be written;
    * the session scope root is a plain read-write bind (`--bind`), so a
      formatter/build/codegen writes the real tree immediately — there is
      no overlay and no delta (ADR 015 decision 2);
    * `.git` is re-bound read-only *over* that bind unless the profile
      grants `git_write`, so plain shell cannot rewrite history;
    * configured cache paths are read-write binds, shared with the host as
      today (ADR 015 decision 3);
    * `/tmp` is a tmpfs; the network is off (`--unshare-all`, no
      `--share-net`) unless the profile grants `network`;
    * resource caps (`ulimit -u`/`-f`/`-t`) are applied in the shell
      prelude (ADR 015 decision 4);
    * `--new-session` (TIOCSTI guard) and `--die-with-parent`.

  `wrap/2` is pure: it builds argv and never touches the filesystem beyond
  expanding paths. `available?/0` runs a functional probe, not a version
  check — bwrap 0.11.1 fixed a SIGCHLD disposition bug that affects being
  launched from a process that ignores SIGCHLD (the Erlang VM, upstream
  #705), and user namespaces may be disabled by host hardening.
  """

  @behaviour CodingAgent.Core.Sandbox

  @bwrap "bwrap"

  # Caps (ADR 015 decision 4): processes, file size (blocks), CPU seconds,
  # and the scratch tmpfs size (bytes).
  @ulimit_procs 512
  @ulimit_fsize_blocks 4_194_304
  @ulimit_cpu_secs 1800
  @tmpfs_bytes 1024 * 1024 * 1024

  @impl true
  def id, do: :bwrap

  @impl true
  def available? do
    probe()
  end

  @impl true
  def confines?, do: true

  @doc """
  Functional probe, memoised per OS process: run a trivial command through
  bwrap from this VM and see it succeed. Detects a missing binary, missing
  unprivileged user namespaces, and the bwrap < 0.11.1 SIGCHLD bug that
  hits precisely because the Erlang VM is the parent.
  """
  @spec probe() :: boolean()
  def probe do
    case :persistent_term.get({__MODULE__, :probe}, :unset) do
      :unset ->
        result = do_probe()
        :persistent_term.put({__MODULE__, :probe}, result)
        result

      result when is_boolean(result) ->
        result
    end
  end

  defp do_probe do
    argv = [
      "--ro-bind",
      "/",
      "/",
      "--dev",
      "/dev",
      "--proc",
      "/proc",
      "--unshare-all",
      "--die-with-parent",
      "/bin/sh",
      "-c",
      "exit 0"
    ]

    case System.find_executable(@bwrap) do
      nil ->
        false

      exe ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            {:args, argv}
          ])

        await_probe(port, System.monotonic_time(:millisecond) + 5_000)
    end
  rescue
    _ -> false
  end

  defp await_probe(port, deadline) do
    receive do
      {^port, {:data, _}} -> await_probe(port, deadline)
      {^port, {:exit_status, 0}} -> true
      {^port, {:exit_status, _}} -> false
      {^port, :closed} -> false
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        false
    end
  end

  @impl true
  def wrap(command, %{root: root} = profile) when is_binary(command) and is_binary(root) do
    root = Path.expand(root)

    if File.dir?(root) do
      {:ok, executable(), argv(root, command, profile)}
    else
      {:error, {:no_scope_root, root}}
    end
  end

  def wrap(_command, _profile), do: {:error, :bad_profile}

  defp executable do
    System.find_executable(@bwrap) || @bwrap
  end

  @doc """
  Builds the bwrap argv for a command and profile. Public and pure so it
  can be asserted in tests without running bwrap.
  """
  @spec argv(String.t(), String.t(), CodingAgent.Core.Sandbox.profile()) :: [String.t()]
  def argv(root, command, profile) do
    root = Path.expand(root)

    base = [
      "--ro-bind",
      "/",
      "/"
    ]

    network = Map.get(profile, :network, false)
    git_write = Map.get(profile, :git_write, false)

    # Order matters: scratch tmpfs first, then the read-write scope bind
    # *over* it, so a scope root that happens to live under /tmp is still
    # visible (the tmpfs is the lower layer for the rest of /tmp).
    base ++
      ["--size", to_string(@tmpfs_bytes), "--tmpfs", "/tmp"] ++
      rw_args(profile) ++
      ["--bind", root, root] ++
      git_args(root, git_write) ++
      ro_args(profile) ++
      hide_args(profile) ++
      ["--dev", "/dev", "--proc", "/proc"] ++
      namespace_args(network) ++
      ["--new-session", "--die-with-parent", "--chdir", root] ++
      ["/bin/sh", "-c", prelude() <> command]
  end

  # Extra read-write mounts (ADR 015 decision 3): the resolved mount
  # schema. Only existing paths are mounted, so a bare container does not
  # fail on a missing ~/.m2.
  defp rw_args(profile) do
    profile
    |> Map.get(:rw, [])
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.filter(&File.exists?/1)
    |> Enum.flat_map(fn dir -> ["--bind", dir, dir] end)
  end

  # `.git` read-only over the rw scope bind, unless git write is granted.
  defp git_args(root, false) do
    git = Path.join(root, ".git")

    if File.exists?(git) do
      ["--ro-bind", git, git]
    else
      []
    end
  end

  defp git_args(_root, true), do: []

  defp ro_args(profile) do
    extra =
      profile
      |> Map.get(:ro, [])
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&File.exists?/1)

    Enum.flat_map(extra, fn path -> ["--ro-bind", path, path] end)
  end

  # hide: a directory becomes an empty writable tmpfs; a file becomes
  # /dev/null. The distinction is by host type (ADR 015 mount schema).
  defp hide_args(profile) do
    profile
    |> Map.get(:hide, [])
    |> Enum.map(&Path.expand/1)
    |> Enum.flat_map(fn path ->
      cond do
        File.dir?(path) -> ["--tmpfs", path]
        File.exists?(path) -> ["--ro-bind", "/dev/null", path]
        true -> []
      end
    end)
  end

  defp namespace_args(true), do: ["--unshare-all", "--share-net"]
  defp namespace_args(false), do: ["--unshare-all"]

  # rlimits are set in the namespace shell before the command runs, so the
  # command and everything it forks inherits them. No `exec` is needed:
  # under `--unshare-pid` + `--die-with-parent` the shell is PID 1 of the
  # namespace, so when bwrap is killed the whole namespace is torn down —
  # which also makes the Shell timeout kill reach descendants, better than
  # the unconfined path.
  defp prelude do
    "ulimit -u #{@ulimit_procs} 2>/dev/null; " <>
      "ulimit -f #{@ulimit_fsize_blocks} 2>/dev/null; " <>
      "ulimit -t #{@ulimit_cpu_secs} 2>/dev/null; "
  end
end
