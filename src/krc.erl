%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc K Riak Client.
%%%
%%% Copyright 2013 Kivra AB
%%% Copyright 2011-2013 Klarna AB
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration ===============================================
-module(krc).
-compile({no_auto_import, [get/1, put/2]}).

%%%_* Exports ==========================================================
%% API
-export([ delete/3
        , get/3
        , get/4
	, get_bucket/2
        , get_index/4
        , get_index/5
        , get_index_keys/4
        , put/2
        , put_index/3
	, set_bucket/3
        ]).

%% Args
-export_type([ server/0
             ]).

%%%_* Includes =========================================================
-include("krc.hrl").
-include_lib("krc/include/krc.hrl").
-include_lib("stdlib2/include/prelude.hrl").

%%%_* Code =============================================================
%%%_ * Types -----------------------------------------------------------
-type server()   :: atom() | pid().
-type strategy() :: module() %policy
                  | krc_resolver:resolution_procedure().

-type bucket()   :: krc_obj:bucket().
-type key()      :: krc_obj:key().
-type idx()      :: krc_obj:idx().
-type idx_key()  :: {match, _}
                  | {range, integer(), integer()}.
-type obj()      :: krc_obj:ect().
-type props()    :: [{atom(),_}].

%%%_ * API -------------------------------------------------------------
-spec delete(server(), bucket(), key()) -> whynot(_).
%% @doc Delete K from B.
delete(S, B, K) -> krc_server:delete(S, B, K).


-spec get(server(), bucket(), key())             -> maybe(obj(), _).
-spec get(server(), bucket(), key(), strategy()) -> maybe(obj(), _).
%% @doc Fetch the object associated with K in B.
get(S, B, K) ->
  get(S, B, K, krc_policy_default).
get(S, B, K, Policy) when is_atom(Policy) ->
  get(S, B, K, krc_resolver:compose(Policy:lookup(B, K)));
get(S, B, K, F) when is_function(F) ->
  get_loop(S, B, K, F).

get_loop(S, B, K, F) ->
  get_loop(1, get_tries(), S, B, K, F).
get_loop(I, N, S, B, K, F) when N >= I ->
  case krc_server:get(S, B, K) of
    {ok, Obj} ->
      krc_obj:resolve(Obj, F);
    {error, notfound} ->
      ?debug("{~p, ~p} not found, attempt ~p of ~p", [B, K, I, N]),
      ?increment([reads, retries]),
      timer:sleep(retry_wait_ms()),
      get_loop(I+1, N, S, B, K, F);
    {error, _} = Err -> Err
  end;
get_loop(I, N, _, _, _, _) when N < I -> {error, notfound}.

-spec get_bucket(server(), bucket()) -> maybe(props(), _).
get_bucket(S, B) ->
  krc_server:get_bucket(S, B).

-spec get_index(server(), bucket(), idx(), idx_key()) ->
                   maybe([obj()], _).
-spec get_index(server(), bucket(), idx(), idx_key(), strategy()) ->
                   maybe([obj()], _).
%% @doc Get all objects tagged with I in bucket B.
get_index(S, B, I, K) ->
  get_index(S, B, I, K, krc_policy_default).
get_index(S, B, I, K, Strat) ->
  {ok, Keys} =
    case K of
      {match, X}    -> krc_server:get_index(S, B, I, X);
      {range, X, Y} -> krc_server:get_index(S, B, I, X, Y)
    end,
  s2_par:map(fun(Key) -> get(S, B, Key, Strat) end,
             Keys,
             [{errors, false}, {chunksize, 100}]).


-spec get_index_keys(server(), bucket(), idx(), idx_key()) ->
                        maybe([key()], _).
%% @doc Get all keys tagged with I in bucket B.
get_index_keys(S, B, I, K) ->
  case K of
    {match, X}    -> krc_server:get_index(S, B, I, X);
    {range, X, Y} -> krc_server:get_index(S, B, I, X, Y)
  end.


-spec put(server(), obj()) -> whynot(_).
%% @doc Store O.
put(S, O) -> krc_server:put(S, O).

-spec put_index(server(), obj(), krc_obj:indices()) -> whynot(_).
%% @doc Add O to Indices and store it.
put_index(S, O, Indices) when is_list(Indices) ->
  krc_server:put(S, krc_obj:set_indices(O, Indices)).

-spec set_bucket(server(), bucket(), props()) -> whynot(_).
%% @doc Set bucket properties P.
set_bucket(S, B, P) ->
  case krc_bucket_properties:encode(P) of
    {ok, Props}      -> krc_server:set_bucket(S, B, Props);
    {error, _} = Err -> Err
  end.

%%%_ * Internals -------------------------------------------------------
%% @doc We automatically try to GET this many times.
get_tries() -> s2_env:get_arg([], ?APP, get_tries, 3).

%% @doc This many ms in-between tries.
retry_wait_ms() -> s2_env:get_arg([], ?APP, retry_wait_ms, 20).

%%%_* Tests ============================================================
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

put_get_test() ->
  krc_test:with_pb(1, fun(Inputs) ->
    [{B, K, _, _, V}] = Inputs,
    Obj0              = krc_obj:new(B, K, V),
    ok                = put(krc_server, Obj0),
    {ok, Obj}         = get(krc_server, B, K),
    true              = obj_eq(Obj0, Obj)
  end).

notfound_test() ->
  krc_test:with_pb(1, fun(Inputs) ->
    [{B, K, _, _, _}] = Inputs,
    {error, notfound} = get(krc_server, B, K)
  end).

delete_test() ->
  krc_test:with_pb(0, fun([]) ->
    [ {B1, K1, _, _, _}
    , {B2, K2, _, _, _}
    , {B3, K3, _, _, V3}
    , {B4, K4, _, _, V4}
    ]                 = krc_test:gen_inputs(4),
    %% delete
    ok                = delete(krc_server, B1, K1),
    %% delete delete
    ok                = delete(krc_server, B2, K2),
    ok                = delete(krc_server, B2, K2),
    %% put delete
    ok                = put(krc_server, krc_obj:new(B3, K3, V3)),
    ok                = delete(krc_server, B3, K3),
    {error, notfound} = get(krc_server, B3, K3),
    %% delete put
    Obj0              = krc_obj:new(B4, K4, V4),
    ok                = delete(krc_server, B4, K4),
    ok                = put(krc_server, Obj0),
    {ok, Obj}         = get(krc_server, B4, K4),
    true              = obj_eq(Obj0, Obj)
  end).

bucket_test() ->
  krc_test:with_pb(1, fun(Inputs) ->
    [{B, K, _, _, V}] = Inputs,
      Precommit       = [{struct, [{<<"mod">>, foo}, {<<"fun">>, bar}]}],
      ok              = set_bucket(krc_server, B, [{precommit, Precommit}]),
      {ok, Props}     = get_bucket(krc_server, B),
      {ok, Precommit} = s2_lists:assoc(precommit, Props)
  end).

basic_index_test() ->
  krc_test:with_pb(2, fun(Inputs) ->
    [ {B, K1, I, IK, V1}
    , {_, K2, _, _,  V2}
    ]          = Inputs,
    Obj1       = krc_obj:new(B, K1, V1),
    Obj2       = krc_obj:new(B, K2, V2),
    Idx        = {I, IK},
    ok         = put_index(krc_server, Obj1, [Idx]),
    ok         = put_index(krc_server, Obj2, [Idx]),
    {ok, Objs} = get_index(krc_server, B, I, {match, IK}),
    true       = s2_lists:is_permutation([V1, V2], vals(Objs))
  end).

empty_index_test() ->
  krc_test:with_pb(1, fun(Inputs) ->
    [{B, _, I, IK, _}] = Inputs,
    {ok, []}           = get_index(krc_server, B, I, {match, IK})
  end).

multiple_indices_test() ->
  krc_test:with_pb(2, fun(Inputs) ->
    [ {B1, K1, I1, IK1, V1}
    , {B2, K2, I2, IK2, V2}
    ]           = Inputs,

    Obj1        = krc_obj:new(B1, K1, V1),
    Obj2        = krc_obj:new(B1, K2, V2),
    Obj3        = krc_obj:new(B2, K1, V1),
    Obj4        = krc_obj:new(B2, K2, V2),
    Idx1        = {I1, IK1},
    Idx2        = {I2, IK2},

    ok          = put_index(krc_server, Obj1, [Idx1, Idx2]),
    ok          = put_index(krc_server, Obj2, [Idx1, Idx2]),
    ok          = put_index(krc_server, Obj3, [Idx1, Idx2]),
    ok          = put_index(krc_server, Obj4, [Idx1, Idx2]),

    {ok, Objs1} = get_index(krc_server, B1, I1, {match, IK1}),
    {ok, Objs2} = get_index(krc_server, B1, I2, {match, IK2}),
    {ok, Objs3} = get_index(krc_server, B2, I1, {match, IK1}),
    {ok, Objs4} = get_index(krc_server, B2, I2, {match, IK2}),

    true        = s2_lists:is_permutation(vals(Objs1), [V1, V2]),
    true        = s2_lists:is_permutation(vals(Objs2), [V1, V2]),
    true        = s2_lists:is_permutation(vals(Objs3), [V1, V2]),
    true        = s2_lists:is_permutation(vals(Objs4), [V1, V2])
  end).

index_get_error_test() ->
  krc_test:with_pb(3, fun(Inputs) ->
    [ {B, K1, I, IK, V1}
    , {_, K2, _, _,  V2}
    , {_, _,  _, _,  V3}
    ]            = Inputs,
    Obj1         = krc_obj:new(B, K1, V1),
    Obj2         = krc_obj:new(B, K2, V2),
    Idx          = {I, IK},
    ok           = put_index(krc_server, Obj1, [Idx]),
    ok           = put_index(krc_server, Obj2, [Idx]),
    ok           = put(krc_server, krc_obj:set_val(Obj2, V3)), %conflict
    {error, Rsn} = get_index(krc_server, B, I, {match, IK}),
    {worker, _}  = Rsn
  end).

range_index_test() ->
  krc_test:with_pb(3, fun(Inputs) ->
    [ {B, K1, I, _, V1}
    , {_, K2, _, _, V2}
    , {_, K3, _, _, V3}
    ]            = Inputs,
    Obj1         = krc_obj:new(B, K1, V1),
    Obj2         = krc_obj:new(B, K2, V2),
    Obj3         = krc_obj:new(B, K3, V3),
    Idx1         = {I, 5},
    Idx2         = {I, 10},
    Idx3         = {I, 20},
    ok           = put_index(krc_server, Obj1, [Idx1]),
    ok           = put_index(krc_server, Obj2, [Idx2]),
    ok           = put_index(krc_server, Obj3, [Idx3]),

    {ok, Objs1}  = get_index(krc_server, B, I, {range, 5, 20}),
    true         = s2_lists:is_permutation([V1, V2, V3], vals(Objs1)),

    {ok, []}     = get_index(krc_server, B, I, {range, 0, 4}),

    {ok, Objs2}  = get_index(krc_server, B, I, {range, 5, 5}),
    true         = s2_lists:is_permutation([V1], vals(Objs2)),

    {ok, Objs3}  = get_index(krc_server, B, I, {range, 5, 10}),
    true         = s2_lists:is_permutation([V1, V2], vals(Objs3)),

    {ok, Objs4}  = get_index(krc_server, B, I, {range, 15, 20}),
    true         = s2_lists:is_permutation([V3], vals(Objs4)),

    {ok, []}     = get_index(krc_server, B, I, {range, 21, 30})
  end).

conflict_ok_test() ->
  krc_test:with_pb(2, fun(Inputs) ->
    [ {B, K, _, _, V1}
    , {_, _, _, _, V2}
    ]         = Inputs,
    Obj1      = krc_obj:new(B, K, V1),
    Obj2      = krc_obj:set_val(Obj1, V2),
    ok        = put(krc_server, Obj1),
    ok        = put(krc_server, Obj2),
    {ok, Obj} = get(krc_server,
                    B,
                    K,
                    fun(V1, V2) -> erlang:max(V1, V2) end),
    true      = erlang:max(V1, V2) =:= krc_obj:val(Obj)
  end).

conflict_error_test() ->
  krc_test:with_pb(2, fun(Inputs) ->
    [ {B, K, _, _, V1}
    , {_, _, _, _, V2}
    ]                       = Inputs,
    Obj1                    = krc_obj:new(B, K, V1),
    Obj2                    = krc_obj:set_val(Obj1, V2),
    ok                      = put(krc_server, Obj1),
    ok                      = put(krc_server, Obj2),
    {error, Rsn}            = get(krc_server, B, K),
    {conflict, V1_, V2_, _} = Rsn,
    true                    = s2_lists:is_permutation([V1, V2], [V1_, V2_])
  end).

get_error_test() ->
  krc_test:with_mock(?thunk(
    krc_mock_client:disconnect(),
    {error, disconnected} = get(krc_server, mah_bucket, mah_key),
    krc_mock_client:connect()
  )).

%% Helpers.
obj_eq(Obj0, Obj) ->
  krc_obj:bucket(Obj0)  =:= krc_obj:bucket(Obj)  andalso
  krc_obj:key(Obj0)     =:= krc_obj:key(Obj)     andalso
  krc_obj:val(Obj0)     =:= krc_obj:val(Obj)     andalso
  krc_obj:indices(Obj0) =:= krc_obj:indices(Obj) andalso
  krc_obj:vclock(Obj0)  =/= krc_obj:vclock(Obj).


vals(Objs) -> [krc_obj:val(O) || O <- Objs].

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
