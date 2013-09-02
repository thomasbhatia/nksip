%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc NkSIP SIP basic message print and trace tool
%%
%% This module implements a simple but useful SIP trace utility. 
%% You can configure any <i>SipApp</i> to trace SIP messages sent or received
%% from specific IPs, to console or a disk file.
%%
%% It also allows to store (in memory) detailed information about 
%% every request or response sent or received for debug purposes.

-module(nksip_trace).
-behaviour(gen_server).

-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile({no_auto_import, [get/1, put/2]}).

-export([counters/0, get_all/0, start/0, start/1, start/2, start/3, stop/0, stop/1]).
-export([print/1, print/2, sipmsg/5]).
-export([info/1, notice/1]).
-export([store_msgs/1, insert/2, insert/3, find/1, find/2, dump_msgs/0, reset_msgs/0]).
-export([start_link/0, init/1, terminate/2, code_change/3, handle_call/3, 
         handle_cast/2, handle_info/2]).

-include("nksip.hrl").


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets some statistics about current number of active transactions, proxy 
%% transacions, dialogs, etc.
-spec counters() ->
    nksip_lib:proplist().

counters() ->
    [
        {calls, nksip_counters:value(nksip_calls)},
        {sipmsgs, nksip_counters:value(nksip_msgs)},
        {dialogs, nksip_counters:value(nksip_dialogs)},
        {routers_queue, nksip_call_router:pending_msgs()},
        {routers_pending, nksip_call_router:pending_work()},
        {tcp_connections, nksip_counters:value(nksip_transport_tcp)},
        {counters_queue, nksip_counters:pending_msgs()},
        {core_queues, nksip_sipapp_srv:pending_msgs()},
        {uas_response, nksip_stats:get_uas_avg()}
    ].


%% @doc Get all SipApps currently tracing messages.
-spec get_all() ->
    [AppId::term()].

get_all() ->
    Fun = fun(AppId) -> nksip_config:get({nksip_trace, AppId}) =/= undefined end,
    lists:filter(Fun, nksip:get_all()).


%% @doc Equivalent to `start(AppId, [], console)' for all started SipApps.
-spec start() -> 
    ok.
start() -> 
    lists:foreach(fun(AppId) -> start(AppId) end, nksip:get_all()).


%% @doc Equivalent to `start(AppId, [], console)'.
-spec start(nksip:app_id()) -> 
    ok.
start(AppId) -> 
    start(AppId, [], console).


%% @doc Equivalent to `start(AppId, [], File)'.
-spec start(nksip:app_id(), console | string()) -> 
    ok | {error, file:posix()}.

start(AppId, Out) -> 
    start(AppId, [], Out).


%% @doc Configures a <i>SipApp</i> to start tracing SIP messages.
%% Any request or response sent or received by the SipApp, 
%% and using any of the IPs in `IpList' 
%% (or <i>all of them</i> if it list is empty) will be traced to `console' 
%% or a file, that will opened in append mode.
-spec start(nksip:app_id(), [inet:ip4_address()], console|string()) ->
    ok | {error, file:posix()}.

start(AppId, IpList, Out) when is_list(IpList) ->
    case nksip_config:get({nksip_trace, AppId}) of
        undefined -> ok;
        {_, console} -> ok;
        {_, IoDevice0} -> catch file:close(IoDevice0)
    end,
    case Out of
        console ->
            nksip_config:put({nksip_trace, AppId}, {IpList, console});
        _ ->            
            case file:open(Out, [append]) of
                {ok, IoDevice} -> 
                    nksip_config:put({nksip_trace, AppId}, {IpList, IoDevice});
                {error, Error} -> 
                    {error, Error}
            end
    end.


%% @doc Stop all tracing processes, closing all open files.
-spec stop() -> 
    ok.

stop() ->
    lists:foreach(fun(AppId) -> stop(AppId) end, nksip:get_all()).


%% @doc Stop tracing a specific trace process, closing file if it is opened.
-spec stop(nksip:app_id()) ->
    ok | not_found.

stop(AppId) ->
    case nksip_config:get({nksip_trace, AppId}) of
        undefined -> 
            not_found;
        {_, console} ->
            nksip_config:del({nksip_trace, AppId}),
            ok;
        {_, IoDevice} ->
            catch file:close(IoDevice),
            nksip_config:del({nksip_trace, AppId}),
            ok
    end.


%% @doc Pretty-print a `Request' or `Response'.
-spec print(Input::nksip:request()|nksip:response()) ->
 ok.

print(#sipmsg{}=SipMsg) -> 
    print(<<>>, SipMsg).


%% @doc Pretty-print a `Request' or `Response' with a tag.
-spec print(string()|binary(), Input::nksip:request()|nksip:response()) ->
    ok.

print(Header, #sipmsg{}=SipMsg) ->
    Binary = nksip_unparse:packet(SipMsg),
    Lines = [
        [<<"        ">>, Line, <<"\n">>]
        || Line <- binary:split(Binary, <<"\r\n">>, [global])
    ],
    io:format("\n        ---- ~s\n~s\n", [Header, list_to_binary(Lines)]).


%% Helper functions

%% @private
info(Text) -> lager:info(Text).

%% @private
notice(Text) -> lager:notice(Text).





%% ===================================================================
%% gen_server
%% ===================================================================

-record(state, {}).

%% @private
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
        

% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([]) ->
    ets:new(nksip_trace_msgs, [named_table, public, bag, {write_concurrency, true}]),
    {ok, #state{}}.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    gen_server_terminate().

terminate(_Reason, _State) ->  
    ok.


%% ===================================================================
%% Private
%% ===================================================================


%% @private
store_msgs(Bool) when Bool=:=true; Bool=:=false ->
    nksip_config:put(nksip_store_msgs, Bool).


%% @private
insert(#sipmsg{app_id=AppId, call_id=CallId}, Info) ->
    insert(AppId, CallId, Info).


%% @private
insert(AppId, CallId, Info) ->
    case nksip_config:get(nksip_store_msgs) of
        true ->
            Time = nksip_lib:l_timestamp(),
            Info1 = case Info of
                {Type, Str, Fmt} when Type=:=debug; Type=:=info; Type=:=notice; 
                                      Type=:=warning; Type=:=error ->
                    {Type, nksip_lib:msg(Str, Fmt)};
                _ ->
                    Info
            end,
            ets:insert(nksip_trace_msgs, {CallId, Time, AppId, Info1});
        _ ->
            ok
    end.


%% @private
find(CallId) ->
    Lines = lists:sort([{Time, AppId, Info} || {_, Time, AppId, Info} 
                         <- ets:lookup(nksip_trace_msgs, CallId)]),
    [{nksip_lib:l_timestamp_to_float(Time), AppId, Info} 
        || {Time, AppId, Info} <- Lines].


%% @private
find(AppId, CallId) ->
    [{Start, Info} || {Start, C, Info} <- find(CallId), C=:=AppId].


%% @private
dump_msgs() ->
    ets:tab2list(nksip_trace_msgs).


%% @private
reset_msgs() ->
    ets:delete_all_objects(nksip_trace_msgs).


%% @private
-spec sipmsg(nksip:app_id(), nksip:call_id(), binary(), 
             nksip_transport:transport(), binary()) ->
    ok.

sipmsg(AppId, _CallId, Header, 
       #transport{local_ip=Ip1, remote_ip=Ip2}=Transport, Binary) ->
    case nksip_config:get({nksip_trace, AppId}) of
        undefined -> 
            % print_packet(AppId, Header, Transport, Binary, console),
            ok;
        {[], IoDevice} ->
            print_packet(AppId, Header, Transport, Binary, IoDevice);
        {IpList, IoDevice} ->
            case lists:member(Ip1, IpList) orelse lists:member(Ip2, IpList) of
                true -> print_packet(AppId, Header, Transport, Binary, IoDevice);
                false -> ok
            end
    end.


%% @private
print_packet(AppId, Info, 
                #transport{
                    proto = Proto,
                    local_ip = LIp, 
                    local_port = LPort, 
                    remote_ip = RIp, 
                    remote_port = RPort
                }, 
                Binary, IoDevice) ->
    case catch inet_parse:ntoa(RIp) of
        {'EXIT', _} -> RHost = <<"undefined">>;
        RHost -> ok
    end,
    case catch inet_parse:ntoa(LIp) of
        {'EXIT', _} -> LHost = <<"undefined">>;
        LHost -> ok
    end,
    Lines = [
        [<<"        ">>, Line, <<"\n">>]
        || Line <- binary:split(Binary, <<"\r\n">>, [global])
    ],
    Time = nksip_lib:l_timestamp_to_float(nksip_lib:l_timestamp()), 
    Text = io_lib:format("\n        ---- ~p ~s ~s:~p (~p, ~s:~p) ~f (~p)\n~s\n", 
        [AppId, Info, RHost, RPort, 
            Proto, LHost, LPort, Time, self(), list_to_binary(Lines)]),
    case IoDevice of
        console -> io:format("~s", [Text]);
        IoDevice -> catch file:write(IoDevice, Text)
    end.



