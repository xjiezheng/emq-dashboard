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

%% @doc emqttd dashboard supervisor.
-module(emqttd_dashboard_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(CHILD(I), {I, {I, start_link, []}, permanent, 5000, worker, [I]}).

-define(CHILD2(I, Table), {emqttd_dashboard_meter_gc:named(Table), {I, start_link, [Table]}, permanent, 5000, worker, [I]}).

-include("emqttd_dashboard_meter.hrl").

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    GC = [?CHILD2(emqttd_dashboard_meter_gc, Table) || Table <- ?METRICS],
    {ok, { {one_for_all, 10, 100}, [?CHILD(emqttd_dashboard_admin),
                ?CHILD(emqttd_dashboard_meter) | GC]}}.

