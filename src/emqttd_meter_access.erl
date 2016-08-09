%%--------------------------------------------------------------------
%% Copyright (c) 2015-2016 Feng Lee <feng@emqtt.io>.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% @doc The number of indicators of persistence.

-module(emqttd_meter_access).

-behaviour(gen_server).

-include("emqttd_dashboard_meter.hrl").

-define(Suffix, ".dets").
-define(SERVER, ?MODULE).
-define(GC_INTERVAL, 1000 * 60 * 30).
-define(MAXSIZE, (7 * 60 * 60 * 24 * 1000) div (60 * 1000)).

%%-record(interval, {extent = [], })
-record(state, {interval_1 = [], interval_2 = [], interval_3 = []}).

%% gen_server functions export
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% API functions
-export([start_link/0, save_data/3, get_data/3, get_data_all/2]).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

get_data_all(Minutes, Interval) ->
    [get_data(M, Minutes, Interval) || M <- ?METRICS].

%% Access to specify minutes metric data recently.
get_data(Met, Minutes, Interval) ->
    Metric = case Interval of
                ?INTERVAL_1 -> metric_name(Met, "/1");
                ?INTERVAL_2 -> metric_name(Met, "/2");
                ?INTERVAL_3 -> metric_name(Met, "/3");
                5 * 1000    -> Met
             end,
    
    open_table(Metric),
    TotalNum = dets:info(Metric, size),
    Qh = qlc:sort(dets:table(Metric)),
    End = timestamp(), Start = End - (Minutes * 60),
    Limit = (Minutes * 60 * 1000) div Interval,
    Cursor = qlc:cursor(Qh),
    case TotalNum > Limit of
        true  -> qlc:next_answers(Cursor, TotalNum - Limit);
        false -> ignore
    end,
    Rows = case TotalNum >= 1 of
               true  -> qlc:next_answers(Cursor, TotalNum);
               false -> []
           end,
    qlc:delete_cursor(Cursor),
    close_table(Metric),
    
    L = [[{x, Ts}, {y, V}] || {Ts, V} <- Rows, Ts >= Start],
    case L of
        [[{x, Ts}, {y, _V}]|_T] ->
            if  (Ts - Start) >= 60 * 60 ->
                    {Met, [[{x, Start}, {y, 0}]] ++ L};
                true -> {Met, L}
            end;
        [] -> {Met, [[{x, Start}, {y, 0}], [{x, End}, {y, 0}]]}
    end.

metric_name(Met, Name) ->
    list_to_atom(atom_to_list(Met) ++ Name).

%% Save the Metric data, and do a merge.
save_data(Metric, Ts, Value) ->
    gen_server:call(?SERVER, {save_data, Ts, Value, Metric}).


%%--------------------------------------------------------------------
%% Behaviour callback
%%--------------------------------------------------------------------

init([]) ->
    %close_table(),
    %open_table(),
    set_timer(metrics_gc, ?GC_INTERVAL),
    {ok, #state{}}.

handle_call({save_data, Ts, Value, Metric}, _From, State) ->
    % Save the basic data (the original).
    open_table(Metric),
    dets:insert(Metric, {Ts, Value}),
    close_table(Metric),
    
    % Do a data merge.
    #state{interval_1 = I1, interval_2 = I2, interval_3 = I3} = State,
    Met1 = metric_name(Metric, "/1"),
    State1 = merge_data(Met1, Ts, Value, ?INTERVAL_1, I1, State),
    Met2 = metric_name(Metric, "/2"),
    State2 = merge_data(Met2, Ts, Value, ?INTERVAL_2, I2, State1),
    Met3 = metric_name(Metric, "/3"),
    State3 = merge_data(Met3, Ts, Value, ?INTERVAL_3, I3, State2),

    {reply, ok, State3}.

merge_data(Met, Ts, Value, Interval, I, State) ->
    open_table(Met),
    case data_extent(Ts, Interval) of
        [Start, _End] = I     ->
            update_met(Met, Start, Value),
            State;
        [Start, _End] = Other ->
            update_met(Met, Start, Value),
            case Interval of
                ?INTERVAL_1 -> State#state{interval_1 = Other};
                ?INTERVAL_2 -> State#state{interval_2 = Other};
                ?INTERVAL_3 -> State#state{interval_3 = Other}
            end
    end.

update_met(Met, Key, Value) ->
    case dets:lookup(Met, Key) of
        [] -> dets:insert(Met, {Key, Value});
        _  -> dets:update_counter(Met, Key, {2, Value})
    end,
    close_table(Met).

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(metrics_gc, State) ->
    metrics_gc(),
    set_timer(metrics_gc, ?GC_INTERVAL),
    {noreply, State}.

terminate(_Reason, _State) ->
    %close_table(),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ====================================================================
%% Internal functions
%% ====================================================================

set_timer(Name, Timeout) ->
    erlang:send_after(Timeout, self(), Name).

open_table(Tab) ->
    Path = filename:join([code:root_dir(), "data", "metrics"]),
    case file:make_dir(Path) of
        ok -> ok;
        {error, eexist} -> ignore
    end,
    FileName = filename_replace(atom_to_list(Tab)),
    File = filename:join(Path, FileName),
    case dets:open_file(Tab, [{file, File}]) of
        {ok, Tab} -> ok;
        {error, _Reason} -> exit(edestOpen)
    end.

close_table(Tab) ->
    dets:close(Tab).

filename_replace(Src) when is_list(Src) ->
    Des = re:replace(Src, "/", "_", [global, {return, list}]),
    Des ++ ?Suffix.

%% @doc To get the data points in the time interval.
data_extent(Ts, Interval) ->
    {{Year, Month, Day}, {Hour, Minite, Second}} = timestamp_to_datetime(Ts),
    case Interval of
        ?INTERVAL_1 -> 
            Begin = datetime_to_timestamp({{Year, Month, Day}, {Hour, 0, 0}}),
            TimePeriods = time_periods(Begin, ?INTERVAL_1 div 1000, 60),
            [H|_T] = [[Start, End] || [Start, End] <- TimePeriods, Ts >= Start, Ts < End],
            H;
        ?INTERVAL_2 -> 
            {{Year, Month, Day}, {Hour, Minite, Second}} = timestamp_to_datetime(Ts),
            Begin = datetime_to_timestamp({{Year, Month, Day}, {Hour, 0, 0}}),
            TimePeriods = time_periods(Begin, ?INTERVAL_2 div 1000, 4),
            [H|_T] = [[Start, End] || [Start, End] <- TimePeriods, Ts >= Start, Ts < End],
            H;
        ?INTERVAL_3 -> 
            {{Year, Month, Day}, {Hour, Minite, Second}} = timestamp_to_datetime(Ts),
            Begin = datetime_to_timestamp({{Year, Month, Day}, {0, 0, 0}}),
            TimePeriods = time_periods(Begin, ?INTERVAL_3 div 1000, 24),
            [H|_T] = [[Start, End] || [Start, End] <- TimePeriods, Ts >= Start, Ts < End],
            H
    end.

time_periods(_Begin, _Interval, 0)   ->
    [];
time_periods(Begin, Interval, Count) ->
    End = Begin + Interval,
    [[Begin, End]] ++ time_periods(End, Interval, Count - 1).

datetime_to_timestamp(DateTime) ->
    calendar:datetime_to_gregorian_seconds(DateTime) -
        calendar:datetime_to_gregorian_seconds({{1970,1,1}, {0,0,0}}).

timestamp_to_datetime(Timestamp) ->
    calendar:gregorian_seconds_to_datetime(Timestamp +
      calendar:datetime_to_gregorian_seconds({{1970,1,1}, {0,0,0}})).

metrics_gc() ->
    Fun =
    fun(Metric) ->
        open_table(Metric),
        Total = dets:info(Metric, size),
        gc_batch(Metric, ?MAXSIZE, Total),
        close_table(Metric)
    end,
    lists:foreach(Fun, ?METRICS_TABS).

gc_batch(_Table, Max, Total)  when Max >= Total ->
    ignore;
gc_batch(Table, Max, Total)  ->
    RowInx = Total - Max,
    Qh = qlc:sort(dets:table(Table)),
    Cursor = qlc:cursor(Qh),
    Rows = qlc:next_answers(Cursor, RowInx),
    qlc:delete_cursor(Cursor),
    lists:foreach(fun({Key, _V}) ->
                    dets:delete(Table, Key)
                  end, Rows).

timestamp() ->
    {MegaSecs, Secs, _MicroSecs} = os:timestamp(),
    MegaSecs * 1000000 + Secs.
