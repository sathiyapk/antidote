%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
% This file is provided to you under the Apache License,
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
-module(opcounter_SUITE).

-compile({parse_transform, lager_transform}).

%% common_test callbacks
-export([init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0]).

%% tests
-export([clocksi_test1/1,
         clocksi_test2/1,
         clocksi_tx_noclock_test/1,
         clocksi_single_key_update_read_test/1,
         clocksi_multiple_key_update_read_test/1,
         clocksi_test_read_wait/1,
         clocksi_test_read_time/1,
         clocksi_multiple_read_update_test/1,
         clocksi_concurrency_test/1,
         spawn_read/5]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").

init_per_suite(Config) ->
    test_utils:at_init_testsuite(),
    Nodes = test_utils:pmap(fun(N) ->
                    test_utils:start_suite(N, Config)
            end, [dev1, dev2]),

    test_utils:connect_dcs(Nodes),
    [{nodes, Nodes}|Config].

end_per_suite(Config) ->
    Config.

init_per_testcase(_Case, Config) ->
    Config.
    
end_per_testcase(_, _) ->
    ok.

all() -> [clocksi_test1,
          clocksi_test2,
          clocksi_tx_noclock_test,
          clocksi_single_key_update_read_test,
          clocksi_multiple_key_update_read_test,
          clocksi_test_read_time,
          clocksi_test_read_wait,
          clocksi_multiple_read_update_test,
          clocksi_concurrency_test].

%% @doc The following function tests that ClockSI can run a non-interactive tx
%%      that updates multiple partitions.
clocksi_test1(Config) ->
    Nodes = proplists:get_value(nodes, Config),
    FirstNode = hd(Nodes),
    lager:info("Test1 started"),
    Type = crdt_pncounter,
    %% Empty transaction works,

    Key1 = clocksi_test1_pncounter1,
    Key2 = clocksi_test1_pncounter2,
    Result0=rpc:call(FirstNode, antidote, clocksi_execute_int_tx,
                    [[]]),
    ?assertMatch({ok, _}, Result0),
    Result1=rpc:call(FirstNode, antidote, clocksi_execute_int_tx,
                    [[]]),
    ?assertMatch({ok, _}, Result1),

    % A simple read returns empty
    Result11=rpc:call(FirstNode, antidote, clocksi_execute_int_tx,
                    [
                     [{read, {Key1, Type}}]]),
    ?assertMatch({ok, _}, Result11),
    {ok, {_, ReadSet11, _}}=Result11, 
    ?assertMatch([0], ReadSet11),

    %% Read what you wrote
    Result2=rpc:call(FirstNode, antidote, clocksi_execute_int_tx,
                    [
                      [{read, {Key1, Type}},
                      {update, {Key1, Type, {increment, a}}},
                      {update, {Key2, Type, {increment, a}}},
                      {read, {Key1, Type}}]]),
    ?assertMatch({ok, _}, Result2),
    {ok, {_, ReadSet2, _}}=Result2, 
    ?assertMatch([0,1], ReadSet2),

    %% Update is persisted && update to multiple keys are atomic
    Result3=rpc:call(FirstNode, antidote, clocksi_execute_int_tx,
                    [
                     [{read, {Key1, Type}},
                      {read, {Key2, Type}}]]),
    ?assertMatch({ok, _}, Result3),
    {ok, {_, ReadSet3, _}}=Result3,
    ?assertEqual([1,1], ReadSet3),

    %% Multiple updates to a key in a transaction works
    Result5=rpc:call(FirstNode, antidote, clocksi_execute_int_tx,
                    [
                     [{update, {Key1, Type, {increment, a}}},
                      {update, {Key1, Type, {increment, a}}}]]),
    ?assertMatch({ok,_}, Result5),

    Result6=rpc:call(FirstNode, antidote, clocksi_execute_int_tx,
                    [
                     [{read, {Key1, Type}}]]),
    {ok, {_, ReadSet6, _}}=Result6,
    ?assertEqual(3, hd(ReadSet6)),
    pass.

%% @doc The following function tests that ClockSI can run an interactive tx.
%%      that updates multiple partitions.
clocksi_test2(Config) ->
    Nodes = proplists:get_value(nodes, Config),
    FirstNode = hd(Nodes),
    Type = crdt_pncounter,

    Key1 = clocksi_test2_pncounter1,
    Key2 = clocksi_test2_pncounter2,
    Key3 = clocksi_test2_pncounter3,

    {ok,TxId}=rpc:call(FirstNode, antidote, clocksi_istart_tx, []),
    ReadResult0=rpc:call(FirstNode, antidote, clocksi_iread,
                         [TxId, Key1, crdt_pncounter]),
    ?assertEqual({ok, 0}, ReadResult0),
    WriteResult=rpc:call(FirstNode, antidote, clocksi_iupdate,
                         [TxId, Key1, Type, {increment, 4}]),
    ?assertEqual(ok, WriteResult),
    ReadResult=rpc:call(FirstNode, antidote, clocksi_iread,
                        [TxId, Key1, crdt_pncounter]),
    ?assertEqual({ok, 1}, ReadResult),
    WriteResult1=rpc:call(FirstNode, antidote, clocksi_iupdate,
                          [TxId, Key2, Type, {increment, 4}]),
    ?assertEqual(ok, WriteResult1),
    ReadResult1=rpc:call(FirstNode, antidote, clocksi_iread,
                         [TxId, Key2, crdt_pncounter]),
    ?assertEqual({ok, 1}, ReadResult1),
    WriteResult2=rpc:call(FirstNode, antidote, clocksi_iupdate,
                          [TxId, Key3, Type, {increment, 4}]),
    ?assertEqual(ok, WriteResult2),
    ReadResult2=rpc:call(FirstNode, antidote, clocksi_iread,
                         [TxId, Key3, crdt_pncounter]),
    ?assertEqual({ok, 1}, ReadResult2),
    CommitTime=rpc:call(FirstNode, antidote, clocksi_iprepare, [TxId]),
    ?assertMatch({ok, _}, CommitTime),
    End=rpc:call(FirstNode, antidote, clocksi_icommit, [TxId]),
    ?assertMatch({ok, {_Txid, _CausalSnapshot}}, End),
    {ok,{_Txid, CausalSnapshot}} = End,
    ReadResult3 = rpc:call(FirstNode, antidote, clocksi_read,
                           [CausalSnapshot, Key1, Type]),
    {ok, {_,[ReadVal],_}} = ReadResult3,
    ?assertEqual(ReadVal, 1),
    pass.

%% @doc Test to execute transaction with out explicit clock time
clocksi_tx_noclock_test(Config) ->
    Nodes = proplists:get_value(nodes, Config),
    FirstNode = hd(Nodes),
    Key = clocksi_tx_noclock_test_pncounter1,
    Type = crdt_pncounter,

    {ok,TxId}=rpc:call(FirstNode, antidote, clocksi_istart_tx, []),
    ReadResult0=rpc:call(FirstNode, antidote, clocksi_iread,
                         [TxId, Key, crdt_pncounter]),
    ?assertEqual({ok, 0}, ReadResult0),
    WriteResult0=rpc:call(FirstNode, antidote, clocksi_iupdate,
                          [TxId, Key, Type, {increment, 4}]),
    ?assertEqual(ok, WriteResult0),
    CommitTime=rpc:call(FirstNode, antidote, clocksi_iprepare, [TxId]),
    ?assertMatch({ok, _}, CommitTime),
    End=rpc:call(FirstNode, antidote, clocksi_icommit, [TxId]),
    ?assertMatch({ok, _}, End),
    ReadResult1 = rpc:call(FirstNode, antidote, clocksi_read,
                           [Key, crdt_pncounter]),
    {ok, {_, ReadSet1, _}}= ReadResult1,
    ?assertMatch([1], ReadSet1),

    FirstNode = hd(Nodes),
    WriteResult1 = rpc:call(FirstNode, antidote, clocksi_bulk_update,
                            [[{update, {Key, Type, {increment, a}}}]]),
    ?assertMatch({ok, _}, WriteResult1),
    ReadResult2= rpc:call(FirstNode, antidote, clocksi_read,
                          [Key, crdt_pncounter]),
    {ok, {_, ReadSet2, _}}=ReadResult2,
    ?assertMatch([2], ReadSet2),
    pass.

%% @doc The following function tests that ClockSI can run both a single
%%      read and a bulk-update tx.
clocksi_single_key_update_read_test(Config) ->
    Nodes = proplists:get_value(nodes, Config),
    FirstNode = hd(Nodes),
    Key = clocksi_single_key_update_read_test_pncounter1,
    Type = crdt_pncounter,
    Result= rpc:call(FirstNode, antidote, clocksi_bulk_update,
                     [
                      [{update, {Key, Type, {increment, a}}},
                       {update, {Key, Type, {increment, b}}}]]),
    ?assertMatch({ok, _}, Result),
    {ok,{_,_,CommitTime}} = Result,
    Result2= rpc:call(FirstNode, antidote, clocksi_read,
                      [CommitTime, Key, crdt_pncounter]),
    {ok, {_, ReadSet, _}}=Result2,
    ?assertMatch([2], ReadSet),
    pass.

%% @doc Verify that multiple reads/writes are successful.
clocksi_multiple_key_update_read_test(Config) ->
    Nodes = proplists:get_value(nodes, Config),
    Firstnode = hd(Nodes),
    Type = crdt_pncounter,
    Key1 = clocksi_multiple_key_update_read_test_pncounter1,
    Key2 = clocksi_multiple_key_update_read_test_pncounter2,
    Key3 = clocksi_multiple_key_update_read_test_pncounter3,
    Ops = [{update,{Key1, Type, {increment,a}}},
           {update,{Key2, Type, {{increment,10},a}}},
           {update,{Key3, Type, {increment,a}}}],
    Writeresult = rpc:call(Firstnode, antidote, clocksi_bulk_update,
                           [Ops]),
    ?assertMatch({ok,{_Txid, _Readset, _Committime}}, Writeresult),
    {ok,{_Txid, _Readset, Committime}} = Writeresult,
    {ok,{_,[ReadResult1],_}} = rpc:call(Firstnode, antidote, clocksi_read,
                                        [Committime, Key1, crdt_pncounter]),
    {ok,{_,[ReadResult2],_}} = rpc:call(Firstnode, antidote, clocksi_read,
                                        [Committime, Key2, crdt_pncounter]),
    {ok,{_,[ReadResult3],_}} = rpc:call(Firstnode, antidote, clocksi_read,
                                        [Committime, Key3, crdt_pncounter]),
    ?assertMatch(ReadResult1,1),
    ?assertMatch(ReadResult2,10),
    ?assertMatch(ReadResult3,1),
    pass.

%% @doc The following function tests that ClockSI waits, when reading,
%%      for a tx that has updated an element that it wants to read and
%%      has a smaller TxId, but has not yet committed.
clocksi_test_read_time(Config) ->
    Nodes = proplists:get_value(nodes, Config),
    %% Start a new tx,  perform an update over key abc, and send prepare.
    lager:info("Test read_time started"),
    FirstNode = hd(Nodes),
    LastNode= lists:last(Nodes),
    lager:info("Node1: ~p", [FirstNode]),
    lager:info("LastNode: ~p", [LastNode]),
    Type = crdt_pncounter,
    {ok,TxId}=rpc:call(FirstNode, antidote, clocksi_istart_tx, []),
    lager:info("Tx1 Started, id : ~p", [TxId]),
    %% start a different tx and try to read key read_time.
    {ok,TxId1}=rpc:call(LastNode, antidote, clocksi_istart_tx, []),

    lager:info("Tx2 Started, id : ~p", [TxId1]),
    WriteResult=rpc:call(FirstNode, antidote, clocksi_iupdate,
                         [TxId, read_time, Type, {increment, 4}]),
    lager:info("Tx1 Writing..."),
    ?assertEqual(ok, WriteResult),
    CommitTime=rpc:call(FirstNode, antidote, clocksi_iprepare, [TxId]),
    ?assertMatch({ok, _}, CommitTime),
    lager:info("Tx1 sent prepare, got commitTime=..., id : ~p", [CommitTime]),
    %% try to read key read_time.

    lager:info("Tx2 Reading..."),
    ReadResult1=rpc:call(LastNode, antidote, clocksi_iread,
                         [TxId1, read_time, crdt_pncounter]),
    lager:info("Tx2 Reading..."),
    ?assertMatch({ok, 0}, ReadResult1),
    lager:info("Tx2 Read value...~p", [ReadResult1]),

    %% commit the first tx.
    End=rpc:call(FirstNode, antidote, clocksi_icommit, [TxId]),
    ?assertMatch({ok, _}, End),
    lager:info("Tx1 Committed."),

    %% prepare and commit the second transaction.
    CommitTime1=rpc:call(LastNode, antidote, clocksi_iprepare, [TxId1]),
    ?assertMatch({ok, _}, CommitTime1),
    lager:info("Tx2 sent prepare, got commitTime=..., id : ~p", [CommitTime1]),
    End1=rpc:call(LastNode, antidote, clocksi_icommit, [TxId1]),
    ?assertMatch({ok, _}, End1),
    lager:info("Tx2 Committed."),
    lager:info("Test read_time passed"),
    pass.

%% @doc The following function tests that ClockSI does not read values
%%      inserted by a tx with higher commit timestamp than the snapshot time
%%      of the reading tx.
clocksi_test_read_wait(Config) ->
    Nodes = proplists:get_value(nodes, Config),
    FirstNode = hd(Nodes),
    LastNode = lists:last(Nodes),
    Type = crdt_pncounter,
    Key = read_wait_test,

    lager:info("FirstNode: ~p", [FirstNode]),
    lager:info("LastNode: ~p", [LastNode]),

    %% Start a new tx, update a key read_wait_test, and send prepare.
    {ok,TxId} = rpc:call(FirstNode, antidote, clocksi_istart_tx, []),
    lager:info("Tx1 started with id : ~p", [TxId]),
    ok = rpc:call(FirstNode, antidote, clocksi_iupdate,
                         [TxId, Key, Type, {increment, user1}]),
    {ok, CommitTime} = rpc:call(FirstNode, antidote, clocksi_iprepare, [TxId]),
    lager:info("Tx1 sent prepare, got commitTime: ~p", [CommitTime]),


    %% start a different tx and try to read key read_wait_test.
    {ok,TxId1} = rpc:call(LastNode, antidote, clocksi_istart_tx,
                        []),
    lager:info("Tx2 started with id : ~p", [TxId1]),
    lager:info("Tx2 reading..."),
    Pid = spawn(?MODULE, spawn_read, [LastNode, TxId1, self(), Key, Type]),
    
    %% Delay first transaction
    timer:sleep(100),
    %% Commit the first tx.
    End = rpc:call(FirstNode, antidote, clocksi_icommit, [TxId]),
    ?assertMatch({ok, _}, End),
    lager:info("Tx1 committed."),

    receive
        {Pid, ReadResult1} ->
            %%receive the read value
            ?assertMatch({ok, 1}, ReadResult1),
            lager:info("Tx2 read value: ~p", [ReadResult1])
    end,

    %% prepare and commit the second transaction.
    CommitTime1 = rpc:call(LastNode, antidote, clocksi_iprepare, [TxId1]),
    ?assertMatch({ok, _}, CommitTime1),
    lager:info("Tx2 sent prepare with commitTime: ~p", [CommitTime1]),
    End1 = rpc:call(LastNode, antidote, clocksi_icommit, [TxId1]),
    ?assertMatch({ok, _}, End1),
    lager:info("Tx2 committed."),
    pass.

spawn_read(LastNode, TxId, Return, Key, Type) ->
    ReadResult=rpc:call(LastNode, antidote, clocksi_iread,
                        [TxId, Key, Type]),
    Return ! {self(), ReadResult}.

%% @doc Read an update a key multiple times.
clocksi_multiple_read_update_test(Config) ->
    Nodes = proplists:get_value(nodes, Config),
    Node = hd(Nodes),
    Key = get_random_key(),
    NTimes = 100,
    {ok,Result1} = rpc:call(Node, antidote, read,
                       [Key, crdt_pncounter]),
    lists:foreach(fun(_)->
                          read_update_test(Node, Key) end,
                  lists:seq(1,NTimes)),
    {ok,Result2} = rpc:call(Node, antidote, read,
                       [Key, crdt_pncounter]),
    ?assertEqual(Result1+NTimes, Result2),
    pass.

%% @doc Test updating prior to a read.
read_update_test(Node, Key) ->
    Type = crdt_pncounter,
    {ok,Result1} = rpc:call(Node, antidote, read,
                       [Key, Type]),
    {ok,_} = rpc:call(Node, antidote, clocksi_bulk_update,
                      [[{update, {Key, Type, {increment,a}}}]]),
    {ok,Result2} = rpc:call(Node, antidote, read,
                       [Key, Type]),
    ?assertEqual(Result1+1,Result2),
    pass.

get_random_key() ->
    random:seed(now()),
    random:uniform(1000).

%% @doc The following function tests how two concurrent transactions work
%%      when they are interleaved.
clocksi_concurrency_test(Config) ->
    Nodes = proplists:get_value(nodes, Config),
    lager:info("clockSI_concurrency_test started"),
    Node = hd(Nodes),
    %% read txn starts before the write txn's prepare phase,
    Key = clocksi_concurrency_test_pncounter1,
    {ok, TxId1} = rpc:call(Node, antidote, clocksi_istart_tx, []),
    rpc:call(Node, antidote, clocksi_iupdate,
             [TxId1, Key, riak_dt_gcounter, {increment, ucl}]),
    rpc:call(Node, antidote, clocksi_iprepare, [TxId1]),
    {ok, TxId2} = rpc:call(Node, antidote, clocksi_istart_tx, []),
    Pid = self(),
    spawn( fun() ->
                   rpc:call(Node, antidote, clocksi_iupdate,
                            [TxId2, Key, riak_dt_gcounter, {increment, ucl}]),
                   rpc:call(Node, antidote, clocksi_iprepare, [TxId2]),
                   {ok,_}= rpc:call(Node, antidote, clocksi_icommit, [TxId2]),
                   Pid ! ok
           end),

    {ok,_}= rpc:call(Node, antidote, clocksi_icommit, [TxId1]),
     receive
         ok ->
             Result= rpc:call(Node,
                              antidote, read, [Key, riak_dt_gcounter]),
             ?assertEqual({ok, 2}, Result),
             pass
     end.