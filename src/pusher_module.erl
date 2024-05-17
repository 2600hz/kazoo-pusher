%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2024, 2600Hz
%%% @doc Push service behaviour
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @author Daniel Finke <danielfinke2011@gmail.com>
%%% @end
%%%-----------------------------------------------------------------------------
-module(pusher_module).

-include("pusher.hrl").

%%%=============================================================================
%%% Callbacks
%%%=============================================================================

-callback enabled(push_app_id()) -> boolean().
-callback push(Token :: kz_term:ne_binary()
              ,push_app_id()
              ,token_type()
              ,kz_json:object()
              ) -> pusher_result:t().
