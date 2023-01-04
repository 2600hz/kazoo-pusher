%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2023, 2600Hz
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
%% @doc Test finding a user ID in a callflow `flow`
%% @end
%%------------------------------------------------------------------------------
find_owner_id_test_() ->
    UserId = kz_binary:rand_hex(16),
    Flow = kz_json:from_list([{<<"module">>, <<"user">>}
                             ,{<<"data">>, kz_json:from_list([{<<"id">>, UserId}])}
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

    [?_assertMatch(UserId, pusher_missed_call_notification:find_owner_id(Flow))
    ,?_assertMatch('undefined', pusher_missed_call_notification:find_owner_id(kz_json:new()))
    ,?_assertMatch(UserId, pusher_missed_call_notification:find_owner_id(Nested))
    ,?_assertMatch('undefined', pusher_missed_call_notification:find_owner_id(NestedUndefined))
    ].
