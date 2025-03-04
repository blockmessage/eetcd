-module(eetcd_http2_keeper).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([get_http2_client_pid/0]).
-export([check_leader/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("eetcd.hrl").
-record(state, {pid, ref, cluster = [], index = 0, transport = tcp, transport_opts = []}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_http2_client_pid() -> pid() | undefined.
get_http2_client_pid() ->
    erlang:whereis(?ETCD_HTTP2_CLIENT).

-spec check_leader() -> ok.
check_leader() ->
    gen_server:cast(?MODULE, check_leader).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    Transport = application:get_env(eetcd, http2_transport, tcp),
    TransportOpts = application:get_env(eetcd, http2_transport_opts, []),
    Hosts = application:get_env(eetcd, etcd_cluster, ["127.0.0.1:2379"]),
    Cluster =
        [begin
             [IP, Port] = string:tokens(Host, ":"),
             {IP, list_to_integer(Port)}
         end|| Host <- Hosts],
    case connect(Cluster, Transport, TransportOpts) of
        {ok, Pid, N} ->
            Ref = erlang:monitor(process, Pid),
            {ok, #state{
                pid = Pid,
                cluster = Cluster,
                index = N,
                ref = Ref,
                transport = Transport,
                transport_opts = TransportOpts}
            };
        {error, Reason} -> {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(check_leader, State) ->
    case check_leader(State) of
        ignore -> {noreply, State};
        {ok, NewState} -> {noreply, NewState}
    end;
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, Pid, Reason}, State = #state{pid = Pid, ref = Ref}) ->
    error_logger:warning_msg("~p gun(~p) process stop ~p~n", [?MODULE, Pid, Reason]),
    case reconnect(16, "") of
        {ok, NewState} -> {noreply, NewState};
        {error, Reason} -> {stop, Reason, State}
    end;
handle_info({'DOWN', _Ref, process, _OldPid, _Reason}, State) ->
    {noreply, State};

handle_info({gun_down, Pid, http2, {error, Reason}, KilledStreams, UnprocessedStreams},
    State = #state{pid = Pid}) ->
    error_logger:warning_msg(
        "~p connection down on ~p: ~p (Killed: ~p, Unprocessed: ~p)",
        [?MODULE, Pid, Reason, KilledStreams, UnprocessedStreams]),
    {noreply, State};
handle_info({gun_down, Pid, http2, normal, _KilledStreams, _UnprocessedStreams},
    State = #state{pid = Pid}) ->
    {noreply, State};
handle_info({gun_down, Pid, http2, closed, KilledStreams, UnprocessedStreams},
    State = #state{pid = Pid}) ->
    error_logger:warning_msg(
        "~p connection down on ~p: ~p (Killed: ~p, Unprocessed: ~p)",
        [?MODULE, Pid, closed, KilledStreams, UnprocessedStreams]),
    {noreply, State};

handle_info({gun_up, Pid, http2}, State = #state{pid = Pid}) ->
    {noreply, State};

handle_info(Info, State) ->
    error_logger:warning_msg("~p Handle info unknown message ~p~n", [?MODULE, Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

connect(Cluster, Transport, TransportOpts) ->
    connect(Cluster, Transport, TransportOpts, 1, []).

connect(Cluster, Transport, TransportOpts, N, Errors) when N =< length(Cluster) ->
    {IP, Port} = lists:nth(N, Cluster),
    {ok, Pid} = gun:open(IP, Port,
        #{
            protocols => [http2],
            http2_opts => #{keepalive => 45000},
            retry => 4,
            retry_timeout => 2500,
            transport => Transport,
            transport_opts => TransportOpts
        }),
    case gun:await_up(Pid, 1000) of
        {ok, http2} ->
            case register_name(?ETCD_HTTP2_CLIENT, Pid) of
                true -> {ok, Pid, N};
                {false, NewPid} -> {error, {already_started, NewPid}}
            end;
        %The only apparent timeout for gun:open is the connection timeout of the
        %underlying transport. So, a timeout message here comes from gun:await_up.
        {error, timeout} ->
            NewErrors = [{IP, Port, timeout} | Errors],
            connect(Cluster, Transport, TransportOpts, N + 1, NewErrors);
        %gun currently terminates with reason normal if gun:open fails to open
        %the requested connection. This bubbles up through gun:await_up.
        {error, normal} ->
            NewErrors = [{IP, Port, open_failed} | Errors],
            connect(Cluster, Transport, TransportOpts, N + 1, NewErrors)
    end;
connect(_Cluster, _Transport, _TransportOpts, _N, Errors) ->
    {error, Errors}.

reconnect(0, Errors) -> {error, Errors};
reconnect(N, _Errors) ->
    wait_http2_client_app_up(),
    case init([]) of
        {ok, State} -> {ok, State};
        {stop, Reason} -> reconnect(N - 1, Reason)
    end.

register_name(Name, Pid) when is_atom(Name) ->
    try register(Name, Pid) of
        true -> true
    catch
        error:_ ->
            {false, whereis(Name)}
    end.

wait_http2_client_app_up() ->
    case whereis(gun_sup) of
        undefined ->
            timer:sleep(240),
            wait_http2_client_app_up();
        _ -> ok
    end.

check_leader(State) ->
    case eetcd_maintenance:status(#'Etcd.StatusRequest'{}) of
        #'Etcd.StatusResponse'{leader = Leader} when Leader > 0 ->
            error_logger:warning_msg("Leader(~p) already exist but request timeout~n", [?MODULE, Leader]),
            ignore;
        _ -> choose_ready_for_client(State, 1)
    end.

choose_ready_for_client(#state{cluster = Cluster}, N) when length(Cluster) > N -> ignore;
choose_ready_for_client(State, N) ->
    #state{cluster = Cluster, index = Index, transport = Transport, transport_opts = TransportOpts} = State,
    case Index =/= N of
        true ->
            {IP, Port} = lists:nth(N, Cluster),
            {ok, Pid} = gun:open(IP, Port,
                #{
                    protocols => [http2],
                    http2_opts => #{keepalive => 45000},
                    retry => 4,
                    retry_timeout => 2500,
                    transport => Transport,
                    transport_opts => TransportOpts
                }),
            case gun:await_up(Pid, 1000) of
                {ok, http2} ->
                    Request = #'Etcd.StatusRequest'{},
                    Path = <<"/etcdserverpb.Maintenance/Status">>,
                    case eetcd_stream:unary(Request, Path, 'Etcd.StatusResponse') of
                        #'Etcd.StatusResponse'{leader = Leader} when Leader > 0 ->
                            OldPid = erlang:whereis(?ETCD_HTTP2_CLIENT),
                            true = register(?ETCD_HTTP2_CLIENT, Pid),
                            gun:close(OldPid),
                            {ok, State#state{
                                pid = Pid,
                                cluster = Cluster,
                                index = N,
                                ref = erlang:monitor(process, Pid)
                            }};
                        _ ->
                            gun:close(Pid),
                            choose_ready_for_client(State, N + 1)
                    end;
                {error, _Reason} ->
                    choose_ready_for_client(State, N + 1)
            end;
        false ->
            choose_ready_for_client(State, N + 1)
    end.
