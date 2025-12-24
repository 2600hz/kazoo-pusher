%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2013-2025, 2600Hz
%%% @doc Maintenance functions for all
%%% @author Luis Azedo
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(pusher_maintenance).

-export([add_firebase_v1_app/2
        ,add_firebase_v1_app_from_service_account_file/2
        ,add_firebase_app/2
        ,add_apple_app/2, add_apple_app/3
        ,add_apple_pem_file/1
        ,push/2
        ]).

-elvis([{elvis_style, no_debug_call, disable}]).

-include("pusher.hrl").

-spec add_firebase_v1_app(kz_term:ne_binary(), kz_term:ne_binary()) -> 'ok'.
add_firebase_v1_app(AppId, ServiceAccountData) ->
    ServiceAccountJObj = kz_json:unsafe_decode(ServiceAccountData),
    _ = kapps_config:set_node(
          ?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE_V1, <<"service_account">>], ServiceAccountJObj, AppId
         ),
    'ok'.

-spec add_firebase_v1_app_from_service_account_file(kz_term:ne_binary(), kz_term:ne_binary()) -> 'ok'.
add_firebase_v1_app_from_service_account_file(AppId, ServiceAccountFilename) ->
    {'ok', ServiceAccountData} = file:read_file(ServiceAccountFilename),
    add_firebase_v1_app(AppId, ServiceAccountData).

%%------------------------------------------------------------------------------
%% @deprecated Due to sunset of legacy FCM APIs
%% [https://firebase.google.com/docs/cloud-messaging/migrate-v1]. Use
%% {@link add_firebase_v1_app/2} going forward.
%% @end
%%------------------------------------------------------------------------------
-spec add_firebase_app(kz_term:ne_binary(), binary()) -> 'ok'.
add_firebase_app(AppId, Secret) ->
    ?SUP_LOG_INFO("Legacy FCM APIs are removed as of June 2024. Migrate to the HTTP v1 API."),
    _ = kapps_config:set_node(?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE, <<"api_key">>], Secret, AppId),
    'ok'.

-spec add_apple_app(kz_term:ne_binary(), binary()) -> 'ok' | {'error', atom()}.
add_apple_app(AppId, Certfile) ->
    add_apple_app(AppId, Certfile, ?DEFAULT_APNS_HOST).

-spec add_apple_app(kz_term:ne_binary(), binary(), kz_term:ne_binary()) -> 'ok' | {'error', atom()}.
add_apple_app(AppId, Certfile, Host) ->
    case file:read_file(Certfile) of
        {'ok', Binary} ->
            _ = kapps_config:set_node(?CONFIG_CAT, [?TOKEN_TYPE_APPLE, <<"certificate">>], Binary, AppId),
            _ = kapps_config:set_node(?CONFIG_CAT, [?TOKEN_TYPE_APPLE, <<"host">>], Host, AppId),
            'ok';
        {'error', _} = Err -> Err
    end.

-spec add_apple_pem_file(binary()) -> 'ok' | {'error', atom()}.
add_apple_pem_file(PemKeyFile) ->
    case file:read_file(PemKeyFile) of
        {'ok', Binary} ->
            Options = [{'content_type', <<"application/x-pem-file">>}],
            case kz_datamgr:put_attachment(?KZ_CONFIG_DB, ?CONFIG_CAT, ?APNS_AUTH_KEY_PEM, Binary, Options) of
                {'ok', _} -> 'ok';
                {'error', _} = Err -> Err
            end;
        {'error', _} = Err -> Err
    end.

-spec push(kz_term:ne_binary(), kz_term:ne_binary()) -> 'ok'.
push(AccountId, DeviceId) ->
    case kzd_devices:fetch(AccountId, DeviceId) of
        {'ok', Device} -> push(kzd_devices:push(Device));
        {'error', Error} -> io:format("error: ~p~n", [Error])
    end.

push('undefined') ->
    io:format("error: no push propeties for device~n");
push(Push) ->
    CallId = kz_binary:rand_hex(16),
    MsgId = kz_binary:rand_hex(16),
    RegToken = kz_binary:rand_hex(16),
    CallerIdNumber = <<"15555555555">>,
    CallerIdName = <<"this is a push test">>,
    TokenApp = kz_json:get_ne_binary_value(<<"Token-App">>, Push),
    TokenType = kz_json:get_ne_binary_value(<<"Token-Type">>, Push),
    TokenId = kz_json:get_ne_binary_value(<<"Token-ID">>, Push),
    TokenProxy = kz_json:get_ne_binary_value(<<"Token-Proxy">>, Push),
    Payload = [{<<"call-id">>, CallId}
              ,{<<"proxy">>, TokenProxy}
              ,{<<"caller-id-number">>, CallerIdNumber}
              ,{<<"caller-id-name">>, CallerIdName}
              ,{<<"registration-token">>, RegToken}
              ],
    Msg = [{<<"Msg-ID">>, MsgId}
          ,{<<"App-Name">>, <<"Kamailio">>}
          ,{<<"App-Version">>, <<"1.0">>}
          ,{<<"Event-Category">>, <<"notification">>}
          ,{<<"Event-Name">>, <<"push_req">>}
          ,{<<"Call-ID">>, CallId}
          ,{<<"Token-ID">>, TokenId}
          ,{<<"Token-Type">>, TokenType}
          ,{<<"Token-App">>, TokenApp}
          ,{<<"Alert-Key">>, <<"IC_SIL">>}
          ,{<<"Alert-Params">>, [CallerIdNumber]}
          ,{<<"Sound">>, <<"ring.caf">>}
          ,{<<"Payload">>, kz_json:from_list(Payload)}
          ],
    pusher_listener:push(kz_json:from_list(Msg)).
