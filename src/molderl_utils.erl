
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-module(molderl_utils).
-export([gen_heartbeat/2, gen_endofsession/2,
         gen_streamname/1, gen_messagepacket/3,
         gen_messagepacket_without_seqnum/3]).
-export([message_length/2]).
-include("molderl.hrl").

%% ------------------------------
%% Generates a Heart Beat packet.
%% ------------------------------
-spec gen_heartbeat(binary(), pos_integer()) -> binary().
gen_heartbeat(StreamName,NextSeq) ->
    <<StreamName/binary,NextSeq:64/big-integer,?HEARTBEAT:16/big-integer>>.

%% -----------------------------------
%% Generates an End Of Session packet.
%% -----------------------------------
-spec gen_endofsession(binary(), pos_integer()) -> binary().
gen_endofsession(StreamName,NextSeq) ->
    <<StreamName/binary,NextSeq:64/big-integer,?END_OF_SESSION:16/big-integer>>.

%% ---------------------------------------------
%% Takes a stream name as either a list, binary
%% or an integer. It then converts to a binary
%% that is right padded with spaces (ala NASDAQ)
%% ---------------------------------------------
-spec gen_streamname(atom() | binary() | string() | integer()) -> binary().
gen_streamname(StreamName) when is_atom(StreamName) ->
    gen_streamname(atom_to_list(StreamName));
gen_streamname(StreamName) when is_binary(StreamName) ->
    gen_streamname(binary_to_list(StreamName));
gen_streamname(StreamName) when is_integer(StreamName) ->
    gen_streamname(integer_to_list(StreamName));
gen_streamname(StreamName) when is_list(StreamName), length(StreamName) > 10 ->
    %First take the first 10 characters
    {FirstTen,_TheRest} = lists:split(10,StreamName),
    binary_padder(list_to_binary(FirstTen));
gen_streamname(StreamName) when is_list(StreamName) ->
    binary_padder(list_to_binary(StreamName)).

%% --------------------------------------------
%% Takes a binary and pads it out to ten bytes.
%% This is needed by the Stream Name.
%% Doesn't handle binaries larger than 10, but
%% should never get called for those ;-)
%% --------------------------------------------
-spec binary_padder(binary()) -> binary().
binary_padder(BinaryToPad) when byte_size(BinaryToPad) < 10 ->
    binary_padder(<<BinaryToPad/binary,16#20:8/big-integer>>);
binary_padder(BinaryToPad) ->
    BinaryToPad.

%% -------------------------------------------------
%% Generates a message packet. This takes the stream
%% name, the next sequence number and a message (or
%% list of messages). It returns a completed MOLD64
%% packet as well as the next sequence number. This
%% is needed for generating the next message in the
%% stream.
%% -------------------------------------------------
-spec gen_messagepacket(binary(), pos_integer(), binary() | [binary()])
    -> {pos_integer(), binary(), [{pos_integer(), binary()}]}.
gen_messagepacket(StreamName, NextSeq, Message) when not is_list(Message) ->
    gen_messagepacket(StreamName, NextSeq, [Message]);
gen_messagepacket(StreamName, NextSeq, Messages) ->
    Lambda = fun(Msg, I) -> {encode_message(Msg), I+1} end,
    {EncodedMsgs, Count} = lists:mapfoldl(Lambda, 0, Messages),
    EncodedMsgsBinary = list_to_binary(EncodedMsgs),
    Payload = <<StreamName/binary, NextSeq:64, Count:16, EncodedMsgsBinary/binary>>,
    EncodedMsgsWithSeqNum = lists:zip(lists:seq(NextSeq, NextSeq+Count-1), EncodedMsgs),
    {NextSeq+Count, Payload, EncodedMsgsWithSeqNum}.

-spec gen_messagepacket_without_seqnum(binary(), pos_integer(), list()) -> binary().
gen_messagepacket_without_seqnum(StreamName, NextSeq, Messages) ->
    Count = length(Messages),
    FlattenedMessages = list_to_binary(lists:flatten(Messages)),
    <<StreamName/binary,NextSeq:64/big-integer,Count:16/big-integer,FlattenedMessages/binary>>.

%% ------------------------------------------------
%% Takes a message as either a list of a binary and
%% then adds the length header needed by MOLD64. It
%% returns the binary encoded message.
%% ------------------------------------------------
-spec encode_message(list() | binary()) -> binary().
encode_message(Message) when is_list(Message) ->
    encode_message(list_to_binary(Message));
encode_message(Message) when is_binary(Message) ->
    Length = byte_size(Message),
    <<Length:16/big-integer,Message/binary>>.

%% ------------------------------------------------
%% Given a parent message's length and a child
%% message (as a bitstring), returns what would
%% be the resulting message length if the child
%% message was to be appended to the parent message
%% (according to Mold 64 protocol)
%% ------------------------------------------------
-spec message_length(non_neg_integer(), binary()) -> pos_integer().
message_length(0,Message) ->
    % Header is 20 bytes
    % 2 bytes for length of message
    % X bytes for message
    22 + byte_size(Message);
message_length(Size,Message) ->
    % Need to add 2 bytes for the length
    % and X bytes for the message itself
    Size + 2 + byte_size(Message).

-ifdef(TEST).

%% -----------------------
%% Tests for binary_padder
%% -----------------------
binary_padder_empty_test() ->
  ?assert(binary_padder(<<>>) == <<"          ">>).
binary_padder_short_test() ->
  ?assert(binary_padder(<<"hello">>) == <<"hello     ">>).
binary_padder_ten_test() ->
  ?assert(binary_padder(<<"helloworld">>) == <<"helloworld">>).

%% ------------------------
%% Tests for gen_streamname
%% ------------------------
gen_streamname_integer_test() ->
  ?assert(gen_streamname(1234) == <<"1234      ">>).
gen_streamname_binary_test() ->
  ?assert(gen_streamname(<<"1234">>) == <<"1234      ">>).
gen_streamname_short_list_test() ->
  ?assert(gen_streamname("hello") == <<"hello     ">>).
gen_streamname_long_list_test() ->
  ?assert(gen_streamname("helloworld123") == <<"helloworld">>).
gen_streamname_ten_list_test() ->
  ?assert(gen_streamname("helloworld") == <<"helloworld">>).

%% -------------------------------
%% Tests for Heart Beat generation
%% -------------------------------
gen_heartbeat_test() ->
  StreamName = <<"helloworld">>,
  ?assert(gen_heartbeat(StreamName,10) == <<StreamName/binary,10:64/big-integer,?HEARTBEAT:16/big-integer>>).

%% -----------------------------------
%% Tests for End of Session generation
%% -----------------------------------
gen_endofsession_test() ->
  StreamName = <<"helloworld">>,
  ?assert(gen_endofsession(StreamName,20) == <<StreamName/binary,20:64/big-integer,?END_OF_SESSION:16/big-integer>>).

%% -----------------------------------
%% Tests for message length computing
%% -----------------------------------
message_length_test() ->
    ?assertEqual(22, message_length(0,<<>>)),
    ?assertEqual(25, message_length(0,<<"f","o","o">>)),
    ?assertEqual(3, message_length(1,<<>>)),
    ?assertEqual(6, message_length(1,<<"f","o","o">>)).

%% -----------------------------------
%% Tests for encoding messages
%% -----------------------------------
encode_message_test() ->
    ?assertEqual(encode_message(<<"foo">>), <<3:16/big-integer, <<"foo">>/binary>>),
    ?assertEqual(encode_message("foo"), <<3:16/big-integer, <<"foo">>/binary>>).

%% -----------------------------------
%% Tests for generating message packet
%% -----------------------------------
gen_messagepacket_test() ->
    Msgs = ["foo", "bar", "baz", "qux"],
    Result = gen_messagepacket(<<"foo">>, 23, Msgs),
    {NextSeq, PacketPayload, EncodedMessagesWithSequenceNumbers} = Result,
    ?assertEqual(27, NextSeq),
    EncodedMsgs = [<<3:16/integer, <<"foo">>/binary>>, <<3:16/integer, <<"bar">>/binary>>,
                   <<3:16/integer, <<"baz">>/binary>>, <<3:16/integer, <<"qux">>/binary>>],
    FlattenedMsgs = list_to_binary(lists:flatten(EncodedMsgs)),
    ExpectedPayload = <<<<"foo">>/binary, 23:64/big-integer, 4:16/big-integer, FlattenedMsgs/binary>>,
    ?assertEqual(ExpectedPayload, PacketPayload),
    EncodedMsgsSeqs = [{23, <<3:16/integer, <<"foo">>/binary>>}, {24, <<3:16/integer, <<"bar">>/binary>>},
                       {25, <<3:16/integer, <<"baz">>/binary>>}, {26, <<3:16/integer, <<"qux">>/binary>>}],
    ?assertEqual(EncodedMsgsSeqs, EncodedMessagesWithSequenceNumbers).

-endif.

