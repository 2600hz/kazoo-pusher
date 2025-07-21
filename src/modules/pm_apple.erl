%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2025, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @author Daniel Finke <danielfinke2011@gmail.com>
%%% @end
%%%-----------------------------------------------------------------------------
-module(pm_apple).
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

%% Value formatters used by `pm_firebase' for multiplatform
-export([apns_priority/1
        ,apns_expiration/2
        ,content_available/1
        ,mutable_content/1
        ]).

-record(state, {tab :: ets:tid()}).
-type state() :: #state{}.

-define(KEY_APS, <<"aps">>).
-define(KEY_ALERT, <<"alert">>).

-define(HEADER_MAP, #{<<"APNs">> => #{<<"Push-Type">> => 'apns_push_type'
                                     ,<<"Topic">> => 'apns_topic'
                                     }
                     ,<<"Collapse-ID">> => 'apns_collapse_id'
                     ,<<"Priority">> => fun set_apns_priority/2
                     ,<<"TTL">> => fun set_apns_expiration/3
                     }).
-define(PAYLOAD_MAP, #{<<"Alert">> => #{<<"Title">> => [?KEY_APS, ?KEY_ALERT, <<"title">>]
                                       ,<<"Subtitle">> => [?KEY_APS, ?KEY_ALERT, <<"subtitle">>]
                                       ,<<"Body">> => [?KEY_APS, ?KEY_ALERT, <<"body">>]
                                       ,<<"Title-Key">> => [?KEY_APS, ?KEY_ALERT, <<"title-loc-key">>]
                                       ,<<"Title-Params">> => [?KEY_APS, ?KEY_ALERT, <<"title-loc-args">>]
                                       ,<<"Body-Key">> => [?KEY_APS, ?KEY_ALERT, <<"loc-key">>]
                                       ,<<"Body-Params">> => [?KEY_APS, ?KEY_ALERT, <<"loc-args">>]
                                       }
                      ,<<"APNs">> => #{<<"Alert">> => #{<<"Subtitle-Key">> => [?KEY_APS, ?KEY_ALERT, <<"subtitle-loc-key">>]
                                                       ,<<"Subtitle-Params">> => [?KEY_APS, ?KEY_ALERT, <<"subtitle-loc-args">>]
                                                       }
                                      ,<<"Thread-ID">> => [?KEY_APS, <<"thread-id">>]
                                      }
                      ,<<"Badge">> => [?KEY_APS, <<"badge">>]
                      ,<<"Category">> => [?KEY_APS, <<"category">>]
                      ,<<"Content-Available">> => fun set_content_available/2
                      ,<<"Content-Mutable">> => fun set_mutable_content/2
                      ,<<"Sound">> => [?KEY_APS, <<"sound">>]
                       %% For `push_req` backwards-compatibility
                      ,<<"Call-ID">> => [?KEY_APS, <<"call-id">>]
                      }).

-type header() :: 'apns_collapse_id' | 'apns_expiration' | 'apns_id' |
                  'apns_priority' | 'apns_push_type' | 'apns_topic'.
-type header_v() :: kz_term:ne_binary().
-type headers() :: #{header() => header_v()}.
-type headers_m(K) :: #{header() => header_v()
                       ,K := header_v()
                       }.

-type maybe_push_app() :: push_app() | 'undefined'.

-spec start_link() -> kz_types:startlink_ret().
start_link() ->
    gen_server:start_link({'local', ?SERVER}, ?MODULE, [],[]).

%%------------------------------------------------------------------------------
%% @doc Returns true if this service is enabled for the specified app.
%% @end
%%------------------------------------------------------------------------------
-spec enabled(push_app_id()) -> boolean().
enabled(App) ->
    kapps_config:get_boolean(?CONFIG_CAT, [?TOKEN_TYPE_APPLE, <<"enabled">>], 'true', App).

%%------------------------------------------------------------------------------
%% @doc Send a push notification using this service.
%% @end
%%------------------------------------------------------------------------------
-spec push(kz_term:ne_binary(), push_app_id(), token_type(), kz_json:object()) -> pusher_result:t().
push(Token, TokenApp, _TokenType, JObj) ->
    gen_server:call(?SERVER, {'push', Token, TokenApp, JObj}).

-spec init([]) -> {'ok', state()}.
init([]) ->
    kz_log:put_callid(?MODULE),
    {'ok', #state{tab=ets:new(?MODULE, [])}}.

-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call({'push', Token, TokenApp, JObj}, _From, #state{tab=ETS}=State) ->
    kz_log:put_callid(JObj),
    Reply = maybe_send_push_notification(get_apns(TokenApp, ETS), Token, TokenApp, JObj),
    {'reply', Reply, State};
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast('stop', State) ->
    {'stop', 'normal', State};
handle_cast(_Msg, State) ->
    lager:debug_unsafe("unhandled cast => ~p", [_Msg]),
    {'ok', State}.

-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info({'connection_up', Pid}, State) ->
    lager:debug("connection ~p up", [Pid]),
    {'noreply', State};
handle_info({'reconnecting', Pid}, State) ->
    lager:debug("connection ~p reconnecting", [Pid]),
    {'noreply', State};
handle_info({'DOWN', Ref, 'process', Pid, Reason}, #state{tab=ETS}=State) ->
    _ = case ets:lookup(ETS, Ref) of
            [{Ref, App}] ->
                lager:warning("received down message for ~s / ~p / ~p => ~p", [App, Pid, Ref, Reason]),
                ets:delete(ETS, Ref),
                ets:delete(ETS, App),
                erlang:send_after(?MILLISECONDS_IN_SECOND * 5, self(), {'reload', App});
            _ ->
                lager:critical("app not found")
        end,
    {'noreply', State};
handle_info({'reload', App}, #state{tab=ETS}=State) ->
    _ = reload_apns(App, ETS),
    {'noreply', State};
handle_info(_Msg, State) ->
    lager:debug_unsafe("unhandled message => ~p", [_Msg]),
    {'noreply', State}.

-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, #state{tab=ETS}) ->
    apns:stop(),
    ets:delete(ETS),
    'ok'.

-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Format headers for logging.
%% @end
%%------------------------------------------------------------------------------
-spec log_headers(map()) -> binary().
log_headers(Headers) ->
    kz_binary:join([list_to_binary([kz_term:to_binary(K), "=", kz_term:to_binary(V)]) || {K, V} <- maps:to_list(Headers)],<<",">>).

%%------------------------------------------------------------------------------
%% @doc Send the push notification if a connection is established to APNs.
%% @end
%%------------------------------------------------------------------------------
-spec maybe_send_push_notification(maybe_push_app()
                                  ,kz_term:ne_binary()
                                  ,kz_term:ne_binary()
                                  ,kz_json:object()
                                  ) -> pusher_result:t().
maybe_send_push_notification('undefined', _, _, _) ->
    pusher_result:internal_server_error(<<"No APNs connection">>);
maybe_send_push_notification({Pid, ExtraHeaders}, Token, TokenApp, JObj) ->
    JObj1 = maybe_set_apns_topic(TokenApp, JObj),
    {CustomData, JObj2} = pusher_module_util:extract_custom_data(JObj1),

    FlatProps = kz_json:to_proplist(kz_json:flatten(JObj2)),
    MsgId = kz_api:msg_id(JObj2),

    Headers = build_headers(FlatProps, JObj2, MsgId, ExtraHeaders),
    Msg = build_payload(FlatProps, JObj2, kz_json:to_map(CustomData)),

    lager:debug_unsafe("pushing for token ~s (headers: ~s): ~s"
                      ,[Token
                       ,log_headers(Headers)
                       ,kz_json:encode(kz_json:from_map(Msg))
                       ]),
    try
        Result = apns:push_notification(Pid, Token, Msg, Headers),
        lager:debug("apns result for ~s : ~p", [TokenApp, Result]),
        to_pusher_result(Result)
    catch
        Type:Reason:_ST ->
            lager:error_unsafe("PUBLISH ERROR => ~p / ~p", [Type, Reason]),
            ?LOGSTACK(_ST),
            pusher_result:internal_server_error(<<"Failed to push notification">>)
    end.

%%------------------------------------------------------------------------------
%% @doc Build the APNs message headers, merging in the AMQP `MsgId' and any
%% header overrides specified in the token app.
%% @end
%%------------------------------------------------------------------------------
-spec build_headers(kz_json:flat_proplist()
                   ,kz_json:object()
                   ,kz_term:ne_binary()
                   ,map()
                   ) -> map().
build_headers(FlatProps, JObj, MsgId, ExtraHeaders) ->
    Headers = pusher_module_util:build_payload(FlatProps, JObj, ?HEADER_MAP, #{}),
    %% APNs only accepts a canonical 8-4-4-4-12 UUID for `apns-id', returns a
    %% `400' for other formats
    Headers1 = case kz_term:is_rfc4122_uuid(MsgId) of
                   'true' -> Headers#{apns_id => MsgId};
                   'false' ->
                       %% Leave APNs to generate the `apns-id' and return it in
                       %% the result
                       Headers
               end,
    kz_maps:merge(Headers1, ExtraHeaders).

%%------------------------------------------------------------------------------
%% @doc Build the APNs message payload.
%% @end
%%------------------------------------------------------------------------------
-spec build_payload(kz_json:flat_proplist()
                   ,kz_json:object()
                   ,pusher_module_util:payload(kz_json:key())
                   ) -> pusher_module_util:payload(kz_json:key()).
build_payload(FlatProps, JObj, CustomData) ->
    pusher_module_util:build_payload(FlatProps, JObj, ?PAYLOAD_MAP, CustomData).

-spec reload_apns(kz_term:ne_binary(), ets:tid()) -> 'ok' | reference().
reload_apns(App, ETS) ->
    case get_apns(App, ETS) of
        'undefined' -> erlang:send_after(?MILLISECONDS_IN_SECOND * 5, self(), {'reload', App});
        _Push -> 'ok'
    end.

-spec get_apns(kz_term:ne_binary(), ets:tid()) -> maybe_push_app().
get_apns(App, ETS) ->
    case ets:lookup(ETS, App) of
        [] -> maybe_load_apns(App, ETS);
        [{App, Push}] -> Push
    end.

-spec maybe_load_apns(kz_term:ne_binary(), ets:tid()) -> maybe_push_app().
maybe_load_apns(App, ETS) ->
    CertBin = kapps_config:get_ne_binary(?CONFIG_CAT, [?TOKEN_TYPE_APPLE, <<"certificate">>], 'undefined', App),
    Host = kapps_config:get_ne_binary(?CONFIG_CAT, [?TOKEN_TYPE_APPLE, <<"host">>], ?DEFAULT_APNS_HOST, App),
    ExtraHeaders = kapps_config:get_json(?CONFIG_CAT, [?TOKEN_TYPE_APPLE, <<"headers">>], kz_json:new(), App),
    Headers = kz_maps:keys_to_atoms(kz_json:to_map(ExtraHeaders)),
    maybe_load_apns(App, ETS, CertBin, Host, Headers).

-spec maybe_load_apns(kz_term:ne_binary()
                     ,ets:tid()
                     ,kz_term:api_ne_binary()
                     ,kz_term:ne_binary()
                     ,map()
                     ) -> maybe_push_app().
maybe_load_apns(App, _, 'undefined', _, _) ->
    lager:debug("apple pusher certificate for app ~s not found", [App]),
    'undefined';
maybe_load_apns(App, ETS, CertBin, Host, Headers) ->
    {Key, Cert} = pusher_util:binary_to_keycert(CertBin),
    lager:debug("starting apple push connection for ~s : ~s", [App, Host]),
    Connection = #{name => kz_term:to_atom(<<"apns_", App/binary>>, 'true')
                  ,apple_host => kz_term:to_list(Host)
                  ,apple_port => 443
                  ,type => 'certdata'
                  ,certdata => Cert
                  ,keydata => Key
                  ,timeout => 10000
                  ,options => #{transport => tls
                               ,trace => false
                               ,http2_opts => #{keepalive => ?MILLISECONDS_IN_MINUTE  * 15}
                               }
                  },
    try apns:connect(Connection) of
        {'ok', Pid} ->
            ets:insert(ETS, {App, {Pid, Headers}}),
            Ref = erlang:monitor(process, Pid),
            ets:insert(ETS, {Ref, App}),
            {Pid, Headers};
        {'error', {'already_started', Pid}} ->
            apns:close_connection(Pid),
            maybe_load_apns(App, ETS, CertBin, Host, Headers);
        {'error', Reason} ->
            lager:error("error loading apns ~p", [Reason]),
            'undefined'
    catch
        ?CATCH(_Er, _Ex,_ST) ->
            lager:error("error loading apns ~p / ~p", [_Er, _Ex]),
            ?LOGSTACK(_ST),
            undefined
    end.

%%------------------------------------------------------------------------------
%% @doc Set the APNs topic on the push req if unspecified.
%% @end
%%------------------------------------------------------------------------------
-spec maybe_set_apns_topic(kz_term:ne_binary(), kz_json:object()) -> kz_json:object().
maybe_set_apns_topic(TokenApp, JObj) ->
    kz_json:insert_value([<<"APNs">>, <<"Topic">>], apns_topic(TokenApp), JObj).

-spec apns_topic(kz_term:ne_binary()) -> kz_term:ne_binary().
apns_topic(TokenApp) ->
    case kapps_config:get_ne_binary(<<"pusher">>
                                   ,[?TOKEN_TYPE_APPLE, <<"apns_topic">>]
                                   ,'undefined'
                                   ,TokenApp
                                   )
    of
        'undefined' -> default_apns_topic(TokenApp);
        APNsTopic -> APNsTopic
    end.

%% Retains the old behaviour
-spec default_apns_topic(kz_term:ne_binary()) -> binary().
default_apns_topic(TokenApp) ->
    re:replace(TokenApp, <<"\\.(?:dev|prod)$">>, <<>>, [{'return', 'binary'}]).

%%------------------------------------------------------------------------------
%% @doc Set the `apns-priority' header.
%% @end
%%------------------------------------------------------------------------------
-spec set_apns_priority(kz_term:ne_binary(), headers()) -> headers_m('apns_priority').
set_apns_priority(PriorityBin, Headers) ->
    Headers#{apns_priority => apns_priority(PriorityBin)}.

-spec apns_priority(kz_term:ne_binary()) -> kz_term:ne_binary().
apns_priority(PriorityBin) ->
    kz_term:to_binary(apns_priority_int(PriorityBin)).

-spec apns_priority_int(kz_term:ne_binary()) -> 1 | 5 | 10.
apns_priority_int(<<"low">>) -> 1;
apns_priority_int(<<"normal">>) -> 5;
apns_priority_int(<<"high">>) -> 10.

%%------------------------------------------------------------------------------
%% @doc Set the `apns-expiration' header. A value of `0' tells APNs to only try
%% delivery once.
%% @end
%%------------------------------------------------------------------------------
-spec set_apns_expiration(integer(), kz_json:object(), headers()) -> headers_m('apns_expiration').
set_apns_expiration(TTL, JObj, Headers) ->
    Headers#{apns_expiration => apns_expiration(TTL, JObj)}.

-spec apns_expiration(integer(), kz_json:object()) -> kz_term:ne_binary().
apns_expiration(TTL, JObj) ->
    kz_term:to_binary(apns_expiration_int(TTL, JObj)).

-spec apns_expiration_int(integer(), kz_json:object()) -> integer().
apns_expiration_int(0, _) -> 0;
apns_expiration_int(TTL, JObj) ->
    pusher_util:timestamp_ms(JObj) div 1000 + TTL.

%%------------------------------------------------------------------------------
%% @doc Set whether the notification should be delivered as a silent background
%% update.
%% @end
%%------------------------------------------------------------------------------
-spec set_content_available(boolean(), map()) -> map().
set_content_available(ContentAvailable, Payload) ->
    kz_maps:put([?KEY_APS, <<"content-available">>]
               ,Payload
               ,content_available(ContentAvailable)
               ).

-spec content_available(boolean()) -> 0 | 1.
content_available(ContentAvailable) -> to_integer(ContentAvailable).

%%------------------------------------------------------------------------------
%% @doc Set whether a notification service app extensions should be able to
%% modify the notification's content before delivery.
%% @end
%%------------------------------------------------------------------------------
-spec set_mutable_content(boolean(), map()) -> map().
set_mutable_content(MutableContent, Payload) ->
    kz_maps:put([?KEY_APS, <<"mutable-content">>]
               ,Payload
               ,mutable_content(MutableContent)
               ).

-spec mutable_content(boolean()) -> 0 | 1.
mutable_content(MutableContent) -> to_integer(MutableContent).

%%------------------------------------------------------------------------------
%% @doc Convert an APNs response into a `pusher_result'.
%% @end
%%------------------------------------------------------------------------------
-spec to_pusher_result(apns:response()) -> pusher_result:t().
to_pusher_result({200, _, _}) -> pusher_result:success();
to_pusher_result({RespCode, _, Data}) ->
    Reason = props:get_ne_binary_value(<<"reason">>, Data),
    ErrorMessage = push_error_message(Reason),
    case resp_code_override(Reason) of
        'undefined' ->
            pusher_result:new(RespCode, Reason, ErrorMessage);
        RespCodeOverride ->
            pusher_result:new(RespCodeOverride, Reason, ErrorMessage)
    end;
to_pusher_result('timeout') ->
    pusher_result:gateway_timeout(<<"Timed out communicating with APNs">>).

%%------------------------------------------------------------------------------
%% @doc Get the error message corresponding to an APNs response error code. See
%% [https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/handling_notification_responses_from_apns].
%% @end
%%------------------------------------------------------------------------------
-spec push_error_message(kz_term:ne_binary()) -> kz_term:ne_binary().
push_error_message(<<"BadCollapseId">>) ->
    <<"The collapse identifier exceeds the maximum allowed size.">>;
push_error_message(<<"BadDeviceToken">>) -> <<"The specified device token is invalid.">>;
push_error_message(<<"BadExpirationDate">>) -> <<"The TTL value is invalid.">>;
push_error_message(<<"BadMessageId">>) -> <<"The `apns-id` value is invalid.">>;
push_error_message(<<"BadPriority">>) -> <<"The priority value is invalid.">>;
push_error_message(<<"BadTopic">>) -> <<"The APNs topic value is invalid.">>;
push_error_message(<<"DeviceTokenNotForTopic">>) ->
    <<"The device token doesn't match the specified topic.">>;
push_error_message(<<"DuplicateHeaders">>) -> <<"One or more headers are repeated.">>;
push_error_message(<<"IdleTimeout">>) -> <<"Idle timeout.">>;
push_error_message(<<"InvalidPushType">>) -> <<"The APNs push type value is invalid.">>;
push_error_message(<<"MissingDeviceToken">>) ->
    <<"The device token isn't specified in the request.">>;
push_error_message(<<"MissingTopic">>) ->
    <<"The APNs topic header of the request isn't specified and is required.">>;
push_error_message(<<"PayloadEmpty">>) -> <<"The message payload is empty.">>;
push_error_message(<<"TopicDisallowed">>) -> <<"Pushing to this topic is not allowed.">>;
push_error_message(<<"BadCertificate">>) -> <<"The certificate is invalid.">>;
push_error_message(<<"BadCertificateEnvironment">>) ->
    <<"The client certificate is for the wrong environment.">>;
push_error_message(<<"ExpiredProviderToken">>) ->
    <<"The provider token is stale and a new token should be generated.">>;
push_error_message(<<"Forbidden">>) -> <<"The specified action is not allowed.">>;
push_error_message(<<"InvalidProviderToken">>) ->
    <<"The provider token is not valid, or the token signature can't be verified.">>;
push_error_message(<<"MissingProviderToken">>) ->
    <<"The `authorization` header is missing or no provider token is specified.">>;
push_error_message(<<"BadPath">>) -> <<"The request contained an invalid path value.">>;
push_error_message(<<"MethodNotAllowed">>) -> <<"The specified method value isn't `POST`.">>;
push_error_message(<<"ExpiredToken">>) -> <<"The device token has expired.">>;
push_error_message(<<"Unregistered">>) ->
    <<"The device token is inactive for the specified topic.">>;
push_error_message(<<"PayloadTooLarge">>) -> <<"The message payload is too large.">>;
push_error_message(<<"TooManyProviderTokenUpdates">>) ->
    <<"The provider's authentication token is being updated too often.">>;
push_error_message(<<"TooManyRequests">>) ->
    <<"Too many requests were made consecutively to the same device token.">>;
push_error_message(<<"InternalServerError">>) -> <<"An internal server error occurred.">>;
push_error_message(<<"ServiceUnavailable">>) -> <<"The service is unavailable.">>;
push_error_message(<<"Shutdown">>) -> <<"The APNs server is shutting down.">>.

%%------------------------------------------------------------------------------
%% @doc Get an overridden response code from an APNs response error code when
%% there is a more appropriate one for returning to the push notification
%% requestor. For example, some can be overridden with 500s, since they would
%% indicate issues with the `pusher' implementation.
%% @end
%%------------------------------------------------------------------------------
-spec resp_code_override(kz_term:ne_binary()) -> kz_term:api_pos_integer().
resp_code_override(<<"DuplicateHeaders">>) ->
    lager:error("duplicate headers included in request"),
    500;
resp_code_override(<<"IdleTimeout">>) ->
    500;
resp_code_override(<<"BadPath">>) ->
    lager:error("request contained invalid `:path` value"),
    500;
resp_code_override(<<"MethodNotAllowed">>) ->
    lager:error("request method was not `POST`"),
    500;
resp_code_override(_) -> 'undefined'.

-spec to_integer(boolean()) -> 0 | 1.
to_integer('true') -> 1;
to_integer('false') -> 0.
