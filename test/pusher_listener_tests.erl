%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2023, 2600Hz
%%% @doc `pusher_listener' tests
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%% @author Daniel Finke <danielfinke2011@gmail.com>
%%%-----------------------------------------------------------------------------
-module(pusher_listener_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../src/pusher.hrl").

%%%=============================================================================
%%% Eunit Tests
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Test converting legacy push reqs into endpoint push reqs.
%% @end
%%------------------------------------------------------------------------------
to_endpoint_push_req_test_() ->
    CallId = kz_binary:rand_hex(16),
    CIDName = <<"Bryan Mills">>,
    CIDNumber = <<"+15555555555">>,
    PushType = <<"incoming_call">>,
    BodyKey = <<"IC_SIL">>,
    BodyParams = [<<CIDNumber/binary, " - ", CIDName/binary>>],
    Sound = <<"ring.caf">>,
    PMMod = 'pm_firebase',

    Payload = kz_json:from_list([{<<"call-id">>, CallId}
                                ,{<<"caller-id-name">>, CIDName}
                                ,{<<"caller-id-number">>, CIDNumber}
                                ,{<<"proxy">>, <<"proxy">>}
                                ,{<<"registration-token">>, kz_binary:rand_hex(16)}
                                ,{<<"account-ref">>, kz_binary:rand_hex(16)}
                                ,{<<"Kazoo-Device-Id">>, kz_binary:rand_hex(16)}
                                ,{<<"Push-Type">>, PushType}
                                ]),

    Req = kz_json:from_list(
            [{<<"Alert-Key">>, BodyKey}
            ,{<<"Alert-Params">>, BodyParams}
            ,{<<"Call-ID">>, CallId}
            ,{<<"Payload">>, Payload}
            ,{<<"Sound">>, Sound}
            ]),

    Alert = kz_json:from_list([{<<"Body-Key">>, BodyKey}
                              ,{<<"Body-Params">>, BodyParams}
                              ]),

    [{"Kamailio pusher role push reqs (apple)"
     ,fun() ->
              EPReq = pusher_listener:to_endpoint_push_req(Req, 'pm_apple'),
              ?assert(kz_json:is_defined(?KEY_TIMESTAMP_MS, EPReq)),
              Data = add_unix_timestamp(EPReq, Payload),
              ?assert(kz_json:are_equal(Alert, kz_json:get_json_value(<<"Alert">>, EPReq))),
              ?assert(kz_json:are_equal(Data, kz_json:get_json_value(<<"Data">>, EPReq))),
              ?assertNot(kz_json:is_defined(<<"Badge">>, EPReq))
      end
     }
    ,{"Kamailio pusher role push reqs (firebase)"
     ,fun() ->
              EPReq = pusher_listener:to_endpoint_push_req(Req, PMMod),
              Data = kz_json:set_values([{[<<"alert">>, <<"loc-key">>], BodyKey}
                                        ,{[<<"alert">>, <<"loc-args">>], BodyParams}
                                        ,{<<"sound">>, Sound}
                                        ], add_unix_timestamp(EPReq, Payload)),
              ?assert(kz_json:are_equal(Data, kz_json:get_json_value(<<"Data">>, EPReq))),
              ?assertNot(kz_json:is_defined(<<"Alert">>, EPReq)),
              ?assertNot(kz_json:is_defined(<<"Sound">>, EPReq))
      end
     }
    ,{"ignore optional headers unused by pm modules"
     ,fun() ->
              Values = [{<<"Account-ID">>, <<"a">>}
                       ,{<<"Endpoint-ID">>, <<"e">>}
                       ,{<<"Alert">>, <<"al">>}
                       ,{<<"Badge">>, 1}
                       ,{<<"Expires">>, 1}
                       ,{<<"Queue">>, <<"q">>}
                       ,{<<"Token-Reg">>, <<"t">>}
                       ],
              Req1 = kz_json:set_values(Values, Req),
              EPReq = pusher_listener:to_endpoint_push_req(Req, PMMod),
              EPReq1 = kz_json:delete_keys(props:get_keys(Values)
                                          ,pusher_listener:to_endpoint_push_req(Req1, PMMod)
                                          ),
              ?assertEqual(EPReq, copy_unix_timestamp(EPReq, EPReq1))
      end
     }
    ].

add_unix_timestamp(EPReq, Data) ->
    kz_json:set_value(<<"utc_unix_timestamp_ms">>
                     ,kz_term:to_binary(pusher_util:timestamp_ms(EPReq))
                     ,Data
                     ).

copy_unix_timestamp(EPReq, EPReq1) ->
    kz_json:set_values([{[<<"Data">>,<<"utc_unix_timestamp_ms">>]
                        ,kz_json:get_binary_value([<<"Data">>,<<"utc_unix_timestamp_ms">>], EPReq)
                        }
                       ,{<<"Timestamp-MS">>
                        ,kz_json:get_integer_value(<<"Timestamp-MS">>, EPReq)
                        }
                       ]
                      ,EPReq1
                      ).
