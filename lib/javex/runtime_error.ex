defmodule Javex.RuntimeError do
  @moduledoc """
  Returned when a Javex call is rejected or fails at execution time.

  The `:kind` field distinguishes the failure mode:

    * `:timeout` - wall-clock timeout elapsed.
    * `:fuel_exhausted` - wasmtime fuel budget exhausted.
    * `:oom` - memory cap exceeded.
    * `:js_error` - an uncaught JavaScript exception.
    * `:trap` - a Wasm trap that was not a JS error (e.g. unreachable).
    * `:input_limit`, `:output_limit`, `:diagnostic_limit`, `:module_limit` -
      a host-side byte quota was exceeded.
    * `:invalid_options` - malformed options or module metadata.
    * `:busy` - the runtime's bounded worker capacity is occupied.
    * `:cancelled` - the execution was cancelled.
    * `:runtime_down` - the runtime is unavailable or stopped during the call.
    * `:worker_error` - the isolated OS worker crashed or could not enforce its policy.
    * `:unknown` - anything else, with the raw reason stringified.
  """

  @type kind ::
          :timeout
          | :fuel_exhausted
          | :oom
          | :js_error
          | :trap
          | :unknown
          | :input_limit
          | :output_limit
          | :diagnostic_limit
          | :module_limit
          | :invalid_options
          | :busy
          | :cancelled
          | :runtime_down
          | :worker_error

  @type t :: %__MODULE__{kind: kind(), message: String.t()}

  defexception [:kind, :message]

  @impl true
  def message(%__MODULE__{kind: kind, message: msg}), do: "Javex runtime error (#{kind}): #{msg}"
end
