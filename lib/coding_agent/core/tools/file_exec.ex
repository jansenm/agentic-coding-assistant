defmodule CodingAgent.Core.Tools.FileExec do
  @moduledoc """
  The confined file-operation executor for the native file tools (ADR
  030): `read_file`, `write_file`, `edit`, `list_dir`, `delete_file` and
  `move_file` run their operation as a CHILD PROCESS under the session's
  sandbox profile, exactly as `shell`/`git` do. The BEAM performs no
  scope-relevant filesystem access itself.

  One boundary: the bwrap profile. `hide`ed paths read as their empty
  image, `ro`-bound paths fail with `EROFS`, and the scope root's
  read-write bind is the only writable tree — all by construction, with
  no second predicate to keep in sync (`Tools.in_scope?/2` degrades to a
  discovery helper).

  The operation is a small, fixed program per tool (`cat`, `tee`, `ls`,
  `rm`, `mv`, `mkdir`, `sed`); the PATH is passed as an argument, never
  interpolated into the script, so a quote in a filename cannot escape the
  command. `Exec.run/5` carries the profile and, for writes, the payload on
  stdin (see
  `{:stdin, ...}` in `CodingAgent.Core.Sandbox`).

  A relative path is resolved against the sandbox's working directory
  (the scope root, set by `{:cd, cwd}`), so the confined program sees the
  same tree the profile describes. An absolute path is used as-is — the
  profile decides what is reachable.
  """

  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.Tools

  # The fixed programs, by bare name so each sandbox resolves them its
  # own way (`None`/the stub via PATH; bwrap's inner `sh` inside the
  # namespace). `--` terminates option parsing so a path that starts
  # with `-` is a filename, not a flag. `cat`/`tee`/`ls` are POSIX.
  @cat "cat"
  @tee "tee"
  @ls "ls"
  @sed "sed"
  @rm "rm"
  @mv "mv"
  @mkdir "mkdir"

  @doc """
  Reads a file through a confined `cat`. Returns `{:ok, contents}` or
  `{:error, message}`.   A file larger than `max_bytes` is REPORTED, not
  truncated, and never fully buffered: the read is capped at `max_bytes`
  (`truncate: false`, `:max_output`), so the moment the file exceeds it
  the command is killed and the BEAM holds only that much.
  """
  @spec read(Tools.scope(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def read(scope, path, secs, max_bytes) do
    profile = Tools.profile(scope)
    opts = [truncate: false, max_output: max_bytes, label: nil]

    case Exec.run({:exec, @cat, ["--", path]}, cwd(scope), secs, profile, opts) do
      {:ok, output, 0} ->
        {:ok, output}

      {:raw_too_large, _size} ->
        Tools.error("file larger than #{div(max_bytes, 1024)} KiB: #{path}")

      {:ok, output, _code} ->
        {:error, failure(output, path)}

      {:timeout, _partial} ->
        {:error, "timed out reading #{path}"}

      {:stopped, _partial} ->
        {:error, "stopped by the user while reading #{path}"}

      {:sandbox_error, reason} ->
        {:error, "cannot read #{path} under the sandbox: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Writes `content` through a confined `tee`. Returns `{:ok, path}` or
  `{:error, message}`. The content goes on stdin; the payload's byte size
  is computed here and the pipe close is the child's EOF.
  """
  @spec write(Tools.scope(), String.t(), iodata(), pos_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def write(scope, path, content, secs) do
    profile = Tools.profile(scope)

    case Exec.run({:exec, @tee, ["--", path]}, cwd(scope), secs, profile, stdin: content) do
      # tee echoes the payload to stdout; a zero exit means the bytes were
      # written (and flushed) before it returned.
      {:ok, _output, 0} ->
        {:ok, path}

      {:ok, output, _code} ->
        {:error, failure(output, path)}

      {:timeout, _partial} ->
        {:error, "timed out writing #{path}"}

      {:stopped, _partial} ->
        {:error, "stopped by the user while writing #{path}"}

      {:sandbox_error, reason} ->
        {:error, "cannot write #{path} under the sandbox: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "cannot write #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Creates a directory through a confined `mkdir` (`write_file`'s
  `parents`).

  `--parents` is always on: it creates the whole chain and does not mind
  an existing directory (measured: exit 0), while a FILE in the way still
  fails with `File exists`. The one caller is `write_file` creating the
  parent of the file it is about to write, so there is no unpinned
  variant to offer.
  """
  @spec mkdir(Tools.scope(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def mkdir(scope, path, secs) do
    profile = Tools.profile(scope)

    case Exec.run({:exec, @mkdir, ["--parents", "--", path]}, cwd(scope), secs, profile) do
      {:ok, _output, 0} ->
        {:ok, path}

      {:ok, output, _code} ->
        {:error, failure(output, path)}

      {:timeout, _partial} ->
        {:error, "timed out creating #{path}"}

      {:stopped, _partial} ->
        {:error, "stopped by the user while creating #{path}"}

      {:sandbox_error, reason} ->
        {:error, "cannot create #{path} under the sandbox: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "cannot create #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Removes a path through a confined `rm` (`delete_file`).

  The flags are the tool's own, in the tool's spelling: `-r` when
  `recursive`, `-d` when `dir`. `-d` is what lets `rm` remove an empty
  directory or any symlink (the link itself — `rm` never dereferences);
  a file needs neither flag. Without the matching flag `rm` reports its
  own reason ("Is a directory", "Directory not empty") rather than
  silently succeeding, which is exactly the signal we want.

  `--` terminates option parsing, so a path that starts with `-` is a
  filename.
  """
  @spec remove(Tools.scope(), String.t(), keyword(), pos_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def remove(scope, path, opts, secs) do
    profile = Tools.profile(scope)
    argv = rm_flags(opts) ++ ["--", path]

    case Exec.run({:exec, @rm, argv}, cwd(scope), secs, profile) do
      {:ok, _output, 0} ->
        {:ok, path}

      {:ok, output, _code} ->
        {:error, failure(output, path)}

      {:timeout, _partial} ->
        {:error, "timed out deleting #{path}"}

      {:stopped, _partial} ->
        {:error, "stopped by the user while deleting #{path}"}

      {:sandbox_error, reason} ->
        {:error, "cannot delete #{path} under the sandbox: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "cannot delete #{path}: #{inspect(reason)}"}
    end
  end

  # The tool's own flags, in the long spelling the parameters are named
  # after. `--recursive` removes a non-empty directory; `--dir` removes an
  # empty one (or a symlink) — a plain file needs neither.
  defp rm_flags(opts) do
    recursive = if Keyword.get(opts, :recursive, false), do: ["--recursive"], else: []
    dir = if Keyword.get(opts, :dir, false), do: ["--dir"], else: []
    recursive ++ dir
  end

  @doc """
  Moves or renames a path through a confined `mv` (`move_file`).

  `-T` is always on: the destination is the exact new path, never a
  directory to move into (`mv -- a b` with an existing directory `b`
  would otherwise put the source at `b/a`). By default `--no-clobber`
  makes an existing destination a no-op; `force: true` switches to `-f`
  and overwrites. A symlink moves as a link — `mv` never dereferences.
  """
  @spec move(Tools.scope(), String.t(), String.t(), keyword(), pos_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def move(scope, from, to, opts, secs) do
    profile = Tools.profile(scope)
    argv = ["-T"] ++ clobber_flags(opts) ++ ["--", from, to]

    case Exec.run({:exec, @mv, argv}, cwd(scope), secs, profile) do
      {:ok, _output, 0} ->
        {:ok, to}

      {:ok, output, _code} ->
        {:error, failure(output, from)}

      {:timeout, _partial} ->
        {:error, "timed out moving #{from}"}

      {:stopped, _partial} ->
        {:error, "stopped by the user while moving #{from}"}

      {:sandbox_error, reason} ->
        {:error, "cannot move #{from} under the sandbox: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "cannot move #{from}: #{inspect(reason)}"}
    end
  end

  defp clobber_flags(opts) do
    if Keyword.get(opts, :force, false), do: ["-f"], else: ["--no-clobber"]
  end

  @doc """
  Lists a directory through a confined `ls`. Returns the raw listing or an
  error. `opts` are passed to `ls` (e.g. `["-a"]`); `--` guards the path.
  """
  @spec list(Tools.scope(), String.t(), [String.t()], pos_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def list(scope, path, opts, secs) do
    profile = Tools.profile(scope)

    case Exec.run({:exec, @ls, opts ++ ["--", path]}, cwd(scope), secs, profile) do
      {:ok, output, 0} ->
        {:ok, output}

      {:ok, output, _code} ->
        {:error, failure(output, path)}

      {:timeout, _partial} ->
        {:error, "timed out listing #{path}"}

      {:stopped, _partial} ->
        {:error, "stopped by the user while listing #{path}"}

      {:sandbox_error, reason} ->
        {:error, "cannot list #{path} under the sandbox: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "cannot list #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Existence + type probe through a confined `ls`: `:dir`, `:file` or
  `:missing`. Used by `edit`'s fail-closed shape check without a BEAM
  `File.stat/1`.
  """
  @spec stat(Tools.scope(), String.t(), pos_integer()) :: :dir | :file | :missing
  def stat(scope, path, secs) do
    profile = Tools.profile(scope)

    # `ls -d` succeeds for a file OR a directory; `--` guards the path.
    case Exec.run({:exec, @ls, ["-d", "--", path]}, cwd(scope), secs, profile) do
      {:ok, _output, 0} -> type_probe(scope, path, secs)
      _ -> :missing
    end
  end

  # `ls -d -- path/.` succeeds only if path is a directory (the trailing
  # `/.` fails for a regular file). One more argument to the same fixed
  # program; the path is never interpolated into a script.
  defp type_probe(scope, path, secs) do
    profile = Tools.profile(scope)

    case Exec.run({:exec, @ls, ["-d", "--", path <> "/."]}, cwd(scope), secs, profile) do
      {:ok, _output, 0} -> :dir
      _ -> :file
    end
  end

  @doc """
  Reads a LINE WINDOW of a file through a confined `sed` (ADR 038): lines
  `offset..offset+limit-1` (1-based), so a file larger than any whole-file
  cap is retrievable page by page. Also returns the total line count (a
  confined `wc -l`) so the caller can say how much remains.

  The window is bounded in the CHILD process, not in BEAM memory — a
  2 GiB file read as 200 lines costs 200 lines here.
  """
  @spec read_window(Tools.scope(), String.t(), pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, String.t()}
  def read_window(scope, path, offset, limit, secs) do
    profile = Tools.profile(scope)
    last = offset + limit - 1

    # `sed -n 'start[,end]p'` — the range is built from two integers we
    # validated, never from a string, so no expression can be injected.
    expr = if limit == 1, do: "#{offset}p", else: "#{offset},#{last}p"

    with {:ok, window} <-
           run_probe(profile, cwd(scope), ["-n", expr, "--", path], secs, path, "read"),
         {:ok, count} <- line_count(profile, cwd(scope), path, secs) do
      {:ok, window, count}
    end
  end

  # Total lines through a confined `sed -n '$='`. Chosen over `wc -l`
  # because it counts a final line WITHOUT a trailing newline correctly
  # (`wc -l` would report one less); an empty file prints nothing -> 0.
  @spec line_count(Tools.profile(), String.t(), String.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  defp line_count(profile, cwd, path, secs) do
    case Exec.run({:exec, @sed, ["-n", "$=", "--", path]}, cwd, secs, profile) do
      {:ok, output, 0} ->
        case String.trim(output) do
          "" -> {:ok, 0}
          trimmed -> count_or_error(trimmed, path)
        end

      {:ok, output, _code} ->
        {:error, failure(output, path)}

      {:timeout, _} ->
        {:error, "timed out counting #{path}"}

      {:stopped, _} ->
        {:error, "stopped by the user while counting #{path}"}

      {:sandbox_error, reason} ->
        {:error, "cannot count #{path} under the sandbox: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "cannot count #{path}: #{inspect(reason)}"}
    end
  end

  defp count_or_error(trimmed, path) do
    case Integer.parse(trimmed) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "could not count lines in #{path}"}
    end
  end

  defp run_probe(profile, cwd, args, secs, path, verb) do
    case Exec.run({:exec, @sed, args}, cwd, secs, profile) do
      {:ok, output, 0} ->
        {:ok, output}

      {:ok, output, _code} ->
        {:error, failure(output, path)}

      {:timeout, _partial} ->
        {:error, "timed out #{verb}ing #{path}"}

      {:stopped, _partial} ->
        {:error, "stopped by the user while #{verb}ing #{path}"}

      {:sandbox_error, reason} ->
        {:error, "cannot #{verb} #{path} under the sandbox: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "cannot #{verb} #{path}: #{inspect(reason)}"}
    end
  end

  defp cwd(%{root: root}), do: Path.expand(root)

  # The confined program's stderr (merged into stdout by Exec) is the
  # error text; trim and cap it so the model reads a sentence, not a dump.
  defp failure(output, path) do
    detail =
      output
      |> to_string()
      |> String.trim()
      |> String.slice(0, 500)

    if detail == "", do: "operation failed: #{path}", else: detail
  end
end
