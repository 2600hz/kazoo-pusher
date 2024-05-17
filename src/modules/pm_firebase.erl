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

%% Number of times to retry push. Matches value from older version of
%% `fcm-erlang'. Only used for the legacy API.
-define(RETRIES, 3).

-define(FIREBASE_MAP, [{<<"Alert-Key">>, [<<"alert">>, <<"loc-key">>]}
                      ,{<<"Alert-Params">>, [<<"alert">>, <<"loc-args">>]}
                      ,{<<"Sound">>, [<<"sound">>]}
                      ,{<<"Call-ID">>, [<<"Call-ID">>]}
                      ,{<<"Payload">>, fun kz_json:merge/2}
                      ]).

-type maybe_push_app() :: push_app() | 'undefined'.

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
handle_cast({'push', JObj}, #state{tab=ETS}=State) ->
    lager:debug("process a push"),
    TokenApp = kz_json:get_value(<<"Token-App">>, JObj),
    maybe_send_push_notification(get_fcm(TokenApp, ETS), JObj),
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

-spec maybe_send_push_notification(maybe_push_app(), kz_json:object()) -> 'ok'.
maybe_send_push_notification('undefined', _JObj) -> lager:debug("no pid to send push");
maybe_send_push_notification({Pid, Envelope}, JObj) ->
    TokenID = kz_json:get_value(<<"Token-ID">>, JObj),
    MessageJObj = kz_json:from_list([{<<"data">>, build_payload(JObj)}]),
    Message = kz_maps:merge(kz_json:to_map(MessageJObj), Envelope),

    lager:debug("pushing to ~p: ~s: ~p", [Pid, TokenID, Message]),

    _Result = fcm:push(Pid, TokenID, Message, ?RETRIES),
    'ok'.

-spec build_payload(kz_json:object()) -> kz_json:object().
build_payload(JObj) ->
    CustomData = kz_json:foldl(fun map_key/3, kz_json:new(), JObj),
    kz_json:map(fun encode_objects/2, CustomData).

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

-spec map_key(term(), term(), kz_json:object()) -> kz_json:object().
map_key(K, V, JObj) ->
    case lists:keyfind(K, 1, ?FIREBASE_MAP) of
        'false' -> JObj;
        {_, Fun} when is_function(Fun, 2) -> Fun(V, JObj);
        {_, K1} -> kz_json:set_value(K1, V, JObj)
    end.

-spec get_fcm(kz_term:api_binary(), ets:tid()) -> maybe_push_app().
get_fcm('undefined', _) -> 'undefined';
get_fcm(App, ETS) ->
    case ets:lookup(ETS, App) of
        [] -> maybe_load_fcm(App, ETS);
        [{App, Push}] -> Push
    end.

-spec maybe_load_fcm(binary(), ets:tid()) -> maybe_push_app().
maybe_load_fcm(App, ETS) ->
    lager:debug("loading fcm secret for ~s", [App]),
    case maybe_start_pool(App) of
        {'ok', Active} ->
            ets:insert(ETS, {App, Active}),
            Active;
        {'error', 'not_found'} ->
            'undefined';
        {'error', Reason} ->
            lager:error("error loading FCM: ~p", [Reason]),
            'undefined'
    end.

-spec maybe_start_pool(binary()) -> kz_either:either(any(), push_app()).
maybe_start_pool(App) ->
    case maybe_start_v1_pool(App) of
        {'ok', _}=Ret -> Ret;
        {'error', 'not_found'} -> maybe_start_legacy_pool(App);
        {'error', _E}=E -> E
    end.

-spec maybe_start_v1_pool(binary()) -> kz_either:either(any(), push_app()).
maybe_start_v1_pool(App) ->
    case kapps_config:get_json(?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE_V1, <<"service_account">>], 'undefined', App) of
        'undefined' ->
            lager:debug("firebase pusher service_account for app ~s not found", [App]),
            {'error', 'not_found'};
        ServiceAccountData -> start_v1_pool(App, ServiceAccountData)
    end.

-spec maybe_start_legacy_pool(binary()) -> kz_either:either(any(), push_app()).
maybe_start_legacy_pool(App) ->
    case kapps_config:get_ne_binary(?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE, <<"api_key">>], 'undefined', App) of
        'undefined' ->
            lager:debug("firebase pusher api_key for app ~s not found", [App]),
            {'error', 'not_found'};
        APIKey -> start_legacy_pool(App, APIKey)
    end.

-spec start_v1_pool(binary(), kz_json:object()) -> kz_either:either(any(), push_app()).
start_v1_pool(App, ServiceAccountData) ->
    Name = pool_name(App, 'v1'),
    ServiceAccountBin = kz_json:encode(ServiceAccountData),
    EnvelopeJObj = kapps_config:get_json(?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE_V1, <<"headers">>], kz_json:new(), App),
    Envelope = kz_json:to_map(EnvelopeJObj),
    case fcm:start_pool_with_json_service_file_bin(Name, ServiceAccountBin) of
        {'ok', Pid} -> {'ok', {Pid, Envelope}};
        {'error', {'already_started', Pid}} -> {'ok', {Pid, Envelope}};
        {'error', _}=E -> E
    end.

-spec start_legacy_pool(binary(), kz_term:ne_binary()) -> kz_either:either(any(), push_app()).
start_legacy_pool(App, APIKey) ->
    Name = pool_name(App, 'legacy'),
    EnvelopeJObj = kapps_config:get_json(?CONFIG_CAT, [?TOKEN_TYPE_FIREBASE, <<"headers">>], kz_json:new(), App),
    Envelope = kz_json:to_map(EnvelopeJObj),
    case fcm:start_pool_with_api_key(Name, kz_term:to_list(APIKey)) of
        {'ok', Pid} -> {'ok', {Pid, Envelope}};
        {'error', {'already_started', Pid}} -> {'ok', {Pid, Envelope}};
        {'error', _E}=E -> E
    end.

-spec pool_name(binary(), 'v1' | 'legacy') -> atom().
pool_name(App, Version) ->
    kz_term:to_atom(<<"fcm_", (kz_term:to_binary(Version))/binary, "_", App/binary>>, 'true').
