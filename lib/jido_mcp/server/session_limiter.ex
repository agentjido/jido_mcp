defmodule Jido.MCP.Server.SessionLimiter do
  @moduledoc false

  use GenServer

  @type identity :: {String.t() | nil, String.t() | nil}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def reserve(
        server,
        identity,
        session_family_id,
        max_sessions,
        idle_ttl_ms,
        reservation_ttl_ms
      ) do
    GenServer.call(
      __MODULE__,
      {:reserve, server, identity, session_family_id, max_sessions, idle_ttl_ms,
       reservation_ttl_ms}
    )
  end

  def bind(token, session_id), do: GenServer.call(__MODULE__, {:bind, token, session_id})
  def release(token), do: GenServer.call(__MODULE__, {:release, token})

  def touch(server, session_id, identity),
    do: GenServer.call(__MODULE__, {:touch, server, session_id, identity})

  def remove(server, session_id, identity),
    do: GenServer.call(__MODULE__, {:remove, server, session_id, identity})

  def session(server, session_id), do: GenServer.call(__MODULE__, {:session, server, session_id})

  def sessions(server, identity), do: GenServer.call(__MODULE__, {:sessions, server, identity})

  @impl true
  def init(_state),
    do:
      {:ok,
       %{sessions: %{}, reservations: %{}, clock_offset_ms: 0, timer_ref: nil, timer_token: nil}}

  @impl true
  def handle_call(
        {:reserve, server, identity, session_family_id, max_sessions, idle_ttl_ms,
         reservation_ttl_ms},
        _from,
        state
      ) do
    now = now_ms(state)
    {state, expired} = expire(state, now)
    terminate_sessions(expired)
    active = count_for_identity(state, server, identity)

    if is_nil(max_sessions) or active < max_sessions do
      token = make_ref()

      reservation = %{
        server: server,
        identity: identity,
        session_family_id: session_family_id,
        inserted_at: now,
        idle_ttl_ms: idle_ttl_ms,
        reservation_ttl_ms: reservation_ttl_ms
      }

      state = put_in(state.reservations[token], reservation)
      {:reply, {:ok, token, expired}, schedule_expiry(state)}
    else
      {:reply, {:error, :session_limit_exceeded, expired}, schedule_expiry(state)}
    end
  end

  def handle_call({:bind, token, session_id}, _from, state) do
    case pop_in(state.reservations[token]) do
      {nil, state} ->
        {:reply, :error, schedule_expiry(state)}

      {reservation, state} ->
        session = Map.put(reservation, :last_seen_at, now_ms(state))
        {:reply, :ok, state |> put_in([:sessions, session_id], session) |> schedule_expiry()}
    end
  end

  def handle_call({:release, token}, _from, state) do
    {:reply, :ok,
     state |> update_in([:reservations], &Map.delete(&1, token)) |> schedule_expiry()}
  end

  def handle_call({:touch, server, session_id, identity}, _from, state) do
    now = now_ms(state)
    {state, expired} = expire(state, now)
    terminate_sessions(expired)

    case Map.fetch(state.sessions, session_id) do
      {:ok, %{server: ^server, identity: ^identity} = session} ->
        state = put_in(state.sessions[session_id], %{session | last_seen_at: now})
        {:reply, {:ok, expired}, schedule_expiry(state)}

      _ ->
        {:reply, {:error, expired}, schedule_expiry(state)}
    end
  end

  def handle_call({:remove, server, session_id, identity}, _from, state) do
    state =
      case Map.get(state.sessions, session_id) do
        %{server: ^server, identity: ^identity} ->
          update_in(state.sessions, &Map.delete(&1, session_id))

        _ ->
          state
      end

    {:reply, :ok, schedule_expiry(state)}
  end

  def handle_call({:session, server, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      %{server: ^server} = session -> {:reply, {:ok, session}, state}
      _ -> {:reply, :error, state}
    end
  end

  def handle_call({:sessions, server, identity}, _from, state) do
    sessions =
      for {session_id, %{server: ^server, identity: ^identity} = session} <- state.sessions,
          do: {session_id, session}

    {:reply, sessions, state}
  end

  @impl true
  def handle_info({:expire, token}, %{timer_token: token} = state) do
    {state, expired} = expire(state, now_ms(state))
    terminate_sessions(expired)
    {:noreply, schedule_expiry(state)}
  end

  def handle_info({:expire, _stale_token}, state), do: {:noreply, state}

  defp expire(state, now) do
    {state, expired} =
      Enum.reduce(state.sessions, {state, []}, fn {session_id, session}, {acc, expired} ->
        if expired?(session.last_seen_at, session.idle_ttl_ms, now) do
          {update_in(acc.sessions, &Map.delete(&1, session_id)), [session_id | expired]}
        else
          {acc, expired}
        end
      end)

    state =
      update_in(state.reservations, fn reservations ->
        Map.reject(reservations, fn {_token, reservation} ->
          expired?(reservation.inserted_at, reservation.reservation_ttl_ms, now)
        end)
      end)

    {state, expired}
  end

  defp expired?(_timestamp, nil, _now), do: false
  defp expired?(timestamp, ttl_ms, now), do: timestamp + ttl_ms <= now

  defp schedule_expiry(state) do
    cancel_timer(state.timer_ref)

    case next_expiry(state) do
      nil ->
        %{state | timer_ref: nil, timer_token: nil}

      deadline ->
        token = make_ref()
        delay = max(deadline - now_ms(state), 0)
        timer_ref = Process.send_after(self(), {:expire, token}, delay)
        %{state | timer_ref: timer_ref, timer_token: token}
    end
  end

  defp next_expiry(state) do
    session_expiries =
      for {_session_id, session} <- state.sessions,
          is_integer(session.idle_ttl_ms),
          do: session.last_seen_at + session.idle_ttl_ms

    reservation_expiries =
      for {_token, reservation} <- state.reservations,
          do: reservation.inserted_at + reservation.reservation_ttl_ms

    case session_expiries ++ reservation_expiries do
      [] -> nil
      expiries -> Enum.min(expiries)
    end
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    _ = Process.cancel_timer(timer_ref, async: true, info: false)
    :ok
  end

  defp terminate_sessions(session_ids) do
    Enum.each(session_ids, fn session_id ->
      try do
        ExMCP.SessionManager.terminate_session(session_id)
      rescue
        _exception -> :ok
      catch
        _kind, _reason -> :ok
      end
    end)
  end

  defp count_for_identity(state, server, identity) do
    reservations =
      Enum.count(state.reservations, fn {_token, entry} ->
        entry.server == server and entry.identity == identity
      end)

    sessions =
      Enum.count(state.sessions, fn {_session_id, entry} ->
        entry.server == server and entry.identity == identity
      end)

    reservations + sessions
  end

  defp now_ms(state), do: System.monotonic_time(:millisecond) + state.clock_offset_ms
end
