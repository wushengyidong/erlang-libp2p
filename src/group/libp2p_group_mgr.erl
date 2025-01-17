-module(libp2p_group_mgr).

-behaviour(gen_server).

%% API
-export([
         start_link/2,
         mgr/1,
         add_group/4,
         remove_group/2,
         stop_all/1,
         force_gc/1
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state,
        {
         tid :: term(),
         group_deletion_predicate :: fun((string()) -> boolean()),
         servers = #{},
         storage_dir :: string()
        }).

%%%===================================================================
%%% API
%%%===================================================================

start_link(TID, Predicate) ->
    gen_server:start_link(reg_name(TID), ?MODULE, [TID, Predicate], []).

reg_name(TID)->
    {local, libp2p_swarm:reg_name_from_tid(TID, ?MODULE)}.

mgr(TID) ->
    ets:lookup_element(TID, ?SERVER, 2).

%% these are a simple wrapper around swarm add group to prevent races
add_group(Mgr, GroupID, Module, Args) ->
    gen_server:call(Mgr, {add_group, GroupID, Module, Args}, infinity).

remove_group(Mgr, GroupID) ->
    gen_server:call(Mgr, {remove_group, GroupID}, infinity).

stop_all(TID) ->
    gen_server:call(element(2, reg_name(TID)), stop_all, infinity).

%% not implemented
force_gc(Mgr) ->
    gen_server:call(Mgr, force_gc, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([TID, Predicate]) ->
    _ = ets:insert(TID, {?SERVER, self()}),
    erlang:send_after(timer:seconds(30), self(), gc_tick),
    Dir = libp2p_config:swarm_dir(TID, [groups]),
    lager:debug("groups dir ~p", [Dir]),
    {ok, #state{tid  = TID,
                group_deletion_predicate = Predicate,
                storage_dir = Dir}}.

handle_call({add_group, GroupID, Module, Args}, _From,
            #state{tid = TID, servers = Servers} = State) ->
    {Reply, State1} =
        case libp2p_config:lookup_group(TID, GroupID) of
            {ok, Pid} ->
                lager:info("trying to add running group: ~p", [GroupID]),
                {{ok, Pid}, State};
            false ->
                lager:info("newly starting group: ~p", [GroupID]),
                GroupSup = libp2p_swarm_group_sup:sup(TID),
                ChildSpec = #{ id => GroupID,
                               start => {Module, start_link, [TID, GroupID, Args]},
                               restart => transient,
                               shutdown => 5000,
                               type => supervisor },
                case supervisor:start_child(GroupSup, ChildSpec) of
                    {error, Error} -> {{error, Error}, State};
                    {ok, GroupPid} ->
                        libp2p_config:insert_group(TID, GroupID, GroupPid),
                        Server = libp2p_group_relcast_sup:server(GroupPid),
                        Ref = erlang:monitor(process, Server),
                        Servers1 = Servers#{Server => {GroupID, Ref}},
                        {{ok, GroupPid}, State#state{servers = Servers1}}
                end
        end,
    {reply, Reply, State1};
handle_call({remove_group, GroupID}, _From,
            #state{tid = TID, servers = Servers} = State) ->
    case libp2p_config:lookup_group(TID, GroupID) of
        {ok, Pid} ->
            Server = libp2p_group_relcast_sup:server(Pid),
            lager:info("removing group ~p ~p  ~p", [GroupID, Pid, Server]),
            GroupSup = libp2p_swarm_group_sup:sup(TID),
            libp2p_group_relcast_server:stop(Server),
            receive
                {'DOWN', _Ref, process, Server, _} ->
                    lager:info("got down from ~p", [Server]),
                    ok
            %% wait a max of 30s for the rocks-owning server to
            %% gracefully shutdown
            after 30000 ->
                    ok
            end,
            %% then stop the sup and the workers, and maybe kill the
            %% server if it's still hung
            _ = supervisor:terminate_child(GroupSup, GroupID),
            _ = supervisor:delete_child(GroupSup, GroupID),
            _ = libp2p_config:remove_group(TID, GroupID),
            Servers1 = maps:remove(Server, Servers),
            {reply, ok, State#state{servers = Servers1}};
        false ->
            lager:warning("removing missing group ~p", [GroupID]),
            {reply, ok, State}
        end;
handle_call(stop_all, _From,  #state{tid = TID} = State) ->
    case libp2p_config:all_groups(TID) of
        [] -> ok;
        Groups ->
            [_, Last] = lists:last(Groups),
            LastServer = libp2p_group_relcast_sup:server(Last),
            [begin
                 Server = libp2p_group_relcast_sup:server(Pid),
                 libp2p_group_relcast_server:stop(Server),
                 _ = libp2p_config:remove_group(TID, ID)
             end
             || [ID, Pid] <- Groups],
            receive
                {'DOWN', _Ref, process, LastServer, _} ->
                    ok
                    %% wait a max of 30s for the rocks-owning server to
                    %% gracefully shutdown
            after 30000 ->
                    ok
            end
    end,
    {reply, ok, State};
handle_call(force_gc, _From, #state{group_deletion_predicate = Predicate,
                                    storage_dir = Dir} = State) ->
    lager:info("forcing gc"),
    Reply = gc(Predicate, Dir),
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    {noreply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

handle_info(gc_tick, #state{group_deletion_predicate = Predicate,
                            storage_dir = Dir} = State) ->
    gc(Predicate, Dir),
    Timeout = application:get_env(libp2p, group_gc_tick, timer:seconds(30)),
    erlang:send_after(Timeout, self(), gc_tick),
    {noreply, State};
handle_info({'DOWN', _Ref, process, Server, _},
            #state{servers = Servers, tid = TID} = State) ->
    case maps:find(Server, Servers) of
        {ok, {ID, _StoredRef}} ->
            case libp2p_config:lookup_group(TID, ID) of
                {ok, _Sup} ->
                    lager:info("saw DOWN from ~p ~p", [ID, Server]),
                    GroupSup = libp2p_swarm_group_sup:sup(TID),
                    %% then stop the sup and the workers, and maybe kill the
                    %% server if it's still hung
                    _ = supervisor:terminate_child(GroupSup, ID),
                    _ = supervisor:delete_child(GroupSup, ID),
                    _ = libp2p_config:remove_group(TID, ID),
                    Servers1 = maps:remove(Server, Servers),
                    {noreply, State#state{servers = Servers1}};
                false ->
                    lager:info("saw DOWN from missing server ~p", [ID]),
                    Servers1 = maps:remove(Server, Servers),
                    {noreply, State#state{servers = Servers1}}
            end;
        error ->
            lager:info("saw DOWN from unknown server ~p", [Server]),
            {noreply, State}
    end;
handle_info(_Info, State) ->
    lager:warning("unexpected message ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

gc(_Predicate, "") ->
    lager:debug("no dir"),
    ok;
gc(Predicate, Dir) ->
    %% fetch all directories in Dir
    case file:list_dir(Dir) of
        {ok, Groups} ->
            %% filter using predicate
            Dels = lists:filter(Predicate, lists:sublist(Groups, 100)),
            lager:debug("groups ~p dels ~p", [Groups, Dels]),
            %% delete.
            lists:foreach(fun(Grp) -> rm_rf(Dir ++ "/" ++ Grp) end,
                          lists:sublist(Dels, 50));
        _ ->
            ok
    end,
    ok.


-spec rm_rf(file:filename()) -> ok.
rm_rf(Dir) ->
    lager:debug("deleting dir: ~p", [Dir]),
    Paths = filelib:wildcard(Dir ++ "/**"),
    {Dirs, Files} = lists:partition(fun filelib:is_dir/1, Paths),
    ok = lists:foreach(fun file:delete/1, Files),
    Sorted = lists:reverse(lists:sort(Dirs)),
    ok = lists:foreach(fun file:del_dir/1, Sorted),
    file:del_dir(Dir).
