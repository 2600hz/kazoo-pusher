%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2014-2023, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(pusher_voicemail_notification).
-behaviour(gen_listener).

-export([start_link/0]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,handle_message/2
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
    kz_log:put_callid(<<?MODULE_STRING>>),
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
%% @doc Allows listener to pass options to handlers.
%% @end
%%------------------------------------------------------------------------------
-spec handle_event(kz_json:object(), kz_term:proplist()) -> gen_listener:handle_event_return().
handle_event(_JObj, _State) ->
    {'reply', []}.

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
            generate_and_maybe_push_payload(JObj, AccountId, OwnerId);
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

-spec generate_and_maybe_push_payload(kz_json:object(), kz_term:ne_binary(), kz_term:ne_binary()) -> ok.
generate_and_maybe_push_payload(JObj, AccountDb, OwnerId) ->
    generate_and_maybe_push_payload(JObj, fetch_owned_devices(AccountDb, OwnerId)).

generate_and_maybe_push_payload(_JObj, []) -> 'ok';
generate_and_maybe_push_payload(JObj, Devices) ->
    PushObj = generate_push_payload(JObj),
    maybe_push_notification(PushObj, Devices).

fetch_owned_devices(AccountDb, OwnerId) ->
    {'ok', DeviceDocList} = kz_datamgr:get_results(AccountDb
                                                  ,<<"devices/listing_by_owner">>
                                                  ,[{'key', OwnerId}, 'include_docs']
                                                  ),
    DeviceDocList.

generate_push_payload(JObj) ->
    ToUser = kz_json:get_ne_binary_value(<<"To">>, JObj),
    New = kz_json:get_ne_binary_value(<<"Messages-New">>, JObj),
    Saved = kz_json:get_ne_binary_value(<<"Messages-Saved">>, JObj),
    PresenceId = kz_json:get_ne_binary_value(<<"Presence-ID">>, JObj),
    CallId = kz_json:get_ne_binary_value(<<"Call-ID">>, JObj),

    Payload = [{<<"To">>, ToUser}
              ,{<<"Messages-New">>, New}
              ,{<<"Messages-Saved">>, Saved}
              ,{<<"Extended-Presence-ID">>, PresenceId}
              ,{<<"Call-ID">>, CallId}
              ],
    kz_json:set_values([{<<"Payload">>, kz_json:from_list(Payload)}], JObj).

%% foreach element in a list, check conditional on element, and if true, do work on element

%% foreach device, if push object, send Push notification

maybe_push_notification(PushJObj, Devices) ->
    %% foreach device
    lists:foreach(fun(Device) -> maybe_push_to_device(PushJObj, Device) end
                 ,Devices
                 ).

maybe_push_to_device(PushJObj, Device) ->
    %% if push object
    case kz_json:get_json_value([<<"doc">>, <<"push">>], Device) of
        'undefined' -> 'ok';
        DevicePushJObj -> push_to_device(PushJObj, DevicePushJObj)
    end.

%% send Push notification
push_to_device(PushJObj, DevicePushJObj) ->
    TokenInfo = [{<<"Token-ID">>, kz_json:get_ne_binary_value(<<"Token-ID">>, DevicePushJObj)}
                ,{<<"Token-Type">>, kz_json:get_ne_binary_value(<<"Token-Type">>, DevicePushJObj)}
                ,{<<"Token-App">>, kz_json:get_ne_binary_value(<<"Token-App">>, DevicePushJObj)}
                ],
    pusher_listener:push(kz_json:set_values(TokenInfo, PushJObj)).
