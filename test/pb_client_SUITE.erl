%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(pb_client_SUITE).

-compile({parse_transform, lager_transform}).

%% common_test callbacks
-export([%% suite/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0]).

%% tests
-export([start_stop_test/1,
        simple_transaction_test/1,
        read_write_test/1,
        get_empty_crdt_test/1,
        pb_test_counter_read_write/1,
        pb_test_set_read_write/1,
        pb_empty_txn_clock_test/1,
        update_counter_crdt_test/1,
        update_counter_crdt_and_read_test/1,
        update_set_read_test/1,
        static_transaction_test/1]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").

-define(ADDRESS, "localhost").

-define(PORT, 10017).

init_per_suite(Config) ->
    test_utils:at_init_testsuite(),
    Nodes = test_utils:pmap(fun(N) ->
                    test_utils:start_suite(N, Config)
            end, [dev1]),

    test_utils:connect_dcs(Nodes),
    [{nodes, Nodes}|Config].

end_per_suite(Config) ->
    Config.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_, _) ->
    ok.

all() -> [start_stop_test,
        simple_transaction_test,
        read_write_test,
        get_empty_crdt_test,
        pb_test_counter_read_write,
        pb_test_set_read_write,
        pb_empty_txn_clock_test,
        update_counter_crdt_test,
        update_counter_crdt_and_read_test,
        update_set_read_test,
        static_transaction_test].

start_stop_test(_Config) ->
    lager:info("Verifying pb connection..."),
    {ok, Pid} = antidotec_pb_socket:start(?ADDRESS, ?PORT),
    Disconnected = antidotec_pb_socket:stop(Pid),
    ?assertMatch(ok, Disconnected),
    pass.

%% starts and transaction and read a key
simple_transaction_test(Config) ->
    Nodes = proplists:get_value(nodes, Config),
    Node = hd(Nodes),
    Bound_object = {pb_client_SUITE_simple_transaction_test, riak_dt_pncounter, bucket},
    {ok, TxId} = rpc:call(Node, antidote, start_transaction, [ignore, []]),
    {ok, [0]} = rpc:call(Node, antidote, read_objects, [[Bound_object], TxId]),
    rpc:call(Node, antidote, commit_transaction, [TxId]).


read_write_test(Config) ->
    Nodes = proplists:get_value(nodes, Config),
    Node = hd(Nodes),
    Bound_object = {pb_client_SUITE_read_write_test, riak_dt_pncounter, bucket},
    {ok, TxId} = rpc:call(Node, antidote, start_transaction, [ignore, []]),
    {ok, [0]} = rpc:call(Node, antidote, read_objects, [[Bound_object], TxId]),
    ok = rpc:call(Node, antidote, update_objects, [[{Bound_object, increment, 1}], TxId]),
    rpc:call(Node, antidote, commit_transaction, [TxId]).


%% Single object rea
get_empty_crdt_test(_Config) ->
    {ok, Pid} = antidotec_pb_socket:start(?ADDRESS, ?PORT),
    Bound_object = {<<"pb_client_SUITE_get_empty_crdt_test">>, riak_dt_pncounter, <<"bucket">>},
    {ok, TxId} = antidotec_pb:start_transaction(Pid, term_to_binary(ignore), {}),
    {ok, [Val]} = antidotec_pb:read_objects(Pid, [Bound_object], TxId),
    {ok, _} = antidotec_pb:commit_transaction(Pid, TxId),
    _Disconnected = antidotec_pb_socket:stop(Pid),
    ?assertMatch(true, antidotec_counter:is_type(Val)).

pb_test_counter_read_write(_Config) ->
    Key = <<"pb_client_SUITE_pb_test_counter_read_write">>,
    {ok, Pid} = antidotec_pb_socket:start(?ADDRESS, ?PORT),
    Bound_object = {Key, riak_dt_pncounter, <<"bucket">>},
    {ok, TxId} = antidotec_pb:start_transaction(Pid, term_to_binary(ignore), {}),
    ok = antidotec_pb:update_objects(Pid, [{Bound_object, increment, 1}], TxId),
    {ok, _} = antidotec_pb:commit_transaction(Pid, TxId),
    %% Read committed updated
    {ok, Tx2} = antidotec_pb:start_transaction(Pid, term_to_binary(ignore), {}),
    {ok, [Val]} = antidotec_pb:read_objects(Pid, [Bound_object], Tx2),
    {ok, _} = antidotec_pb:commit_transaction(Pid, Tx2),
    ?assertEqual(1, antidotec_counter:value(Val)),
    _Disconnected = antidotec_pb_socket:stop(Pid).

pb_test_set_read_write(_Config) ->
    Key = <<"pb_client_SUITE_pb_test_set_read_write">>,
    {ok, Pid} = antidotec_pb_socket:start(?ADDRESS, ?PORT),
    Bound_object = {Key, riak_dt_orset, <<"bucket">>},
    {ok, TxId} = antidotec_pb:start_transaction(Pid, term_to_binary(ignore), {}),
    ok = antidotec_pb:update_objects(Pid, [{Bound_object, add, "a"}], TxId),
    {ok, _} = antidotec_pb:commit_transaction(Pid, TxId),
    %% Read committed updated
    {ok, Tx2} = antidotec_pb:start_transaction(Pid, term_to_binary(ignore), {}),
    {ok, [Val]} = antidotec_pb:read_objects(Pid, [Bound_object], Tx2),
    {ok, _} = antidotec_pb:commit_transaction(Pid, Tx2),
    ?assertEqual(["a"],antidotec_set:value(Val)),
    _Disconnected = antidotec_pb_socket:stop(Pid).

pb_empty_txn_clock_test(_Config) ->
    {ok, Pid} = antidotec_pb_socket:start(?ADDRESS, ?PORT),
    {ok, TxId} = antidotec_pb:start_transaction(Pid, term_to_binary(ignore), {}),
    {ok, CommitTime} = antidotec_pb:commit_transaction(Pid, TxId),
    %% Read committed updated
    {ok, Tx2} = antidotec_pb:start_transaction(Pid, CommitTime, {}),
    {ok, _} = antidotec_pb:commit_transaction(Pid, Tx2),
    _Disconnected = antidotec_pb_socket:stop(Pid).


update_counter_crdt_test(_Config) ->
    lager:info("Verifying retrieval of updated counter CRDT..."),
    Key = <<"pb_client_SUITE_update_counter_crdt_test">>,
    Bucket = <<"bucket">>,
    Amount = 10,
    update_counter_crdt(Key, Bucket, Amount).

update_counter_crdt(Key, Bucket, Amount) ->
    BObj = {Key, riak_dt_pncounter, Bucket},
    {ok, Pid} = antidotec_pb_socket:start(?ADDRESS, ?PORT),
    Obj = antidotec_counter:new(),
    Obj2 = antidotec_counter:increment(Amount, Obj),
    {ok, TxId} = antidotec_pb:start_transaction(Pid, term_to_binary(ignore), {}),
    ok = antidotec_pb:update_objects(Pid,
                                     antidotec_counter:to_ops(BObj, Obj2),
                                     TxId),
    {ok, _} = antidotec_pb:commit_transaction(Pid, TxId),
    _Disconnected = antidotec_pb_socket:stop(Pid),
    pass.

update_counter_crdt_and_read_test(_Config) ->
    Key = <<"pb_client_SUITE_update_counter_crdt_and_read_test">>,
    Amount = 15,
    pass = update_counter_crdt(Key, <<"bucket">>, Amount),
    pass = get_crdt_check_value(Key, riak_dt_pncounter, <<"bucket">>, Amount).

get_crdt_check_value(Key, Type, Bucket, Expected) ->
    lager:info("Verifying value of updated CRDT..."),
    BoundObject = {Key, Type, Bucket},
    {ok, Pid} = antidotec_pb_socket:start(?ADDRESS, ?PORT),
    {ok, Tx2} = antidotec_pb:start_transaction(Pid, term_to_binary(ignore), {}),
    {ok, [Val]} = antidotec_pb:read_objects(Pid, [BoundObject], Tx2),
    {ok, _} = antidotec_pb:commit_transaction(Pid, Tx2),
    _Disconnected = antidotec_pb_socket:stop(Pid),
    Mod = antidotec_datatype:module_for_term(Val),
    ?assertEqual(Expected,Mod:value(Val)),
    pass.

update_set_read_test(_Config) ->
    Key = <<"pb_client_SUITE_update_set_read_test">>,
    {ok, Pid} = antidotec_pb_socket:start(?ADDRESS, ?PORT),
    Bound_object = {Key, riak_dt_orset, <<"bucket">>},
    Set = antidotec_set:new(),
    Set1 = antidotec_set:add("a", Set),
    Set2 = antidotec_set:add("b", Set1),

    {ok, TxId} = antidotec_pb:start_transaction(Pid,
                                                term_to_binary(ignore), {}),
    ok = antidotec_pb:update_objects(Pid,
                                     antidotec_set:to_ops(Bound_object, Set2),
                                     TxId),
    {ok, _} = antidotec_pb:commit_transaction(Pid, TxId),
    %% Read committed updated
    {ok, Tx2} = antidotec_pb:start_transaction(Pid, term_to_binary(ignore), {}),
    {ok, [Val]} = antidotec_pb:read_objects(Pid, [Bound_object], Tx2),
    {ok, _} = antidotec_pb:commit_transaction(Pid, Tx2),
    ?assertEqual(2,length(antidotec_set:value(Val))),
    ?assertMatch(true, antidotec_set:contains("a", Val)),
    ?assertMatch(true, antidotec_set:contains("b", Val)),
    _Disconnected = antidotec_pb_socket:stop(Pid).

static_transaction_test(_Config) ->
    Key = <<"pb_client_SUITE_static_transaction_test">>,
    {ok, Pid} = antidotec_pb_socket:start(?ADDRESS, ?PORT),
    Bound_object = {Key, riak_dt_orset, <<"bucket">>},
    Set = antidotec_set:new(),
    Set1 = antidotec_set:add("a", Set),
    Set2 = antidotec_set:add("b", Set1),

    {ok, TxId} = antidotec_pb:start_transaction(Pid,
                                                term_to_binary(ignore), [{static, true}]),
    ok = antidotec_pb:update_objects(Pid,
                                     antidotec_set:to_ops(Bound_object, Set2),
                                     TxId),
    {ok, _} = antidotec_pb:commit_transaction(Pid, TxId),
    %% Read committed updated
    {ok, Tx2} = antidotec_pb:start_transaction(Pid, term_to_binary(ignore), [{static, true}]),
    {ok, [Val]} = antidotec_pb:read_objects(Pid, [Bound_object], Tx2),
    {ok, _} = antidotec_pb:commit_transaction(Pid, Tx2),
    ?assertEqual(2,length(antidotec_set:value(Val))),
    ?assertMatch(true, antidotec_set:contains("a", Val)),
    ?assertMatch(true, antidotec_set:contains("b", Val)),
    _Disconnected = antidotec_pb_socket:stop(Pid).
