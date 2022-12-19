%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2022-2023, 2600Hz
%%% @doc A result from a push notification attempt.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%% @author Daniel Finke <danielfinke2011@gmail.com>
%%%-----------------------------------------------------------------------------
-module(pusher_result).

%%%=============================================================================
%%% Export and Defs
%%%=============================================================================

%% External API
-export([new/3
        ,identify/2

        ,success/0, success/1
        ,bad_request/1
        ,internal_server_error/1
        ,gateway_timeout/1
        ]).

-export_type([t/0
             ,identified_t/0
             ]).

-type t() :: t(resp_code()).
-type t(RespCode) :: t(RespCode, message()).
-type t(RespCode, Message) :: t(RespCode, status(), Message).
-type t(RespCode, Status, Message) :: {RespCode, Status, Message}.
-type identified_t() :: identified_t(resp_code(), status(), message()).
-type identified_t(RespCode, Status, Message) :: {device_id(), RespCode, Status, Message}.

-type resp_code() :: pos_integer().
-type status() :: kz_term:ne_binary().
-type message() :: binary().
-type device_id() :: kz_term:ne_binary().

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Create a new result.
%% @end
%%------------------------------------------------------------------------------
-spec new(RespCode, Status, Message) -> t(RespCode, Status, Message)
              when RespCode :: resp_code(), Status :: status(), Message :: message().
new(RespCode, Status, Message) -> {RespCode, Status, Message}.

%%------------------------------------------------------------------------------
%% @doc Add the ID of the device that was going to receive a push notification
%% to the result of that push attempt.
%% @end
%%------------------------------------------------------------------------------
-spec identify(device_id(), t(RespCode, Status, Message)) ->
          identified_t(RespCode, Status, Message) when RespCode :: resp_code(),
                                                       Status :: status(),
                                                       Message :: message().
identify(DeviceId, {RespCode, Status, Message}) ->
    {DeviceId, RespCode, Status, Message}.

%%------------------------------------------------------------------------------
%% @doc A successful attempt to send a push notification.
%% @end
%%------------------------------------------------------------------------------
-spec success() -> t(200).
success() -> success(<<"Success">>).

-spec success(Message) -> t(200, Message) when Message :: message().
success(Message) -> new(200, <<"OK">>, Message).

%%------------------------------------------------------------------------------
%% @doc A bad request error indicating missing or invalid push notification
%% request data.
%% @end
%%------------------------------------------------------------------------------
-spec bad_request(Message) -> t(400, Message) when Message :: message().
bad_request(Message) -> new(400, <<"Bad Request">>, Message).

%%------------------------------------------------------------------------------
%% @doc An internal server error that occurred when trying to send a push
%% notification.
%% @end
%%------------------------------------------------------------------------------
-spec internal_server_error(Message) -> t(500, Message) when Message :: message().
internal_server_error(Message) -> new(500, <<"InternalServerError">>, Message).

%%------------------------------------------------------------------------------
%% @doc A gateway timeout error indicating a timeout communicating with APNs or
%% FCM.
%% @end
%%------------------------------------------------------------------------------
-spec gateway_timeout(Message) -> t(504, Message) when Message :: message().
gateway_timeout(Message) -> new(504, <<"Gateway Timeout">>, Message).
