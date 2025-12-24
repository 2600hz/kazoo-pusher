%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2013-2025, 2600Hz
%%% @doc
%%% @author Luis Azedo
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(pusher_listener).

-behaviour(gen_listener).

-export([push/1
        ]).

-export([start_link/0
        ,handle_endpoint_push/2
        ,handle_push/2
        ,handle_reg_success/2
        ]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,terminate/2
        ,code_change/3
        ]).

-ifdef(TEST).
-export([to_endpoint_push_req/2]).
-endif.

-include("pusher.hrl").
-include_lib("kazoo_sip/include/kzsip_uri.hrl").

-define(SERVER, ?MODULE).

-type state() :: 'ok'.

%% By convention, we put the options here in macros, but not required.
-define(BINDINGS, [{'self', []}
                  ,{'pusher', []}
                  ,{'registration', [{'restrict_to',['reg_success']}]}
                  ]).
-define(RESPONDERS, [{{?MODULE, 'handle_endpoint_push'}
                     ,[{<<"notification">>, <<"endpoint_push_req">>}]
                     }
                    ,{{?MODULE, 'handle_push'}
                     ,[{<<"notification">>, <<"push_req">>}]
                     }
                    ,{{?MODULE, 'handle_reg_success'}
                     ,[{<<"directory">>, <<"reg_success">>}]
                     }
                    ]).

-define(QUEUE_NAME, <<"pusher_shared_listener">>).
-define(QUEUE_OPTIONS, [{'exclusive', 'false'}]).
-define(CONSUME_OPTIONS, [{'exclusive', 'false'}]).

-type maybe_pm_module() :: module() | 'undefined'.
-type endpoint_id() :: kz_term:ne_binary().
-type endpoint_type() :: 'device' | 'user'.
%% A tuple containing a token, token app, and token type.
-type push_props() :: {kz_term:api_ne_binary(), kz_term:api_ne_binary(), token_type() | 'undefined'}.

-type device_fetch_error() :: {endpoint_id()
                              ,kz_datamgr:data_errors() | 'invalid_parameters'
                              }.
-type device_fetch_result() :: kz_either:either(device_fetch_error(), kzd_devices:doc()).
-type device_fetch_results() :: [device_fetch_result()].
-type pusher_results() :: [pusher_result:identified_t()].

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Handle a request to push to an endpoint.
%% @end
%%------------------------------------------------------------------------------
-spec handle_endpoint_push(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_endpoint_push(JObj, _Props) ->
    kz_log:put_callid(JObj),
    'true' = kapi_pusher:endpoint_push_req_v(JObj),
    JObj1 = add_timestamp_to_req(JObj),
    DeviceResults = fetch_devices(JObj1),
    Results = push_to_devices(JObj1, DeviceResults),
    maybe_publish_endpoint_push_resp(JObj, Results).

%%------------------------------------------------------------------------------
%% @doc Handle a legacy request to push to a push-enabled device.
%% @end
%%------------------------------------------------------------------------------
-spec handle_push(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_push(JObj, _Props) ->
    kz_log:put_callid(JObj),
    'true' = kapi_pusher:push_req_v(JObj),
    PushProps = {_, _, TokenType} = push_props(JObj),
    JObj1 = to_endpoint_push_req(JObj, pm_module(TokenType)),
    _ = maybe_push_to_target(JObj1, PushProps),
    'ok'.

-spec pm_module(kz_term:api_ne_binary()) -> maybe_pm_module().
pm_module(<<"google">>) -> pm_module(?TOKEN_TYPE_FIREBASE);
pm_module(<<"android">>) -> pm_module(?TOKEN_TYPE_FIREBASE);
pm_module(?TOKEN_TYPE_APPLE) -> 'pm_apple';
pm_module(?TOKEN_TYPE_FIREBASE) -> 'pm_firebase';
pm_module(?TOKEN_TYPE_FIREBASE_V1) -> 'pm_firebase';
pm_module(_) -> 'undefined'.

-spec add_timestamp_to_req(kz_json:object()) -> kz_json:object().
add_timestamp_to_req(JObj) ->
    kz_json:insert_value(?KEY_TIMESTAMP_MS, os:system_time('millisecond'), JObj).

-spec handle_reg_success(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_reg_success(JObj, _Props) ->
    UserAgent = kz_json:get_value(<<"User-Agent">>, JObj),
    UserAgentProperties = pusher_util:user_agent_push_properties(UserAgent),
    maybe_process_reg_success(UserAgentProperties, JObj).

-spec maybe_process_reg_success(kz_term:api_object(), kz_json:object()) -> 'ok'.
maybe_process_reg_success('undefined', _JObj) -> 'ok';
maybe_process_reg_success(UA, JObj) ->
    Contact = kz_json:get_value(<<"Contact">>, JObj),
    [#uri{opts=A, ext_opts=B}] = kzsip_uri:uris(Contact),
    Params = A ++ B,
    TokenKey = kz_json:get_value(?TOKEN_KEY, UA),
    Token = props:get_value(TokenKey, Params),
    maybe_process_reg_success(Token, add_proxy_keys(UA), JObj, Params).

add_proxy_keys(UA) ->
    KVs = [{<<"Token-Proxy">>, ?TOKEN_PROXY_KEY}
          ,{<<"Token-Public-Proxy">>, ?TOKEN_PUBLIC_PROXY_KEY}
          ],
    kz_json:set_values(KVs, UA).

-spec maybe_process_reg_success(kz_term:api_binary(), kz_json:object(), kz_json:object(), kz_term:proplist()) -> 'ok'.
maybe_process_reg_success('undefined', _UA, _JObj, _Params) -> 'ok';
maybe_process_reg_success(_Token, UA, JObj, Params) ->
    maybe_update_push_token(UA, JObj, Params).

-spec maybe_update_push_token(kz_json:object(), kz_json:object(), kz_term:proplist()) -> 'ok'.
maybe_update_push_token(UA, JObj, Params) ->
    AccountId = kz_json:get_first_defined([[<<"Custom-Channel-Vars">>, <<"Account-ID">>]
                                          ,<<"Account-ID">>
                                          ], JObj),
    AuthorizingId = kz_json:get_first_defined([[<<"Custom-Channel-Vars">>, <<"Authorizing-ID">>]
                                              ,<<"Authorizing-ID">>
                                              ], JObj),
    maybe_update_push_token(AccountId, AuthorizingId, UA, JObj, Params).

-spec maybe_update_push_token(kz_term:api_binary(), kz_term:api_binary(), kz_json:object(), kz_json:object(), kz_term:proplist()) -> 'ok'.
maybe_update_push_token('undefined', _AuthorizingId, _UA, _JObj, _Params) -> 'ok';
maybe_update_push_token(_AccountId, 'undefined', _UA, _JObj, _Params) -> 'ok';
maybe_update_push_token(AccountId, AuthorizingId, UA, JObj, Params) ->
    AccountDb = kzs_util:format_account_db(AccountId),
    case kz_datamgr:open_cache_doc(AccountDb, AuthorizingId) of
        {'ok', Doc} ->
            Push = kzd_devices:push(Doc),
            NewPush = build_push(UA, JObj, Params, kz_json:new()),
            case kz_json:are_equal(Push, NewPush) of
                'true' ->
                    lager:debug("push not changed : ~s", [kz_json:encode(Push)]);
                'false' ->
                    lager:debug("setting push object for ~s: ~s: ~s", [AccountId, AuthorizingId, kz_json:encode(NewPush)]),
                    case kz_datamgr:save_doc(AccountDb, kzd_devices:set_push(Doc, NewPush)) of
                        {'ok', _} -> lager:debug("push object for ~s: ~s updated successfuly", [AccountId, AuthorizingId]);
                        {'error', _Err} -> lager:warning("push object for ~s: ~s was not updated => ~p", [AccountId, AuthorizingId, _Err])
                    end
            end;
        {'error', _} -> lager:debug("failed to open ~s in ~s", [AuthorizingId, AccountId])
    end.

-spec build_push(kz_json:object(), kz_json:object(), kz_term:proplist(), kz_json:object()) ->
          kz_json:object().
build_push(UA, JObj, Params, InitialAcc) ->
    kz_json:foldl(
      fun(K, V, Acc) ->
              build_push_fold(K, V, Acc, JObj, Params)
      end, InitialAcc, UA).

-spec build_push_fold(kz_json:path(), kz_json:json_term(), kz_json:object(), kz_json:object(), kz_term:proplist()) -> kz_json:object().
build_push_fold(K, V, Acc, JObj, Params) ->
    case props:get_value(V, Params) of
        'undefined' ->
            case kz_json:get_value(V, JObj) of
                'undefined' -> Acc;
                V1 -> kz_json:set_value(K, kz_http_util:urldecode(V1), Acc)
            end;
        V2 -> kz_json:set_value(K, kz_http_util:urldecode(V2), Acc)
    end.

%%------------------------------------------------------------------------------
%% @doc Starts the server.
%% @end
%%------------------------------------------------------------------------------
-spec start_link() -> kz_types:startlink_ret().
start_link() ->
    Options = [{'bindings', ?BINDINGS}
              ,{'responders', ?RESPONDERS}
              ,{'queue_name', ?QUEUE_NAME}       % optional to include
              ,{'queue_options', ?QUEUE_OPTIONS} % optional to include
              ,{'consume_options', ?CONSUME_OPTIONS} % optional to include
              ],
    gen_listener:start_link({'local', ?SERVER}, ?MODULE, Options, []).

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
    lager:debug("pusher_listener started"),
    {'ok', 'ok'}.

%%------------------------------------------------------------------------------
%% @doc Handling call messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast({'kz_amqp_channel',{'new_channel',_IsNew}}, State) ->
    {'noreply', State};
handle_cast({'gen_listener',{'created_queue',_Queue}}, State) ->
    {'noreply', State};
handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};
handle_cast({'push', JObj}, State) ->
    handle_push(JObj, []),
    {'noreply', State};
handle_cast({'reg',JObj}, State) ->
    lager:debug("handle_cast_reg ~p",[JObj]),
    {'noreply', State};
handle_cast(_Msg, State) ->
    lager:debug("unhandled cast: ~p", [_Msg]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info({'DOWN', _Ref, 'process', _Pid, _R}, State) ->
    {'noreply', State};
handle_info(_Info, State) ->
    lager:debug("unhandled msg: ~p", [_Info]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Allows listener to pass options to handlers.
%% @end
%%------------------------------------------------------------------------------
-spec handle_event(kz_json:object(), state()) -> gen_listener:handle_event_return().
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
    lager:debug("pusher listener terminating: ~p", [_Reason]).

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
%% @doc Fetch the list of devices referred to by an endpoint object.
%% @end
%%------------------------------------------------------------------------------
-spec fetch_devices(kz_json:object()) -> device_fetch_results().
fetch_devices(JObj) ->
    AccountId = kz_api:account_id(JObj),
    EndpointId = kz_json:get_ne_binary_value([<<"Endpoint">>, <<"ID">>], JObj),
    EndpointType = endpoint_type(JObj),
    fetch_devices(AccountId, EndpointId, EndpointType).

-spec fetch_devices(kz_term:ne_binary(), endpoint_id(), endpoint_type()) ->
          device_fetch_results().
fetch_devices(AccountId, DeviceId, 'device') ->
    case kzd_devices:fetch(AccountId, DeviceId) of
        {'ok', Device} -> [{'ok', Device}];
        {'error', 'not_found'} ->
            lager:info("device '~s' in account '~s' was not found"
                      ,[DeviceId, AccountId]
                      ),
            %% Not treating missing device as an error - device might have been
            %% deleted since req was submitted
            [];
        {'error', E} ->
            lager:error("failed to fetch device '~s' in account '~s': ~p"
                       ,[DeviceId, AccountId, E]
                       ),
            [{'error', {DeviceId, E}}]
    end;
fetch_devices(AccountId, UserId, 'user') ->
    Devices = kz_attributes:owned_by_docs(UserId, <<"device">>, AccountId),
    [{'ok', Device} || Device <- Devices].

%%------------------------------------------------------------------------------
%% @doc Get the endpoint type from a push request.
%% @end
%%------------------------------------------------------------------------------
-spec endpoint_type(kz_json:object()) -> endpoint_type().
endpoint_type(JObj) ->
    case kz_json:get_ne_binary_value([<<"Endpoint">>, <<"Type">>], JObj) of
        <<"device">> -> 'device';
        <<"user">> -> 'user'
    end.

%%------------------------------------------------------------------------------
%% @doc Push to a list of devices. Errors in fetching devices are propagated
%% through. Devices without push configuration are ignored.
%% @end
%%------------------------------------------------------------------------------
-spec push_to_devices(kz_json:object(), device_fetch_results()) -> pusher_results().
push_to_devices(JObj, DeviceResults) ->
    [kz_either:cata(DeviceResult
                   ,fun to_push_error/1
                   ,fun(Device) -> maybe_push_to_device(JObj, Device) end
                   )
     || DeviceResult <- DeviceResults
    ].

-spec to_push_error(device_fetch_error()) -> pusher_result:identified_t().
to_push_error({DeviceId, FetchError}) ->
    Message = kz_term:to_binary(io_lib:format("~p", [FetchError])),
    pusher_result:identify(DeviceId
                          ,pusher_result:internal_server_error(Message)
                          ).

-spec maybe_push_to_device(kz_json:object(), kzd_devices:doc()) -> pusher_result:identified_t().
maybe_push_to_device(JObj, Device) ->
    Result = case kzd_devices:push(Device) of
                 'undefined' ->
                     %% Ignore devices that aren't configured for push
                     pusher_result:success(<<"Not push device">>);
                 Push -> maybe_push_to_target(add_kazoo_device_id(JObj, Device), push_props(Push))
             end,
    pusher_result:identify(kz_doc:id(Device), Result).

%%------------------------------------------------------------------------------
%% @doc Push to a push-enabled target using token information. Token information
%% is validated before sending the push.
%% @end
%%------------------------------------------------------------------------------
-spec maybe_push_to_target(kz_json:object(), push_props()) -> pusher_result:t().
maybe_push_to_target(_, {Token, TokenApp, TokenType}) when Token =:= 'undefined';
                                                           TokenApp =:= 'undefined';
                                                           TokenType =:= 'undefined' ->
    lager:error("missing mandatory push properties"),
    pusher_result:bad_request(<<"Missing mandatory push properties">>);
maybe_push_to_target(JObj, {Token, TokenApp, TokenType}) ->
    Module = pm_module(TokenType),
    AppEnabled = app_enabled(TokenApp, Module),
    lager:info("received push ~s / ~s / ~s", [TokenType, TokenApp, Token]),

    case Module of
        'undefined' ->
            lager:error("pm module not available for token type ~s", [TokenType]),
            pusher_result:bad_request(<<"Token type unknown">>);
        _ when not AppEnabled ->
            lager:debug("app ~s is disabled for token type ~s", [TokenApp, TokenType]),
            pusher_result:success(<<"App disabled">>);
        _ ->
            lager:debug("pushing for token ~s(~s) to module ~s", [Token, TokenType, Module]),
            Module:push(Token, TokenApp, TokenType, JObj)
    end.

%%------------------------------------------------------------------------------
%% @doc Convert a legacy push req into an endpoint push req. Endpoint ID/type
%% are excluded since the token information is already known.
%% @end
%%------------------------------------------------------------------------------
-spec to_endpoint_push_req(kz_json:object(), maybe_pm_module()) -> kz_json:object().
to_endpoint_push_req(JObj, PMMod) ->
    JObj1 = add_timestamp_to_req(JObj),
    Payload = kz_json:set_value(<<"utc_unix_timestamp_ms">>
                               ,kz_term:to_binary(pusher_util:timestamp_ms(JObj1))
                               ,kz_json:get_json_value(<<"Payload">>, JObj1)
                               ),

    Definition = kapi_pusher:api_definition(<<"endpoint_push_req">>),
    Values = [{<<"Alert">>, alert(JObj1, PMMod)}
             ,{<<"Data">>, maybe_add_extra_param(JObj1, data(JObj1, Payload, PMMod))}
             ,{<<"Event-Category">>, kapi_definition:category(Definition)}
             ,{<<"Event-Name">>, kapi_definition:name(Definition)}
             ],
    kz_json:exec([{fun kz_json:delete_keys/2, delete_keys(PMMod)}
                 ,{fun kz_json:set_values/2, Values}
                 ]
                ,JObj1
                ).

%%------------------------------------------------------------------------------
%% @doc Convert alert data from a `push_req' to be compatible with an
%% `endpoint_push_req'.
%% @end
%%------------------------------------------------------------------------------
-spec alert(kz_json:object(), maybe_pm_module()) -> kz_term:api_object().
alert(_, 'pm_firebase') -> 'undefined';
alert(JObj, _) ->
    BodyKey = kz_json:get_value(<<"Alert-Key">>, JObj),
    BodyParams = kz_json:get_value(<<"Alert-Params">>, JObj),
    kz_json:from_list([{<<"Body-Key">>, BodyKey}
                      ,{<<"Body-Params">>, BodyParams}
                      ]).

%%------------------------------------------------------------------------------
%% @doc Address backwards-compatibility for FCM when converting a `push_req'
%% into an `endpoint_push_req'. Alert/sound are nested under the custom data.
%% @end
%%------------------------------------------------------------------------------
-spec data(kz_json:object(), kz_json:object(), maybe_pm_module()) -> kz_json:object().
data(JObj, Data, 'pm_firebase') ->
    BodyKey = kz_json:get_value(<<"Alert-Key">>, JObj),
    BodyParams = kz_json:get_value(<<"Alert-Params">>, JObj),
    Sound = kz_json:get_value(<<"Sound">>, JObj),
    kz_json:set_values([{[<<"alert">>, <<"loc-key">>], BodyKey}
                       ,{[<<"alert">>, <<"loc-args">>], BodyParams}
                       ,{<<"sound">>, Sound}
                       ]
                      ,Data
                      );
data(_, Data, _) -> Data.

%%------------------------------------------------------------------------------
%% @doc Keys to delete from a req that was converted from a `push_req' into an
%% `endpoint_push_req'. `<<"Sound">>' is only deleted for FCM messages because
%% it is nested under the custom data.
%% @end
%%------------------------------------------------------------------------------
-spec delete_keys(maybe_pm_module()) -> kz_term:ne_binaries().
delete_keys('pm_firebase') -> [<<"Sound">> | common_delete_keys()];
delete_keys(_) -> common_delete_keys().

-spec common_delete_keys() -> kz_term:ne_binaries().
common_delete_keys() ->
    [<<"Alert">>, <<"Alert-Key">>, <<"Alert-Params">>, <<"Badge">>, <<"Payload">>].

%%------------------------------------------------------------------------------
%% @doc Returns true if the app is enabled for the specified push service
%% module.
%% @end
%%------------------------------------------------------------------------------
-spec app_enabled(push_app_id(), maybe_pm_module()) -> boolean().
app_enabled(_, 'undefined') -> 'false';
app_enabled(App, Module) ->
    lager:info("checking if ~s / ~s is enabled", [App, Module]),
    Module:enabled(App).

-spec push(kz_json:object()) -> 'ok'.
push(JObj) ->
    gen_listener:cast(?MODULE, {'push', JObj}).

%%------------------------------------------------------------------------------
%% @doc Get the push token information from a device or legacy push request.
%% @end
%%------------------------------------------------------------------------------
-spec push_props(kz_json:object()) -> push_props().
push_props(JObj) ->
    Token = kz_json:get_ne_binary_value(<<"Token-ID">>, JObj),
    TokenApp = kz_json:get_ne_binary_value(<<"Token-App">>, JObj),
    TokenType = kz_json:get_ne_binary_value(<<"Token-Type">>, JObj),
    {Token, TokenApp, TokenType}.

%%------------------------------------------------------------------------------
%% @doc Publish a response to an `endpoint_push_req' if there is a response
%% queue to send it to.
%% @end
%%------------------------------------------------------------------------------
-spec maybe_publish_endpoint_push_resp(kz_json:object(), pusher_results()) -> 'ok'.
maybe_publish_endpoint_push_resp(Req, Results) ->
    maybe_publish_endpoint_push_resp(
      kz_api:server_id(Req), kz_api:msg_id(Req), Results
     ).

-spec maybe_publish_endpoint_push_resp(kz_term:api_ne_binary()
                                      ,kz_term:api_ne_binary()
                                      ,pusher_results()
                                      ) -> 'ok'.
maybe_publish_endpoint_push_resp('undefined', _, Results) ->
    lager:debug("push results: ~p", [Results]);
maybe_publish_endpoint_push_resp(ServerId, MsgId, Results) ->
    EndpointPushRespResults = [to_endpoint_push_resp_result(Result)
                               || Result <- Results
                              ],
    Resp = [{<<"Overall-Status">>, overall_status(Results)}
           ,{<<"Results">>, EndpointPushRespResults}
           ,{<<"Msg-ID">>, MsgId}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    kapi_pusher:publish_endpoint_push_resp(ServerId, Resp).

%%------------------------------------------------------------------------------
%% @doc Convert a `pusher_result:identified_t()' into a single result in an
%% `endpoint_push_resp'. Error details will be conditionally added for error
%% results.
%% @end
%%------------------------------------------------------------------------------
-spec to_endpoint_push_resp_result(pusher_result:identified_t()) -> kz_json:object().
to_endpoint_push_resp_result({DeviceId, RespCode, Reason, Message}) ->
    Result = kz_json:from_list([{<<"Device-ID">>, DeviceId}
                               ,{<<"Status">>, RespCode}
                               ,{<<"Message">>, Message}
                               ]),
    case RespCode of
        200 -> Result;
        _ -> kz_json:set_value(<<"Error">>, Reason, Result)
    end.

%%------------------------------------------------------------------------------
%% @doc Get the overall status from endpoint push results.
%% @end
%%------------------------------------------------------------------------------
-spec overall_status(pusher_results()) -> pos_integer().
overall_status(Results) ->
    RespCodesWithPriorities = [{resp_code_priority(RespCode), RespCode}
                               || {_, RespCode, _, _} <- Results
                              ],
    case RespCodesWithPriorities of
        [] ->
            %% No pushes were sent, this is OK
            %% User might have no enabled devices, device was not found, etc.
            200;
        _ ->
            %% Term order will give us the most relevant resp code, first by
            %% priority then minimum resp code. Should be decent - bad requests
            %% & authz failures before system and possible implementation errors
            {_, RespCode} = lists:min(RespCodesWithPriorities),
            RespCode
    end.

-spec resp_code_priority(pos_integer()) -> pos_integer().
resp_code_priority(RespCode) when RespCode >= 400 -> 1;
resp_code_priority(RespCode) when RespCode > 200 -> 2;
resp_code_priority(_) -> 3.

-spec add_kazoo_device_id(kz_json:object(), kzd_devices:doc()) -> kz_json:object().
add_kazoo_device_id(JObj, Device) ->
    kz_json:set_value([<<"Data">>, <<"Kazoo-Device-Id">>], kz_doc:id(Device), JObj).

-spec maybe_add_extra_param(kz_json:object(), kz_json:object()) -> kz_json:object().
maybe_add_extra_param(JObj, DataJobj) ->
    case not kz_json:is_defined(<<"Push-Type">>, DataJobj)
        andalso kz_json:get_value(<<"Alert-Key">>, JObj) =:= <<"IC_SIL">>
    of
        'true' -> maybe_add_auth_param(JObj, add_incoming_call_push_type(DataJobj));
        'false' -> DataJobj
    end.

-spec add_incoming_call_push_type(kz_json:object()) -> kz_json:object().
add_incoming_call_push_type(DataJobj) ->
    kz_json:set_value(<<"Push-Type">>, <<"incoming_call">>, DataJobj).

-spec maybe_add_auth_param(kz_json:object(), kz_json:object()) -> kz_json:object().
maybe_add_auth_param(JObj, DataJObj) ->
    kz_json:set_values([{<<"Authorizing-Type">>, kz_json:get_ne_binary_value(<<"Authorizing-Type">>, JObj)}
                       ,{<<"Authorizing-ID">>, kz_json:get_ne_binary_value(<<"Authorizing-ID">>, JObj)}
                       ]
                      ,DataJObj
                      ).
