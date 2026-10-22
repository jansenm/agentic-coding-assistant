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
      grants `change_vcs`, so plain shell cannot rewrite history — for a
      worktree that is the MAIN repository's `.git/worktrees/<name>` (and
      its commondir), which is why the sentence is about VCS state and
      not about a path inside the scope;
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

  # The session scratch is bound over this mount (ADR 022); `visible_path/2`
  # is its inverse, and both must name the same place.
  @scratch_mount "/tmp"

  @impl true
  def id, do: :bwrap

  @impl true
  def available? do
    probe()
  end

  @doc """
  Functional probe, memoised per OS process: run a trivial command through
  bwrap from this VM and see it succeed. Detects a missing binary, missing
  unprivileged user namespaces, and the bwrap < 0.11.1 SIGCHLD bug that
  hits precisely because the Erlang VM is the parent.
  """
  @spec probe() :: boolean()
  def probe do
    match?(:ok, check())
  end

  @doc """
  The functional probe with a **reason**: `:ok`, or `{:error, reason}` where
  reason is a human-readable sentence for the startup log. Memoised.
  """
  @impl true
  @spec check() :: :ok | {:error, String.t()}
  def check do
    case :persistent_term.get({__MODULE__, :check}, :unset) do
      :unset ->
        result = do_check()
        :persistent_term.put({__MODULE__, :check}, result)
        result

      result ->
        result
    end
  end

  defp do_check do
    case System.find_executable(@bwrap) do
      nil ->
        {:error, "bubblewrap (bwrap) was not found on PATH"}

      exe ->
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

        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            {:args, argv}
          ])

        await_check(port, System.monotonic_time(:millisecond) + 5_000)
    end
  rescue
    e -> {:error, "bwrap probe failed: #{Exception.message(e)}"}
  end

  defp await_check(port, deadline) do
    receive do
      {^port, {:data, data}} -> await_check(port, deadline, data)
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, code}} -> {:error, "bwrap exited #{code}: bwrap probe setup"}
      {^port, :closed} -> {:error, "bwrap exited without a status: bwrap probe setup"}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        {:error, "bwrap probe timed out after 5s"}
    end
  end

  defp await_check(port, deadline, acc) do
    receive do
      {^port, {:data, data}} ->
        await_check(port, deadline, acc <> data)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        {:error, "bwrap exited #{code}: #{probe_detail(acc)}"}

      {^port, :closed} ->
        {:error, "bwrap exited without a status: #{probe_detail(acc)}"}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        {:error, "bwrap probe timed out after 5s"}
    end
  end

  # Turn bwrap's stderr into a hint a user can act on. The common case on
  # hardened hosts is a disabled unprivileged user namespace.
  defp probe_detail(output) do
    output = output |> to_string() |> String.trim()

    cond do
      output == "" ->
        "no output (see `bwrap --version`)"

      String.contains?(output, [
        "Operation not permitted",
        "permission denied",
        "Permission denied"
      ]) ->
        output <>
          " — unprivileged user namespaces are likely disabled " <>
          "(sysctl user.max_user_namespaces=0 on hardened hosts)"

      true ->
        output
    end
  end

  @impl true
  def wrap(spec, %{root: root} = profile) when is_binary(root) do
    root = Path.expand(root)

    with true <- File.dir?(root) || {:error, {:no_scope_root, root}},
         {:ok, _} <- ensure_scratch(profile) do
      {:ok, executable(), argv(root, spec, profile)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def wrap(_spec, _profile), do: {:error, :bad_profile}

  @doc """
  The session scratch is bound over `#{@scratch_mount}` (ADR 022), so a host
  file under it is addressed inside the sandbox by its `#{@scratch_mount}/...`
  path. Any other host path is unchanged.
  """
  @impl true
  def visible_path(host_path, %{scratch: dir}) when is_binary(dir) and dir != "" do
    dir = Path.expand(dir)
    host = Path.expand(host_path)

    if host == dir or String.starts_with?(host, dir <> "/") do
      @scratch_mount <> String.replace_prefix(host, dir, "")
    else
      host_path
    end
  end

  def visible_path(host_path, _profile), do: host_path

  # The session scratch directory (ADR 022) is created lazily on the first
  # confined call. A scope without a session id carries no `:scratch` and
  # keeps the ephemeral tmpfs, so nothing is created.
  defp ensure_scratch(%{scratch: dir}) when is_binary(dir) and dir != "" do
    CodingAgent.Core.Session.Scratch.ensure(dir)
  end

  defp ensure_scratch(_profile), do: {:ok, nil}

  defp executable do
    System.find_executable(@bwrap) || @bwrap
  end

  @doc """
  Builds the bwrap argv for a command spec and profile. Public and pure so
  it can be asserted in tests without running bwrap.
  """
  @spec argv(String.t(), CodingAgent.Core.Sandbox.spec(), CodingAgent.Core.Sandbox.profile()) ::
          [String.t()]
  def argv(root, spec, profile) do
    root = Path.expand(root)

    base = [
      "--ro-bind",
      "/",
      "/"
    ]

    network = Map.get(profile, :network, false)
    change_vcs = Map.get(profile, :change_vcs, false)
    root_ro = Map.get(profile, :root_ro, false)

    # Order matters: scratch first, then the scope bind *over* it, so a
    # scope root that happens to live under /tmp is still visible (the
    # scratch is the lower layer for the rest of /tmp). With `root_ro` the
    # scope is bound read-only: an agent that denies the write tools gets a
    # shell that cannot write the source either (`echo > f` bypass).
    # A read-only root keeps .git read-only too: `change_vcs` is an
    # escalation that re-binds `.git` writable OVER the root, so allowing
    # it here would re-open the very path `root_ro` closes. The narrower
    # grant wins (a read-only agent cannot change the repository, period).
    base ++
      scratch_args(profile) ++
      rw_args(profile) ++
      [root_bind(root_ro), root, root] ++
      git_args(root, change_vcs and not root_ro) ++
      ro_args(profile) ++
      hide_args(profile) ++
      ["--dev", "/dev", "--proc", "/proc"] ++
      namespace_args(network) ++
      ["--new-session", "--die-with-parent", "--chdir", root] ++
      inner(spec)
  end

  # The command launched inside the namespace. Both forms go through
  # /bin/sh only to apply the rlimits; the exec form then `exec`s the
  # real program with its argv, so an agent-supplied argument list is
  # never re-parsed by a shell (no injection from the git tool's args).
  defp inner({:shell, command}), do: ["/bin/sh", "-c", prelude() <> command]

  defp inner({:exec, file, args}) do
    ["/bin/sh", "-c", prelude() <> ~s(exec "$@"), "sh", file | args]
  end

  # `{:stdin, count, spec}` (ADR 030): feed exactly `count` bytes, then
  # close the pipe — that close is the inner process's EOF, which a port
  # cannot signal any other way. The pipeline wraps the SAME inner forms,
  # so the exec form keeps its argv as positional parameters and the
  # rlimits still apply to the whole pipeline.
  defp inner({:stdin, count, {:shell, command}}) when is_integer(count) and count >= 0 do
    ["/bin/sh", "-c", prelude() <> "{ head -c #{count}; } | " <> command]
  end

  defp inner({:stdin, count, {:exec, file, args}})
       when is_integer(count) and count >= 0 do
    ["/bin/sh", "-c", prelude() <> ~s({ head -c #{count}; } | exec "$@"), "sh", file | args]
  end

  # The scratch over /tmp (ADR 022): a session-scoped host directory,
  # bound so `/tmp` persists across calls but stays private to the
  # session (the host's shared /tmp is never visible). Without a session
  # scratch the historical per-call tmpfs is kept — `/tmp` then dies with
  # the namespace, exactly as before. `--size` is tmpfs-only
  # (`bwrap: --size must be followed by --tmpfs`), so it appears only on
  # the fallback path.
  defp scratch_args(%{scratch: dir}) when is_binary(dir) and dir != "" do
    ["--bind", Path.expand(dir), @scratch_mount]
  end

  defp scratch_args(_profile) do
    ["--size", to_string(@tmpfs_bytes), "--tmpfs", @scratch_mount]
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

  # The git directories `.git` resolves to, re-bound OVER the scope bind:
  # read-only for plain shell, read-write when git write is granted (the
  # dedicated `git` tool). A plain checkout needs one bind; a WORKTREE
  # checkout needs two, because git splits its state.
  #
  # Found live (dogfooding in a worktree): `.git` was a gitfile pointing
  # at a gitdir *outside* the scope root, so it was only covered by the
  # read-only `/` bind and `git commit` died on `index.lock` (EROFS).
  # Binding just that worktree gitdir is not enough — a commit also writes
  # the object and ref under the COMMON dir (`<gitdir>/commondir`, e.g.
  # `../..`), which is likewise outside the scope. Resolve both from the
  # filesystem only (gitfile + commondir), no git invocation, so `argv/3`
  # stays pure and cheap.
  defp git_args(root, change_vcs) do
    root
    |> git_dirs()
    |> Enum.flat_map(fn dir -> [git_bind(change_vcs), dir, dir] end)
  end

  defp git_bind(true), do: "--bind"
  defp git_bind(false), do: "--ro-bind"

  defp root_bind(true), do: "--ro-bind"
  defp root_bind(false), do: "--bind"

  # Every real git directory for `root`, de-duplicated, common dir
  # included. Empty when there is no git metadata.
  #
  # The `.git` entry is looked up on the walk UP from `root` to the git
  # root (`Core.Repo`), not just at `root` itself: a session started in a
  # SUBDIRECTORY of the checkout found no `.git` here, so the writable
  # git bind was never emitted and `git add`/`commit` (and the checkpoint
  # index) died with EROFS on the read-only `/` bind — silently, because
  # `ensure_repo`'s `rev-parse` reports "inside work tree" even from a
  # subdirectory. A `git worktree` is the same shape and is handled by the
  # same walk. Finding the real git dir fixes that without moving
  # `scope_root`.
  defp git_dirs(root) do
    case CodingAgent.Core.Repo.root(root) do
      nil -> []
      git_root -> uniq_git_dirs(Path.join(git_root, ".git"))
    end
  end

  defp uniq_git_dirs(git) do
    cond do
      # a normal checkout: `.git` is the gitdir itself
      File.dir?(git) ->
        [git]

      # a worktree/submodule checkout: `.git` is a gitfile naming the
      # per-worktree gitdir, plus a commondir pointing at the shared dir
      File.exists?(git) ->
        case gitfile_target(git) do
          nil -> []
          dir -> Enum.uniq([dir | List.wrap(common_dir(dir))])
        end

      true ->
        []
    end
  end

  # The gitdir named by a gitfile's `gitdir: <path>` (an absolute path in
  # practice; resolved against the gitfile's dir if relative). The file
  # may carry a trailing newline.
  defp gitfile_target(path) do
    case File.read(path) do
      {:ok, content} ->
        case Regex.run(~r/^gitdir:\s*(.+)$/m, String.trim_trailing(content)) do
          [_, dir] -> expand_target(dir, Path.dirname(path))
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp expand_target(dir, base) do
    case String.trim(dir) do
      "" -> nil
      stripped -> Path.expand(stripped, base)
    end
  end

  # The shared gitdir from `<worktree-gitdir>/commondir` (relative to the
  # worktree gitdir). A normal checkout has no commondir file; nil then.
  defp common_dir(gitdir) do
    file = Path.join(gitdir, "commondir")

    case File.read(file) do
      {:ok, content} ->
        rel = String.trim(content)
        if rel == "", do: nil, else: Path.expand(rel, gitdir)

      _ ->
        nil
    end
  end

  defp ro_args(profile) do
    extra =
      profile
      |> Map.get(:ro, [])
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&File.exists?/1)

    Enum.flat_map(extra, fn path -> ["--ro-bind", path, path] end)
  end

  # hide: the path becomes a READ-ONLY bind of the shipped notice — as a
  # directory for a hidden directory (so the notice file sits inside it),
  # as a file for a hidden file. One flag and one asset for both cases:
  # `--ro-bind <notice-dir> <p>` / `--ro-bind <notice-dir>/README.txt <p>`.
  #
  # A hidden path therefore EXISTS and says so, instead of being an empty
  # image the agent cannot tell from a missing one, and it is not
  # writable, so nothing about it evaporates silently. The path must
  # exist on the host for bwrap to mount over it; a stale entry emits
  # nothing at all.
  defp hide_args(profile) do
    notice = Path.dirname(notice_path())

    profile
    |> Map.get(:hide, [])
    |> Enum.map(&Path.expand/1)
    |> Enum.flat_map(fn path ->
      cond do
        File.dir?(path) -> ["--ro-bind", notice, path]
        File.exists?(path) -> ["--ro-bind", notice_path(), path]
        true -> []
      end
    end)
  end

  # The notice shipped with the app; its content is the whole message, so
  # the text lives in `priv/` and not here.
  defp notice_path do
    Path.join([
      Application.app_dir(:coding_agent),
      "priv",
      "coding-agent",
      "sandbox",
      "README.txt"
    ])
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
    # TMPDIR points at the scratch mounted over /tmp (ADR 022), so tools
    # that honour $TMPDIR and tools that hardcode /tmp agree on one place.
    "export TMPDIR=/tmp; " <>
      "ulimit -u #{@ulimit_procs} 2>/dev/null; " <>
      "ulimit -f #{@ulimit_fsize_blocks} 2>/dev/null; " <>
      "ulimit -t #{@ulimit_cpu_secs} 2>/dev/null; "
  end
end
