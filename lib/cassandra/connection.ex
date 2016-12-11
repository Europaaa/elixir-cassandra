defmodule Cassandra.Connection do
  @moduledoc """
  A Connection is a process to handle single connection to a one Cassandra host
  to send requests and parse responses.
  """

  use Connection

  require Logger

  alias :gen_tcp, as: TCP
  alias CQL.{Frame, Startup, Ready, Event, Error}
  alias CQL.Result.{Rows, Void, Prepared, SetKeyspace}
  alias Cassandra.{Session, Reconnection, Host}

  @default_options [
    host: "127.0.0.1",
    port: 9042,
    connect_timeout: 5000,
    timeout: :infinity,
    reconnection_policy: Reconnection.Exponential,
    reconnection_args: [],
    session: nil,
    event_manager: nil,
    async_init: true,
    keyspace: nil,
  ]

  @call_timeout 5000

  # Client API

  @doc """
  Starts a Connection process without links (outside of a supervision tree).

  See start_link/2 for more information.
  """
  def start(options \\ [], gen_server_options \\ []) do
    Connection.start(__MODULE__, options, gen_server_options)
  end

  @doc """
  Starts a Connection process linked to the current process.

  ## Options

  * `:host` - Cassandra host to connecto to (default: `"127.0.0.1"`)
  * `:port` - Cassandra native protocol port (default: `9042`)
  * `:async_init` - when false call to `start_link/2` will block until connection establishment (default: `true`)
  * `:connection_timeout` - connection timeout in milliseconds (defult: `5000`)
  * `:timeout` - request execution timeout in milliseconds (default: `:infinity`)
  * `:keyspace` - name of keyspace to bind connection to
  * `:reconnection_policy` - module which implements Cassandra.Reconnection.Policy (defult: `Exponential`)
  * `:reconnection_args` - list of arguments to pass to `:reconnection_policy` on init (defult: `[]`)
  * `:event_manager` - pid of GenServer process for handling events
  * `:session` - pid of Cassandra.Session process to add this connection to

  For `gen_server_options` values see `GenServer.start_link/3`.

  ## Return values

  If `:async_init` options is set it returns `{:ok, pid}`, otherwise `:async_init` is `false`
  it returns `{:ok, pid}` after opening connection sending handshake and seting keyspace, and on error
  it returns `{:error, reason}` where reason is one of `:connection_failed`, `:handshake_error` or `:keyspace_error`.
  """
  def start_link(options \\ [], gen_server_options \\ []) do
    Connection.start_link(__MODULE__, options, gen_server_options)
  end

  @doc """
  Sends the `request` synchronously on `connection` and waits for it's response.

  For `timeout` values see `GenServer.call/3`.

  ## Return values

  `{:ok, :done}` when cassandra response is VOID in response to some queries

  `{:ok, :ready}` when cassandra response is READY in response to `Register` requests

  `{:ok, data}` where data is one of the following structs:

    * `CQL.Supported`
    * `CQL.Result.SetKeyspace`
    * `CQL.Result.SchemaChange`
    * `CQL.Result.Prepared`
    * `CQL.Result.Rows`

  `{:error, {code, message}}` when cassandra response is an error

  `{:error, :closed}` when connection closed

  `{:error, :not_connected}` when connection not established yet (for queuing requests use `Session`)

  `{:error, :invalid}` when `request` is not a valid cql request frame binary

  `{:error, reason}` otherwise
  """
  def send(connection, request, timeout \\ @call_timeout) do
    Connection.call(connection, {:send_request, request}, timeout)
  end

  @doc """
  Sends the `request` asynchronously on `connection`.

  It returns a `ref` reference and when response is ready it will be sent to calling process as `{ref, result}` tuple.

  See `send/3` for `result` types.
  """
  def send_async(connection, request) do
    send_async(connection, request, {self, make_ref})
  end

  @doc false
  def send_async(connection, request, _from = {pid, ref}) do
    Connection.cast(connection, {:send_request, request, {pid, ref}})
    ref
  end

  @doc """
  Stops the connection server with the given `reason`.
  """
  def stop(connection, reason \\ :normal, timeout \\ :infinity) do
    GenServer.stop(connection, reason, timeout)
  end

  # Connection Callbacks

  @doc false
  def init(options) do
    options = Keyword.merge(@default_options, options)


    {:ok, reconnection} =
      options
      |> Keyword.take([:reconnection_policy, :reconnection_args])
      |> Reconnection.start_link

    host = case options[:host] do
      %Host{ip: ip} -> ip
      address when is_bitstring(address) -> to_charlist(address)
      inet -> inet
    end

    host_id = case options[:host] do
      %Host{id: id} -> id
      _ -> nil
    end

    state =
      options
      |> Keyword.take([:port, :connect_timeout, :timeout, :session, :event_manager, :keyspace])
      |> Enum.into(%{
        host: host,
        host_id: host_id,
        streams: %{},
        last_stream_id: 1,
        socket: nil,
        buffer: "",
        reconnection: reconnection,
      })

    if options[:async_init] == true do
      {:connect, :init, state}
    else
      with {:ok, socket} <- startup(state) do
        after_connect(socket, state)
      else
        {:stop, reason} ->
          {:stop, reason}
        _ ->
          {:stop, :connection_failed}
      end
    end
  end

  @doc false
  def connect(_info, state) do
    with {:ok, socket} <- startup(state) do
      after_connect(socket, state)
    else
      {:stop, reason} ->
        {:stop, {:shutdown, reason}, state}
      _ ->
        case Reconnection.next(state.reconnection) do
          :stop ->
            Logger.error("#{__MODULE__} connection failed after max attempts")
            {:stop, {:shutdown, :max_attempts}, state}
          backoff ->
            Logger.warn("#{__MODULE__} connection failed, retrying in #{backoff}ms ...")
            {:backoff, backoff, state}
        end
    end
  end

  @doc false
  def disconnect(info, %{socket: socket} = state) do
    :ok = TCP.close(socket)

    case info do
      {:error, :closed} ->
        Logger.error("#{__MODULE__} connection closed")
      {:error, reason} ->
        message = :inet.format_error(reason)
        Logger.error("#{__MODULE__} connection error #{message}")
      :timeout ->
        Logger.error("#{__MODULE__} connection timeout")
    end

    notify(state, :connection_closed)
    reply_all(state, {:error, :closed})

    next_state = %{
      state |
      streams: %{},
      last_stream_id: 1,
      socket: nil,
    }

    {:connect, :reconnect, next_state}
  end

  @doc false
  def terminate(reason, state) do
    reply_all(state, {:error, :closed})
    notify(state, :connection_stopped)
    reason
  end

  @doc false
  def handle_cast({:send_request, request, from}, state) do
    case send_request(request, from, state) do
      {:ok, state} ->
        {:noreply, state}
      {:error, reason} ->
        {:disconnect, {:error, reason}}
    end
  end

  @doc false
  def handle_call({:send_request, _}, _, %{socket: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  @doc false
  def handle_call({:send_request, request}, from, state) do
    case send_request(request, from, state) do
      {:ok, state} ->
        {:noreply, state}
      {:error, reason} ->
        {:disconnect, {:error, reason}}
    end
  end

  @doc false
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    handle_data(data, state)
  end

  @doc false
  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    {:disconnect, {:error, reason}, state}
  end

  @doc false
  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    {:disconnect, {:error, :closed}, state}
  end

  @doc false
  def handle_info(:timeout, state) do
    {:disconnect, :timeout, state}
  end

  # Helpers

  defp handle_data(data, %{buffer: buffer} = state) do
    case CQL.decode(buffer <> data) do
      {%Frame{stream: id, warnings: warnings} = frame, rest} ->
        Enum.each(warnings, &Logger.warn/1)
        result = case id do
          -1 -> handle_event(frame, state)
           0 -> {:ok, state}
           _ -> handle_response(frame, state)
        end
        case result do
          {:ok, next_state} ->
            handle_data(rest, %{next_state | buffer: ""})
          {:error, reason} ->
            {:disconnect, {:error, reason}, %{state | buffer: ""}}
        end
      {nil, buffer} ->
        {:noreply, %{state | buffer: buffer}}
    end
  end

  defp handle_event(%Frame{body: %Event{} = event}, %{event_manager: nil} = state) do
    Logger.warn("#{__MODULE__} unhandled CQL event (missing event_manager) #{inspect event}")
    {:ok, state}
  end

  defp handle_event(%Frame{body: %Event{} = event}, %{event_manager: pid} = state) do
    Logger.debug("#{__MODULE__} got event #{inspect event}")
    GenServer.cast(pid, {:notify, event})
    {:ok, state}
  end

  defp handle_response(%Frame{stream: id, body: {%Rows{} = data, nil}}, state) do
    with {{_, from}, next_state} <- pop_in(state.streams[id]) do
      case from do
        {:gen_event, manager} ->
          Enum.map(data.rows, &GenEvent.ack_notify(manager, &1))
          GenEvent.stop(manager)

        from ->
          Connection.reply(from, {:ok, data})
      end
      {:ok, next_state}
    else
      _ -> {:error, {:invalid, :stream}}
    end
  end

  defp handle_response(%Frame{stream: id, body: {%Rows{rows: rows} = data, paging}}, state) do
    with {{request, from}, next_state} <- pop_in(state.streams[id]) do
      manager = case from do
        {:gen_event, manager} ->
          manager

        from ->
          {:ok, manager} = GenEvent.start_link
          stream = GenEvent.stream(manager)
          Connection.reply(from, {:ok, %{data | rows: stream, rows_count: nil}})
          manager
      end

      Enum.map(rows, &GenEvent.ack_notify(manager, &1))

      next_request = %{request | params: %{request.params | paging_state: paging}}

      send_request(next_request, {:gen_event, manager}, next_state)
    else
      _ -> {:error, {:invalid, :stream}}
    end
  end

  defp handle_response(%Frame{stream: 1, body: body}, state) do
    case body do
      %Error{} = error ->
        log_error(error)
      response ->
        Logger.info("#{__MODULE__} #{inspect response}")
    end
    {:ok, state}
  end

  defp handle_response(%Frame{stream: id, body: body}, state) do
    {{request, from}, next_state} = pop_in(state.streams[id])
    response = case body do
      %Error{message: message, code: code} ->
        {:error, {code, message}}

      %Ready{} ->
        {:ok, :ready}

      %Void{} ->
        {:ok, :done}

      %Prepared{} = prepared ->
        notify(state, {:prepared, hash(request), prepared})
        {:ok, prepared}

      response ->
        {:ok, response}
    end
    Connection.reply(from, response)
    {:ok, next_state}
  end

  defp send_request(_, from, %{socket: nil} = state) do
    Connection.reply(from, {:error, :not_connected})
    {:ok, state}
  end

  defp send_request(request, from, %{socket: socket, last_stream_id: id} = state) do
    id = next_stream_id(id)
    case send_to(socket, request, id) do
      :ok ->
        next_state =
          state
          |> Map.put(:last_stream_id, id)
          |> put_in([:streams, id], {request, from})

        {:ok, next_state}

      {:error, :invalid} ->
        Logger.error("#{__MODULE__} invalid request #{inspect request}")
        Connection.reply(from, {:error, :invalid})
        {:ok, state}

      {:error, :timeout} ->
        Logger.error("#{__MODULE__} TCP send timeout")
        Connection.reply(from, {:error, :timeout})
        {:error, :timeout}

      {:error, reason} ->
        message = :inet.format_error(reason)
        Logger.error("#{__MODULE__} TCP error #{message}")
        Connection.reply(from, {:error, message})
        {:error, reason}
    end
  end

  defp reply_all(%{streams: streams}, message) do
    streams
    |> Map.values
    |> Enum.each(fn {_, from} -> Connection.reply(from, message) end)
  end

  defp startup(%{host: host, port: port, connect_timeout: connect_timeout, timeout: timeout, keyspace: keyspace}) do
    with {:ok, socket} <- TCP.connect(host, port, [:binary, active: false], connect_timeout),
         :ok <- handshake(socket, timeout),
         :ok <- set_keyspace(socket, keyspace, timeout)
    do
      {:ok, socket}
    else
      {:stop, reason, error} ->
        log_error(error)
        {:stop, reason}

      {:error, error} ->
        log_error(error)
        :error
    end
  end

  defp log_error(%Error{code: code, message: message}) do
    Logger.error("#{__MODULE__} [#{code}] #{message}")
  end

  defp log_error(:closed) do
    Logger.error("#{__MODULE__} connection closed")
  end

  defp log_error(reason) do
    message = :inet.format_error(reason)
    Logger.error("#{__MODULE__} connection error: #{message}")
  end

  defp after_connect(socket, state) do
    :inet.setopts(socket, [
      active: true,
      send_timeout: state.timeout,
      send_timeout_close: true,
    ])

    notify(state, :connection_opened)

    Reconnection.reset(state.reconnection)

    {:ok, %{state | socket: socket}}
  end

  defp send_to(socket, request) do
    TCP.send(socket, request)
  end

  defp send_to(socket, request, id) when is_bitstring(request) do
    case CQL.set_stream_id(request, id) do
      {:ok, request_with_id} ->
        send_to(socket, request_with_id)
      :error ->
        {:error, :invalid}
    end
  end

  defp send_to(socket, request, id) do
    case CQL.encode(request, id) do
      :error ->
        {:error, :invalid}
      request_with_id ->
        send_to(socket, request_with_id)
    end
  end

  defp set_keyspace(_socket, nil, _timeout), do: :ok
  defp set_keyspace(socket, keyspace, timeout) do
    with :ok <- send_to(socket, CQL.encode(%CQL.Query{query: "USE #{keyspace}"})),
         {:ok, buffer} <- TCP.recv(socket, 0, timeout),
         {%Frame{body: %SetKeyspace{name: ^keyspace}}, ""} <- CQL.decode(buffer)
    do
      :ok
    else
      {%Frame{body: %Error{} = error}, _} ->
        {:stop, :keyspace_error, error}
      error ->
        {:stop, :keyspace_error, error}
    end
  end

  defp handshake(socket, timeout) do
    with :ok <- send_to(socket, CQL.encode(%Startup{})),
         {:ok, buffer} <- TCP.recv(socket, 0, timeout),
         {%Frame{body: %Ready{}}, ""} <- CQL.decode(buffer)
    do
      :ok
    else
      {%Frame{body: %Error{} = error}, _} ->
        {:stop, :handshake_error, error}
      error ->
        {:error, error}
    end
  end

  defp notify(%{session: nil}, _), do: :ok
  defp notify(%{host_id: nil}, _), do: :ok
  defp notify(%{session: session, host_id: id}, message) do
    Session.notify(session, {message, {id, self}})
  end

  defp next_stream_id(32_000), do: 2
  defp next_stream_id(n), do: n + 1

  defp hash(request) when is_bitstring(request) do
    :crypto.hash(:md5, request)
  end

  defp hash(request) do
    request |> CQL.encode |> hash
  end
end
