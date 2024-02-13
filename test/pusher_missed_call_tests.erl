%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2024, 2600Hz
%%% @doc `pusher_listener' tests
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(pusher_missed_call_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../src/pusher.hrl").

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Test finding an endpoint ID in a callflow
%% @end
%%------------------------------------------------------------------------------
find_owner_id_test_() ->
    EndpointId = kz_binary:rand_hex(16),
    EndpointList = [<<"user">>,<<"device">>],
    Flow = kz_json:from_list([{<<"module">>, lists:nth(rand:uniform(length(EndpointList))
                                                      ,EndpointList
                                                      )}
                             ,{<<"data">>, kz_json:from_list([{<<"id">>, EndpointId}])}
                             ]),

    Nested = kz_json:from_list([{<<"module">>, <<?MODULE_STRING>>}
                               ,{<<"data">>, kz_json:new()}
                               ,{<<"children">>, kz_json:from_list([{<<"1">>, kz_json:new()}
                                                                   ,{<<"_">>, Flow}
                                                                   ])}
                               ]),


    NestedUndefined = kz_json:from_list([{<<"module">>, <<?MODULE_STRING>>}
                                        ,{<<"data">>, kz_json:new()}
                                        ,{<<"children">>, kz_json:from_list([{<<"1">>, kz_json:new()}
                                                                            ,{<<"_">>, kz_json:new()}
                                                                            ])}
                                        ]),

    [?_assertMatch(EndpointId, get_endpoint_id(pusher_missed_call_notification:find_endpoint_object(Flow)))
    ,?_assertMatch('undefined', get_endpoint_id(pusher_missed_call_notification:find_endpoint_object(kz_json:new())))
    ,?_assertMatch(EndpointId, get_endpoint_id(pusher_missed_call_notification:find_endpoint_object(Nested)))
    ,?_assertMatch('undefined', get_endpoint_id(pusher_missed_call_notification:find_endpoint_object(NestedUndefined)))
    ].

get_endpoint_id(Endpoint) ->
    kz_json:get_ne_binary_value(<<"ID">>, Endpoint).
