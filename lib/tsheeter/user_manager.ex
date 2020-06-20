defmodule Tsheeter.UserManager do
  alias Tsheeter.Token
  alias OAuth2.Client
  use GenServer
  require Logger

  defmodule State do
    defstruct [
      :id,            # this session's identifier to the outside world
      :tsheets_uid,   # tsheets user ID
      :state_token,   # random string used to verify sender during OAuth2 callback
      :client         # oauth2 client
    ]
  end

  @timezone "US/Eastern"

  ### Client API

  def create(%Token{slack_uid: slack_uid} = token) do
    create(slack_uid, token)
  end

  def create(id, token \\ nil) do
    case Horde.DynamicSupervisor.start_child(Tsheeter.UserSupervisor, {__MODULE__, %{id: id, token: token}}) do
      {:ok, _} = response -> response
      {:error, {{:badmatch, {:error, {:already_started, pid}}}, _}} ->
        {:ok, pid}
      x -> x
    end
  end

  def start_link(%{id: id, token: token}) do
    client =
      Client.new(Application.fetch_env!(:tsheeter, :oauth))
      |> Client.put_serializer("application/json", Jason)

    state = %State{
      id: id,
      state_token: random_string(16),
      client: client
    }
    |> apply_token(token)

    {:ok, _pid} = GenServer.start_link(__MODULE__, state, name: via_registry(id))
  end

  def init(%State{} = state) do
    {:ok, state}
  end

  def client(id) do
    GenServer.call(via_registry(id), {:get_client})
  end

  def authorize_url(id) do
    GenServer.call(via_registry(id), {:authorize_url})
  end

  def todays_timesheet(id) do
    GenServer.call(via_registry(id), {:todays_timesheet})
  end

  def encode_oauth_state(id, state_token), do: Base.encode64("#{id}:#{state_token}")

  def decode_oauth_state!(state) do
    [id, state_token] =
      state
      |> Base.decode64!
      |> String.split(":")
    {id, state_token}
  end

  def got_auth_code(code, oauth_state) do
    {id, state_token} = decode_oauth_state!(oauth_state)
    GenServer.cast(via_registry(id), {:got_auth_code, code, state_token})
    id
  end

  def refresh_token(id) do
    GenServer.cast(via_registry(id), :refresh_token)
  end

  def forget_token(id) do
    GenServer.cast(via_registry(id), :forget_token)
  end

  ### Private functions

  defp process_id(%State{id: id}), do: process_id(id)
  defp process_id(id), do: :"user_#{id}"

  defp via_registry(id) do
    {:via, Horde.Registry, {Tsheeter.Registry, process_id(id)}}
  end

  defp random_string(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64
    |> binary_part(0, length)
  end

  defp apply_token(%State{} = state, nil), do: state

  defp apply_token(%State{client: client} = state, %Token{access_token: access_token, refresh_token: refresh_token, expires_at: expires_at, tsheets_uid: tsheets_uid}) do
    token =
      OAuth2.AccessToken.new(access_token)
      |> Map.put(:refresh_token, refresh_token)
      |> Map.put(:expires_at, DateTime.to_unix(expires_at))
      |> Map.put(:token_type, "Bearer")

    %{state | client: %{client | token: token}, tsheets_uid: tsheets_uid}
  end

  ### Server callbacks

  def handle_call({:get_client}, _from, state) do
    {:reply, state.client, state}
  end

  def handle_call({:authorize_url}, _from, %State{id: id, client: client, state_token: state_token} = state) do
    oauth_state = Base.encode64("#{id}:#{state_token}")
    url = Client.authorize_url!(client, state: oauth_state)
    {:reply, url, state}
  end

  def handle_call({:todays_timesheet}, _from, %{client: client, tsheets_uid: tsheets_uid} = state) do
    today =
      DateTime.utc_now()
      |> DateTime.shift_zone!(@timezone)
      |> DateTime.to_date

    params = [page: 1, user_ids: tsheets_uid, start_date: today, end_date: today]
    response = Client.get!(client, "/api/v1/timesheets", [], params: params)
    result = get_in(response.body, ["results", "timesheets"])
    {:reply, result, state}
  end

  def handle_cast({:got_auth_code, code, state_token}, %State{id: id, state_token: state_token, client: client} = state) do
    case Client.get_token(client, code: code, client_secret: client.client_secret) do
      {:ok, client} ->
        token = Token.store_from_oauth!(id, client.token)
        {:noreply, %{state | client: client, tsheets_uid: token.tsheets_uid}}
      {:error, result} ->
        Token.error!(id, :getting, result)
        {:noreply, state}
    end
  end

  def handle_cast(:refresh_token, %State{id: id, client: client} = state) do
    Logger.info "Refreshing token for #{id}"

    result =
      Client.refresh_token(client,
        [client_id: client.client_id, client_secret: client.client_secret],
        [{"Authorization", "Bearer " <> client.token.access_token}])

    case result do
      {:ok, client} ->
        token = Token.store_from_oauth!(id, client.token)
        {:noreply, %{state | client: %{state.client | token: client.token}, tsheets_uid: token.tsheets_uid}}
      {:error, result} ->
        Token.error!(id, :refreshing, result)
        {:noreply, state}
    end
  end

  def handle_cast(:forget_token, %State{id: id} = state) do
    token = Token.get_by_slack_id(id)
    if token, do: Token.delete!(token)

    {:noreply, %{state | client: %{state.client | token: nil}}}
  end
end