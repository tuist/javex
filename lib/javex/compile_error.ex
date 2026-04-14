defmodule Javex.CompileError do
  @moduledoc """
  Raised when Javy fails to compile a JavaScript source to Wasm.
  """

  @type t :: %__MODULE__{message: String.t()}

  defexception [:message]

  @impl true
  def message(%__MODULE__{message: msg}), do: "Javex compile error: #{msg}"
end
