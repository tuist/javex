defmodule Javex.IncompatibleProviderError do
  @moduledoc """
  Returned when a dynamically linked `Javex.Module` is run on a runtime
  whose Javy provider plugin does not match the one the module was
  compiled against.

  Recompile the module against the current runtime's plugin, or start a
  runtime that hosts the matching plugin via `Javex.Runtime.start_link/1`
  with `:plugin_path`.
  """

  @type t :: %__MODULE__{expected: binary(), got: binary() | nil}

  defexception [:expected, :got]

  @impl true
  def message(%__MODULE__{expected: expected, got: got}) do
    "module was compiled against provider #{hex(got)} but runtime hosts #{hex(expected)}"
  end

  defp hex(nil), do: "<none>"
  defp hex(bin), do: Base.encode16(bin, case: :lower) |> String.slice(0, 12)
end
