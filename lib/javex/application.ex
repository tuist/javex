defmodule Javex.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:javex, :start_default_runtime, true) do
        [{Javex.Runtime, name: Javex.Runtime}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Javex.Supervisor)
  end
end
