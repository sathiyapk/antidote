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

%% Transaction buffer, used to check for message loss through operation log id gaps.

-module(inter_dc_sub_buf).
-include("antidote.hrl").
-include("inter_dc_repl.hrl").

%% Expected time to wait until the logging_vnode is started
-define(LOG_STARTUP_WAIT, 1000).

%% API
-export([
  new_state/1,
  process/2]).

%% State
-record(state, {
  state_name :: normal | buffering,
  pdcid :: pdcid(),
  last_observed_opid :: non_neg_integer() | init,
  queue :: queue()
}).

%%%% API --------------------------------------------------------------------+

%% TODO: Fetch last observed ID from durable storage (maybe log?). This way, in case of a node crash, the queue can be fetched again.
-spec new_state(pdcid()) -> #state{}.
new_state(PDCID) -> #state{
  state_name = normal,
  pdcid = PDCID,
  last_observed_opid = init,
  queue = queue:new()
}.

-spec process({txn, #interdc_txn{}} | {log_reader_resp, [#interdc_txn{}]}, #state{}) -> #state{}.
process({txn, Txn}, State = #state{last_observed_opid = init, pdcid = {DCID, Partition}}) ->
    %% If this is the first txn received (i.e. if last_observed_opid = init) then check the log
    %% to see if there was a previous op received (i.e. in the case of fail and restart) so that
    %% you can check for duplocates or lost messages
    Result = try
		 logging_vnode:request_op_id(dc_utilities:partition_to_indexnode(Partition),
					 DCID, Partition)
	     catch
		 _:Reason ->
		     lager:info("Error loading last opid from log: ~w, will retry", [Reason])
	     end,
    case Result of
	{ok, OpId} ->
	    lager:info("Loaded opid ~p from log for dc ~p, partition, ~p", [OpId, DCID, Partition]),
	    process({txn, Txn}, State#state{last_observed_opid=OpId});
	_ ->
	    riak_core_vnode:send_command_after(?LOG_STARTUP_WAIT, {txn, Txn}),
	    State
    end;
process({txn, Txn}, State = #state{state_name = normal}) -> process_queue(push(Txn, State));
process({txn, Txn}, State = #state{state_name = buffering}) ->
  lager:info("Buffering txn in ~p", [State#state.pdcid]),
  push(Txn, State);

process({log_reader_resp, Txns}, State = #state{queue = Queue, state_name = buffering}) ->
  ok = lists:foreach(fun deliver/1, Txns),
  NewLast = case queue:peek(Queue) of
    empty -> State#state.last_observed_opid;
    {value, Txn} -> Txn#interdc_txn.prev_log_opid#op_number.local
  end,
  NewState = State#state{last_observed_opid = NewLast},
  process_queue(NewState).

%%%% Methods ----------------------------------------------------------------+
process_queue(State = #state{queue = Queue, last_observed_opid = Last}) ->
  case queue:peek(Queue) of
    empty -> State#state{state_name = normal};
    {value, Txn} ->
      TxnLast = Txn#interdc_txn.prev_log_opid#op_number.local,
      case cmp(TxnLast, Last) of

      %% If the received transaction is immediately after the last observed one
        eq ->
          deliver(Txn),
          Max = (inter_dc_txn:last_log_opid(Txn))#op_number.local,
          process_queue(State#state{queue = queue:drop(Queue), last_observed_opid = Max});

      %% If the transaction seems to come after an unknown transaction, ask the remote log
        gt ->
          lager:info("Whoops, lost message. New is ~p, last was ~p. Asking the remote DC ~p",
		     [TxnLast, Last, State#state.pdcid]),
          case inter_dc_log_reader_query:query(State#state.pdcid, State#state.last_observed_opid + 1, TxnLast) of
            ok ->
              State#state{state_name = buffering};
            _ ->
              lager:warning("Failed to send log query to DC, will retry on next ping message"),
              State#state{state_name = normal}
          end;

      %% If the transaction has an old value, drop it.
        lt ->
	      lager:warning("Dropping duplicate message ~w, last time was ~w", [Txn, Last]),
	      process_queue(State#state{queue = queue:drop(Queue)})
      end
  end.

-spec deliver(#interdc_txn{}) -> ok.
deliver(Txn) -> inter_dc_dep_vnode:handle_transaction(Txn).

%% TODO: consider dropping messages if the queue grows too large.
%% The lost messages would be then fetched again by the log_reader.
-spec push(#interdc_txn{}, #state{}) -> #state{}.
push(Txn, State) -> State#state{queue = queue:in(Txn, State#state.queue)}.

cmp(A, B) when A > B -> gt;
cmp(A, B) when B > A -> lt;
cmp(_, _) -> eq.
