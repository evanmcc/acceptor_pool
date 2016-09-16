-module(acceptor).

-behaviour(acceptor_loop).

%% public api

-export([spawn_opt/6]).

%% private api

-export([init_it/7]).

%% acceptor_loop api

-export([acceptor_continue/3]).
-export([acceptor_terminate/3]).

-type option() :: {spawn_opt, [proc_lib:spawn_option()]}.

-export_type([option/0]).

-type data() :: #{module => module(),
                  state => term(),
                  socket_module => module(),
                  socket => gen_tcp:socket(),
                  ack => reference()}.

-callback init(SockName, LSock, Args) ->
    {ok, State} | {ok, State, TimeoutOrHib} | ignore | {error, Reason} when
      SockName :: acceptor_pool:name(),
      LSock :: gen_tcp:socket(),
      Args :: term(),
      State :: term(),
      TimeoutOrHib :: timeout() | hibernate,
      Reason :: term().

-callback enter_loop(PeerName, Sock, State) -> no_return() when
      PeerName :: acceptor_pool:name(),
      Sock :: gen_tcp:socket(),
      State :: term().

-callback terminate(Reason, State) -> any() when
      Reason :: normal | system_limit | inet:posix() | term(),
      State :: term().

%% public api

%% @private
-spec spawn_opt(Mod, SockMod, SockName, LSock, Args, Opts) -> {Pid, Ref} when
      Mod :: module(),
      SockMod :: module(),
      SockName :: acceptor_pool:sockname(),
      LSock :: gen_tcp:socket(),
      Args :: term(),
      Opts :: [option()],
      Pid :: pid(),
      Ref :: reference().
spawn_opt(Mod, SockMod, SockName, LSock, Args, Opts) ->
    AckRef = make_ref(),
    SArgs = [self(), AckRef, Mod, SockMod, SockName, LSock, Args],
    Pid = proc_lib:spawn_opt(?MODULE, init_it, SArgs, spawn_options(Opts)),
    {Pid, AckRef}.

%% private api

%% @private
init_it(Parent, AckRef, Mod, SockMod, SockName, LSock, Args) ->
    _ = put('$initial_call', {Mod, init, 1}),
    try Mod:init(SockName, LSock, Args) of
        Result ->
            handle_init(Result, Mod, SockMod, LSock, Parent, AckRef)
    catch
        throw:Result ->
            handle_init(Result, Mod, SockMod, LSock, Parent, AckRef);
        error:Reason ->
            exit({Reason, erlang:get_stacktrace()})
    end.

%% acceptor_loop api

%% @private
-spec acceptor_continue({ok, Sock} | {error, Reason}, Parent, Data) ->
    no_return() when
      Sock :: gen_tcp:socket(),
      Reason :: timeout | closed | system_limit | inet:posix(),
      Parent :: pid(),
      Data :: data().
acceptor_continue({ok, Sock}, Parent, Data) ->
    #{module := Mod, state := State, ack := AckRef} = Data,
    {ok, PeerName} = inet:peername(Sock),
    _ = Parent ! {'ACCEPT', self(), AckRef, PeerName},
    case init_socket(Sock, Data) of
        ok              -> Mod:enter_loop(PeerName, Sock, State);
        {error, Reason} -> failure(Reason, Data)
    end;
acceptor_continue({error, Reason}, Parent, #{ack := ARef} = Data) ->
    _ = Parent ! {'CANCEL', self(), ARef},
    failure(Reason, Data).

-spec acceptor_terminate(Reason, Parent, Data) -> no_return() when
      Reason :: term(),
      Parent :: pid(),
      Data :: data().
acceptor_terminate(Reason, _, Data) ->
    terminate(Reason, Data).

%% internal

spawn_options(Opts) ->
    case lists:keyfind(spawn_options, 1, Opts) of
        {_, SpawnOpts} -> [link | SpawnOpts];
        false          -> [link]
    end.

handle_init({ok, State}, Mod, SockMod, LSock, Parent, AckRef) ->
    handle_init({ok, State, infinity}, Mod, SockMod, LSock, Parent, AckRef);
handle_init({ok, State, Timeout}, Mod, SockMod, LSock, Parent, AckRef) ->
    Data = #{module => Mod, state => State, socket_module => SockMod,
             socket => LSock, ack => AckRef},
    % Use another module to accept so can reload this module.
    acceptor_loop:accept(LSock, Timeout, Parent, ?MODULE, Data);
handle_init(Other, _, _, _, _, _) ->
    handle_init(Other).

handle_init(ignore) ->
    exit(normal);
handle_init({error, Reason}) ->
    exit(Reason);
handle_init(Other) ->
    exit({bad_return_value, Other}).

init_socket(Sock, #{socket_module := SockMod, socket := LSock}) ->
	inet_db:register_socket(Sock, SockMod),
    % As done by prim_inet:accept/2
    OptNames = [active, nodelay, keepalive, delay_send, priority, tos],
    case inet:getopts(LSock, OptNames) of
        {ok, Opts}         -> inet:setopts(Sock, Opts);
        {error, _} = Error -> Error
    end.

failure(timeout, Data) ->
    terminate(normal, Data);
failure(closed, Data) ->
    terminate(normal, Data);
failure(einval, #{socket := LSock} = Data) ->
    % LSock could have closed
    case erlang:port_info(LSock, connected) of
        {connected, _} -> terminate(einval, Data);
        undefined      -> terminate(normal, Data)
    end;
failure(Reason, #{socket := LSock} = Data) ->
    gen_tcp:close(LSock),
    terminate(Reason, Data).

%% TODO: log abnormal exits
terminate(Reason, #{module := Mod, state := State}) ->
    try
        Mod:terminate(Reason, State)
    catch
        throw:_       -> exit(Reason);
        error:NReason -> exit({NReason, erlang:get_stacktrace()})
    end.
