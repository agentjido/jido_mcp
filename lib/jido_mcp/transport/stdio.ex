defmodule Jido.MCP.Transport.STDIO do
  @moduledoc false

  @behaviour Anubis.Transport.Behaviour

  use GenServer
  use Anubis.Logging

  import Peri

  alias Anubis.Telemetry
  alias Anubis.Transport.Behaviour, as: Transport
  alias Jido.MCP.Transport.STDIOBuffer

  @type option ::
          {:command, Path.t()}
          | {:args, [String.t()] | nil}
          | {:env, map() | nil}
          | {:cwd, Path.t() | nil}
          | {:client, GenServer.server()}
          | GenServer.option()

  defschema(:options_schema, %{
    name: {{:custom, &Anubis.genserver_name/1}, {:default, __MODULE__}},
    client: {:required, Anubis.get_schema(:process_name)},
    command: {:required, :string},
    args: {{:list, :string}, {:default, nil}},
    env: {:map, {:default, nil}},
    cwd: {:string, {:default, nil}}
  })

  @unix_default_env ["HOME", "LOGNAME", "PATH", "SHELL", "TERM", "USER"]

  @win32_default_env [
    "APPDATA",
    "HOMEDRIVE",
    "HOMEPATH",
    "LOCALAPPDATA",
    "PATH",
    "PROCESSOR_ARCHITECTURE",
    "SYSTEMDRIVE",
    "SYSTEMROOT",
    "TEMP",
    "USERNAME",
    "USERPROFILE"
  ]

  @impl Transport
  @spec start_link(Enumerable.t(option())) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = options_schema!(opts)
    GenServer.start_link(__MODULE__, Map.new(opts), name: opts[:name])
  end

  @impl Transport
  def send_message(pid \\ __MODULE__, message, opts) when is_binary(message) do
    GenServer.call(pid, {:send, message}, Keyword.get(opts, :timeout, 5_000))
  end

  @impl Transport
  def shutdown(pid \\ __MODULE__) do
    GenServer.cast(pid, :close_port)
  end

  @impl Transport
  def supported_protocol_versions, do: :all

  @impl GenServer
  def init(%{} = opts) do
    state = Map.merge(opts, %{port: nil, ref: nil, buffer: ""})

    Telemetry.execute(
      Telemetry.event_transport_init(),
      %{system_time: System.system_time()},
      %{
        transport: :stdio,
        command: opts.command,
        args: opts.args,
        client: opts.client
      }
    )

    {:ok, state, {:continue, :spawn}}
  end

  @impl GenServer
  def handle_continue(:spawn, state) do
    case System.find_executable(state.command) do
      nil ->
        {:stop, {:error, "Command not found: #{state.command}"}, state}

      command ->
        port = spawn_port(command, state)
        ref = Port.monitor(port)

        GenServer.cast(state.client, :initialize)
        {:noreply, %{state | port: port, ref: ref}}
    end
  end

  @impl GenServer
  def handle_call({:send, message}, _from, %{port: port} = state) when is_port(port) do
    Telemetry.execute(
      Telemetry.event_transport_send(),
      %{system_time: System.system_time()},
      %{
        transport: :stdio,
        message_size: byte_size(message),
        command: state.command
      }
    )

    Port.command(port, message)
    {:reply, :ok, state}
  end

  def handle_call({:send, message}, _from, state) do
    Telemetry.execute(
      Telemetry.event_transport_error(),
      %{system_time: System.system_time()},
      %{
        transport: :stdio,
        error: :port_not_connected,
        message_size: byte_size(message)
      }
    )

    {:reply, {:error, :port_not_connected}, state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logging.transport_event("stdio_received", String.slice(data, 0, 100))

    Telemetry.execute(
      Telemetry.event_transport_receive(),
      %{system_time: System.system_time()},
      %{
        transport: :stdio,
        message_size: byte_size(data)
      }
    )

    {messages, buffer} = STDIOBuffer.push(state.buffer, data)
    Enum.each(messages, &GenServer.cast(state.client, {:response, &1}))

    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({port, :closed}, %{port: port} = state) do
    Telemetry.execute(
      Telemetry.event_transport_disconnect(),
      %{system_time: System.system_time()},
      %{transport: :stdio, reason: :normal}
    )

    {:stop, :normal, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logging.transport_event("stdio_exit", %{status: status}, level: :warning)

    Telemetry.execute(
      Telemetry.event_transport_error(),
      %{system_time: System.system_time()},
      %{transport: :stdio, error: :exit_status, status: status}
    )

    {:stop, status, state}
  end

  def handle_info({:DOWN, ref, :port, port, reason}, %{ref: ref, port: port} = state) do
    Logging.transport_event("stdio_down", %{reason: reason}, level: :error)

    Telemetry.execute(
      Telemetry.event_transport_error(),
      %{system_time: System.system_time()},
      %{transport: :stdio, error: :port_down, reason: reason}
    )

    {:stop, reason, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logging.transport_event("stdio_exit", %{reason: reason}, level: :error)

    Telemetry.execute(
      Telemetry.event_transport_error(),
      %{system_time: System.system_time()},
      %{transport: :stdio, error: :port_exit, reason: reason}
    )

    {:stop, reason, state}
  end

  @impl GenServer
  def handle_cast(:close_port, %{port: port} = state) when is_port(port) do
    Telemetry.execute(
      Telemetry.event_transport_disconnect(),
      %{system_time: System.system_time()},
      %{transport: :stdio, reason: :client_closed}
    )

    Port.close(port)
    {:stop, :normal, state}
  end

  def handle_cast(:close_port, state), do: {:stop, :normal, state}

  @impl GenServer
  def terminate(reason, _state) do
    Telemetry.execute(
      Telemetry.event_transport_terminate(),
      %{system_time: System.system_time()},
      %{transport: :stdio, reason: reason}
    )

    :ok
  end

  defp spawn_port(command, state) do
    opts =
      [:binary, :exit_status]
      |> maybe_concat(:args, state.args)
      |> maybe_put_env(state.env)
      |> maybe_concat(:cd, state.cwd)

    Port.open({:spawn_executable, command}, opts)
  end

  defp maybe_concat(opts, _key, nil), do: opts
  defp maybe_concat(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_env(opts, nil), do: opts

  defp maybe_put_env(opts, %{} = env) do
    Keyword.put(opts, :env, env_with_defaults(env) |> normalize_env_for_erlang())
  end

  defp env_with_defaults(%{} = env), do: Map.merge(default_env(), env)

  defp default_env do
    default_keys =
      if :os.type() == {:win32, :nt} do
        @win32_default_env
      else
        @unix_default_env
      end

    System.get_env()
    |> Enum.filter(fn {key, _value} -> key in default_keys end)
    |> Enum.reject(fn {_key, value} -> String.starts_with?(value, "()") end)
    |> Map.new()
  end

  defp normalize_env_for_erlang(env) do
    env
    |> Map.new(fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
    |> Enum.to_list()
  end
end
