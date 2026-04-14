defmodule Javex.RuntimeError do
  @moduledoc """
  Raised when a Javex module fails at execution time.

  The `:kind` field distinguishes the failure mode:

    * `:timeout` - wall-clock timeout elapsed.
    * `:fuel_exhausted` - wasmtime fuel budget exhausted.
    * `:oom` - memory cap exceeded.
    * `:js_error` - an uncaught JavaScript exception.
    * `:trap` - a Wasm trap that was not a JS error (e.g. unreachable).
    * `:unknown` - anything else, with the raw reason stringified.
  """

  @type kind :: :timeout | :fuel_exhausted | :oom | :js_error | :trap | :unknown

  @type t :: %__MODULE__{kind: kind(), message: String.t()}

  defexception [:kind, :message]

  @impl true
  def message(%__MODULE__{kind: kind, message: msg}),
    do: "Javex runtime error (#{kind}): #{msg}"
end
