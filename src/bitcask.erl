%% -------------------------------------------------------------------
%%
%% bitcask: Eric Brewer-inspired key/value store
%%
%% Copyright (c) 2010 Basho Technologies, Inc. All Rights Reserved.
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
-module(bitcask).

-export([open/1,
         get/2,
         put/3,
         delete/2]).

-include("bitcask.hrl").

%% @type bc_state().
-record(bc_state, {dirname,
                   openfile, % filestate open for writing
                   files,    % List of #filestate
                   keydir}). % Key directory

-define(TOMBSTONE, <<"bitcask_tombstone">>).
-define(LARGE_FILESIZE, 2#1111111111111111111111111111111).

%% Filename convention is {integer_timestamp}.bitcask

open(Dirname) ->
    %% Make sure the directory exists
    ok = filelib:ensure_dir(filename:join(Dirname, "bitcask")),

    %% Build a list of all the bitcask data files and sort it in
    %% descending order (newest->oldest)
    Files = [bitcask_fileops:filename(Dirname, N) ||
             N <- lists:reverse(lists:sort(
                   [list_to_integer(hd(string:tokens(X,"."))) ||
                       X <- lists:reverse(lists:sort(
                                            filelib:wildcard("*data")))]))],

    %% Setup a keydir and scan all the data files into it
    {ok, KeyDir} = bitcask_nifs:keydir_new(),
    ok = scan_key_files(Files, KeyDir),  %% MAKE THIS NOT A NOP
    {ok, OpenFS} = bitcask_fileops:create_file(Dirname),
    {ok, #bc_state{dirname=Dirname,
                   openfile=OpenFS,
                   files=Files,
                   keydir=KeyDir}}.

get(#bc_state{keydir = KeyDir} = State, Key) ->
    case bitcask_nifs:keydir_get(KeyDir, Key) of
        not_found ->
            {not_found, State};

        E when is_record(E, bitcask_entry) ->
            {Filestate, State2} = get_filestate(E#bitcask_entry.file_id, State),
            case bitcask_fileops:read(Filestate, E#bitcask_entry.value_pos,
                                      E#bitcask_entry.value_sz) of
                {ok, _Key, ?TOMBSTONE} -> {not_found, State2};
                {ok, _Key, Value} -> {ok, Value, State2}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

put(State=#bc_state{dirname=Dirname,openfile=OpenFS,keydir=KeyHash,
                    files=Files},
    Key,Value) ->
    {ok, NewFS, OffSet, Size} = bitcask_fileops:write(OpenFS,Key,Value),
    ok = bitcask_nifs:keydir_put(KeyHash,Key,
                                 bitcask_fileops:file_tstamp(OpenFS),
                                 Size,OffSet,
                                 bitcask_fileops:tstamp()),
    {FinalFS,FinalFiles} = case OffSet+Size > ?LARGE_FILESIZE of
        true ->
            bitcask_fileops:close(NewFS),
            {ok, OpenFS} = bitcask_fileops:create_file(Dirname),
            {OpenFS,[NewFS#filestate.filename|Files]};
        false ->
            {NewFS,Files}
    end,
    {ok,State#bc_state{openfile=FinalFS,files=FinalFiles}}.

delete(_State, _Key) ->
    %put(State,Key,?TOMBSTONE).
    ok.


%% ===================================================================
%% Internal functions
%% ===================================================================

scan_key_files([], _KeyDir) ->
    ok;
scan_key_files([_Filename | Rest], KeyDir) ->
    scan_key_files(Rest, KeyDir).


get_filestate(FileId, #bc_state{ dirname = Dirname, files = Files } = State) ->
    Fname = bitcask_fileops:filename(Dirname, FileId),
    case lists:keysearch(Fname, #filestate.filename, Files) of
        {value, Filestate} ->
            {Filestate, State};
        false ->
            {ok, Filestate} = bitcask_fileops:open_file(Fname),
            {Filestate, State#bc_state { files = [Filestate | State#bc_state.files] }}
    end.
