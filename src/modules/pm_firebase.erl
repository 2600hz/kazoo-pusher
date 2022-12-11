%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2022, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(pm_firebase).
-behaviour(gen_server).

-include("pusher.hrl").

-define(SERVER, ?MODULE).

-export([start_link/0]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,terminate/2
        ,code_change/3
        ]).

-record(state, {tab :: ets:tid()}).
-type state() :: #state{}.

-define(KEY_DATA, <<"data">>).
-define(KEY_NOTIFICATION, <<"notification">>).

-define(PAYLOAD_MAP, #{<<"Alert">> => #{<<"Title">> => [?KEY_NOTIFICATION, <<"title">>]
                                       ,<<"Subtitle">> => [?KEY_NOTIFICATION, <<"subtitle">>]
                                       ,<<"Body">> => [?KEY_NOTIFICATION, <<"body">>]
                                       ,<<"Title-Key">> => [?KEY_NOTIFICATION, <<"title_loc_key">>]
                                       ,<<"Title-Params">> => [?KEY_NOTIFICATION, <<"title_loc_args">>]
                                       ,<<"Body-Key">> => [?KEY_NOTIFICATION, <<"body_loc_key">>]
                                       ,<<"Body-Params">> => [?KEY_NOTIFICATION, <<"body_loc_args">>]
                                       }
                      ,<<"Badge">> => fun set_badge/2
                      ,<<"Category">> => [?KEY_NOTIFICATION, <<"click_action">>]
                      ,<<"Collapse-ID">> => <<"collapse_key">>
                      ,<<"Content-Available">> => <<"content_available">>
                      ,<<"Content-Mutable">> => <<"mutable_content">>
                      ,<<"FCM">> => #{<<"Android">> => #{<<"Channel-ID">> => [?KEY_NOTIFICATION, <<"android_channel_id">>]
                                                        ,<<"Color">> => [?KEY_NOTIFICATION, <<"color">>]
                                                        ,<<"Icon">> => [?KEY_NOTIFICATION, <<"icon">>]
                                                        ,<<"Tag">> => [?KEY_NOTIFICATION, <<"tag">>]
                                                        }}
                      ,<<"Priority">> => fun set_priority/2
                      ,<<"Sound">> => [?KEY_NOTIFICATION, <<"sound">>]
                      ,<<"TTL">> => <<"time_to_live">>
                           %% For `push_req` backwards-compatibility
                      ,<<"Call-ID">> => [?KEY_DATA, <<"Call-ID">>]
                      }).

-spec start_link() -> kz_types:startlink_ret().
start_link() ->
    gen_server:start_link({'local', ?SERVER}, ?MODULE, [],[]).

-spec init([]) -> {'ok', state()}.
init([]) ->
    kz_log:put_callid(?MODULE),
    lager:debug("starting server"),
    {'ok', #state{tab=ets:new(?MODULE, [])}}.

-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast({'push', Token, TokenApp, JObj}, #state{tab=ETS}=State) ->
    kz_log:put_callid(JObj),
    maybe_send_push_notification(get_fcm(TokenApp, ETS), Token, JObj),
    {'noreply', State};
handle_cast('stop', State) ->
    {'stop', 'normal', State}.

-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info(_Request, State) ->
    {'noreply', State}.

-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, #state{tab=ETS}) ->
    ets:delete(ETS),
    'ok'.

-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Send the push notification if an FCM worker is running.
%% @end
%%------------------------------------------------------------------------------
-spec maybe_send_push_notification(push_app(), kz_term:ne_binary(), kz_json:object()) -> 'ok'.
maybe_send_push_notification('undefined', _, _) ->
    lager:debug("no pid to send push"),
    'ok';
maybe_send_push_notification({Pid, Envelope}, TokenID, JObj) ->
    {CustomData, JObj1} = pusher_module_util:extract_custom_data(JObj),

    Message = build_message(JObj1, CustomData, Envelope),

    lager:debug("pushing to ~p: ~s: ~p", [Pid, TokenID, Message]),

    fcm:push(Pid, [TokenID], Message).

%%------------------------------------------------------------------------------
%% @doc Build the FCM message payload.
%% @end
%%------------------------------------------------------------------------------
-spec build_message(kz_json:object(), map(), map()) -> map().
build_message(JObj, CustomData, Envelope) ->
    FlatProps = kz_json:to_proplist(kz_json:flatten(JObj)),
    Message = pusher_module_util:build_payload(
                FlatProps, JObj, ?PAYLOAD_MAP, #{?KEY_DATA => CustomData}
               ),
    kz_maps:merge(Message, Envelope).

-spec get_fcm(kz_term:ne_binary(), ets:tid()) -> push_app().
get_fcm(App, ETS) ->
    case ets:lookup(ETS, App) of
        [] -> maybe_load_fcm(App, ETS);
        [{App, Push}] -> Push
    end.

-spec maybe_load_fcm(kz_term:ne_binary(), ets:tid()) -> push_app().
maybe_load_fcm(App, ETS) ->
    lager:debug("loading fcm secret for ~s", [App]),
    FCMSecret = kapps_config:get_binary(?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE, <<"api_key">>], <<>>, App),
    EnvelopeJObj = kapps_config:get_json(?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE, <<"headers">>], kz_json:new(), App),
    Envelope = kz_json:to_map(EnvelopeJObj),
    maybe_load_fcm(App, ETS, FCMSecret, Envelope).

-spec maybe_load_fcm(kz_term:ne_binary(), ets:tid(), binary(), map()) -> push_app().
maybe_load_fcm(App, _ETS, <<>>, _Envelope) ->
    lager:debug("firebase pusher api_key for app ~s not found", [App]),
    'undefined';
maybe_load_fcm(App, ETS, APIKey, Envelope) ->
    case fcm:start(kz_term:to_atom(<<"fcm_", App/binary>>, 'true'), kz_term:to_list(APIKey)) of
        {'ok', Pid} ->
            ets:insert(ETS, {App, {Pid, Envelope}}),
            {Pid, Envelope};
        {'error', {'already_started', Pid}} ->
            ets:insert(ETS, {App, {Pid, Envelope}}),
            {Pid, Envelope};
        {'error', Reason} ->
            lager:error("error loading fcm ~p", [Reason]),
            'undefined'
    end.

%%------------------------------------------------------------------------------
%% @doc Set the home screen badge value.
%% @end
%%------------------------------------------------------------------------------
-spec set_badge(integer(), map()) -> map().
set_badge(Badge, Payload) ->
    kz_maps:put([?KEY_NOTIFICATION, <<"badge">>]
               ,Payload
               ,kz_term:to_binary(Badge)
               ).

%%------------------------------------------------------------------------------
%% @doc Set the message delivery priority.
%% @end
%%------------------------------------------------------------------------------
-spec set_priority(kz_term:ne_binary(), map()) -> map().
set_priority(PriorityBin, Payload) ->
    Priority = adjusted_priority(PriorityBin),
    Payload#{<<"priority">> => Priority}.

-spec adjusted_priority(kz_term:ne_binary()) -> kz_term:ne_binary().
adjusted_priority(<<"low">>) -> <<"normal">>;
adjusted_priority(Priority) -> Priority.
