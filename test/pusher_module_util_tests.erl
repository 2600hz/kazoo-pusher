%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2023, 2600Hz
%%% @doc `pusher_module_util' tests
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%% @author Daniel Finke <danielfinke2011@gmail.com>
%%%-----------------------------------------------------------------------------
-module(pusher_module_util_tests).

-include_lib("eunit/include/eunit.hrl").

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Test building of push payloads using key path lookups.
%% @end
%%------------------------------------------------------------------------------
build_payload_test() ->
    GetKeyMap = #{<<"a">> => 1
                 ,<<"b">> => [2]
                 ,<<"c">> => #{<<"c1">> => 3}
                 ,<<"d">> => fun(V, Payload) -> Payload#{4 => V} end
                 ,<<"e">> => fun(V, _, Payload) -> Payload#{5 => V} end
                 },
    JObj = kz_json:set_values([{<<"a">>, <<"v1">>}
                              ,{<<"b">>, <<"v2">>}
                               %% `set_values' is used in order to set this via key path
                              ,{[<<"c">>, <<"c1">>], <<"v3">>}
                              ,{<<"d">>, <<"v4">>}
                              ,{<<"e">>, <<"v5">>}
                              ,{<<"f">>, <<"v6">>}
                              ], kz_json:new()),
    FlatProps = kz_json:to_proplist(kz_json:flatten(JObj)),
    BasePayload = #{<<"keep">> => <<"kept">>
                   ,1 => <<"overwritten">>
                   },

    Payload = pusher_module_util:build_payload(FlatProps, JObj, GetKeyMap, BasePayload),
    ?assertEqual(BasePayload#{1 => <<"v1">>
                             ,2 => <<"v2">>
                             ,3 => <<"v3">>
                             ,4 => <<"v4">>
                             ,5 => <<"v5">>
                             }, Payload).
