%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2024, 2600Hz
%%% @doc
%%% @author Wimal Dhammika
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(pusher_missed_call_notification).
-behaviour(gen_listener).

-export([start_link/0, handle_message/2]).

-ifdef(TEST).
-export([find_endpoint_object/1]).
-endif.

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,terminate/2
        ,code_change/3
        ]).

-include("pusher.hrl").

-define(SERVER, ?MODULE).

-record(state, {}).
-type state() :: #state{}.

-define(RESPONDERS, [{{?SERVER, 'handle_message'}
                     ,[{<<"notification">>, <<"missed_call">>}]
                     }
                    ]).
-define(BINDINGS, [{'notifications', [{'restrict_to', ['missed_call']}]}]).

-define(QUEUE_NAME, <<"pusher_missed_call_listener">>).
-define(QUEUE_OPTIONS, [{'exclusive', 'false'}]).
-define(CONSUME_OPTIONS, [{'exclusive', 'false'}]).
-define(PUSH_TYPE, <<"missed_call">>).
-define(TITLE_KEY, <<"IC_MISSED_CALL_TITLE">>).
-define(BODY_KEY, <<"IC_MISSED_CALL_BODY">>).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Starts the server.
%% @end
%%------------------------------------------------------------------------------
-spec start_link() -> kz_types:startlink_ret().
start_link() ->
    gen_listener:start_link({'local', ?SERVER}
                           ,?SERVER
                           ,[{'bindings', ?BINDINGS}
                            ,{'responders', ?RESPONDERS}
                            ,{'queue_name', ?QUEUE_NAME}
                            ,{'queue_options', ?QUEUE_OPTIONS}
                            ,{'consume_options', ?CONSUME_OPTIONS}
                            ]
                           ,[]
                           ).
%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server.
%% @end
%%------------------------------------------------------------------------------
-spec init([]) -> {'ok', state()}.
init([]) ->
    kz_log:put_callid(?MODULE),
    {'ok', #state{}}.

%%------------------------------------------------------------------------------
%% @doc Handling call messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(_Request, _From, State) ->
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast({'gen_listener', {'created_queue', _QueueName}}, State) ->
    {'noreply', State};
handle_cast({'gen_listener', {'is_consuming', _IsConsuming}}, State) ->
    {'noreply', State};
handle_cast(_Msg, State) ->
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info(_Info, State) ->
    lager:debug("unhandled message: ~p", [_Info]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc This function is called by a `gen_server' when it is about to
%% terminate. It should be the opposite of `Module:init/1' and do any
%% necessary cleaning up. When it returns, the `gen_server' terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, _State) ->
    lager:debug("listener terminating: ~p", [_Reason]).

%%------------------------------------------------------------------------------
%% @doc Convert process state when code is changed.
%% @end
%%------------------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec handle_message(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_message(JObj, _Props) ->
    AccountId = kz_json:get_ne_binary_value(<<"Account-ID">>, JObj),
    Endpoint = get_endpoint(JObj, AccountId),
    publish_endpoint_push(Endpoint, AccountId, JObj).

-spec publish_endpoint_push(kz_term:api_object(), kz_term:ne_binary(), kz_json:object()) -> 'ok'.
publish_endpoint_push('undefined', _AccountId, _JObj) ->
    'ok';
publish_endpoint_push(Endpoint, AccountId, JObj) ->
    Payload = kz_json:from_list_recursive([{<<"Account-ID">>, AccountId}
                                          ,{<<"Endpoint">>, Endpoint}
                                          ,{<<"Alert">>, generate_alert(JObj)}
                                          ,{<<"Category">>, ?PUSH_TYPE}
                                          ,{<<"Data">>, generate_data(JObj)}
                                          | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                                          ]),
    kapi_pusher:publish_endpoint_push_req(Payload).

-spec get_endpoint(kz_json:object(), kz_term:ne_binary()) -> kz_term:api_object().
get_endpoint(JObj, AccountId) ->
    ToUser = kz_json:get_ne_binary_value(<<"To-User">>, JObj),
    get_endpoint(JObj, AccountId
                ,kz_datamgr:get_single_result(AccountId
                                             ,<<"callflows/listing_by_number">>
                                             ,[{'key', ToUser}
                                              ,'include_docs'
                                              ]
                                             )
                ).

get_endpoint(_JObj, _AccountId, {'error', _E}) ->
    ToUser = kz_json:get_ne_binary_value(<<"To-User">>, _JObj),
    lager:info("failed to find callflow for ~s: ~p", [ToUser, _E]),
    'undefined';
get_endpoint(_JObj, _AccountId, {'ok', CallflowJObj}) ->
    find_endpoint_object(kz_json:get_json_value([<<"doc">>, <<"flow">>], CallflowJObj)).

-spec find_endpoint_object(kz_json:object()) -> kz_term:api_object().
find_endpoint_object(FlowJObj) ->
    find_endpoint_object(FlowJObj, flow_module(FlowJObj)).

find_endpoint_object(FlowJObj, EPType)->
    case EPType=:=<<"user">>
            orelse EPType=:=<<"device">>
    of
        'true' ->
            build_endpoint(EPType, kz_json:get_ne_binary_value([<<"data">>, <<"id">>], FlowJObj));
        'false' ->
            find_endpoint_object_in_children(flow_children(FlowJObj))
    end.

find_endpoint_object_in_children([]) -> 'undefined';
find_endpoint_object_in_children([Child | Children]) ->
    case find_endpoint_object(Child) of
        'undefined' -> find_endpoint_object_in_children(Children);
        EndpointObject -> EndpointObject
    end.

build_endpoint(Type, Id) ->
    kz_json:from_list([{<<"Type">>, Type}
                      ,{<<"ID">>, Id}
                      ]).

flow_module(FlowJObj) ->
    kz_json:get_ne_binary_value(<<"module">>, FlowJObj).

flow_children(FlowJObj) ->
    Children = kz_json:get_json_value(<<"children">>, FlowJObj, kz_json:new()),
    {Kids, _BranchKeys} = kz_json:get_values(Children),
    Kids.

-spec generate_alert(kz_json:object()) -> kz_json:object().
generate_alert(JObj) ->
    %% e.g. title: New Missed Call
    %% body: From <CID Name> (<CID Number>)
    kz_json:from_list([{<<"Title-Key">>, ?TITLE_KEY}
                      ,{<<"Body-Key">>, ?BODY_KEY}
                      ,{<<"Body-Params">>, [kz_json:get_ne_binary_value(<<"Caller-ID-Name">>, JObj)
                                           ,kz_json:get_ne_binary_value(<<"Caller-ID-Number">>, JObj)
                                           ]}
                      ]).

-spec generate_data(kz_json:object()) -> kz_json:object().
generate_data(JObj) ->
    kz_json:from_list([{<<"Push-Type">>, ?PUSH_TYPE}
                      ,{<<"Call-ID">>, kz_json:get_ne_binary_value(<<"Call-ID">>, JObj)}
                      ,{<<"Caller-ID-Number">>, kz_json:get_ne_binary_value(<<"Caller-ID-Number">>, JObj)}
                      ,{<<"Caller-ID-Name">>, kz_json:get_ne_binary_value(<<"Caller-ID-Name">>, JObj)}
                      ,{<<"Authorizing-Type">>, kz_json:get_ne_binary_value(<<"Authorizing-Type">>, JObj)}
                      ,{<<"Authorizing-ID">>, kz_json:get_ne_binary_value(<<"Authorizing-ID">>, JObj)}
                      ]).
