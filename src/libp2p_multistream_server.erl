-module(libp2p_multistream_server).

-define(NEGOTIATION_TIME, 30000).

-export([start_link/4, start_link/3, init/1]).

-record(state, {
          connection :: libp2p_connection:connection(),
          handlers :: [{prefix(), handler()}],
          handler_opt :: any(),
          timeout :: reference()
         }).

-type prefix() :: string().
-type handler() :: {atom(), atom()} | {atom(), atom(), any()}.

%%
%% Note that this is NOT a gen_server, it is just a small shim to exec into some other main loop
%%

-spec start_link(any(), libp2p_connection:connection(), [{string(), term()}], any()) -> {ok, pid()}.
start_link(Ref, Connection, Handlers, HandlerOpt) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [{Ref, Connection, Handlers, HandlerOpt}])}.

-spec start_link(libp2p_connection:connection(), [{string(), term()}], any()) -> {ok, pid()}.
start_link(Connection, Handlers, HandlerOpt) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [{Connection, Handlers, HandlerOpt}])}.

init({Ref, Connection, Handlers, HandlerOpt}) ->
    ok = libp2p_connection:acknowledge(Connection, Ref),
    self() ! handshake,
    TimerRef = erlang:send_after(?NEGOTIATION_TIME, self(), timeout),
    loop(#state{connection=Connection, handlers=Handlers, handler_opt=HandlerOpt, timeout=TimerRef});
init({Connection, Handlers, HandlerOpt}) ->
    TimerRef = erlang:send_after(?NEGOTIATION_TIME, self(), timeout),
    ok = libp2p_connection:fdset(Connection),
    loop(#state{connection=Connection, handlers=Handlers, handler_opt=HandlerOpt, timeout=TimerRef}).


loop(State) ->
    %% XXX to avoid accidentally consuming messages destined for the actual session, once negotiated
    %% only do a selective receive here.
    receive
        {inert_read, _, _} = Msg ->
            handle_msg(Msg, State);
        handshake = Msg ->
            handle_msg(Msg, State);
        timeout = Msg ->
            handle_msg(Msg, State)
    after
        5000 ->
             ok
    end.

handle_msg(Msg, State) ->
    case handle_info(Msg, State) of
        {noreply, NewState} ->
            loop(NewState);
        {exec, M, F, A} ->
            erlang:cancel_timer(State#state.timeout),
            try erlang:apply(M, F, A) of
                Result -> Result
            catch
                What:Why -> terminate({What, Why}, State)
            end;
        {stop, Reason, NewState} ->
            terminate(Reason, NewState)
    end.

handle_info({inert_read, _, _}, State=#state{connection=Conn,
                                             handlers=Handlers,
                                             handler_opt=HandlerOpt}) ->
    lager:info("BB: mul steam server stack: ~s~n", [element(2, process_info(self(), backtrace))]),
    case libp2p_multistream:read(Conn) of
        {error, timeout} ->
            lager:debug("Timeout reading from multistream"),
            {stop, normal, State};
        {error, Reason} ->
            {stop, {error, Reason}, State};
        "ls" ->
            handle_ls_reply(Conn, Handlers, State);
        Line ->
            case find_handler(Line, Handlers, error) of
                {Key, {M, F}, LineRest} ->
                    {_, RemoteAddr} = libp2p_connection:addr_info(Conn),
                    write(Conn, Line),
                    lager:debug("Negotiated server handler for ~p: ~p", [RemoteAddr, Key]),
                    {exec, M, F, [Conn, LineRest, HandlerOpt, []]};
                {Key, {M, F, A}, LineRest} ->
                    {_, RemoteAddr} = libp2p_connection:addr_info(Conn),
                    write(Conn, Line),
                    lager:debug("Negotiated server handler for ~p: ~p", [RemoteAddr, Key]),
                    {exec, M, F, [Conn, LineRest, HandlerOpt, A]};
                error ->
                    lager:debug("Can't find handler for ~p in ~p", [Line, Handlers]),
                    write(Conn, "na"),
                    fdset_return(Conn, State)
            end
    end;
handle_info(handshake, State=#state{connection=Conn}) ->
    {_, RemoteAddr} = libp2p_connection:addr_info(Conn),
    case handshake(Conn) of
        ok ->
            fdset_return(Conn, State);
        {error, timeout} ->
            lager:notice("Timeout handshaking client ~p", [RemoteAddr]),
            {stop, normal, State};
        {error, Error} ->
            lager:notice("Failed to handshake client ~p: ~p", [RemoteAddr, Error]),
            {stop, {error, Error}, State}
    end;
handle_info(timeout, State) ->
    {stop, normal, State}.


terminate(_Reason, State=#state{connection=Connection}) ->
    fdclr(Connection, State),
    libp2p_connection:close(Connection).

%%
%% Internal
%%

fdset_return(Connection, State) ->
    case libp2p_connection:fdset(Connection) of
        ok -> {noreply, State};
        {error, Error} -> {stop, {error, Error}, State}
    end.

fdclr(Connection, State) ->
    libp2p_connection:fdclr(Connection),
    State.

handle_ls_reply(Conn, Handlers, State) ->
    Keys = [Key || {Key, _} <- Handlers],
    try libp2p_multistream:write_lines(Conn, Keys) of
        ok -> fdset_return(Conn, State);
        {error, timeout} -> {stop, normal, State};
        {error, Reason} -> {stop, {error, Reason}, State}
    catch
        What:Why -> {stop, {What, Why}, State}
    end.

-spec handshake(libp2p_connection:connection()) -> ok | {error, term()}.
handshake(Connection) ->
    Id = libp2p_multistream:protocol_id(),
    write(Connection, Id),
    case libp2p_multistream:read(Connection) of
        {error, Reason} -> {error, Reason};
        Id -> ok;
        ClientId -> {error, {protocol_mismatch, ClientId}}
    end.

-spec find_handler(string(), [{prefix(), handler()}], Acc :: error | {string(), handler(), string()}) -> {string(), handler(), string()} | error.
find_handler(_Line, [], Acc) ->
    Acc;
find_handler(Line, [{Prefix, Handler} | Handlers], Acc) ->
    case string:prefix(Line, Prefix) of
        nomatch -> find_handler(Line, Handlers, Acc);
        Rest ->
            case Acc of
                error ->
                    find_handler(Line, Handlers, {Prefix, Handler, Rest});
                {Prefix2, _Handler2, _Rest2} ->
                    case length(Prefix2) < length(Prefix) of
                        true ->
                            find_handler(Line, Handlers, {Prefix, Handler, Rest});
                        false ->
                            find_handler(Line, Handlers, Acc)
                    end
            end
    end.


write(Conn, Data) ->
    libp2p_multistream:write(Conn, Data).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

longest_prefix_test() ->
    ?assertMatch({"consensus-10", lol, "/blah"}, find_handler("consensus-10/blah", [{"consensus-1", hah}, {"consensus-10", lol}], error)),
    ?assertMatch({"consensus-1", hah, "/foo"}, find_handler("consensus-1/foo", [{"consensus-1", hah}, {"consensus-10", lol}], error)),
    ?assertMatch({"consensus-1", heh, "/foo"}, find_handler("consensus-1/foo", [{"consensus-10", lol}, {"consensus-1", heh}], error)),
    ok.

-endif.
