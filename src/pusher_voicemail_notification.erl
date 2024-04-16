%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2023-2024, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(pusher_voicemail_notification).
-behaviour(gen_listener).

-export([start_link/0, handle_message/2]).

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

-define(RESPONDERS, [{{?MODULE, 'handle_message'}
                     ,[{<<"presence">>, <<"mwi_update">>}]
                     }
                    ]).
-define(BINDINGS, [{'presence', [{'restrict_to', ['mwi_update']}]}]).

-define(QUEUE_NAME, <<"pusher_voicemail_listener">>).
-define(QUEUE_OPTIONS, [{'exclusive', 'false'}]).
-define(CONSUME_OPTIONS, [{'exclusive', 'false'}]).
-define(PUSH_TYPE, <<"voicemail">>).
-define(TITLE_KEY, <<"IC_VOICEMAIL_TITLE">>).
-define(BODY_KEY, <<"IC_VOICEMAIL_BODY">>).

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
    ToRealm = to_realm(JObj),
    case kz_datamgr:get_single_result(?KZ_ACCOUNTS_DB
                                     ,<<"accounts/listing_by_realm">>
                                     ,[{'key', ToRealm}]
                                     )
    of
        {'ok', AccountJObj} ->
            AccountId = kz_doc:id(AccountJObj),
            OwnerId = get_owner_id(JObj, AccountId),
            Payload = kz_json:from_list_recursive([{<<"Account-ID">>, AccountId}
                                                  ,{<<"Endpoint">>
                                                   ,[{<<"ID">>, OwnerId}
                                                    ,{<<"Type">>, <<"user">>}
                                                    ]
                                                   }
                                                  ,{<<"Alert">>, generate_alert(JObj)}
                                                  ,{<<"Category">>, ?PUSH_TYPE}
                                                  ,{<<"Data">>, generate_data(JObj)}
                                                  | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
                                                  ]),
            kapi_pusher:publish_endpoint_push_req(Payload);
        {_Type, _Error} ->
            lager:info("failed to find realm ~s: ~p: ~p", [ToRealm, _Type, _Error])
    end.

to_realm(JObj) ->
    case kz_json:get_ne_binary_value(<<"To-Realm">>, JObj) of
        <<ToRealm/binary>> -> ToRealm;
        'undefined' ->
            To = kz_json:get_ne_binary_value(<<"To">>, JObj),
            [_ToUser, ToRealm] = binary:split(To, <<$@>>),
            ToRealm
    end.

-spec get_owner_id(kz_json:object(), kz_term:ne_binary()) -> kz_term:ne_binary().
get_owner_id(JObj, AccountDb) ->
    ToUser = kz_json:get_ne_binary_value(<<"To-User">>, JObj),
    {'ok', VMBox} = kz_datamgr:get_single_result(AccountDb
                                                ,<<"vmboxes/listing_by_mailbox">>
                                                ,[{'key', ToUser}, 'include_docs']
                                                ),
    VMBoxDoc = kz_json:get_json_value(<<"doc">>, VMBox),
    kzd_vmboxes:owner_id(VMBoxDoc).

-spec generate_alert(kz_json:object()) -> kz_json:object().
generate_alert(JObj) ->
    %% e.g. title: New Voicemail in Box <To-User>
    %% body: New: <new count> Saved: <saved count>
    kz_json:from_list([{<<"Title-Key">>, ?TITLE_KEY}
                      ,{<<"Title-Params">>, [kz_json:get_ne_binary_value(<<"To-User">>, JObj)]}
                      ,{<<"Body-Key">>, ?BODY_KEY}
                      ,{<<"Body-Params">>, [kz_json:get_ne_binary_value(<<"Messages-New">>, JObj)
                                           ,kz_json:get_ne_binary_value(<<"Messages-Saved">>, JObj)
                                           ]}
                      ]).

-spec generate_data(kz_json:object()) -> kz_json:object().
generate_data(JObj) ->
    kz_json:from_list([{<<"Push-Type">>, ?PUSH_TYPE}
                      ,{<<"To">>, kz_json:get_ne_binary_value(<<"To">>, JObj)}
                      ,{<<"Messages-New">>, kz_json:get_ne_binary_value(<<"Messages-New">>, JObj)}
                      ,{<<"Messages-Saved">>, kz_json:get_ne_binary_value(<<"Messages-Saved">>, JObj)}
                      ,{<<"Extended-Presence-ID">>, kz_json:get_ne_binary_value(<<"Presence-ID">>, JObj)}
                      ,{<<"Call-ID">>, kz_json:get_ne_binary_value(<<"Call-ID">>, JObj)}
                      ]).
