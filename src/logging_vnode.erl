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
-module(logging_vnode).

-behaviour(riak_core_vnode).

-include("antidote.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

%% Expected time to wait until the inter_dc_log_sender_vnode is started
-define(LOG_SENDER_STARTUP_WAIT, 1000).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_vnode/1,
	 is_sync_log/0,
	 set_sync_log/1,
	 set_sync_log_internal/1,
         asyn_read/2,
	 get_stable_time/1,
         read/2,
         asyn_append/3,
         append/3,
         append_commit/3,
         append_group/4,
         asyn_append_group/4,
         asyn_read_from/3,
         read_from/3,
         get/5,
	 get_all/4,
	 request_op_id/3]).

-export([init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_info/2,
         handle_exit/3]).

-ignore_xref([start_vnode/1]).

-record(state, {partition :: partition_id(),
		logs_map :: dict(),
		clock :: dict(),
		recovered_vector :: vectorclock(),
		senders_awaiting_ack :: dict(),
		last_read :: term()}).

%% API
-spec start_vnode(integer()) -> any().
start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

%% @doc Sends a `threshold read' asynchronous command to the Logs in
%%      `Preflist' From is the operation id form which the caller wants to
%%      retrieve the operations.  The operations are retrieved in inserted
%%      order and the From operation is also included.
-spec asyn_read_from(preflist(), key(), op_id()) -> ok.
asyn_read_from(Preflist, Log, From) ->
    riak_core_vnode_master:command(Preflist,
                                   {read_from, Log, From},
                                   {fsm, undefined, self()},
                                   ?LOGGING_MASTER).

%% @doc synchronous read_from operation
-spec read_from({partition(), node()}, log_id(), op_id()) -> {ok, [term()]} | {error, term()}.
read_from(Node, LogId, From) ->
    riak_core_vnode_master:sync_command(Node,
                                        {read_from, LogId, From},
					?LOGGING_MASTER).

%% @doc Sends a `read' asynchronous command to the Logs in `Preflist'
-spec asyn_read(preflist(), key()) -> ok.
asyn_read(Preflist, Log) ->
    riak_core_vnode_master:command(Preflist,
                                   {read, Log},
                                   {fsm, undefined, self()},
                                   ?LOGGING_MASTER).

%% @doc Sends a `get_stable_time' synchronous command to `Node'
-spec get_stable_time({partition(), node()}) -> ok.
get_stable_time(Node) ->
    riak_core_vnode_master:command(Node,
				   {get_stable_time},
				   ?LOGGING_MASTER).

%% @doc Sends a `read' synchronous command to the Logs in `Node'
-spec read({partition(), node()}, key()) -> {error, term()} | {ok, [term()]}.
read(Node, Log) ->
    riak_core_vnode_master:sync_command(Node,
                                        {read, Log},
                                        ?LOGGING_MASTER).

%% @doc Sends an `append' asyncrhonous command to the Logs in `Preflist'
-spec asyn_append(preflist(), key(), payload()) -> ok.
asyn_append(Preflist, Log, Payload) ->
    riak_core_vnode_master:command(Preflist,
                                   {append, Log, Payload},
                                   {fsm, undefined, self(), ?SYNC_LOG},
                                   ?LOGGING_MASTER).

%% @doc synchronous append operation payload
-spec append(index_node(), key(), payload()) -> {ok, op_id()} | {error, term()}.
append(IndexNode, LogId, Payload) ->
    riak_core_vnode_master:sync_command(IndexNode,
                                        {append, LogId, Payload, false},
                                        ?LOGGING_MASTER,
                                        infinity).

%% @doc synchronous append operation payload
%% If enabled in antidote.hrl will ensure item is written to disk
-spec append_commit(index_node(), key(), payload()) -> {ok, op_id()} | {error, term()}.
append_commit(IndexNode, LogId, Payload) ->
    riak_core_vnode_master:sync_command(IndexNode,
                                        {append, LogId, Payload, is_sync_log()},
                                        ?LOGGING_MASTER,
                                        infinity).

%% @doc synchronous append list of operations (note an operations is a payload with an operation number)
%% The IsLocal flag indicates if the operations in the transaction were handled by the local or remote DC.
-spec append_group(index_node(), key(), [#operation{}], boolean()) -> {ok, op_id()} | {error, term()}.
append_group(IndexNode, LogId, OperationList, IsLocal) ->
    riak_core_vnode_master:sync_command(IndexNode,
                                        {append_group, LogId, OperationList, IsLocal, is_sync_log()},
                                        ?LOGGING_MASTER,
                                        infinity).

%% @doc asynchronous append list of operations
-spec asyn_append_group(index_node(), key(), [term()], boolean()) -> ok.
asyn_append_group(IndexNode, LogId, PayloadList, IsLocal) ->
    riak_core_vnode_master:command(IndexNode,
				   {append_group, LogId, PayloadList, IsLocal, is_sync_log()},
				   ?LOGGING_MASTER,
				   infinity).

%% @doc given the MinSnapshotTime and the type, this method fetchs from the log the
%% desired operations so a new snapshot can be created.
-spec get(index_node(), key(), vectorclock(), term(), key()) ->
		 {number(), list(), snapshot(), vectorclock(), false} | {error, term()}.
get(IndexNode, LogId, MinSnapshotTime, Type, Key) ->
    riak_core_vnode_master:sync_command(IndexNode,
					{get, LogId, MinSnapshotTime, Type, Key},
					?LOGGING_MASTER,
					infinity).

%% @doc Given the logid and position in the log (given by continuation) and a dict
%% of non_commited operations up to this position returns
%% a tuple with three elements
%% the first is a dict with all operations that had been committed until the next chunk in the log
%% the second contains those without commit operations
%% the third is the location of the next chunk
%% Otherwise if the end of the file is reached it returns a tuple
%% where the first elelment is 'eof' and the second is a dict of commited operations
-spec get_all(index_node(), log_id(), start | disk_log:continuation(), dict()) ->
		     {disk_log:continuation(), dict(), dict()} | {eof, dict()} | {error, term()}.
get_all(IndexNode, LogId, Continuation, PrevOps) ->
    riak_core_vnode_master:sync_command(IndexNode, {get_all, LogId, Continuation, PrevOps},
					?LOGGING_MASTER,
					infinity).

%% @doc Gets the last id of operations stored in the log for the given DCID
-spec request_op_id(index_node(), dcid(), partition()) -> {ok, non_neg_integer()}.
request_op_id(IndexNode, DCID, Partition) ->
    riak_core_vnode_master:sync_command(IndexNode, {get_op_id, DCID, Partition},
					?LOGGING_MASTER,
					infinity).

%% @doc Returns true if syncrounous logging is enabled
%%      False otherwise.
%%      Uses environment variable "sync_log" set in antidote.app.src
-spec is_sync_log() -> boolean().
is_sync_log() ->
    application:get_env(antidote,sync_log,false).

%% @doc Takes as input a boolean to set whether or not items will
%%      be logged synchronously at this DC (sends a broadcast to update
%%      the environment variable "sync_log" to all nodes).
%%      If true, items will be logged synchronously
%%      If false, items will be logged asynchronously
-spec set_sync_log(boolean()) -> ok.
set_sync_log(Value) ->
    Nodes = dc_utilities:get_my_dc_nodes(),
    %% Update the environment varible on all nodes in the DC
    lists:foreach(fun(Node) -> 
			  ok = rpc:call(Node, logging_vnode, set_sync_log_internal, [Value])
		  end, Nodes).

%% @doc internal function to set syncrounous logging environment variable.
-spec set_sync_log_internal(boolean()) -> ok.
set_sync_log_internal(Value) ->
    lager:info("setting sync log ~p at ~p", [Value,node()]),
    application:set_env(antidote,sync_log,Value).

%% @doc Opens the persistent copy of the Log.
%%      The name of the Log in disk is a combination of the the word
%%      `log' and the partition identifier.
init([Partition]) ->
    LogFile = integer_to_list(Partition),
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    GrossPreflists = riak_core_ring:all_preflists(Ring, ?N),
    Preflists = lists:filter(fun(X) -> preflist_member(Partition, X) end, GrossPreflists),
    lager:info("Opening logs for partition ~w", [Partition]),
    case open_logs(LogFile, Preflists, dict:new(), dict:new(), vectorclock:new()) of
        {error, Reason} ->
	    lager:error("ERROR: opening logs for partition ~w, reason ~w", [Partition, Reason]),
            {error, Reason};
        {Map,Clock,MaxVector} ->
	    lager:info("Done opening logs for partition ~w", [Partition]),
            {ok, #state{partition=Partition,
                        logs_map=Map,
                        clock=Clock,
			recovered_vector=MaxVector,
                        senders_awaiting_ack=dict:new(),
                        last_read=start}}
    end.

handle_command({hello}, _Sender, State) ->
  {reply, ok, State};

handle_command({get_op_id, DCID, Partition}, _Sender, State=#state{clock=ClockDict}) ->
    {OpId,_} = get_op_id(ClockDict,[Partition],DCID),
    #op_number{local = Local, global = _Global} = OpId,
    {reply, {ok, Local}, State};

%% Let the log sender know the last log id that was sent so the receiving DCs
%% don't think they are getting old messages
handle_command({start_timer, undefined}, Sender, State) ->
    handle_command({start_timer, Sender}, Sender, State);
handle_command({start_timer, Sender}, _, State = #state{partition=Partition, clock=ClockDict, recovered_vector=MaxVector}) ->
    MyDCID = dc_meta_data_utilities:get_my_dc_id(),
    {OpId,_} = get_op_id(ClockDict,[Partition],MyDCID),
    IsReady = try
		  ok = inter_dc_dep_vnode:set_dependency_clock(Partition, MaxVector),
		  ok = inter_dc_log_sender_vnode:update_last_log_id(Partition, OpId),
		  ok = inter_dc_log_sender_vnode:start_timer(Partition),
		  true
	      catch
		  _:Reason ->
		      lager:info("Error updating inter_dc_log_sender_vnode last sent log id: ~w, will retry", [Reason]),
		      false
	      end,
    case IsReady of
	true ->
	    riak_core_vnode:reply(Sender, ok);
	false ->
	    riak_core_vnode:send_command_after(?LOG_SENDER_STARTUP_WAIT, {start_timer, Sender})
    end,
    {noreply, State};

%% @doc Read command: Returns the phyiscal time of the 
%%      clocksi vnode for which no transactions will commit with smaller time
%%      Output: {ok, Time}
handle_command({send_min_prepared, Time}, _Sender,
               #state{partition=Partition}=State) ->
    ok = inter_dc_log_sender_vnode:send_stable_time(Partition, Time),
    {noreply, State};

%% @doc Read command: Returns the operations logged for Key
%%          Input: The id of the log to be read
%%      Output: {ok, {vnode_id, Operations}} | {error, Reason}
handle_command({read, LogId}, _Sender,
               #state{partition=Partition, logs_map=Map}=State) ->
    case get_log_from_map(Map, Partition, LogId) of
        {ok, Log} ->
           {Continuation, Ops} = 
                case disk_log:chunk(Log, start) of
                    {C, O} -> {C,O};
                    {C, O, _} -> {C,O};
                    eof -> {eof, []}
                end,
            case Continuation of
                error -> {reply, {error, Ops}, State};
                eof -> {reply, {ok, Ops}, State#state{last_read=start}};
                _ -> {reply, {ok, Ops}, State#state{last_read=Continuation}}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

%% @doc Threshold read command: Returns the operations logged for Key
%%      from a specified op_id-based threshold.
%%
%%      Input:  From: the oldest op_id to return
%%              LogId: Identifies the log to be read
%%      Output: {vnode_id, Operations} | {error, Reason}
%%
handle_command({read_from, LogId, _From}, _Sender,
               #state{partition=Partition, logs_map=Map, last_read=Lastread}=State) ->
    case get_log_from_map(Map, Partition, LogId) of
        {ok, Log} ->
            ok = disk_log:sync(Log),
            {Continuation, Ops} = 
                case disk_log:chunk(Log, Lastread) of
                    {error, Reason} -> {error, Reason};
                    {C, O} -> {C,O};
                    {C, O, _} -> {C,O};
                    eof -> {eof, []}
                end,
            case Continuation of
                error -> {reply, {error, Ops}, State};
                eof -> {reply, {ok, Ops}, State};
                _ -> {reply, {ok, Ops}, State#state{last_read=Continuation}}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

%% @doc Append command: Appends a new op to the Log of Key
%%      Input:  LogId: Indetifies which log the operation has to be
%%              appended to.
%%              Payload of the operation
%%              OpId: Unique operation id
%%      Output: {ok, {vnode_id, op_id}} | {error, Reason}
%%
handle_command({append, LogId, Payload, Sync}, _Sender,
               #state{logs_map=Map,
                      clock=ClockDict,
                      partition=Partition}=State) ->
    case get_log_from_map(Map, Partition, LogId) of
        {ok, Log} ->
	    MyDCID = dc_meta_data_utilities:get_my_dc_id(),
	    {OpId,OpIdDict} = get_op_id(ClockDict, LogId, MyDCID),
	    #op_number{local = Local, global = Global} = OpId,
	    NewOpId = OpId#op_number{local =  Local + 1, global = Global + 1},
	    NewClockDict = dict:store(LogId,dict:store(MyDCID,NewOpId,OpIdDict),ClockDict),
            Operation = #operation{op_number = NewOpId, payload = Payload},
            case insert_operation(Log, LogId, Operation) of
                {ok, NewOpId} ->
		    inter_dc_log_sender_vnode:send(Partition, Operation),
		    case Sync of
			true ->
			    case disk_log:sync(Log) of
				ok ->
				    {reply, {ok, OpId}, State#state{clock=NewClockDict}};
				{error, Reason} ->
				    {reply, {error, Reason}, State}
			    end;
			false ->
			    {reply, {ok, OpId}, State#state{clock=NewClockDict}}
		    end;
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

%% Currently this should be only used for external operations
%% That already have their operation id numbers assigned
%% That is why IsLocal is hard coded to false
%% Might want to support appending groups of local operations in the future
%% for efficency
handle_command({append_group, LogId, OperationList, _IsLocal = false, Sync}, _Sender,
               #state{logs_map=Map,
                      clock=ClockDict,
                      partition=Partition}=State) ->
    MyDCID = dc_meta_data_utilities:get_my_dc_id(),
    {ErrorList, SuccList, UpdatedLogs, NNC} =
	lists:foldl(fun(Operation, {AccErr, AccSucc, UpdatedLogs, NewClockDict}) ->
			    case get_log_from_map(Map, Partition, LogId) of
				{ok, Log} ->
				    %% Generate the new operation ID
				    %% This is only stored in memory to count the total number
				    %% of operations, since the input operations should
				    %% have already been assigned an op id number since
				    %% they are coming from an external DC
				    {OpId,OpIdDict} = get_op_id(NewClockDict, LogId, MyDCID),
				    #op_number{local = _Local, global = Global} = OpId,
				    NewOpId = OpId#op_number{global = Global + 1},
				    %% Should assign the opid as follows if this function starts being
				    %% used for operations generated locally
				    %% NewOpId = 
				    %% 	case IsLocal of
				    %% 	    true ->
				    %% 		OpId#op_number{local =  Local + 1, global = Global + 1};
				    %% 	    false ->
				    %% 		OpId#op_number{global = Global + 1}
				    %% 	end,
				    NewNewClockDict = dict:store(LogId,dict:store(MyDCID,NewOpId,OpIdDict),NewClockDict),
				    ExternalOpNum = Operation#operation.op_number,
				    case insert_operation(Log, LogId, Operation) of
					{ok, ExternalOpNum} ->
					    %% Would need to uncomment this is local ops are sent to this function
					    %% case IsLocal of
					    %% 	true -> inter_dc_log_sender_vnode:send(Partition, Operation);
					    %% 	false -> ok
					    %% end,
					    {AccErr, AccSucc ++ [NewOpId], ordsets:add_element(Log,UpdatedLogs), NewNewClockDict};
					{error, Reason} ->
					    {AccErr ++ [{reply, {error, Reason}, State}], AccSucc, UpdatedLogs, NewNewClockDict}
				    end;
				{error, Reason} ->
				    {AccErr ++ [{reply, {error, Reason}, State}], AccSucc, UpdatedLogs, NewClockDict}
			    end
		    end, {[],[], ordsets:new(),ClockDict}, OperationList),
    %% Sync the updated logs if necessary
    case Sync of
	true ->
	    ordsets:fold(fun(Log,_Acc) ->
				 ok = disk_log:sync(Log)
			 end, ok, UpdatedLogs);
	false ->
	    ok
    end,
    case ErrorList of
	[] ->
	    [SuccId|_T] = SuccList,
	    {reply, {ok, SuccId}, State#state{clock=NNC}};
	[Error|_T] ->
	    %%Error
	    {reply, Error, State}
    end;

handle_command({get, LogId, MinSnapshotTime, Type, Key}, _Sender,
    #state{logs_map = Map, clock = _Clock, partition = Partition} = State) ->
    case get_log_from_map(Map, Partition, LogId) of
        {ok, Log} ->
            case get_ops_from_log(Log, {key, Key}, start, MinSnapshotTime, dict:new(), dict:new(), load_all) of
                {error, Reason} ->
                    {reply, {error, Reason}, State};
                {eof, CommittedOpsForKeyDict} ->
		    CommittedOpsForKey =
			case dict:find(Key, CommittedOpsForKeyDict) of
			    {ok, Val} ->
				Val;
			    error ->
				[]
			end,
                    {reply, {length(CommittedOpsForKey), CommittedOpsForKey, {0,clocksi_materializer:new(Type)},
			     vectorclock:new(), false}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

%% This will reply with all downstream operations that have
%% been stored in the log given by LogId
%% The resut is a dict, with a list of ops per key
handle_command({get_all, LogId, Continuation, Ops}, _Sender,
	       #state{logs_map = Map, clock = _Clock, partition = Partition} = State) ->
    case get_log_from_map(Map, Partition, LogId) of
        {ok, Log} ->
	    case get_ops_from_log(Log, undefined, Continuation, undefined, Ops, dict:new(), load_per_chunk) of
                {error, Reason} ->
                    {reply, {error, Reason}, State};
                CommittedOpsForKeyDict ->
		    {reply, CommittedOpsForKeyDict, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_command(_Message, _Sender, State) ->
    {noreply, State}.

reverse_and_add_op_id([],_Id,Acc) ->
    Acc;
reverse_and_add_op_id([Next|Rest],Id,Acc) ->
    reverse_and_add_op_id(Rest,Id+1,[{Id,Next}|Acc]).

%% Gets the id of the last operation that was put in the log
%% and the maximum vectorclock of the commited transactions stored in the log
-spec get_last_op_from_log(log_id(), disk_log:continuation() | start, dict(), vectorclock()) -> {eof, dict(), vectorclock()} | {error, term()}.
get_last_op_from_log(Log, Continuation, PrevMaxOpDict, PrevMaxVector) ->
    case disk_log:chunk(Log, Continuation) of
	eof ->
	    {eof, PrevMaxOpDict, PrevMaxVector};
	{error, Reason} ->
	    {error, Reason};
	{NewContinuation, NewTerms} ->
	    {NewMaxOpDict, NewMaxVector} = get_max_op_numbers(NewTerms,PrevMaxOpDict,PrevMaxVector),
	    get_last_op_from_log(Log, NewContinuation, NewMaxOpDict, NewMaxVector);
	 {NewContinuation, NewTerms, BadBytes} ->
            case BadBytes > 0 of
                true -> {error, bad_bytes};
                false ->
		    {NewMaxOpDict,NewMaxVector} = get_max_op_numbers(NewTerms,PrevMaxOpDict,PrevMaxVector),
		    get_last_op_from_log(Log, NewContinuation, NewMaxOpDict, NewMaxVector)
	    end
    end.

-spec get_max_op_numbers([{log_id(),#operation{}}],dict(), vectorclock()) -> {dict(), vectorclock()}.
get_max_op_numbers([],MaxOpDict,MaxVector) ->
    {MaxOpDict,MaxVector};
get_max_op_numbers([{_, #operation{op_number = NewOp, payload = Payload}}|Rest],PrevMaxOpDict,PrevMaxVector) ->
    #op_number{local = Num, node = {_,DCID}} = NewOp,
    #log_record{op_type = OpType,
		op_payload = OpPayload
	       } = Payload,
    NewMaxVector =
	case OpType of
	    commit ->
		{{DcId, TxCommitTime}, _} = OpPayload,
		vectorclock:set_clock_of_dc(DcId, TxCommitTime, PrevMaxVector);
	    _ ->
		PrevMaxVector
	end,
    NewMaxOpDict = 
	dict:update(DCID,fun(OldOp = #op_number{local = OldNum}) ->
				 case Num >= OldNum of
				     true ->
					 NewOp;
				     false ->
					 OldOp
				 end
			 end, NewOp, PrevMaxOpDict),
    get_max_op_numbers(Rest,NewMaxOpDict,NewMaxVector).

%% @doc This method successively calls disk_log:chunk so all the log is read.
%% With each valid chunk, filter_terms_for_key is called.
get_ops_from_log(Log, Key, Continuation, MinSnapshotTime, Ops, CommittedOpsDict, LoadAll) ->
    case disk_log:chunk(Log, Continuation) of
        eof ->
	    {eof, finish_op_load(CommittedOpsDict)};
        {error, Reason} ->
            {error, Reason};
        {NewContinuation, NewTerms} ->
            {NewOps, NewCommittedOps} = filter_terms_for_key(NewTerms, Key, MinSnapshotTime, Ops, CommittedOpsDict),
	    case LoadAll of
		load_all ->
		    get_ops_from_log(Log, Key, NewContinuation, MinSnapshotTime, NewOps, NewCommittedOps, LoadAll);
		load_per_chunk ->
		    {NewContinuation, NewOps, finish_op_load(NewCommittedOps)}
	    end;
        {NewContinuation, NewTerms, BadBytes} ->
            case BadBytes > 0 of
                true -> {error, bad_bytes};
                false ->
		    {NewOps, NewCommittedOps} = filter_terms_for_key(NewTerms, Key, MinSnapshotTime, Ops, CommittedOpsDict),
		    case LoadAll of
			load_all ->
			    get_ops_from_log(Log, Key, NewContinuation, MinSnapshotTime, NewOps, NewCommittedOps, LoadAll);
			load_per_chunk ->
			    {NewContinuation, NewOps, finish_op_load(NewCommittedOps)}
		    end
            end
    end.

finish_op_load(CommittedOpsDict) ->
    dict:fold(fun(Key1, CommittedOps, Acc) ->
		      dict:store(Key1, reverse_and_add_op_id(CommittedOps,0,[]), Acc)
	      end, dict:new(), CommittedOpsDict).

%% @doc Given a list of log_records, this method filters the ones corresponding to Key.
%% If key is undefined then is returns all records for all keys
%% It returns a dict corresponding to all the ops matching Key and
%% a list of the commited operations for that key which have a smaller commit time than MinSnapshotTime.
filter_terms_for_key([], _Key, _MinSnapshotTime, Ops, CommittedOpsDict) ->
    {Ops, CommittedOpsDict};
filter_terms_for_key([H|T], Key, MinSnapshotTime, Ops, CommittedOpsDict) ->
    {_, {operation, _, #log_record{tx_id = TxId, op_type = OpType, op_payload = OpPayload}}} = H,
    case OpType of
        update ->
            handle_update(TxId, OpPayload, T, Key, MinSnapshotTime, Ops, CommittedOpsDict);
        commit ->
            handle_commit(TxId, OpPayload, T, Key, MinSnapshotTime, Ops, CommittedOpsDict);
        _ ->
            filter_terms_for_key(T, Key, MinSnapshotTime, Ops, CommittedOpsDict)
    end.

handle_update(TxId, OpPayload,  T, Key, MinSnapshotTime, Ops, CommittedOpsDict) ->
    {Key1, _, _} = OpPayload,
    case (Key == {key, Key1}) or (Key == undefined) of
        true ->
            filter_terms_for_key(T, Key, MinSnapshotTime,
                dict:append(TxId, OpPayload, Ops), CommittedOpsDict);
        false ->
            filter_terms_for_key(T, Key, MinSnapshotTime, Ops, CommittedOpsDict)
    end.

handle_commit(TxId, OpPayload, T, Key, MinSnapshotTime, Ops, CommittedOpsDict) ->
    {{DcId, TxCommitTime}, SnapshotTime} = OpPayload,
    case dict:find(TxId, Ops) of
        {ok, OpsList} ->
	    NewCommittedOpsDict = 
		lists:foldl(fun({KeyInternal, Type, Op}, Acc) ->
				    case ((MinSnapshotTime == undefined) orelse
									   (not vectorclock:gt(SnapshotTime, MinSnapshotTime))) of
					true ->
					    CommittedDownstreamOp =
						#clocksi_payload{
						   key = KeyInternal,
						   type = Type,
						   op_param = Op,
						   snapshot_time = SnapshotTime,
						   commit_time = {DcId, TxCommitTime},
						   txid = TxId},
					    dict:append(KeyInternal, CommittedDownstreamOp, Acc);
					false ->
					    Acc
				    end
			    end, CommittedOpsDict, OpsList),
	    filter_terms_for_key(T, Key, MinSnapshotTime, dict:erase(TxId,Ops),
				 NewCommittedOpsDict);
	error ->
	    filter_terms_for_key(T, Key, MinSnapshotTime, Ops, CommittedOpsDict)
    end.

handle_handoff_command(?FOLD_REQ{foldfun=FoldFun, acc0=Acc0}, _Sender,
                       #state{logs_map=Map}=State) ->
    F = fun({Key, Operation}, Acc) -> FoldFun(Key, Operation, Acc) end,
    Acc = join_logs(dict:to_list(Map), F, Acc0),
    {reply, Acc, State};

handle_handoff_command({get_all, _logId}, _Sender, State) ->
    {reply, {error, not_ready}, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(Data, #state{partition=Partition, logs_map=Map}=State) ->
    {LogId, Operation} = binary_to_term(Data),
    case get_log_from_map(Map, Partition, LogId) of
        {ok, Log} ->
            %% Optimistic handling; crash otherwise.
            {ok, _OpId} = insert_operation(Log, LogId, Operation),
            ok = disk_log:sync(Log),
            {reply, ok, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

encode_handoff_item(Key, Operation) ->
    term_to_binary({Key, Operation}).

is_empty(State=#state{logs_map=Map}) ->
    LogIds = dict:fetch_keys(Map),
    case no_elements(LogIds, Map) of
        true ->
            {true, State};
        false ->
            {false, State}
    end.

delete(State) ->
    {ok, State}.

handle_info({sync, Log, LogId},
            #state{senders_awaiting_ack=SendersAwaitingAck0}=State) ->
    case dict:find(LogId, SendersAwaitingAck0) of
        {ok, Senders} ->
            _ = case dets:sync(Log) of
                ok ->
                    [riak_core_vnode:reply(Sender, {ok, OpId}) || {Sender, OpId} <- Senders];
                {error, Reason} ->
                    [riak_core_vnode:reply(Sender, {error, Reason}) || {Sender, _OpId} <- Senders]
            end,
            ok;
        _ ->
            ok
    end,
    SendersAwaitingAck = dict:erase(LogId, SendersAwaitingAck0),
    {ok, State#state{senders_awaiting_ack=SendersAwaitingAck}}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================%%
%% Internal Functions %%
%%====================%%

%% @doc no_elements: checks whether any of the logs contains any data
%%      Input:  LogIds: Each logId is a preflist that represents one log
%%              Map: the dictionary that relates the preflist with the
%%              actual log
%%      Return: true if all logs are empty. false if at least one log
%%              contains data.
%%
-spec no_elements([log_id()], dict()) -> boolean().
no_elements([], _Map) ->
    true;
no_elements([LogId|Rest], Map) ->
    case dict:find(LogId, Map) of
        {ok, Log} -> 
            case disk_log:chunk(Log, start) of
                eof ->
                    no_elements(Rest, Map);
                _ ->
                    false
            end;
        error ->
            {error, no_log_for_preflist}
    end.

%% @doc open_logs: open one log per partition in which the vnode is primary
%%      Input:  LogFile: Partition concat with the atom log
%%                      Preflists: A list with the preflist in which
%%                                 the vnode is involved
%%                      Initial: Initial log identifier. Non negative
%%                               integer. Consecutive ids for the logs.
%%                      Map: The ongoing map of preflist->log. dict()
%%                           type.
%%      Return:         LogsMap: Maps the  preflist and actual name of
%%                               the log in the system. dict() type.
%%
-spec open_logs(string(), [preflist()], dict(), dict(), vectorclock()) -> {dict(),dict(),vectorclock()} | {error, reason()}.
open_logs(_LogFile, [], Map, Clock, MaxVector) ->
    {Map,Clock, MaxVector};
open_logs(LogFile, [Next|Rest], Map, Clock, MaxVector)->
    PartitionList = log_utilities:remove_node_from_preflist(Next),
    PreflistString = string:join(
                       lists:map(fun erlang:integer_to_list/1, PartitionList), "-"),
    LogId = LogFile ++ "--" ++ PreflistString,
    LogPath = filename:join(
                app_helper:get_env(riak_core, platform_data_dir), LogId),
    case disk_log:open([{name, LogPath}]) of
        {ok, Log} ->
            Map2 = dict:store(PartitionList, Log, Map),
            open_logs(LogFile, Rest, Map2, Clock, MaxVector);
        {repaired, Log, _, _} ->
	    {eof, LastOpDict, NewMaxVector} = get_last_op_from_log(Log, start, dict:new(), MaxVector),
	    NewClock = dict:store(PartitionList,LastOpDict,Clock),
            lager:info("Repaired log ~p, last op ids are ~p, max vector is ~p", [Log, dict:to_list(LastOpDict), dict:to_list(NewMaxVector)]),
            Map2 = dict:store(PartitionList, Log, Map),
            open_logs(LogFile, Rest, Map2, NewClock, NewMaxVector);
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc get_log_from_map: abstracts the get function of a key-value store
%%              currently using dict
%%      Input:  Map:  dict that representes the map
%%              LogId:  identifies the log.
%%      Return: The actual name of the log
%%
-spec get_log_from_map(dict(), partition(), log_id()) ->
                              {ok, log()} | {error, no_log_for_preflist}.
get_log_from_map(Map, _Partition, LogId) ->
    case dict:find(LogId, Map) of
        {ok, Log} ->
           {ok, Log};
        error ->
            {error, no_log_for_preflist}
    end.

%% @doc join_logs: Recursive fold of all the logs stored in the vnode
%%      Input:  Logs: A list of pairs {Preflist, Log}
%%                      F: Function to apply when floding the log (dets)
%%                      Acc: Folded data
%%      Return: Folded data of all the logs.
%%
-spec join_logs([{preflist(), log()}], fun(), term()) -> term().
join_logs([], _F, Acc) ->
    Acc;
join_logs([{_Preflist, Log}|T], F, Acc) ->
    JointAcc = fold_log(Log, start, F, Acc),
    join_logs(T, F, JointAcc).

fold_log(Log, Continuation, F, Acc) ->
    case  disk_log:chunk(Log,Continuation) of 
        eof ->
            Acc;
        {Next,Ops} ->
            NewAcc = lists:foldl(F, Acc, Ops),
            fold_log(Log, Next, F, NewAcc)
    end.


%% @doc insert_operation: Inserts an operation into the log only if the
%%      OpId is not already in the log
%%      Input:
%%          Log: The identifier log the log where the operation will be
%%               inserted
%%          LogId: Log identifier to which the operation belongs.
%%          OpId: Id of the operation to insert
%%          Payload: The payload of the operation to insert
%%      Return: {ok, OpId} | {error, Reason}
%%
-spec insert_operation(log(), log_id(), operation()) -> {ok, #op_number{}} | {error, reason()}.
insert_operation(Log, LogId, Operation) ->
    Result = disk_log:log(Log, {LogId, Operation}),
    case Result of
        ok ->
            {ok, Operation#operation.op_number};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc preflist_member: Returns true if the Partition identifier is
%%              part of the Preflist
%%      Input:  Partition: The partition identifier to check
%%              Preflist: A list of pairs {Partition, Node}
%%      Return: true | false
%%
-spec preflist_member(partition(), preflist()) -> boolean().
preflist_member(Partition,Preflist) ->
    lists:any(fun({P, _}) -> P =:= Partition end, Preflist).

-spec get_op_id(dict(), log_id(), dcid()) -> {#op_number{},dict()}.
get_op_id(ClockDict,LogId,DCID) ->
    OpDict = case dict:find(LogId,ClockDict) of
		 {ok, Val} ->
		     Val;
		 error ->
		     dict:new()
	     end,
    OpId = case dict:find(DCID,OpDict) of
	       {ok, Val2} ->
		   Val2;
	       error ->
		   #op_number{node = {node(), DCID}, global = 0, local = 0}
	   end,
    {OpId,OpDict}.

-ifdef(TEST).

%% @doc Testing get_log_from_map works in both situations, when the key
%%      is in the map and when the key is not in the map
get_log_from_map_test() ->
    Dict = dict:new(),
    Dict2 = dict:store([antidote1, c], value1, Dict),
    Dict3 = dict:store([antidote2, c], value2, Dict2),
    Dict4 = dict:store([antidote3, c], value3, Dict3),
    Dict5 = dict:store([antidote4, c], value4, Dict4),
    ?assertEqual({ok, value3}, get_log_from_map(Dict5, undefined,
            [antidote3,c])),
    ?assertEqual({error, no_log_for_preflist}, get_log_from_map(Dict5,
            undefined, [antidote5, c])).

%% @doc Testing that preflist_member returns true when there is a
%%      match.
preflist_member_true_test() ->
    Preflist = [{partition1, node},{partition2, node},{partition3, node}],
    ?assertEqual(true, preflist_member(partition1, Preflist)).

%% @doc Testing that preflist_member returns false when there is no
%%      match.
preflist_member_false_test() ->
    Preflist = [{partition1, node},{partition2, node},{partition3, node}],
    ?assertEqual(false, preflist_member(partition5, Preflist)).

-endif.
