%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2024, 2600Hz
%%% @doc Utilities for pusher modules.
%%%
%%% @end
%%% @author Daniel Finke <danielfinke2011@gmail.com>
%%%-----------------------------------------------------------------------------
-module(pusher_module_util).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([extract_custom_data/1
        ,build_payload/4
        ]).

-type payload(K) :: #{K => kz_json:json_term()}.
-type setter(K) :: fun((kz_json:json_term(), payload(K)) -> payload(K)) |
                   fun((kz_json:json_term(), kz_json:object(), payload(K)) -> payload(K)).
-type get_key_map(MappedK) :: #{kz_json:key() => MappedK
                               | [MappedK]
                               | get_key_map(MappedK)
                               | setter(MappedK)
                               }.

-export_type([get_key_map/1
             ,payload/1
             ,setter/1
             ]).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Extract custom data from a push req for merging into the push payload
%% separately.
%% @end
%%------------------------------------------------------------------------------
-spec extract_custom_data(kz_json:object()) -> {kz_json:object(), kz_json:object()}.
extract_custom_data(JObj) ->
    case kz_json:take_value(<<"Data">>, JObj) of
        'false' -> {#{}, JObj};
        {'value', Data, JObj1} -> {Data, JObj1}
    end.

%%------------------------------------------------------------------------------
%% @doc Build a push payload using a key path lookup. The lookup can define path
%% mappings or custom payload setter functions for the paths/values.
%% @end
%%------------------------------------------------------------------------------
-spec build_payload(kz_json:flat_proplist(), kz_json:object(), get_key_map(K), payload(K)) ->
          payload(K).
build_payload([], _, _, Acc) -> Acc;
build_payload([{GetKey, V} | FlatProps], JObj, GetKeyMap, Acc) ->
    Acc1 = case kz_maps:get(GetKey, GetKeyMap) of
               'undefined' -> Acc;

               %% Field-specific setter functions
               CF when is_function(CF, 2) -> CF(V, Acc);
               CF when is_function(CF, 3) -> CF(V, JObj, Acc);

               GetKey1 -> kz_maps:put(GetKey1, Acc, V)
           end,
    build_payload(FlatProps, JObj, GetKeyMap, Acc1).
