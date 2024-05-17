%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2024, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @author Daniel Finke <danielfinke2011@gmail.com>
%%% @end
%%%-----------------------------------------------------------------------------
-module(pm_firebase).
-behaviour(gen_server).
-behaviour(pusher_module).

-include("pusher.hrl").

-define(SERVER, ?MODULE).

-export([start_link/0
        ,enabled/1
        ,push/4
        ]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,terminate/2
        ,code_change/3
        ]).

-record(state, {tab :: ets:tid()}).
-type state() :: #state{}.

%% Number of times to retry push. Matches value from older version of
%% `fcm-erlang'. Only used for the legacy API.
-define(RETRIES, 3).
-define(MP_SET(Key), Key => multiplatform_set(Key)).

-define(KEY_DATA, <<"data">>).
-define(KEY_NOTIFICATION, <<"notification">>).
-define(KEY_ANDROID, <<"android">>).
-define(KEY_APNS, <<"apns">>).

-define(KEY_APS, <<"aps">>).
-define(KEY_ALERT, <<"alert">>).

-define(KEYS_APS_HD(Header), [?KEY_APNS, <<"headers">>, Header]).
-define(KEYS_APS_PL, [?KEY_APNS, <<"payload">>, ?KEY_APS]).

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

-define(PAYLOAD_MAP_V1, #{<<"Alert">> => #{<<"Title">> => [?KEY_NOTIFICATION, <<"title">>]
                                          ,<<"Body">> => [?KEY_NOTIFICATION, <<"body">>]
                                          ,<<"Subtitle">> => ?KEYS_APS_PL ++ [?KEY_ALERT, <<"subtitle">>]
                                          ,?MP_SET(<<"Title-Key">>)
                                          ,?MP_SET(<<"Title-Params">>)
                                          ,?MP_SET(<<"Body-Key">>)
                                          ,?MP_SET(<<"Body-Params">>)
                                          }
                         ,<<"APNs">> => #{<<"Alert">> => #{<<"Subtitle-Key">> => ?KEYS_APS_PL ++ [?KEY_ALERT, <<"subtitle-loc-key">>]
                                                          ,<<"Subtitle-Params">> => ?KEYS_APS_PL ++ [?KEY_ALERT, <<"subtitle-loc-args">>]
                                                          }
                                         ,<<"Push-Type">> => ?KEYS_APS_HD(<<"apns-push-type">>)
                                         ,<<"Thread-ID">> => ?KEYS_APS_PL ++ [<<"thread-id">>]
                                         ,<<"Topic">> => ?KEYS_APS_HD(<<"apns-topic">>)
                                         }
                         ,<<"Badge">> => fun set_notification_count/2
                         ,?MP_SET(<<"Category">>)
                         ,?MP_SET(<<"Collapse-ID">>)
                         ,<<"Content-Available">> => fun set_content_available/2
                         ,<<"Content-Mutable">> => fun set_mutable_content/2
                         ,<<"FCM">> => #{<<"Android">> => #{<<"Channel-ID">> => [?KEY_ANDROID, ?KEY_NOTIFICATION, <<"channel_id">>]
                                                           ,<<"Color">> => [?KEY_ANDROID, ?KEY_NOTIFICATION, <<"color">>]
                                                           ,<<"Icon">> => [?KEY_ANDROID, ?KEY_NOTIFICATION, <<"icon">>]
                                                           ,<<"Tag">> => [?KEY_ANDROID, ?KEY_NOTIFICATION, <<"tag">>]
                                                           }}
                         ,<<"Priority">> => fun set_priority_v1/2
                         ,?MP_SET(<<"Sound">>)
                         ,<<"TTL">> => fun set_ttl_v1/3
                          %% For `push_req` backwards-compatibility
                         ,<<"Call-ID">> => [?KEY_DATA, <<"Call-ID">>]
                         }).

-type active_push_app() :: {push_app(), token_type()}.
-type maybe_active_push_app() :: active_push_app() | 'undefined'.

-type reg_id() :: kz_term:ne_binary().
-type fcm_response() :: fcm_response_legacy() | fcm_response_v1().
-type fcm_response_legacy() :: [{reg_id()
                                ,'ok' |
                                 {kz_term:ne_binary(), reg_id()} |
                                 kz_term:ne_binary()
                                },...] |
                               {'error'
                               ,'auth_error' | 'retry' | 'timeout' | kz_term:ne_binary()
                               }.
-type fcm_response_v1() :: [{reg_id()
                            ,{'ok', kz_term:ne_binary()} |
                             {'error', {non_neg_integer(), binary()}} | %% FCM errors
                             {'error', any()} %% `httpc' errors
                            },...].

-spec start_link() -> kz_types:startlink_ret().
start_link() ->
    gen_server:start_link({'local', ?SERVER}, ?MODULE, [],[]).

%%------------------------------------------------------------------------------
%% @doc Returns true if this service is enabled for the specified app. If either
%% legacy or V1 is enabled, consider the service as a whole enabled. Clients can
%% receive messages from V1 even if they previously got them from the legacy
%% API.
%% @end
%%------------------------------------------------------------------------------
-spec enabled(push_app_id()) -> boolean().
enabled(App) ->
    L = kapps_config:get_boolean(?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE, <<"enabled">>], 'true', App),
    V1 = kapps_config:get_boolean(?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE_V1, <<"enabled">>], 'true', App),
    L or V1.

%%------------------------------------------------------------------------------
%% @doc Send a push notification using this service.
%% @end
%%------------------------------------------------------------------------------
-spec push(kz_term:ne_binary(), push_app_id(), token_type(), kz_json:object()) -> pusher_result:t().
push(Token, TokenApp, TokenType, JObj) ->
    gen_server:call(?SERVER, {'push', Token, TokenApp, TokenType, JObj}).

-spec init([]) -> {'ok', state()}.
init([]) ->
    kz_log:put_callid(?MODULE),
    lager:debug("starting server"),
    {'ok', #state{tab=ets:new(?MODULE, [])}}.

-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call({'push', Token, TokenApp, TokenType, JObj}, _From, #state{tab=ETS}=State) ->
    kz_log:put_callid(JObj),
    ActivePushApp = get_fcm(TokenApp, TokenType, ETS),
    Reply = maybe_send_push_notification(ActivePushApp, Token, JObj),
    {'reply', Reply, State};
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
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
-spec maybe_send_push_notification(maybe_active_push_app(), reg_id(), kz_json:object()) -> pusher_result:t().
maybe_send_push_notification('undefined', _, _) ->
    lager:debug("no pid to send push"),
    pusher_result:internal_server_error(<<"No FCM connection">>);
maybe_send_push_notification({{Pid, Envelope}, ActiveTokenType}, TokenID, JObj) ->
    {CustomData, JObj1} = pusher_module_util:extract_custom_data(JObj),

    Message = build_message(JObj1, CustomData, Envelope, ActiveTokenType),

    lager:debug("pushing to ~p: ~s: ~p", [Pid, TokenID, Message]),

    Result = fcm:push(Pid, TokenID, Message, ?RETRIES),
    to_pusher_result(ActiveTokenType, Result).

%%------------------------------------------------------------------------------
%% @doc Build the FCM message payload.
%% @end
%%------------------------------------------------------------------------------
-spec build_message(kz_json:object(), kz_json:object(), map(), token_type()) -> map().
build_message(JObj, CustomData, Envelope, ActiveTokenType) ->
    FlatProps = kz_json:to_proplist(kz_json:flatten(JObj)),
    FlatData = kz_json:map(fun encode_objects/2, CustomData),
    Map = case ActiveTokenType of
              ?TOKEN_TYPE_FIREBASE -> ?PAYLOAD_MAP;
              ?TOKEN_TYPE_FIREBASE_V1 -> ?PAYLOAD_MAP_V1
          end,
    Message = pusher_module_util:build_payload(
                FlatProps, JObj, Map, #{?KEY_DATA => kz_json:to_map(FlatData)}
               ),
    kz_maps:merge(Message, Envelope).

%%------------------------------------------------------------------------------
%% @doc Encode objects within a `data' object, because FCM v1 does not accept
%% nested data. FCM legacy automatically JSON-encoded nested data, so this does
%% not affect the message received downstream.
%% @end
%%------------------------------------------------------------------------------
-spec encode_objects(kz_json:key(), kz_json:json_term()) -> {kz_json:key(), kz_json:json_term()}.
encode_objects(K, V) ->
    case kz_json:is_json_object(V) of
        'true' -> {K, kz_json:encode(V)};
        'false' -> {K, V}
    end.

-spec get_fcm(push_app_id(), token_type(), ets:tid()) -> maybe_active_push_app().
get_fcm(App, TokenType, ETS) ->
    case ets:lookup(ETS, {App, TokenType}) of
        [] -> maybe_load_fcm(App, TokenType, ETS);
        [{{App, TokenType}, Active}] -> Active
    end.

-spec maybe_load_fcm(push_app_id(), token_type(), ets:tid()) -> maybe_active_push_app().
maybe_load_fcm(App, TokenType, ETS) ->
    lager:debug("loading FCM config for ~s (type ~s)", [App, TokenType]),
    case maybe_start_pool(App, TokenType) of
        {'ok', Active} ->
            %% Map the requested app/token type to the FCM PID and which token
            %% type is actually to be used
            ets:insert(ETS, {{App, TokenType}, Active}),
            Active;
        {'error', 'not_found'} ->
            'undefined';
        {'error', Reason} ->
            lager:error("error loading FCM: ~p", [Reason]),
            'undefined'
    end.

-spec maybe_start_pool(push_app_id(), token_type()) -> kz_either:either(any(), active_push_app()).
maybe_start_pool(App, ?TOKEN_TYPE_FIREBASE_V1) ->
    %% Allow clients to opt-in early to exclusively V1 while legacy pool runs
    maybe_start_v1_pool(App);
maybe_start_pool(App, ?TOKEN_TYPE_FIREBASE) ->
    %% If legacy pool isn't started, try V1 in case it has been configured
    case maybe_start_v1_pool(App) of
        {'ok', _}=Ret -> Ret;
        {'error', 'not_found'} -> maybe_start_legacy_pool(App);
        {'error', _}=E -> E
    end.

-spec maybe_start_v1_pool(push_app_id()) -> kz_either:either(any(), active_push_app()).
maybe_start_v1_pool(App) ->
    case kapps_config:get_json(?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE_V1, <<"service_account">>], 'undefined', App) of
        'undefined' ->
            lager:debug("firebase pusher service_account for app ~s not found", [App]),
            {'error', 'not_found'};
        ServiceAccountData -> start_v1_pool(App, ServiceAccountData)
    end.

-spec maybe_start_legacy_pool(push_app_id()) -> kz_either:either(any(), active_push_app()).
maybe_start_legacy_pool(App) ->
    case kapps_config:get_ne_binary(?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE, <<"api_key">>], 'undefined', App) of
        'undefined' ->
            lager:debug("firebase pusher api_key for app ~s not found", [App]),
            {'error', 'not_found'};
        APIKey -> start_legacy_pool(App, APIKey)
    end.

-spec start_v1_pool(push_app_id(), kz_json:object()) -> kz_either:either(any(), active_push_app()).
start_v1_pool(App, ServiceAccountData) ->
    Name = pool_name(App, 'v1'),
    ServiceAccountBin = kz_json:encode(ServiceAccountData),
    EnvelopeJObj = kapps_config:get_json(?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE_V1, <<"headers">>], kz_json:new(), App),
    Envelope = kz_json:to_map(EnvelopeJObj),
    case fcm:start_pool_with_json_service_file_bin(Name, ServiceAccountBin) of
        {'ok', Pid} -> {'ok', {{Pid, Envelope}, ?TOKEN_TYPE_FIREBASE_V1}};
        {'error', {'already_started', Pid}} -> {'ok', {{Pid, Envelope}, ?TOKEN_TYPE_FIREBASE_V1}};
        {'error', _}=E -> E
    end.

-spec start_legacy_pool(push_app_id(), kz_term:ne_binary()) -> kz_either:either(any(), active_push_app()).
start_legacy_pool(App, APIKey) ->
    Name = pool_name(App, 'legacy'),
    EnvelopeJObj = kapps_config:get_json(?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE, <<"headers">>], kz_json:new(), App),
    Envelope = kz_json:to_map(EnvelopeJObj),
    case fcm:start_pool_with_api_key(Name, kz_term:to_list(APIKey)) of
        {'ok', Pid} -> {'ok', {{Pid, Envelope}, ?TOKEN_TYPE_FIREBASE}};
        {'error', {'already_started', Pid}} -> {'ok', {{Pid, Envelope}, ?TOKEN_TYPE_FIREBASE}};
        {'error', _}=E -> E
    end.

-spec pool_name(push_app_id(), 'v1' | 'legacy') -> atom().
pool_name(App, Version) ->
    kz_term:to_atom(<<"fcm_", (kz_term:to_binary(Version))/binary, "_", App/binary>>, 'true').

%%------------------------------------------------------------------------------
%% @doc Produce a setter for a key that sets a multiplatform value.
%% @end
%%------------------------------------------------------------------------------
-spec multiplatform_set(kz_term:ne_binary()) -> pusher_module_util:setter(any()).
multiplatform_set(Key) ->
    fun(V, Payload) ->
            Payload1 = kz_maps:put(multiplatform_set_key('android', Key), Payload, V),
            kz_maps:put(multiplatform_set_key('apns', Key), Payload1, V)
    end.

-spec multiplatform_set_key('android' | 'apns', kz_term:ne_binary()) -> kz_term:ne_binaries().
multiplatform_set_key('android', <<"Title-Key">>) ->
    [?KEY_ANDROID, ?KEY_NOTIFICATION, <<"title_loc_key">>];
multiplatform_set_key('android', <<"Title-Params">>) ->
    [?KEY_ANDROID, ?KEY_NOTIFICATION, <<"title_loc_args">>];
multiplatform_set_key('android', <<"Body-Key">>) ->
    [?KEY_ANDROID, ?KEY_NOTIFICATION, <<"body_loc_key">>];
multiplatform_set_key('android', <<"Body-Params">>) ->
    [?KEY_ANDROID, ?KEY_NOTIFICATION, <<"body_loc_args">>];
multiplatform_set_key('android', <<"Category">>) ->
    [?KEY_ANDROID, ?KEY_NOTIFICATION, <<"click_action">>];
multiplatform_set_key('android', <<"Collapse-ID">>) ->
    [?KEY_ANDROID, <<"collapse_key">>];
multiplatform_set_key('android', <<"Sound">>) ->
    [?KEY_ANDROID, ?KEY_NOTIFICATION, <<"sound">>];

multiplatform_set_key('apns', <<"Title-Key">>) ->
    ?KEYS_APS_PL ++ [?KEY_ALERT, <<"title-loc-key">>];
multiplatform_set_key('apns', <<"Title-Params">>) ->
    ?KEYS_APS_PL ++ [?KEY_ALERT, <<"title-loc-args">>];
multiplatform_set_key('apns', <<"Body-Key">>) ->
    ?KEYS_APS_PL ++ [?KEY_ALERT, <<"loc-key">>];
multiplatform_set_key('apns', <<"Body-Params">>) ->
    ?KEYS_APS_PL ++ [?KEY_ALERT, <<"loc-args">>];
multiplatform_set_key('apns', <<"Category">>) ->
    ?KEYS_APS_PL ++ [<<"category">>];
multiplatform_set_key('apns', <<"Collapse-ID">>) ->
    ?KEYS_APS_HD(<<"apns-collapse-id">>);
multiplatform_set_key('apns', <<"Sound">>) ->
    ?KEYS_APS_PL ++ [<<"sound">>].

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
%% @doc Set the home screen badge value.
%% @end
%%------------------------------------------------------------------------------
-spec set_notification_count(integer(), map()) -> map().
set_notification_count(NotificationCount, Payload) ->
    Payload1 = kz_maps:put([?KEY_ANDROID, ?KEY_NOTIFICATION, <<"notification_count">>]
                          ,Payload
                          ,kz_term:to_binary(NotificationCount)
                          ),
    kz_maps:put(?KEYS_APS_PL ++ [<<"badge">>], Payload1, NotificationCount).

%%------------------------------------------------------------------------------
%% @doc Set whether the notification should be delivered as a silent background
%% update on Apple platforms.
%% @end
%%------------------------------------------------------------------------------
-spec set_content_available(boolean(), map()) -> map().
set_content_available(ContentAvailable, Payload) ->
    kz_maps:put(?KEYS_APS_PL ++ [<<"content-available">>]
               ,Payload
               ,pm_apple:content_available(ContentAvailable)
               ).

%%------------------------------------------------------------------------------
%% @doc Set whether notification service app extensions on Apple platforms
%% should be able to modify the notification's content before delivery.
%% @end
%%------------------------------------------------------------------------------
-spec set_mutable_content(boolean(), map()) -> map().
set_mutable_content(MutableContent, Payload) ->
    kz_maps:put(?KEYS_APS_PL ++ [<<"mutable-content">>]
               ,Payload
               ,pm_apple:mutable_content(MutableContent)
               ).

%%------------------------------------------------------------------------------
%% @doc Set the message delivery priority.
%% @end
%%------------------------------------------------------------------------------
-spec set_priority(kz_term:ne_binary(), map()) -> map().
set_priority(PriorityBin, Payload) ->
    Priority = adjusted_priority(PriorityBin),
    Payload#{<<"priority">> => Priority}.

%%------------------------------------------------------------------------------
%% @doc Set the message delivery priority for an FCM v1 message.
%% @end
%%------------------------------------------------------------------------------
-spec set_priority_v1(kz_term:ne_binary(), map()) -> map().
set_priority_v1(PriorityBin, Payload) ->
    Payload1 = kz_maps:put([?KEY_ANDROID, <<"priority">>], Payload, adjusted_priority(PriorityBin)),
    kz_maps:put(?KEYS_APS_HD(<<"apns-priority">>), Payload1, pm_apple:apns_priority(PriorityBin)).

-spec adjusted_priority(kz_term:ne_binary()) -> kz_term:ne_binary().
adjusted_priority(<<"low">>) -> <<"normal">>;
adjusted_priority(Priority) -> Priority.

%%------------------------------------------------------------------------------
%% @doc Set time to live value.
%% @end
%%------------------------------------------------------------------------------
-spec set_ttl_v1(non_neg_integer(), kz_json:object(), map()) -> map().
set_ttl_v1(TTL, JObj, Payload) ->
    TTLBin = <<(kz_term:to_binary(TTL))/binary, "s">>,
    Payload1 = kz_maps:put([?KEY_ANDROID, <<"ttl">>], Payload, TTLBin),
    ApnsExpiration = pm_apple:apns_expiration(TTL, JObj),
    kz_maps:put(?KEYS_APS_HD(<<"apns-expiration">>), Payload1, ApnsExpiration).

%%------------------------------------------------------------------------------
%% @doc Convert an FCM response into a `pusher_result'. See
%% [https://firebase.google.com/docs/cloud-messaging/http-server-ref#interpret-downstream]
%% and
%% [https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages/send].
%% Results list length should always be 1 since we are only sending to one
%% registration ID at a time.
%% @end
%%------------------------------------------------------------------------------
-spec to_pusher_result(token_type(), fcm_response()) -> pusher_result:t().
to_pusher_result(?TOKEN_TYPE_FIREBASE, Response) ->
    to_pusher_result(Response);
to_pusher_result(?TOKEN_TYPE_FIREBASE_V1, Response) ->
    v1_resp_to_pusher_result(Response).

v1_resp_to_pusher_result([{_RegId, _MsgId}]) when is_binary(_MsgId) ->
    pusher_result:success();
v1_resp_to_pusher_result([{_RegId, {'error', {StatusCode, Result}}}]) ->
    ResultJObj = kz_json:decode(Result),
    Error = kz_json:get_json_value(<<"error">>, ResultJObj, kz_json:new()),
    pusher_result:new(StatusCode
                     ,kz_json:get_ne_binary_value(<<"status">>, Error)
                     ,kz_json:get_ne_binary_value(<<"message">>, Error)
                     );
v1_resp_to_pusher_result([{_RegId, {'error', Reason}}]) ->
    pusher_result:internal_server_error(kz_term:to_binary(Reason)).

to_pusher_result([{_RegId, Result}]) when Result =:= 'ok'; tuple_size(Result) =:= 2 ->
    pusher_result:success();
to_pusher_result([{_RegId, Error}]) ->
    {RespCode, ErrorMessage} = push_error_details(Error),
    pusher_result:new(RespCode, Error, ErrorMessage);
to_pusher_result({'error', 'auth_error'}) ->
    Message = <<"There was an error authenticating the sender account.">>,
    pusher_result:new(401, <<"Unauthorized">>, Message);
to_pusher_result({'error', 'retry'}) ->
    %% Request encountered an error, but `fcm' is going to back off/retry
    Message = <<"Message delivery will be retried later">>,
    pusher_result:new(202, <<"Accepted">>, Message);
to_pusher_result({'error', 'timeout'}) ->
    pusher_result:gateway_timeout(<<"Timed out communicating with FCM">>);
to_pusher_result({'error', Body}) ->
    pusher_result:bad_request(Body).

%%------------------------------------------------------------------------------
%% @doc Get the response code and error message corresponding to a legacy FCM
%% API response error. See
%% [https://firebase.google.com/docs/cloud-messaging/http-server-ref#error-codes].
%% @end
%%------------------------------------------------------------------------------
-spec push_error_details(kz_term:ne_binary()) -> {pos_integer(), kz_term:ne_binary()}.
push_error_details(<<"MissingRegistration">>) ->
    lager:error("missing registration ID in request"),
    {500, <<"Check that the request contains a registration token.">>};
push_error_details(<<"InvalidRegistration">>) ->
    %% Could be that the device doc was updated with an invalid token
    {200, <<"Check the format of the registration token you pass to the server.">>};
push_error_details(<<"NotRegistered">>) ->
    {200, <<"Remove this registration token and stop using it to send messages.">>};
push_error_details(<<"InvalidPackageName">>) ->
    {400, <<"Make sure the message was addressed to a registration token whose package name matches the value passed in the request.">>};
push_error_details(<<"MismatchSenderId">>) ->
    {400, <<"Not one of the senders allowed to send messages to this registration token">>};
push_error_details(<<"InvalidParameters">>) ->
    {400, <<"Check that the provided parameters have the right name and type.">>};
push_error_details(<<"MessageTooBig">>) ->
    {400, <<"Total size of the payload data included in the message exceeds FCM limits">>};
push_error_details(<<"InvalidDataKey">>) ->
    {400, <<"Check that the payload data does not contain a key that is used internally by FCM.">>};
push_error_details(<<"InvalidTtl">>) ->
    {400, <<"TTL must be between 0 and 2,419,200 seconds (4 weeks)">>};
push_error_details(<<"Unavailable">>) ->
    {500, <<"The server couldn't process the request in time.">>};
push_error_details(<<"InternalServerError">>) ->
    {500, <<"The server encountered an error while trying to process the request.">>};
push_error_details(<<"DeviceMessageRateExceeded">>) ->
    {429, <<"Rate of messages to the device is too high">>};
push_error_details(<<"TopicsMessageRateExceeded">>) ->
    {429, <<"Rate of messages to the topic is too high">>};
push_error_details(<<"InvalidApnsCredential">>) ->
    {400, <<"Missing or expired APNs authentication key">>}.
