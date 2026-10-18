defmodule Javex.Options do
  @moduledoc false

  alias Javex.RuntimeError

  @defaults %{
    timeout: 5_000,
    fuel: 100_000_000,
    max_memory: 64 * 1024 * 1024,
    max_input: 1024 * 1024,
    max_output: 1024 * 1024,
    max_stderr: 64 * 1024,
    max_module: 8 * 1024 * 1024
  }
  @runtime_keys Map.new(@defaults, fn {key, _} ->
                  {String.to_atom("default_#{key}"), key}
                end)

  def runtime(opts) do
    allowed =
      Map.keys(@runtime_keys) ++
        [
          :plugin_path,
          :max_concurrency,
          :max_cache_bytes,
          :max_cached_modules,
          :backend,
          :max_process_memory
        ]

    with :ok <- keywords(opts, allowed),
         defaults =
           Enum.reduce(@runtime_keys, @defaults, fn {option, key}, acc ->
             Map.put(acc, key, Keyword.get(opts, option, Map.fetch!(acc, key)))
           end),
         :ok <- budgets(defaults),
         :ok <-
           member(:backend, Keyword.get(opts, :backend, :in_process), [:in_process, :isolated]),
         :ok <-
           integer(
             :max_process_memory,
             Keyword.get(opts, :max_process_memory, 512 * 1024 * 1024),
             1
           ),
         :ok <- integer(:max_concurrency, Keyword.get(opts, :max_concurrency, 4), 1),
         :ok <-
           integer(:max_cache_bytes, Keyword.get(opts, :max_cache_bytes, 64 * 1024 * 1024), 0),
         :ok <- integer(:max_cached_modules, Keyword.get(opts, :max_cached_modules, 64), 0) do
      {:ok, defaults}
    end
  end

  def run(opts, defaults) do
    with :ok <- keywords(opts, Map.keys(@defaults) ++ [:runtime, :encoding, :env]),
         limits = Map.merge(defaults, Map.new(Keyword.take(opts, Map.keys(@defaults)))),
         :ok <- budgets(limits),
         encoding = Keyword.get(opts, :encoding, :json),
         :ok <- member(:encoding, encoding, [:json, :raw]),
         env = Keyword.get(opts, :env, []),
         :ok <- environment(env) do
      {:ok, Map.merge(limits, %{encoding: encoding, env: env})}
    end
  end

  def compile(opts) do
    allowed = [
      :mode,
      :plugin,
      :runtime,
      :timeout,
      :fuel,
      :max_memory,
      :max_source,
      :max_module,
      :max_stderr
    ]

    with :ok <- keywords(opts, allowed),
         :ok <- member(:mode, Keyword.get(opts, :mode, :dynamic), [:dynamic, :static]),
         {:ok, limits} <- run(Keyword.take(opts, Map.keys(@defaults)), @defaults),
         max_source = Keyword.get(opts, :max_source, @defaults.max_input),
         :ok <- integer(:max_source, max_source, 1) do
      {:ok, %{limits | max_input: max_source}}
    end
  end

  def native(limits, mode) do
    limits |> Map.drop([:timeout, :encoding]) |> Map.put(:static_mode, mode == :static)
  end

  defp keywords(opts, allowed) do
    if Keyword.keyword?(opts) && Enum.all?(Keyword.keys(opts), &(&1 in allowed)) &&
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      :ok
    else
      invalid(
        "options must be a keyword list containing only unique keys from #{inspect(allowed)}"
      )
    end
  end

  defp budgets(limits) do
    Enum.reduce_while(limits, :ok, fn {key, value}, :ok ->
      minimum = if key in [:fuel, :max_output, :max_stderr], do: 0, else: 1

      case integer(key, value, minimum) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp integer(key, value, minimum) do
    maximum =
      case key do
        :timeout -> 2_147_483_647
        :max_process_memory -> 9_223_372_036_854_775_807
        _ -> 18_446_744_073_709_551_615
      end

    if is_integer(value) && value >= minimum && value <= maximum do
      :ok
    else
      invalid("#{key} must be an integer between #{minimum} and #{maximum}")
    end
  end

  defp member(key, value, values) do
    if value in values, do: :ok, else: invalid("invalid #{key}: #{inspect(value)}")
  end

  defp environment(env) do
    valid? =
      is_list(env) && length(env) <= 128 &&
        Enum.all?(env, &environment_pair?/1)

    if valid? &&
         Enum.sum(Enum.map(env, fn {key, value} -> byte_size(key) + byte_size(value) end)) <=
           65_536 do
      :ok
    else
      invalid("env must contain at most 128 valid string pairs totaling at most 64 KiB")
    end
  end

  defp environment_pair?({key, value}) when is_binary(key) and is_binary(value) do
    String.valid?(key) && String.valid?(value) && key != "" &&
      not String.contains?(key, ["=", <<0>>]) && not String.contains?(value, <<0>>)
  end

  defp environment_pair?(_pair), do: false

  defp invalid(message), do: {:error, %RuntimeError{kind: :invalid_options, message: message}}
end
