
-module(molderl_integration_tests).

-export([launch/0]).

-include_lib("eunit/include/eunit.hrl").

-include("molderl_tests.hrl").

-define(MAX_RCVD_ATTEMPTS, 10).

-compile([{parse_transform, lager_transform}]).

-record(stream, {process_name:: atom(),
                 name :: string(),
                 ip :: inet:ip4_address(),
                 port :: inet:port_number(),
                 file :: string(),
                 recovery_port :: inet:port_number()}).

-record(state, {stream :: #stream{},
                socket :: inet:socket(),
                sent=[] :: [{pos_integer(), binary()}],
                inflight=[] :: [{pos_integer(), binary()}],
                max_seq_num_rcvd=0 :: non_neg_integer(),
                failed_rcvd_attempts=0 :: non_neg_integer()}).

launch() ->

    File = "/tmp/foo",
    Port = 6666,
    RecPort = 7777,
    NumTests = 1000,

    {ok, [{IP,_,_}|_]} = inet:getif(),

    file:delete(File),
    lager:start(),
    lager:set_loglevel(lager_console_backend, debug),

    {ok, Socket} = gen_udp:open(Port, [binary, {reuseaddr, true}]),
    inet:setopts(Socket, [{add_membership, {?MCAST_GROUP_IP, {127,0,0,1}}}]),

    Stream = #stream{name="foo", ip=IP, port=Port, recovery_port=RecPort, file=File},
    ConnectedStream = launch_stream(Stream),

    loop(#state{stream=ConnectedStream, socket=Socket}, NumTests).

loop(#state{inflight=[]}, 0) ->
    lager:info("[SUCCESS] Passed all tests!"),
    clean_up();
loop(State=#state{failed_rcvd_attempts=?MAX_RCVD_ATTEMPTS}, _NumTests) ->
    Fmt = "[FAILURE] ~p failed receive attempts while ~p messages are still in flight",
    lager:error(Fmt, [?MAX_RCVD_ATTEMPTS, length(State#state.inflight)]),
    clean_up();
loop(State, 0) ->
    Fmt = "No more tests left but still ~p messages in flight, making sure we receive them all",
    lager:info(Fmt, [length(State#state.inflight)]),
    case rcv(State) of
        {passed, Outcome, NewState} ->
            lager:info(Outcome),
            loop(NewState, 0);
        {failed, Reason} ->
            lager:error(Reason),
            clean_up()
    end;
loop(State=#state{sent=Sent, inflight=Inflight, max_seq_num_rcvd=MaxSeqNumRcvd}, NumTests) ->
    Fmt = "[tests left] ~p [msgs in-flight] ~p [msgs sent] ~p [msgs received] ~p",
    lager:info(Fmt, [NumTests, length(Inflight), length(Sent), MaxSeqNumRcvd]),
    Draw = random:uniform(),
    if
        Draw < 0.5 ->
            TestResult = send(State);
        Draw < 0.8 ->
            TestResult = rcv(State);
        Draw < 0.9 ->
            TestResult = recover(State);
        true ->
            TestResult = crash(State)
    end,
    case TestResult of
        {passed, Outcome, NewState} ->
            lager:info(Outcome),
            loop(NewState, NumTests-1);
        {failed, Reason} ->
            lager:error(Reason),
            clean_up()
    end.

send(State=#state{stream=Stream, sent=Sent}) ->
    % generate random payload of random size < 10 bytes
    Msg = crypto:strong_rand_bytes(random:uniform(10)),
    case molderl:send_message(Stream#stream.process_name, Msg) of
        ok ->
            Fmt = "[SUCCESS] Sent packet seq num: ~p, msg: ~p",
            Outcome = io_lib:format(Fmt, [length(Sent)+1, Msg]),
            NewSent = [Msg|Sent],
            Inflight = [Msg|State#state.inflight],
            {passed, Outcome, State#state{sent=NewSent, inflight=Inflight}};
        _ ->
            Fmt = "[FAILURE] Couldn't send packet seq num: ~p, msg: ~p",
            Reason = io_lib:format(Fmt, [length(Sent)+1, Msg]),
            {failed, Reason}
    end.

rcv(State=#state{inflight=[], stream=#stream{name=Name}, socket=Socket}) ->
    case receive_messages(Name, Socket, 100) of
        {error, timeout} ->
            Outcome = "[SUCCESS] Received no packets when none were in flight",
            {passed, Outcome, State};
        {ok, Packets} ->
            Fmt = "[FAILURE] Received ~p packets while none were in flight: ~p",
            {failed, io_lib:format(Fmt, [length(Packets)])}
    end;
rcv(State=#state{inflight=Inflight, failed_rcvd_attempts=Attempts, stream=#stream{name=Name}, socket=Socket}) ->
    case receive_messages(Name, Socket, 100) of
        {error, timeout} ->
            Fmt = "[WARNING] Received no packet while ~p were in flight",
            {passed, io_lib:format(Fmt, [length(Inflight)]), State#state{failed_rcvd_attempts=Attempts+1}};
        {ok, Packets} ->
            rcv(State, Packets, 0)
    end.

rcv(State, [], RcvdMsgs) ->
    Fmt = "[SUCCESS] Received ~p packets that were in flight",
    {passed, io_lib:format(Fmt, [RcvdMsgs]), State};
rcv(State=#state{max_seq_num_rcvd=MaxSeqNumRcvd}, [{SeqNum, Msg}|Packets], RcvdMsgs) ->
    case lists:member(Msg, State#state.inflight) of
        true ->
            Inflight = lists:delete(Msg, State#state.inflight),
            Max = max(MaxSeqNumRcvd, SeqNum),
            rcv(State#state{inflight=Inflight, max_seq_num_rcvd=Max}, Packets, RcvdMsgs+1);
        false ->
            Fmt = "[FAILURE] Received packet ~p that was not in flight",
            {failed, io_lib:format(Fmt, [{SeqNum, Msg}])}
    end.

recover(State=#state{max_seq_num_rcvd=0}) ->
    {passed, "[SUCCESS] No packets were received yet, hence not trying to recover", State};
recover(State=#state{stream=Stream, socket=Socket, sent=Sent}) ->

    % first, craft and send recovery request
    Start = random:uniform(State#state.max_seq_num_rcvd),
    % limit number of requested messages to 40 so as to never bust MTU
    Count = min(40, random:uniform(State#state.max_seq_num_rcvd-Start+1)),
    SessionName = molderl_utils:gen_streamname(Stream#stream.name),
    Request = <<SessionName/binary, Start:64, Count:16>>,
    ok = gen_udp:send(Socket, Stream#stream.ip, Stream#stream.recovery_port, Request),

    % second, pull out of the sent list the packets expected
    % from recovery reply and add them to in-flight set
    Requested = lists:sublist(Sent, length(Sent)-Start-Count+2, Count),
    Inflight = State#state.inflight ++ Requested,

    Fmt = "[SUCCESS] Sent recovery request for sequence number ~p count ~p",
    {passed, io_lib:format(Fmt, [Start, Count]), State#state{inflight=Inflight}}.

crash(State) ->
    timer:sleep(100), % give some time for inflight msgs to be flushed
    ok = application:stop(molderl),
    Stream = launch_stream(State#state.stream),
    {passed, "[SUCCESS] Toggled molderl on and off", State#state{stream=Stream}}.

launch_stream(Stream=#stream{port=P, recovery_port=RP, file=F, ip=IP}) ->
    ok = application:start(molderl),
    {ok, ProcessName} = molderl:create_stream(foo, ?MCAST_GROUP_IP, P, RP, [{ipaddresstosendfrom,IP},{filename,F}]),
    Stream#stream{process_name=ProcessName}.

clean_up() ->
    application:stop(molderl).

