%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is OpenACD.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <andrew at hijacked dot us>
%%	Micah Warren <micahw at lordnull dot com>
%%

%% @doc Listens for new web connections, then spawns an 
%% {@link agent_web_connection} to handle the details.  Uses Mochiweb for 
%% the heavy lifting.
%% 
%% {@web}
%%
%% The listener and connection are designed to be able to function with
%% any ui that adheres to the api.  The api is broken up between the two
%% modules.  {@module} holds the functions that either doe not require a
%% speecific agent, or handle the login procedures.  For 
%% functions dealing with a specific agent, {@link agent_web_connection}.
%% 
%% Some functions in this documentation will have {@web} in front of their 
%% description.  These functions should not be called in the shell, as they
%% likely won't work; they are exported only to aid in documentation.
%% To call a function is very similar to using the json_api
%% in {@link cpx_web_management}.  A request is a json object with a 
%% `"function"' property and an `"args"' property.  Note unlike the 
%% json api there is no need to define a `"module"' property.  In the 
%% documentation of specific functions, references to a proplist should
%% be sent as a json object.  The response is a json object with a 
%% `"success"' property.  If the `"success"' property is set to true, 
%% there may be a `"result"' property holding more data (defined in the 
%% functions below).  If something went wrong, there will be a `"message"' 
%% and `"errcode"' property.  Usually the `"message"' will have a human 
%% readable message, while `"errcode"' could be used for translation.
%%
%% The specifics of the args property will be described in the 
%% documentation.  The number of arguments for the web api call will likely
%% differ.
%% 
%% To make a web api call, make a post request to path "/api" with one
%% field named `"request"'.  The value of the request field should be a 
%% a json object:
%% <pre> {
%% 	"function":  string(),
%% 	"args":      [any()]
%% }</pre>
%% See a functions documentation for what `"args"' should be.
%% 
%% A response will have 3 major forms.  Note that due to legacy reasons 
%% there may be more properties then listed.  They should be ignored, as
%% they will be phased out in favor of the more refined api.
%% 
%% A very simple success:
%% <pre> {
%% 	"success":  true
%% }</pre>
%% A success with a result:
%% <pre> {
%% 	"success":  true,
%% 	"result":   any()
%% }</pre>
%% A failure:
%% <pre> {
%% 	"success":  false,
%% 	"message":  string(),
%% 	"errcode":  string()
%% }</pre>
%% @see agent_web_connection
%% @see cpx_web_management

-module(agent_web_listener).
-author("Micah").

-behaviour(gen_server).

-include_lib("public_key/include/public_key.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").
-include("call.hrl").
-include("queue.hrl").
-include("agent.hrl").
-include("web.hrl").

-ifdef(TEST).
-define(PORT, 55050).
-else.
-define(PORT, 5050).
-endif.
-define(WEB_DEFAULTS, [{name, ?MODULE}, {port, ?PORT}]).
-define(MOCHI_NAME, aweb_mochi).

%% API
-export([start_link/1, start/1, start/0, start_link/0, stop/0, linkto/1, linkto/3]).
%% Web api
-export([
	check_cookie/1,
	get_salt/1,
	login/4,
	get_brand_list/0,
	get_queue_list/0,
	get_release_opts/0
]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-type(salt() :: string() | 'undefined').
-type(connection_handler() :: pid() | 'undefined').
-type(web_connection() :: {string(), salt(), connection_handler()}).

-record(state, {
	connections:: any(), % ets table of the connections
	mochipid :: pid() % pid of the mochiweb process.
}).

-type(state() :: #state{}).
-define(GEN_SERVER, true).
-include("gen_spec.hrl").

%%====================================================================
%% API
%%====================================================================

%% @doc Starts the web listener on the default port of 5050.
-spec(start/0 :: () -> {'ok', pid()}).
start() -> 
	start(?PORT).

%% @doc Starts the web listener on the passed port.
-spec(start/1 :: (Port :: non_neg_integer()) -> {'ok', pid()}).
start(Port) -> 
	gen_server:start({local, ?MODULE}, ?MODULE, [Port], []).

%% @doc Start linked on the default port of 5050.
-spec(start_link/0 :: () -> {'ok', pid()}).
start_link() ->
	start_link(?PORT).

%% @doc Start linked on the given port.
-spec(start_link/1 :: (Port :: non_neg_integer()) -> {'ok', pid()}).
start_link(Port) -> 
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Port], []).

%% @doc Stop the web listener.
-spec(stop/0 :: () -> 'ok').
stop() ->
	gen_server:call(?MODULE, stop).

%% @doc Link to the passed pid; usually an agent pid.
-spec(linkto/1 :: (Pid :: pid()) -> 'ok').
linkto(Pid) ->
	gen_server:cast(?MODULE, {linkto, Pid}).

%% @doc Register an already running web_connection.
-spec(linkto/3 :: (Ref :: reference(), Salt :: any(), Pid :: pid()) -> 'ok').
linkto(Ref, Salt, Pid) ->
	gen_server:cast(?MODULE, {linkto, Ref, Salt, Pid}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Port]) ->
	?DEBUG("Starting on port ~p", [Port]),
	process_flag(trap_exit, true),
	crypto:start(),
	Table = ets:new(web_connections, [set, public, named_table]),
	{ok, Mochi} = mochiweb_http:start([{loop, fun(Req) -> loop(Req, Table) end}, {name, ?MOCHI_NAME}, {port, Port}]),
	{ok, #state{connections=Table, mochipid = Mochi}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
	{stop, shutdown, ok, State};
handle_call(Request, From, State) ->
	?DEBUG("Call from ~p:  ~p", [From, Request]),
    {reply, {unknown_call, Request}, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%--------------------------------------------------------------------
handle_cast({linkto, Pid}, State) ->
	?DEBUG("Linking to ~w", [Pid]),
	link(Pid),
	{noreply, State};
handle_cast({linkto, Reflist, Salt, Pid}, State) ->
	?DEBUG("Linking to ~w with ref ~w and salt ~p", [Pid, Reflist, Salt]),
	link(Pid),
	ets:insert(web_connections, {Reflist, Salt, Pid}),
	{noreply, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%--------------------------------------------------------------------
handle_info({'EXIT', Pid, Reason}, State) ->
	?DEBUG("Doing a match_delete for pid ~w which died due to ~p", [Pid, Reason]),
	ets:match_delete(web_connections, {'$1', '_', Pid}),
	{noreply, State};
handle_info(Info, State) ->
	?DEBUG("Info:  ~p", [Info]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
terminate(shutdown, _State) ->
	?NOTICE("shutdown", []),
	mochiweb_http:stop(?MOCHI_NAME),
	ets:delete(web_connections),
	ok;
terminate(normal, _State) ->
	?NOTICE("normal exit", []),
	mochiweb_http:stop(?MOCHI_NAME),
	ets:delete(web_connections),
	ok;
terminate(Reason, _State) ->
	?NOTICE("Terminating dirty:  ~p", [Reason]),
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

%% @doc listens for a new connection.
%% Based on the path, the loop can take several paths.
%% if the path is "/login" and there is post data, an attempt is made to 
%% start a new {@link agent_web_connection}.
%% On a successful start, a cookie is set that the key reference used by 
%% this module to link new connections
%% to the just started agent_web_connection.
%% 
%% On any other path, the cookie is checked.  The value of the cookie is 
%% looked up on an internal table to see 
%% if there is an active agent_web_connection.  If there is, further 
%% processing is done there, otherwise the request is denied.
loop(Req, Table) ->
	Path = Req:get(path),
	Post = case Req:get_primary_header_value("content-type") of
		"application/x-www-form-urlencoded" ++ _ ->
			Req:parse_post();
		_ ->
			%% TODO Change this to a custom parser rather than mochi's default.
			try mochiweb_multipart:parse_form(Req, fun file_handler/2) of
				Whoa ->
					Whoa
			catch
				_:_ ->
					%?DEBUG("Going with a blank post due to mulipart parse fail:  ~p:~p", [What, Why]),
					[]
			end
	end,
	%?DEBUG("parsed posts:  ~p", [Post]),
	case parse_path(Path) of
		{file, {File, Docroot}} ->
			Cookielist = Req:parse_cookie(),
			%?DEBUG("Cookielist:  ~p", [Cookielist]),
			case proplists:get_value("cpx_id", Cookielist) of
				undefined ->
					Reflist = erlang:ref_to_list(make_ref()),
					Cookie = make_cookie(Reflist),
					ets:insert(Table, {Reflist, undefined, undefined}),
					Language = io_lib:format("cpx_lang=~s; path=/", [determine_language(Req:get_header_value("Accept-Language"))]),
					?DEBUG("Setting cookie and serving file ~p", [string:concat(Docroot, File)]),
					Req:serve_file(File, Docroot, [{"Set-Cookie", Cookie}, {"Set-Cookie", Language}]);
				_Reflist ->
					Language = io_lib:format("cpx_lang=~s; path=/", [determine_language(Req:get_header_value("Accept-Language"))]),
					Req:serve_file(File, Docroot, [{"Set-Cookie", Language}])
			end;
		{api, Api} ->
			Cookie = cookie_good(Req:parse_cookie()),
			keep_alive(Cookie),
			Out = api(Api, Cookie, Post),
			Req:respond(Out)
	end.

file_handler(Name, ContentType) ->
	fun(N) -> file_data_handler(N, {Name, ContentType, <<>>}) end.

file_data_handler(eof, {Name, _ContentType, Acc}) ->
	?DEBUG("eof gotten", []),
	{Name, Acc};
file_data_handler(Data, {Name, ContentType, Acc}) ->
	Newacc = <<Acc/binary, Data/binary>>,
	fun(N) -> file_data_handler(N, {Name, ContentType, Newacc}) end.

determine_language(undefined) ->
	"en"; %% not requested, assume english
determine_language([]) ->
	"";
determine_language(String) ->
	[Head | Other] = util:string_split(String, ",", 2),
	[Lang |_Junk] = util:string_split(Head, ";"),
	case filelib:is_regular(string:concat(string:concat("www/agent/application/nls/", Lang), "/labels.js")) of
		true ->
			Lang;
		false ->
			% try the "super language" (eg en vs en-us) in case it's not in the list itself
			[SuperLang | _SubLang] = util:string_split(Lang, "-"),
			case filelib:is_regular(string:concat(string:concat("www/agent/application/nls/", SuperLang), "/labels.js")) of
				true ->
					SuperLang;
				false ->
					determine_language(Other)
			end
	end.

make_cookie(Value) ->
	io_lib:format("cpx_id=~p; path=/", [Value]).

keep_alive({_Reflist, _Salt, Conn}) when is_pid(Conn) ->
	agent_web_connection:keep_alive(Conn);
keep_alive(_) ->
	ok.

send_to_connection(badcookie, _Function, _Args) ->
	?DEBUG("sent to connection with bad cookie", []),
	check_cookie(badcookie);
send_to_connection({_Ref, _Salt, undefined} = Cookie, _Function, _Args) ->
	?DEBUG("sent to connection with no connection pid", []),
	check_cookie(Cookie);
send_to_connection({_Ref, _Salt, Conn}, <<"poll">>, _Args) ->
	agent_web_connection:poll(Conn, self()),
	receive
		{poll, Return} ->
			%?DEBUG("Got poll message, spitting back ~p", [Return]),
			 Return; 
		{kill, Headers, Body} -> 
			?DEBUG("Got a kill message with heads ~p and body ~p", [Headers, Body]),
			{408, Headers, Body}
	end;
send_to_connection(Cookie, Func, Args) when is_binary(Func) ->
	try list_to_existing_atom(binary_to_list(Func)) of
		Atom ->
			send_to_connection(Cookie, Atom, Args)
	catch
		error:badarg ->
			?reply_err(<<"no such function">>, <<"FUNCTION_NOEXISTS">>)
	end;
send_to_connection(Cookie, Func, Arg) when is_binary(Arg) ->
	send_to_connection(Cookie, Func, [Arg]);
send_to_connection({Ref, _Salt, Conn}, Function, Args) when is_pid(Conn) ->
	case is_process_alive(Conn) of
		false ->
			ets:delete(web_connections, Ref),
			api(checkcookie, badcookie, []);
		true ->
			case agent_web_connection:is_web_api(Function, length(Args) + 1) of
				false ->
					?reply_err(<<"no such function">>, <<"FUNCTION_NOEXISTS">>);
				true ->
					erlang:apply(agent_web_connection, Function, [Conn | Args])
			end
	end.

%% @doc {@web} Determine if the cookie the client sent can be associated
%% with a logged in agent.  This should be the first step of a login 
%% process.  If it replies true, then the client can skip the 
%% {@link get_salt/1} and {@link login/4} steps to immediately start a
%% poll.  All other times, the client should set the given cookie with all
%% subsequent web calls.  The next call after this is usually
%% {@link get_salt/1}.
%%
%% There are no arguments as anything important happens in the http
%% headers.  If the cookie is invalid, the reply will have a set-cookie
%% directive in its headers.
%% 
%% The result json is:
%% <pre> {
%% 	"login":     string(),
%% 	"profile":   string(),
%% 	"state":     string(),
%% 	"statedata": any(),
%% 	"statetime": timestamp(),
%% 	"timestamp": timestamp()
%%  "mediaload": any(); optional
%% }</pre>
check_cookie({_Reflist, _Salt, Conn}) when is_pid(Conn) ->
	%?DEBUG("Found agent_connection pid ~p", [Conn]),
	Agentrec = agent_web_connection:dump_agent(Conn),
	Basejson = [
		{<<"login">>, list_to_binary(Agentrec#agent.login)},
		{<<"profile">>, list_to_binary(Agentrec#agent.profile)},
		{<<"state">>, Agentrec#agent.state},
		{<<"statedata">>, agent_web_connection:encode_statedata(Agentrec#agent.statedata)},
		{<<"statetime">>, Agentrec#agent.lastchange},
		{<<"timestamp">>, util:now()}
	],
	Fulljson = case Agentrec#agent.state of
		oncall ->
			case agent_web_connection:mediaload(Conn) of
				undefined ->
					Basejson;
				MediaLoad ->
					[{<<"mediaload">>, {struct, MediaLoad}} | Basejson]
			end;
		_ ->
			Basejson
	end,
	Json = {struct, [
		{<<"success">>, true},
		{<<"result">>, Fulljson} |
		Fulljson
	]},
	{200, [], mochijson2:encode(Json)};
check_cookie(badcookie) ->
	?INFO("cookie not in ets", []),
	Reflist = erlang:ref_to_list(make_ref()),
	NewCookie = make_cookie(Reflist),
	ets:insert(web_connections, {Reflist, undefined, undefined}),
	Json = {struct, [
		{<<"success">>, false}, 
		{<<"message">>, <<"Your cookie was expired, issueing you a new one">>}, 
		{<<"errcode">>, <<"BAD_COOKIE">>}
	]},
	{200, [{"Set-Cookie", NewCookie}], mochijson2:encode(Json)};
check_cookie({_Reflist, _Salt, undefined}) ->
	?INFO("cookie found, no agent", []),
	Json = {struct, [
		{<<"success">>, false}, 
		{<<"message">>, <<"have cookie, but no agent">>},
		{<<"errcode">>, <<"NO_AGENT">>}
	]},
	{200, [], mochijson2:encode(Json)}.

%% @doc {@web} Get the salt and public key information to encrypt the 
%% password.  Should be the second step in logging in.  Remember the client
%% must be able to send the same cookie it got in the check cookie step.
%% If the cookie does not pass inspection, a salt and public key info will
%% still be sent, but there will be a new cookie header sent as well.  This
%% means this function does not allow for state recovery like 
%% {@link check_cookie/1} does.
%%
%% After getting a successful response from this web api call, move on to
%% {@link login/4}.
%%
%% There are no arguments for this request.
%% 
%% A result is:
%% <pre> {
%% 	"salt":   string(),
%% 	"pubkey": {
%% 		"E":   string(),
%% 		"N":   string()
%% 	}
%% }</pre>
get_salt(badcookie) ->
	Conn = undefined,
	Reflist = erlang:ref_to_list(make_ref()),
	Cookie = make_cookie(Reflist),
	Newsalt = integer_to_list(crypto:rand_uniform(0, 4294967295)),
	ets:insert(web_connections, {Reflist, Newsalt, Conn}),
	?DEBUG("created and sent salt for ~p", [Reflist]),
	[E, N] = get_pubkey(),
	PubKey = {struct, [
		{<<"E">>, list_to_binary(erlang:integer_to_list(E, 16))}, 
		{<<"N">>, list_to_binary(erlang:integer_to_list(N, 16))}
	]},
	{200, [{"Set-Cookie", Cookie}], mochijson2:encode({struct, [
		{success, true}, 
		{message, <<"Salt created, check salt property">>}, 
		{salt, list_to_binary(Newsalt)}, 
		{pubkey, PubKey},
		{<<"result">>, {struct, [
			{salt, list_to_binary(Newsalt)},
			{pubkey, PubKey}
		]}}
	]})};
get_salt({Reflist, _Salt, Conn}) ->
	Newsalt = integer_to_list(crypto:rand_uniform(0, 4294967295)),
	ets:insert(web_connections, {Reflist, Newsalt, Conn}),
	agent_web_connection:set_salt(Conn, Newsalt),
	?DEBUG("created and sent salt for ~p", [Reflist]),
	[E, N] = get_pubkey(),
	PubKey = {struct, [
		{<<"E">>, list_to_binary(erlang:integer_to_list(E, 16))}, 
		{<<"N">>, list_to_binary(erlang:integer_to_list(N, 16))}
	]},
	{200, [], mochijson2:encode({struct, [
		{success, true}, 
		{message, <<"Salt created, check salt property">>}, 
		{salt, list_to_binary(Newsalt)}, 
		{pubkey, PubKey},
		{<<"result">>, {struct, [
			{salt, list_to_binary(Newsalt)},
			{pubkey, PubKey}
		]}}
	]})}.

%% @doc {@web} Login and start an {@link agent_web_connection}.  This is
%% the second to last step in logging in a web client (the final one 
%% starting a poll).  Using the salt and public key information recieved in
%% {@link get_salt/1}, encrypt the password.  Using the built-in gui as an
%% example, the password is encrypted by via the javascript library jsbn:
%% `
%% var getSaltPubKey = 	getSaltResult.pubkey;
%% var rsa = new RSAKey();
%% rsa.setPublic(getSaltPubKey.N, getSaltPubKey.E);
%% rsa.encrypt(getSaltResult.salt + password);
%% '
%% Order of the salt and password is important.
%%
%% If voipdata is not defined, then it is assumed the agent will register a
%% phone via sip using thier login name.
%% 
%% The web api for this actually only takes 3 arguments in the `"args"' 
%% property of the request:
%%
%% `[username, password, options]'
%%
%% `username' and `password' are both string().  `options' is a json
%% object:
%% <pre> {
%% 	"voipendpointdata":  string(),
%% 	"voipendpoint":  "sip_registration" | "sip" | "iax2" | "h323" | "pstn",
%% 	"useoutbandring":  boolean(); optional
%% }</pre>
%% 
%% If `"voipendpoint"' is defined but `"voipendpointdata"' is not,
%% `"username"' is used.
%%
%% Note an agent starts out in a relased state with reason of default.
%%  
%% A result is:
%% `{
%% 	"profile":   string(),
%% 	"statetime": timestamp(),
%% 	"timestamp": timestamp()
%% }'
login(badcookie, _, _, _) ->
	?DEBUG("bad cookie", []),
	check_cookie(badcookie);
login({Ref, undefined, _Conn}, _, _, _) ->
	?reply_err(<<"Your client is requesting a login without first requesting a salt.">>, <<"NO_SALT">>);
login({Ref, Salt, _Conn}, Username, Password, Opts) ->
	Endpointdata = proplists:get_value(voipendpointdata, Opts),
	Endpoint = case {proplists:get_value(voipendpoint, Opts), Endpointdata} of
		{undefined, _} ->
			{sip_registration, Username};
		{sip_registration, undefined} ->
			{sip_registation, Username};
		{EndpointType, _} ->
			{EndpointType, Endpointdata}
	end,
	Bandedness = case proplists:get_value(use_outband_ring, Opts) of
		true ->
			outband;
		_ ->
			inband
	end,
	try decrypt_password(Password) of
		Decrypted ->
			try
				Salt = string:substr(Decrypted, 1, length(Salt)),
				string:substr(Decrypted, length(Salt) + 1)
			of
				DecryptedPassword ->
					case agent_auth:auth(Username, DecryptedPassword) of
						deny ->
							?reply_err(<<"Authentication failed">>, <<"AUTH_FAILED">>);
						{allow, Id, Skills, Security, Profile} ->
							Agent = #agent{
								id = Id, 
								defaultringpath = Bandedness, 
								login = Username, 
								skills = Skills, 
								profile=Profile, 
								password=DecryptedPassword
							},
							case agent_web_connection:start(Agent, Security) of
								{ok, Pid} ->
									?INFO("~s logged in with endpoint ~p", [Username, Endpoint]),
									gen_server:call(Pid, {set_endpoint, Endpoint}),
									linkto(Pid),
									#agent{lastchange = StateTime, profile = EffectiveProfile} = agent_web_connection:dump_agent(Pid),
									ets:insert(web_connections, {Ref, Salt, Pid}),
									?DEBUG("connection started for ~p ~p", [Ref, Username]),
									{200, [], mochijson2:encode({struct, [
										{success, true},
										{<<"result">>, {struct, [
											{<<"profile">>, list_to_binary(EffectiveProfile)},
											{<<"statetime">>, StateTime},
											{<<"timestamp">>, util:now()}]}}]})};
								ignore ->
									?WARNING("Ignore message trying to start connection for ~p ~p", [Ref, Username]),
									?reply_err(<<"login error">>, <<"UNKNOWN_ERROR">>);
								{error, Error} ->
									?ERROR("Error ~p trying to start connection for ~p ~p", [Error, Ref, Username]),
									?reply_err(<<"login error">>, <<"UNKNOWN_ERROR">>)
							end
					end
			catch
				error:{badmatch, _} ->
					?NOTICE("authentication failure for ~p using salt ~p (expected ~p)", [Username, string:substr(Decrypted, 1, length(Salt)), Salt]),
					?reply_err(<<"Invalid salt">>, <<"NO_SALT">>)
			end
	catch
		error:decrypt_failed ->
			?reply_err(<<"Password decryption failed">>, <<"DECRYPT_FAILED">>)
	end.

%% @doc {@web} Returns a list of queues configured in the system.  Useful
%% if you want agents to be able to place media into a queue.
%% Result:
%% `[{
%% 	"name": string()
%% }]'
get_queue_list() ->
	Queues = call_queue_config:get_queues(),
	QueuesEncoded = [{struct, [
		{<<"name">>, list_to_binary(Q#call_queue.name)}
	]} || Q <- Queues],
	?reply_success(QueuesEncoded).

%% @doc {@web} Returns a list of clients confured in the system.  Useful
%% to allow agents to make outbound media.
%% Result:
%% `[{
%% 	"label":  string(),
%% 	"id":     string()
%% }]'
get_brand_list() ->
	Brands = call_queue_config:get_clients(),
	BrandsEncoded = [{struct, [
		{<<"label">>, list_to_binary(C#client.label)},
		{<<"id">>, list_to_binary(C#client.id)}
	]} || C <- Brands, C#client.label =/= undefined],
	?reply_success(BrandsEncoded).

%% @doc {@web} Returns a list of options for use when an agents wants to
%% go released.
%% Result:
%% `[{
%% 	"label":  string(),
%% 	"id":     string(),
%% 	"bias":   -1 | 0 | 1
%% }]'
get_release_opts() ->
	Opts = agent_auth:get_releases(),
	Encoded = [{struct, [
		{<<"label">>, list_to_binary(R#release_opt.label)},
		{<<"id">>, R#release_opt.id},
		{<<"bias">>, R#release_opt.bias}
	]} || R <- Opts],
	?reply_success(Encoded).

api(api, Cookie, Post) ->
	Request = proplists:get_value("request", Post),
	{struct, Props} = mochijson2:decode(Request),
	%?DEBUG("The request:  ~p", [Props]),
	case {proplists:get_value(<<"function">>, Props), proplists:get_value(<<"args">>, Props)} of
		{undefined, _} ->
			?reply_err(<<"no function to call">>, <<"NO_FUNCTION">>);
		{<<"check_cookie">>, _} ->
			check_cookie(Cookie);
		{<<"get_salt">>, _} ->
			get_salt(Cookie);
		{<<"login">>, [Username, Password]} ->
			login(Cookie, binary_to_list(Username), binary_to_list(Password), []);
		{<<"login">>, [Username, Password, {struct, LoginProps}]} ->
			LoginOpts = lists:flatten([case X of
				{<<"voipendpointdata">>, <<>>} ->
					{voipendpointdata, undefined};
				{<<"voipendpointdata">>, Bin} ->
					{voipendpointdata, binary_to_list(Bin)};
				{<<"voipendpoint">>, <<"sip_registration">>} ->
					{voipendpoint, sip_registration};
				{<<"voipendpoint">>, <<"sip">>} ->
					{voipendpoint, sip};
				{<<"voipendpoint">>, <<"iax2">>} ->
					{voipendpoint, iax2};
				{<<"voipendpoint">>, <<"h323">>} -> 
					{voipendpoint, h323};
				{<<"voipendpoint">>, <<"pstn">>} ->
					{voipendpoint, pstn};
				{<<"useoutbandring">>, true} ->
					use_outband_ring;
				{_, _} ->
					[]
			end || X <- LoginProps]),
			login(Cookie, binary_to_list(Username), binary_to_list(Password), LoginOpts);
		{<<"get_brand_list">>, _} ->
			get_brand_list();
		{<<"get_queue_list">>, _} ->
			get_queue_list();
		{<<"get_release_opts">>, _} ->
			get_release_opts();
		{Function, Args} ->
			send_to_connection(Cookie, Function, Args)
	end;
api(checkcookie, Cookie, _Post) ->
	check_cookie(Cookie);
api(getsalt, badcookie, _Post) -> %% badcookie when getting a salt
	get_salt(badcookie);
api(Apirequest, badcookie, _Post) ->
	?INFO("bad cookie for request ~p", [Apirequest]),
	Reflist = erlang:ref_to_list(make_ref()),
	Cookie = make_cookie(Reflist),
	ets:insert(web_connections, {Reflist, undefined, undefined}),
	{403, [{"Set-Cookie", Cookie}], <<"Your session was reset due to a lack of keepalive requests, please log back in.">>};
api(logout, {Reflist, _Salt, Conn}, _Post) ->
	ets:insert(web_connections, {Reflist, undefined, undefined}),
	Cookie = io_lib:format("cpx_id=~p; path=/; Expires=Tue, 29-Mar-2005 19:30: 42 GMT; Max-Age=86400", [Reflist]),
	catch agent_web_connection:api(Conn, logout),
	{200, [{"Set-Cookie", Cookie}], mochijson2:encode({struct, [{success, true}]})};
api(login, {_Reflist, undefined, _Conn}, _Post) ->
	{200, [], mochijson2:encode({struct, [{success, false}, {message, <<"Your client is requesting a login without first requesting a salt.">>}]})};
api(login, {Reflist, Salt, _Conn} = Cookie, Post) ->
	Username = proplists:get_value("username", Post, ""),
	Password = proplists:get_value("password", Post, ""),
	Opts = [],
	Opts2 = case proplists:get_value("voipendpointdata", Post) of
		undefined ->
			Opts;
		[] ->
			Opts;
		Other ->
			[{voipendpointdata, Other} | Opts]
	end,
	Opts3 = case proplists:get_value("voipendpoint", Post) of
		"SIP Registration" ->
			[{voipendpoint, sip_registration} | Opts2];
		"SIP URI" ->
			[{voipendpoint, sip} | Opts2];
		"IAX2 URI" ->
			[{voipendpoint, iax2} | Opts2];
		"H323 URI" ->
			[{voipendpoint, h323} | Opts2];
		"PSTN Number" ->
			[{voipendpoint, pstn} | Opts2];
		_ ->
			Opts2
	end,
	Opts4 = case proplists:get_value("useoutbandring", Post) of
		"useoutbandring" ->
			[use_outband_ring | Opts3];
		_ ->
			Opts3
	end,
	login(Cookie, Username, Password, Opts4);
api(getsalt, {Reflist, Salt, Conn}, _Post) ->
	get_salt({Reflist, Salt, Conn});
api(_Api, {_Reflist, _Salt, undefined}, _Post) ->
	{403, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"no connection">>}]})};
	
api(brandlist, {_Reflist, _Salt, _Conn}, _Post) ->
	case call_queue_config:get_clients() of
	[] ->
		{200, [], mochijson2:encode({struct, [{success, false}, {message, <<"No brands defined">>}]})};
	Brands ->
		Converter = fun
			(#client{label = undefined}, Acc) ->
				Acc;
			(#client{label = Label, id = ID}, Acc) ->
				[{struct, [{<<"label">>, list_to_binary(Label)}, {<<"id">>, list_to_binary(ID)}]} | Acc]
		end,
		Jsons = lists:foldl(Converter, [], Brands),
		{200, [], mochijson2:encode({struct, [{success, true}, {<<"brands">>, Jsons}]})}
	end;
api(queuelist, {_Reflist, _Salt, _Conn}, _Post) ->
	case call_queue_config:get_queues() of
	[] ->
		{200, [], mochijson2:encode({struct, [{success, false}, {message, <<"No queues defined">>}]})};
	Brands ->
		Converter = fun
			(#call_queue{name = Name}, Acc) ->
				[{struct, [{<<"name">>, list_to_binary(Name)}]} | Acc]
		end,
		Jsons = lists:foldl(Converter, [], Brands),
		{200, [], mochijson2:encode({struct, [{success, true}, {<<"queues">>, Jsons}]})}
	end;

api(releaseopts, {_Reflist, _Salt, _Conn}, _Post) ->
	Releaseopts = agent_auth:get_releases(),
	Converter = fun(#release_opt{label = Label, id = Id, bias = Bias}) ->
		{struct, [{<<"label">>, list_to_binary(Label)}, {<<"id">>, Id}, {<<"bias">>, Bias}]}
	end,
	Jsons = lists:map(Converter, Releaseopts),
	{200, [], mochijson2:encode({struct, [{success, true}, {<<"options">>, Jsons}]})};	
	
api(poll, {_Reflist, _Salt, Conn}, []) when is_pid(Conn) ->
	agent_web_connection:poll(Conn, self()),
	receive
		{poll, Return} ->
			%?DEBUG("Got poll message, spitting back ~p", [Return]),
			 Return; 
		{kill, Headers, Body} -> 
			?DEBUG("Got a kill message with heads ~p and body ~p", [Headers, Body]),
			{408, Headers, Body}
	end;
api({undefined, Path}, {_Reflist, _Salt, Conn}, Post) when is_pid(Conn) ->
	case Post of
		[] ->
			agent_web_connection:api(Conn, {undefined, Path});
		_ ->
			agent_web_connection:api(Conn, {undefined, Path, Post})
	end;
api(Api, {_Reflist, _Salt, Conn}, []) when is_pid(Conn) ->
	case agent_web_connection:api(Conn, Api) of
		{Code, Headers, Body} ->
			{Code, Headers, Body}
	end;
api(Api, {_Reflist, _Salt, Conn}, Post) when is_pid(Conn) ->
	case agent_web_connection:api(Conn, {Api, Post}) of
		{Code, Headers, Body} ->
			{Code, Headers, Body}
	end;
api(Api, Whatever, _Post) ->
	?DEBUG("Login required for api ~p with ref/salt/conn ~p", [Api, Whatever]),
	{200, [], mochijson2:encode({struct, [{success, false}, {message, <<"Login required">>}]})}.

%% @doc determine if hte given cookie data is valid
-spec(cookie_good/1 :: ([{string(), string()}]) -> 'badcookie' | web_connection()).
cookie_good([]) ->
	badcookie;
cookie_good(Allothers) ->
	case proplists:get_value("cpx_id", Allothers) of
		undefined ->
			badcookie;
		Reflist ->
			case ets:lookup(web_connections, Reflist) of
				[] ->
					badcookie;
				[{Reflist, Salt, Conn}] ->
					{Reflist, Salt, Conn}
			end
	end.
	
%% @doc determine if the given path is an api call, or if it's a file request.
parse_path(Path) ->
	% easy tests first.
	%?DEBUG("Path:  ~s", [Path]),
	case Path of
		"/" ->
			{file, {"index.html", "www/agent/"}};
		"/api" ->
			{api, api};
		"/poll" ->
			{api, poll};
		"/logout" ->
			{api, logout};
		"/login" ->
			{api, login};
		"/getsalt" ->
			{api, getsalt};
		"/releaseopts" ->
			{api, releaseopts};
		"/brandlist" ->
			{api, brandlist};
		"/queuelist" ->
			{api, queuelist};
		"/checkcookie" ->
			{api, checkcookie};
		_Other ->
			["" | Tail] = util:string_split(Path, "/"),
			case Tail of 
				["dynamic" | Moretail] ->
					File = string:join(Moretail, "/"),
					Dynamic = case application:get_env(cpx, webdir_dynamic) of
						undefined ->
							"www/dynamic";
						{ok, WebDirDyn} ->
							WebDirDyn
					end,
					case filelib:is_regular(string:join([Dynamic, File], "/")) of
						true ->
							{file, {File, Dynamic}};
						false ->
							{api, {undefined, Path}}
					end;
				["state", Statename] ->
					{api, {set_state, Statename}};
				["state", Statename, Statedata] ->
					{api, {set_state, Statename, Statedata}};
				["ack", Counter] ->
					{api, {ack, Counter}};
				["err", Counter] ->
					{api, {err, Counter}};
				["err", Counter, Message] ->
					{api, {err, Counter, Message}};
				["dial", Number] ->
					{api, {dial, Number}};
				["get_avail_agents"] ->
					{api, get_avail_agents};
				["agent_transfer", Agent] ->
					{api, {agent_transfer, Agent}};
				["agent_transfer", Agent, CaseID] ->
					{api, {agent_transfer, Agent, CaseID}};
				["media"] ->
					{api, media};
				["mediapull" | Pulltail] ->
					?DEBUG("pulltail:  ~p", [Pulltail]),
					% TODO Is this even used anymore?
					{api, {mediapull, Pulltail}};
				["mediapush"] ->
					{api, mediapush};
				["warm_transfer", Number] ->
					{api, {warm_transfer, Number}};
				["warm_transfer_complete"] ->
					{api, warm_transfer_complete};
				["warm_transfer_cancel"] ->
					{api, warm_transfer_cancel};
				["queue_transfer", Number] ->
					{api, {queue_transfer, Number}};
%				["queue_transfer", Number, CaseID] ->
%					{api, {queue_transfer, Number, CaseID}};
				["init_outbound", Client, Type] ->
					{api, {init_outbound, Client, Type}};
				["supervisor" | Supertail] ->
					{api, {supervisor, Supertail}};
				_Allother ->
					% is there an actual file to serve?
					case {filelib:is_regular(string:concat("www/agent", Path)), filelib:is_regular(string:concat("www/contrib", Path))} of
						{true, false} ->
							{file, {string:strip(Path, left, $/), "www/agent/"}};
						{false, true} ->
							{file, {string:strip(Path, left, $/), "www/contrib/"}};
						{true, true} ->
							{file, {string:strip(Path, left, $/), "www/contrib/"}};
						{false, false} ->
							{api, {undefined, Path}}
					end
			end
	end.

get_pubkey() ->
	% TODO - this is going to break again for R15A, fix before then
	Entry = case public_key:pem_to_der("./key") of
		{ok, [Ent]} ->
			Ent;
		[Ent] ->
			Ent
	end,
	{ok,{'RSAPrivateKey', 'two-prime', N , E, _D, _P, _Q, _E1, _E2, _C, _Other}} =  public_key:decode_private_key(Entry),
	[E, N].

decrypt_password(Password) ->
	% TODO - this is going to break again for R15A, fix before then
	Entry = case public_key:pem_to_der("./key") of
		{ok, [Ent]} ->
			Ent;
		[Ent] ->
			Ent
	end,
	{ok,{'RSAPrivateKey', 'two-prime', N , E, D, _P, _Q, _E1, _E2, _C, _Other}} =  public_key:decode_private_key(Entry),
	PrivKey = [crypto:mpint(E), crypto:mpint(N), crypto:mpint(D)],
	Bar = crypto:rsa_private_decrypt(util:hexstr_to_bin(Password), PrivKey, rsa_pkcs1_padding),
	binary_to_list(Bar).

-ifdef(TEST).

-define(url(Path), lists:append(["http://127.0.0.1:", integer_to_list(?PORT), Path])).

cooke_file_test_() ->
	{
		foreach,
		fun() ->
			agent_web_listener:start(),
			inets:start(),
			{ok, Httpc} = inets:start(httpc, [{profile, test_prof}]),
			Httpc
		end,
		fun(Httpc) ->
			inets:stop(httpc, Httpc),
			inets:stop(),
			agent_web_listener:stop()
		end,
		[
			fun(_Httpc) ->
				{"Get a cookie on index page request",
				fun() ->
					{ok, Result} = http:request(?url("/")),
					?assertMatch({_Statusline, _Headers, _Boddy}, Result),
					{_Line, Head, _Body} = Result,
					?CONSOLE("Das head:  ~p", [Head]),
					Cookies = proplists:get_all_values("set-cookie", Head),
					Test = fun(C) ->
						case util:string_split(C, "=", 2) of
							["cpx_id", _Whatever] ->
								true;
							_Else ->
								false
						end
					end,
					?CONSOLE("Hmmm, cookie:  ~p", [Cookies]),
					?assert(lists:any(Test, Cookies))
				end}
			end,
			fun(_Httpc) ->
				{"Try to get a page with a bad cookie",
				fun() ->
					{ok, {{_Httpver, Code, _Message}, Head, _Body}} = http:request(get, {?url("/"), [{"Cookie", "goober=snot"}]}, [], []),
					?assertEqual(200, Code),
					?CONSOLE("~p", [Head]),
					Cookies = proplists:get_all_values("set-cookie", Head),
					Test = fun(C) ->
						case util:string_split(C, "=", 2) of
							["cpx_id", _Whatever] ->
								true;
							_Else ->
								false
						end
					end,
					?assertEqual(true, lists:any(Test, Cookies))
				end}
			end,
			fun(_Httpc) ->
				{"Get a cookie, then a request with that cookie",
				fun() ->
					{ok, {_Statusline, Head, _Body}} = http:request(?url("/")),
					Cookie = proplists:get_all_values("set-cookie", Head),
					Cookielist = lists:map(fun(I) -> {"Cookie", I} end, Cookie),
					{ok, {{_Httpver, Code, _Message}, Head2, _Body2}} = http:request(get, {?url(""), Cookielist}, [], []),
					Cookie2 = proplists:get_all_values("set-cookie", Head2),
					Test = fun(C) ->
						case util:string_split(C, "=", 2) of
							["cpx_id", _Whatever] ->
								true;
							_Else ->
								false
						end
					end,
					?assertEqual(false, lists:any(Test, Cookie2)),
					?assertEqual(200, Code)
				end}
			end
		]
	}.

cookie_api_test_() ->
	{
		foreach,
		fun() ->
			agent_web_listener:start(),
			inets:start(),
			{ok, Httpc} = inets:start(httpc, [{profile, test_prof}]),
			{ok, {_Statusline, Head, _Body}} = http:request(?url("")),
			Cookie = proplists:get_all_values("set-cookie", Head),
			?CONSOLE("cookie_api_test_ setup ~p", [Cookie]),
			Cookieproplist = lists:map(fun(I) -> {"Cookie", I} end, Cookie),
			?CONSOLE("cookie proplist ~p", [Cookieproplist]),
			{Httpc, Cookieproplist}
		end,
		fun({Httpc, _Cookie}) ->
			inets:stop(httpc, Httpc),
			inets:stop(),
			agent_web_listener:stop()
		end,
		[
			fun({_Httpc, Cookielist}) ->
				{"Get a salt with a valid cookie",
				fun() ->
					{ok, {{_Ver, Code, _Msg}, _Head, Body}} = http:request(get, {?url("/getsalt"), Cookielist}, [], []),
					?CONSOLE("body:  ~p", [Body]),
					{struct, Pairs} = mochijson2:decode(Body),
					?assertEqual(200, Code),
					?assertEqual(true, proplists:get_value(<<"success">>, Pairs)),
					?assertEqual(<<"Salt created, check salt property">>, proplists:get_value(<<"message">>, Pairs)),
					?assertNot(undefined =:= proplists:get_value(<<"salt">>, Pairs))
				end}
			end,
			fun({_Httpc, _Cookie}) ->
				{"Get a salt with an invalid cookie should issue a new cookie",
				fun() ->
					{ok, {{_Ver, Code, _Msg}, Head, Body}} = http:request(get, {?url("/getsalt"), [{"Cookie", "cpx_id=snot"}]}, [], []),
					?assertEqual(200, Code),
					?assertNot(noexist =:= proplists:get_value("set-cookie", Head, noexist)),
					?assertMatch("{\"success\":true"++_, Body)
				end}
			end
		]
	}.
	
web_connection_login_test_() ->
	{
		foreach,
		fun() ->
			mnesia:stop(),
			mnesia:delete_schema([node()]),
			mnesia:create_schema([node()]),
			mnesia:start(),
			agent_manager:start([node()]),
			agent_web_listener:start(),
			inets:start(),
			{ok, Httpc} = inets:start(httpc, [{profile, test_prof}]),
			{ok, {_Statusline, Head, _Body}} = http:request(?url("")),
			?CONSOLE("request head ~p", [Head]),
			Cookies = proplists:get_all_values("set-cookie", Head),
			Cookielist = lists:map(fun(I) -> {"Cookie", I} end, Cookies), 
			?CONSOLE("~p", [agent_auth:add_agent("testagent", "pass", [english], agent, "Default")]),
			Getsalt = fun() ->
				{ok, {_Statusline2, _Head2, Body2}} = http:request(get, {?url("/getsalt"), Cookielist}, [], []),
				?CONSOLE("Body2:  ~p", [Body2]),
				{struct, Jsonlist} = mochijson2:decode(Body2),
				binary_to_list(proplists:get_value(<<"salt">>, Jsonlist))
			end,
			
			{Httpc, Cookielist, Getsalt}
		end,
		fun({Httpc, _Cookie, _Getsalt}) ->
			inets:stop(httpc, Httpc),
			inets:stop(),
			agent_web_listener:stop(),
			agent_manager:stop(),
			agent_auth:destroy("testagent"),
			mnesia:stop(),
			mnesia:delete_schema([node()])
		end,
		[
			fun({_Httpc, Cookie, _Salt}) ->
				{"Trying to login before salt request",
				fun() ->
					Key = [crypto:mpint(N) || N <- get_pubkey()], % cheating a little here...
					Salted = crypto:rsa_public_encrypt(list_to_binary(string:concat("123345", "badpass")), Key, rsa_pkcs1_padding),
					{ok, {_Statusline, _Head, Body}} = http:request(post, {?url("/login"), Cookie, "application/x-www-form-urlencoded", lists:append(["username=badun&password=", util:bin_to_hexstr(Salted), "&voipendpoint=SIP Registration"])}, [], []),
					?CONSOLE("BODY:  ~p", [Body]),
					{struct, Json} = mochijson2:decode(Body),
					?assertEqual(false, proplists:get_value(<<"success">>, Json)),
					?assertEqual(<<"Your client is requesting a login without first requesting a salt.">>, proplists:get_value(<<"message">>, Json))
				end}
			end,
			fun({_Httpc, Cookie, _Salt}) ->
				{"Trying to login before salt request, refined api",
				fun() ->
					Key = [crypto:mpint(N) || N <- get_pubkey()], % cheating a little here...
					Salted = crypto:rsa_public_encrypt(list_to_binary(string:concat("123345", "badpass")), Key, rsa_pkcs1_padding),
					Request = mochijson2:encode({struct, [
						{<<"function">>, <<"login">>},
						{<<"args">>, [
							<<"badun">>,
							list_to_binary(util:bin_to_hexstr(Salted))
						]}
					]}),
					RequestBody = binary_to_list(list_to_binary(lists:flatten(["request=", Request]))),
					{ok, {_Statusline, _Head, Body}} = http:request(post, 
						{?url("/api"), 
						Cookie, 
						"application/x-www-form-urlencoded",
						RequestBody},
					[], []),
					?CONSOLE("BODY:  ~p", [Body]),
					{struct, Json} = mochijson2:decode(Body),
					?assertEqual(false, proplists:get_value(<<"success">>, Json)),
					?assertEqual(<<"Your client is requesting a login without first requesting a salt.">>, proplists:get_value(<<"message">>, Json))
				end}
			end,
			fun({_Httpc, Cookie, Salt}) ->
				{"Login with a bad pw",
				fun() ->
					Key = [crypto:mpint(N) || N <- get_pubkey()], % cheating a little here...
					Salted = crypto:rsa_public_encrypt(list_to_binary(string:concat(Salt(),"badpass")), Key, rsa_pkcs1_padding),
					{ok, {_Statusline, _Head, Body}} = http:request(post, {?url("/login"), Cookie, "application/x-www-form-urlencoded", lists:append(["username=testagent&password=", util:bin_to_hexstr(Salted), "&voipendpoint=SIP Registration"])}, [], []),
					?CONSOLE("BODY:  ~p", [Body]),
					{struct, Json} = mochijson2:decode(Body),
					?assertEqual(false, proplists:get_value(<<"success">>, Json)),
					?assertEqual(<<"Authentication failed">>, proplists:get_value(<<"message">>, Json))
				end}
			end,
			fun({_Httpc, Cookie, Salt}) ->
				{"Login with a bad pw refined api",
				fun() ->
					Key = [crypto:mpint(N) || N <- get_pubkey()], % cheating a little here...
					Salted = crypto:rsa_public_encrypt(list_to_binary(string:concat(Salt(),"badpass")), Key, rsa_pkcs1_padding),
					RequestJson = mochijson2:encode({struct, [
						{<<"function">>, <<"login">>},
						{<<"args">>, [
							<<"testagent">>,
							list_to_binary(util:bin_to_hexstr(Salted))
						]}
					]}),
					RequestBody = binary_to_list(list_to_binary(lists:flatten(["request=", RequestJson]))),
					{ok, {_Statusline, _Head, Body}} = http:request(post, {?url("/api"), Cookie, "application/x-www-form-urlencoded", RequestBody}, [], []),
					?CONSOLE("BODY:  ~p", [Body]),
					{struct, Json} = mochijson2:decode(Body),
					?assertEqual(false, proplists:get_value(<<"success">>, Json)),
					?assertEqual(<<"Authentication failed">>, proplists:get_value(<<"message">>, Json))
				end}
			end,
			fun({_Httpc, Cookie, Salt}) ->
				{"Login with bad un",
				fun() ->
					Key = [crypto:mpint(N) || N <- get_pubkey()], % cheating a little here...
					Salted = crypto:rsa_public_encrypt(list_to_binary(string:concat(Salt(),"pass")), Key, rsa_pkcs1_padding),
					{ok, {_Statusline, _Head, Body}} = http:request(post, {?url("/login"), Cookie, "application/x-www-form-urlencoded", lists:append(["username=badun&password=", util:bin_to_hexstr(Salted), "&voipendpoint=SIP Registration"])}, [], []),
					?CONSOLE("BODY:  ~p", [Body]),
					{struct, Json} = mochijson2:decode(Body),
					?assertEqual(false, proplists:get_value(<<"success">>, Json)),
					?assertEqual(<<"Authentication failed">>, proplists:get_value(<<"message">>, Json))
				end}
			end,
			fun({_Httpc, Cookie, Salt}) ->
				{"Login with bad un refined api",
				fun() ->
					Key = [crypto:mpint(N) || N <- get_pubkey()], % cheating a little here...
					Salted = crypto:rsa_public_encrypt(list_to_binary(string:concat(Salt(),"pass")), Key, rsa_pkcs1_padding),
					Request = mochijson2:encode({struct, [
						{<<"function">>, <<"login">>},
						{<<"args">>, [
							<<"badun">>,
							list_to_binary(util:bin_to_hexstr(Salted))
						]}
					]}),
					RequestBody = binary_to_list(list_to_binary(lists:flatten(["request=", Request]))),
					{ok, {_Statusline, _Head, Body}} = http:request(post, {?url("/api"), Cookie, "application/x-www-form-urlencoded", RequestBody}, [], []),
					?CONSOLE("BODY:  ~p", [Body]),
					{struct, Json} = mochijson2:decode(Body),
					?assertEqual(false, proplists:get_value(<<"success">>, Json)),
					?assertEqual(<<"Authentication failed">>, proplists:get_value(<<"message">>, Json))
				end}
			end,
			fun({_Httpc, Cookie, Salt}) ->
				{"Login with bad salt",
				fun() ->
					Key = [crypto:mpint(N) || N <- get_pubkey()], % cheating a little here...
					Salt(),
					Salted = crypto:rsa_public_encrypt(list_to_binary(string:concat("345678","pass")), Key, rsa_pkcs1_padding),
					{ok, {_Statusline, _Head, Body}} = http:request(post, {?url("/login"), Cookie, "application/x-www-form-urlencoded", lists:append(["username=testagent&password=", util:bin_to_hexstr(Salted), "&voipendpoint=SIP Registration"])}, [], []),
					?CONSOLE("BODY:  ~p", [Body]),
					{struct, Json} = mochijson2:decode(Body),
					?assertEqual(false, proplists:get_value(<<"success">>, Json)),
					?assertEqual(<<"Invalid salt">>, proplists:get_value(<<"message">>, Json))
				end}
			end,
			fun({_Httpc, Cookie, Salt}) ->
				{"Login with bad salt refined api",
				fun() ->
					Key = [crypto:mpint(N) || N <- get_pubkey()], % cheating a little here...
					Salt(),
					Salted = crypto:rsa_public_encrypt(list_to_binary(string:concat("345678","pass")), Key, rsa_pkcs1_padding),
					Request = mochijson2:encode({struct, [
						{<<"function">>, <<"login">>},
						{<<"args">>, [
							<<"testagent">>,
							list_to_binary(util:bin_to_hexstr(Salted))
						]}
					]}),
					RequestBody = binary_to_list(list_to_binary(lists:flatten(["request=", Request]))),
					{ok, {_Statusline, _Head, Body}} = http:request(post, {?url("/api"), Cookie, "application/x-www-form-urlencoded", RequestBody}, [], []),
					?CONSOLE("BODY:  ~p", [Body]),
					{struct, Json} = mochijson2:decode(Body),
					?assertEqual(false, proplists:get_value(<<"success">>, Json)),
					?assertEqual(<<"Invalid salt">>, proplists:get_value(<<"message">>, Json))
				end}
			end,





			fun({_Httpc, Cookie, Salt}) ->
				{"Login properly",
				fun() ->
					Key = [crypto:mpint(N) || N <- get_pubkey()], % cheating a little here...
					Salted = crypto:rsa_public_encrypt(list_to_binary(string:concat(Salt(),"pass")), Key, rsa_pkcs1_padding),
					{ok, {_Statusline, _Head, Body}} = http:request(post, {?url("/login"), Cookie, "application/x-www-form-urlencoded", lists:append(["username=testagent&password=", util:bin_to_hexstr(Salted), "&voipendpoint=SIP Registration"])}, [], []),
					?CONSOLE("BODY:  ~p", [Body]),
					{struct, Json} = mochijson2:decode(Body),
					?assertEqual(true, proplists:get_value(<<"success">>, Json))
				end}
			end,
			fun({_Httpc, Cookie, Salt}) ->
				{"Login proper with refined api",
				fun() ->
					Key = [crypto:mpint(N) || N <- get_pubkey()],
					Salted = crypto:rsa_public_encrypt(list_to_binary(string:concat(Salt(), "pass")), Key, rsa_pkcs1_padding),
					BodyJson = mochijson2:encode({struct, [
						{<<"function">>, <<"login">>},
						{<<"args">>, [
							<<"testagent">>,
 							list_to_binary(util:bin_to_hexstr(Salted))
						]}
					]}),
					{ok, {_, _, Body}} = http:request(post, {?url("/api"), Cookie, "application/x-www-form-urlencoded", binary_to_list(list_to_binary(lists:flatten(["request=", BodyJson])))}, [], []),
					?CONSOLE("BODY:  ~p", [Body]),
					{struct, Json} = mochijson2:decode(Body),
					?assertEqual(true, proplists:get_value(<<"success">>, Json))
				end}
			end
		]
	}.



% TODO add tests for interaction w/ agent, agent_manager

-define(PATH_TEST_SET, [
		{"/", {file, {"index.html", "www/agent/"}}},
		{"/poll", {api, poll}},
		{"/logout", {api, logout}},
		{"/login", {api, login}},
		{"/getsalt", {api, getsalt}},
		{"/state/teststate", {api, {set_state, "teststate"}}},
		{"/state/teststate/statedata", {api, {set_state, "teststate", "statedata"}}},
		{"/ack/7", {api, {ack, "7"}}},
		{"/err/89", {api, {err, "89"}}},
		{"/err/74/testmessage", {api, {err, "74", "testmessage"}}},
		{"/index.html", {file, {"index.html", "www/agent/"}}},
		{"/otherfile.ext", {api, {undefined, "/otherfile.ext"}}},
		{"/other/path", {api, {undefined, "/other/path"}}},
		{"/releaseopts", {api, releaseopts}},
		{"/brandlist", {api, brandlist}},
		{"/queuelist", {api, queuelist}},
		{"/checkcookie", {api, checkcookie}},
		{"/dial/12345", {api, {dial, "12345"}}},
		{"/get_avail_agents", {api, get_avail_agents}},
		{"/agent_transfer/agent@domain", {api, {agent_transfer, "agent@domain"}}},
		{"/agent_transfer/agent@domain/1234", {api, {agent_transfer, "agent@domain", "1234"}}},
		{"/mediapush", {api, mediapush}},
		{"/dynamic/test.html", {file, {"test.html", "www/dynamic"}}}
	]
).

path_parse_test_() ->
	{generator,
	fun() ->
		Test = fun({Path, Expected}) ->
			Name = string:concat("Testing path ", Path),
			{Name, fun() -> ?assertEqual(Expected, parse_path(Path)) end}
		end,
		lists:map(Test, ?PATH_TEST_SET)
	end}.

cookie_good_test_() ->
	[
		{"A blanke cookie",
		fun() ->
			?assertEqual(badcookie, cookie_good([]))
		end},
		{"An invalid cookie",
		fun() ->
			?assertEqual(badcookie, cookie_good([{"cookiekey", "cookievalue"}]))
		end},
		{"A well formed cookie, but not in ets",
		fun() ->
			ets:new(web_connections, [set, public, named_table]),
			Reflist = erlang:ref_to_list(make_ref()),
			?assertEqual(badcookie, cookie_good([{"cpx_id", Reflist}])),
			ets:delete(web_connections)
		end},
		{"A well formed cookie in the ets",
		fun() ->
			ets:new(web_connections, [set, public, named_table]),
			Reflist = erlang:ref_to_list(make_ref()),
			ets:insert(web_connections, {Reflist, undefined, undefined}),
			?assertEqual({Reflist, undefined, undefined}, cookie_good([{"cpx_id", Reflist}])),
			ets:delete(web_connections)
		end}
	].
	
	

-define(MYSERVERFUNC, fun() -> {ok, Pid} = start_link(), unlink(Pid), {?MODULE, fun() -> stop() end} end).

-include("gen_server_test.hrl").


-endif.
