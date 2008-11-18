%%%-------------------------------------------------------------------
%%% File          : agent_web_listener.erl
%%% Author        : Micah Warren
%%% Organization  : __MyCompanyName__
%%% Project       : cpxerl
%%% Description   : 
%%%
%%% Created       :  10/30/08
%%%-------------------------------------------------------------------
-module(agent_web_listener).
-author("Micah").

-behaviour(gen_server).

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("call.hrl").
-include("agent.hrl").

-define(PORT, 5050).
-define(WEB_DEFAULTS, [{name, ?MODULE}, {port, ?PORT}]).

%% API
-export([start_link/1, start/1, start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {
	connections, % ets table of the connections
	mochipid % pid of the mochiweb process.
}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------

start() -> 
	start(?PORT).

start(Port) -> 
	gen_server:start(?MODULE, [Port], []).
	
start_link() ->
	start_link(?PORT).

start_link(Port) -> 
    gen_server:start_link(?MODULE, [Port], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Port]) ->
	Table = ets:new(web_connections, [set, public, named_table]),
	{ok, Mochi} = mochiweb_http:start([{loop, fun(Req) -> loop(Req, Table) end}, {name, ?MODULE}, {port, Port}]),
    {ok, #state{connections=Table, mochipid = Mochi}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

loop(Req, Table) -> 
	io:format("loop start~n"),
	case Req:get(path) of
		"/login" -> 
			io:format("/login~n"),
			Post = Req:parse_post(),
			case Post of 
				% normally this would check against a database and not just discard the un/pw.
				[] -> 
					io:format("empty post~n"),
					Req:respond({403, [], mochijson2:encode({struct, [{success, false}, {message, <<"No post data supplied">>}]})});
				_Any -> 
					io:format("trying to start connection~n"),
					Ref = make_ref(),
					case agent_web_connection:start(Post, Ref, Table) of
						{ok, _Aconnpid} -> 
							Cookie = io_lib:format("cpx_id=~p", [erlang:ref_to_list(Ref)]),
							Req:respond({200, [{"Set-Cookie", Cookie}], mochijson2:encode({struct, [{success, true}, {message, <<"Login successful">>}]})});
						{error, Reason} -> 
							Req:respond({403, [{"Set-Cookie", "cpx_id=0"}], mochijson2:encode({struct, [{success, false}, {message, list_to_binary(io_lib:format("~p", [Reason]))}]})});
						ignore -> 
							Req:respond({403, [{"Set-Cookie", "cpx_id=0"}], mochijson2:encode({struct, [{success, false}, {message, <<"ignored">>}]})})
					end
			end;
		Path -> 
			io:format("any other path~n"),
			case Req:parse_cookie() of 
				[{"cpx_id", Reflist}] -> 
					io:format("cookie looks good~nReflist: ~p~n", [Reflist]),
					Etsres = ets:lookup(Table, Reflist),
					io:format("ets res:~p~n", [Etsres]),
					[{_Key, Aconn, _Login} | _Rest] = Etsres,
					Reqresponse = agent_web_connection:request(Aconn, Path, Req:parse_post(), Req:parse_cookie()),
					Req:respond(Reqresponse);
				_Allelse -> 
					io:format("bad cookie~n"),
					Req:respond({403, [], io_lib:format("Invalid cookie: ~p", [Req:parse_cookie()])})
			end
	end.
