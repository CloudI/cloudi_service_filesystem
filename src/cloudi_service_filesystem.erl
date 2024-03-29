%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Filesystem==
%%% A service that caches filesystem data for quick responses.
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2011-2022 Michael Truog <mjtruog at protonmail dot com>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a
%%% copy of this software and associated documentation files (the "Software"),
%%% to deal in the Software without restriction, including without limitation
%%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%%% and/or sell copies of the Software, and to permit persons to whom the
%%% Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
%%% DEALINGS IN THE SOFTWARE.
%%%
%%% @author Michael Truog <mjtruog at protonmail dot com>
%%% @copyright 2011-2022 Michael Truog
%%% @version 2.0.5 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_service_filesystem).
-author('mjtruog at protonmail dot com').

-behaviour(cloudi_service).

%% cloudi_service callbacks
-export([cloudi_service_init/4,
         cloudi_service_handle_request/11,
         cloudi_service_handle_info/3,
         cloudi_service_terminate/3]).

-include_lib("cloudi_core/include/cloudi_logger.hrl").
-include_lib("kernel/include/file.hrl").

-define(DEFAULT_DIRECTORY,           undefined). % required argument, string
-define(DEFAULT_FILES_SIZE,          undefined). % limit in KiB
        % Set the maximum amount of memory a single service
        % process will use for file data
        % (n.b., does not limit write_append accumulated file data).
-define(DEFAULT_REFRESH,             undefined). % seconds, see below:
        % The refresh frequency for updating the in-memory
        % copy of the file data from the filesystem based
        % on the file modification time.
-define(DEFAULT_CACHE,               undefined). % seconds, see below:
        % If defined, the request is treated as an HTTP request with the
        % modification time checked to determine if the file has changed
        % since it was last requested, allowing the HTTP client to
        % possibly reuse its cached copy.  HTTP headers are added to the
        % ResponseInfo to provide the modification time.
        % Use the value 'refresh' to assign (0.5 * refresh).
-define(DEFAULT_REPLACE,                 false).
        % Provide a file data cache replacement algorithm
        % (requires both the files_size and refresh arguments are set).
        % When set to 'true' (or 'lfuda') the
        % "Least-Frequently Used with Dynamic Aging" (LFUDA)
        % algorithm is used and the LFUDA policy (high byte hit rate).
        % When set to 'lfuda_gdsf' the LFUDA algorithm is used and the
        % "GreedyDual-Size with Frequency" (GDSF) policy (high hit rate).
        % When set to 'lru' the "Least Recently Used" (LRU) algorithm is used.
        %
        % LFUDA algorithm information:
        % M. Arlitt, R. F. L. Cherkasova, J. Dilley, and T. Jin.
        % Evaluating content management techniques for Web proxy caches.
        % HP Technical Report. Palo Alto, 1999.
        % https://www.hpl.hp.com/techreports/98/HPL-98-173.pdf
-define(DEFAULT_REPLACE_INDEX,            true).
        % Write the replacement algorithm ordering to the filesystem
        % for usage after a restart.
-define(DEFAULT_READ,                       []). % see below:
        % A list of file service names (provided by this service) that
        % will explicitly specify the files to read from the directory.
        % Any other files within the directory will be ignored.
        % The entries can be strings or tuples that provide a file
        % segment to read:
        % "/tests/http_req/hexpi.txt"
        % (specific file segment) position 0, 64 bytes:
        % {"/tests/http_req/hexpi.txt", {0, 64}}
        % (specific file segment) offset 64 from end, 32 bytes:
        % {"/tests/http_req/hexpi.txt", {-64, 32}}
        % (specific file segment) offset 64 from end, read till end:
        % {"/tests/http_req/hexpi.txt", {-64, undefined}}
        % {"/tests/http_req/hexpi.txt", -64}
-define(DEFAULT_WRITE_TRUNCATE,             []). % see below:
        % A list of file service names (and/or service name patterns)
        % (provided by this service) that will overwrite the file
        % contents with the service request data.
        % If a service name pattern is provided, it must match at
        % least one existing file path.
-define(DEFAULT_WRITE_APPEND,               []). % see below:
        % A list of file service names (and/or service name patterns)
        % (provided by this service) that will append to the file
        % contents with the service request data
        % (n.b., use to update with a range request in bytes).
        % If a service name pattern is provided, it must match at
        % least one existing file path.
        % If used with files_size it is possible for append data
        % to accumulate while maintaining file consistency in-memory
        % if the files_size limit prevents the append data from being
        % written to the filesystem.
-define(DEFAULT_REDIRECT,                   []). % see below:
        % A list of file service name patterns
        % ({Pattern, RedirectPattern}) to provide a mapping from
        % a received service name to a different service name.
        % Each service name pattern must match at least one existing file path.
-define(DEFAULT_NOTIFY_ONE,                 []). % see below:
        % A list of {NameOrPattern, NotifyName} entries that provide a
        % mapping from a file service name (and/or service name pattern)
        % (provided by this service) to a notification service name which
        % will receive the file's data in a service request sent with
        % send_async. If a service name pattern is provided, it must match
        % at least one existing file path.
-define(DEFAULT_NOTIFY_ALL,                 []). % see below:
        % A list of {NameOrPattern, NotifyName} entries that provide a
        % mapping from a file service name (and/or service name pattern)
        % (provided by this service) to a notification service name which
        % will receive the file's data in a service request sent with
        % mcast_async. If a service name pattern is provided, it must match
        % at least one existing file path.
-define(DEFAULT_NOTIFY_ON_START,          true). % send notify in init
-define(DEFAULT_HTTP_CLOCK_SKEW_MAX,       300). % seconds
-define(DEFAULT_USE_CONTENT_TYPES,        true). % see below:
        % Should the content-type ResponseInfo data be a guess based on
        % the file extension?
-define(DEFAULT_USE_CONTENT_DISPOSITION, false). % see below:
        % Should the content-disposition ResponseInfo data be set
        % to provide the filename and mark the file data as an
        % attachment to download
-define(DEFAULT_USE_EXPIRES,              true). % see below:
        % Should the expires HTTP header be used instead of the
        % cache-control max-age value?
-define(DEFAULT_USE_HTTP_GET_SUFFIX,      true). % see below:
        % Uses the "/get" suffix on service name patterns used for
        % subscriptions as would be used from HTTP related senders like
        % cloudi_service_http_cowboy.  Required for write-related
        % functionality and reading ranges.
-define(DEFAULT_DEBUG,                    true).
-define(DEFAULT_DEBUG_LEVEL,             trace).

-type read_list_exact() :: list({string(),
                                 integer() | undefined,
                                 non_neg_integer() | undefined}).

-record(lfuda,
    {
        policy :: lfuda | gdsf,
        age = 0 :: non_neg_integer()
    }).

-record(lru,
    {
        start :: cloudi_timestamp:native_monotonic()
    }).

-record(state,
    {
        prefix :: string(),
        prefix_length :: pos_integer(),
        service :: pid(),
        process_index :: non_neg_integer(),
        directory :: string(),
        directory_length :: non_neg_integer(),
        files_size_limit :: undefined | pos_integer(),
        files_size :: non_neg_integer(),
        refresh :: undefined | pos_integer(),
        cache :: undefined | pos_integer(),
        replace :: undefined | #lfuda{} | #lru{},
        replace_index_used :: boolean(),
        replace_hit :: undefined | trie:trie(),
        http_clock_skew_max :: non_neg_integer() | undefined,
        use_http_get_suffix :: boolean(),
        use_content_disposition :: boolean(),
        use_expires :: boolean(),
        debug_level :: off | trace | debug | info | warn | error | fatal,
        read :: read_list_exact(),
        toggle :: boolean(),
        files :: trie:trie(),
        content_type_lookup :: undefined | trie:trie()
    }).

-record(file_notify,
    {
        send :: mcast_async | send_async,
        service_name :: cloudi_service:service_name(),
        timeout :: cloudi_service_api:timeout_send_async_value_milliseconds(),
        priority :: cloudi_service:priority()
    }).

-record(file,
    {
        contents :: binary(),
        size :: non_neg_integer(),
        path :: string(),
        headers :: list({binary(), binary()}),
        mtime_i :: {calendar:datetime(), non_neg_integer()},
        access :: 'read' | 'write' | 'read_write' | 'none',
        toggle :: boolean(),
        notify = [] :: list(#file_notify{}),
        write = [] :: list(truncate | append),
        write_appends = [] :: list({binary(),
                                    list({non_neg_integer(),
                                          {any(), any()}})}),
        redirect = undefined :: undefined | binary()
    }).

-define(REPLACE_INDEX_FILENAME, ".cloudi_service_filesystem_replace_index_").

%%%------------------------------------------------------------------------
%%% Callback functions from cloudi_service
%%%------------------------------------------------------------------------

cloudi_service_init(Args, Prefix, _, Dispatcher) ->
    Defaults = [
        {directory,                    ?DEFAULT_DIRECTORY},
        {files_size,                   ?DEFAULT_FILES_SIZE},
        {refresh,                      ?DEFAULT_REFRESH},
        {cache,                        ?DEFAULT_CACHE},
        {replace,                      ?DEFAULT_REPLACE},
        {replace_index,                ?DEFAULT_REPLACE_INDEX},
        {read,                         ?DEFAULT_READ},
        {write_truncate,               ?DEFAULT_WRITE_TRUNCATE},
        {write_append,                 ?DEFAULT_WRITE_APPEND},
        {redirect,                     ?DEFAULT_REDIRECT},
        {notify_one,                   ?DEFAULT_NOTIFY_ONE},
        {notify_all,                   ?DEFAULT_NOTIFY_ALL},
        {notify_on_start,              ?DEFAULT_NOTIFY_ON_START},
        {http_clock_skew_max,          ?DEFAULT_HTTP_CLOCK_SKEW_MAX},
        {use_content_types,            ?DEFAULT_USE_CONTENT_TYPES},
        {use_content_disposition,      ?DEFAULT_USE_CONTENT_DISPOSITION},
        {use_expires,                  ?DEFAULT_USE_EXPIRES},
        {use_http_get_suffix,          ?DEFAULT_USE_HTTP_GET_SUFFIX},
        {debug,                        ?DEFAULT_DEBUG},
        {debug_level,                  ?DEFAULT_DEBUG_LEVEL}],
    [DirectoryRaw, FilesSizeLimit0, Refresh, Cache0, Replace0, ReplaceIndexUsed,
     ReadL0, WriteTruncateL, WriteAppendL, RedirectL,
     NotifyOneL, NotifyAllL, NotifyOnStart, HTTPClockSkewMax,
     UseContentTypes, UseContentDisposition, UseExpires, UseHttpGetSuffix,
     Debug, DebugLevel] = cloudi_proplists:take_values(Defaults, Args),
    false = cloudi_service_name:pattern(Prefix),
    true = is_list(DirectoryRaw),
    ProcessIndex = cloudi_service:process_index(Dispatcher),
    Directory = cloudi_environment:transform(DirectoryRaw),
    DirectoryLength = erlang:length(Directory),
    FilesSizeLimitN = if
        FilesSizeLimit0 =:= undefined ->
            undefined;
        is_integer(FilesSizeLimit0), FilesSizeLimit0 > 0 ->
            FilesSizeLimit0 * 1024 % bytes
    end,
    true = (Refresh =:= undefined) orelse
           (is_integer(Refresh) andalso
            (Refresh > 0) andalso (Refresh =< 4294967)),
    CacheN = if
        Cache0 =:= undefined ->
            undefined;
        Cache0 =:= refresh, is_integer(Refresh) ->
            erlang:max(Refresh div 2, 1);
        is_integer(Cache0), is_integer(Refresh),
        Cache0 > 0, Cache0 =< 31536000 ->
            Cache0
    end,
    true = is_boolean(ReplaceIndexUsed),
    {ReplaceN,
     ReplaceHit0} = if
        Replace0 =:= false ->
            {undefined,
             undefined};
        Replace0 =:= true;
        Replace0 =:= lfuda;
        Replace0 =:= lfuda_gdsf;
        Replace0 =:= lru ->
            true = is_integer(FilesSizeLimitN) andalso
                   is_integer(Refresh),
            replace_new(Replace0, ReplaceIndexUsed, ProcessIndex, Directory)
    end,
    true = is_list(ReadL0),
    true = is_list(WriteTruncateL),
    true = is_list(WriteAppendL),
    true = is_list(RedirectL),
    true = is_list(NotifyOneL),
    true = is_list(NotifyAllL),
    true = is_boolean(NotifyOnStart),
    true = (is_integer(HTTPClockSkewMax) andalso
            (HTTPClockSkewMax >= 0)) orelse
           (HTTPClockSkewMax =:= undefined),
    true = is_boolean(UseContentTypes),
    true = is_boolean(UseContentDisposition),
    true = is_boolean(UseExpires),
    true = (UseHttpGetSuffix =:= true) orelse
           ((UseHttpGetSuffix =:= false) andalso
            (UseContentTypes =:= false) andalso
            (WriteTruncateL == []) andalso
            (WriteAppendL == []) andalso
            (RedirectL == [])),
    true = is_boolean(Debug),
    true = ((DebugLevel =:= trace) orelse
            (DebugLevel =:= debug) orelse
            (DebugLevel =:= info) orelse
            (DebugLevel =:= warn) orelse
            (DebugLevel =:= error) orelse
            (DebugLevel =:= fatal)),
    DebugLogLevel = if
        Debug =:= false ->
            off;
        Debug =:= true ->
            DebugLevel
    end,
    ContentTypeLookup = if
        UseContentTypes =:= true ->
            cloudi_response_info:lookup_content_type();
        UseContentTypes =:= false ->
            undefined
    end,
    true = if
        Refresh =:= undefined ->
            filelib:is_dir(Directory);
        true ->
            true % directory may appear later
    end,
    ReadLN = lists:map(fun(Read) ->
        case Read of
            [_ | _] = ReadName ->
                {cloudi_args_type:service_name_suffix(Prefix, ReadName),
                 undefined, undefined};
            {[_ | _] = ReadName, ReadSegmentI}
                when is_integer(ReadSegmentI) orelse
                     (ReadSegmentI =:= undefined) ->
                {cloudi_args_type:service_name_suffix(Prefix, ReadName),
                 ReadSegmentI, undefined};
            {[_ | _] = ReadName, {ReadSegmentI, ReadSegmentSize}}
                when (is_integer(ReadSegmentI) orelse
                      (ReadSegmentI =:= undefined)) andalso
                     ((is_integer(ReadSegmentSize) andalso
                       (ReadSegmentSize >= 0)) orelse
                      (ReadSegmentSize =:= undefined)) ->
                {cloudi_args_type:service_name_suffix(Prefix, ReadName),
                 ReadSegmentI, ReadSegmentSize}
        end
    end, ReadL0),
    Toggle = true,
    {ReplaceHitN,
     FilesSizeN,
     Files1} = read_files_init(ReplaceHit0, ReplaceN, ReadLN, Toggle,
                               ContentTypeLookup,
                               UseContentDisposition, UseHttpGetSuffix,
                               FilesSizeLimitN, Directory, Prefix, Dispatcher),
    MTimeFake = datetime_utc(cloudi_timestamp:native_monotonic()),
    Files7 = lists:foldl(fun(Pattern, Files2) ->
        true = UseHttpGetSuffix,
        PatternRead = Pattern ++ "/get",
        Files6 = trie:fold_match(PatternRead, fun(_, File, Files3) ->
            Files4 = if
                Files3 =:= undefined ->
                    Files2;
                true ->
                    Files3
            end,
            #file{path = FilePath,
                  access = Access,
                  write = []} = File,
            if
                Access =:= read_write ->
                    FileNew = File#file{write = [truncate]},
                    FileName = lists:nthtail(DirectoryLength, FilePath),
                    Files5 = file_add_write_truncate(FileName, FileNew,
                                                     Files4, Prefix,
                                                     Dispatcher),
                    file_refresh(FileName, FileNew,
                                 Files5, true, Prefix);
                true ->
                    ?LOG_ERROR("unable to read and write file: \"~s\"",
                               [FilePath]),
                    erlang:exit({eacces, FilePath}),
                    Files4
            end
        end, undefined, Files2),
        if
            Files6 =:= undefined ->
                false = cloudi_service_name:pattern(Pattern),
                FileName = cloudi_args_type:service_name_suffix(Prefix,
                                                                Pattern),
                FilePath = filename:join(Directory, FileName),
                Headers = file_headers(FilePath, ContentTypeLookup,
                                       UseContentDisposition),
                file_add_write(FileName,
                               #file{contents = <<>>,
                                     size = 0,
                                     path = FilePath,
                                     headers = Headers,
                                     mtime_i = {MTimeFake, 0},
                                     access = 'read_write',
                                     toggle = Toggle,
                                     write = [truncate]},
                               Files2, Prefix, Dispatcher);
            true ->
                Files6
        end
    end, Files1, WriteTruncateL),
    Files13 = lists:foldl(fun(Pattern, Files8) ->
        true = UseHttpGetSuffix,
        PatternRead = Pattern ++ "/get",
        Files12 = trie:fold_match(PatternRead, fun(_, File, Files9) ->
            Files10 = if
                Files9 =:= undefined ->
                    Files8;
                true ->
                    Files9
            end,
            #file{path = FilePath,
                  access = Access,
                  write = Write} = File,
            if
                Access =:= read_write ->
                    FileNew = File#file{write = [append | Write]},
                    FileName = lists:nthtail(DirectoryLength, FilePath),
                    Files11 = file_add_write_append(FileName, FileNew,
                                                    Files10, Prefix,
                                                    Dispatcher),
                    file_refresh(FileName, FileNew,
                                 Files11, true, Prefix);
                true ->
                    ?LOG_ERROR("unable to read and write file: \"~s\"",
                               [FilePath]),
                    erlang:exit({eacces, FilePath}),
                    Files10
            end
        end, undefined, Files8),
        if
            Files12 =:= undefined ->
                false = cloudi_service_name:pattern(Pattern),
                FileName = cloudi_args_type:service_name_suffix(Prefix,
                                                                Pattern),
                FilePath = filename:join(Directory, FileName),
                Headers = file_headers(FilePath, ContentTypeLookup,
                                       UseContentDisposition),
                file_add_write(FileName,
                               #file{contents = <<>>,
                                     size = 0,
                                     path = FilePath,
                                     headers = Headers,
                                     mtime_i = {MTimeFake, 0},
                                     access = 'read_write',
                                     toggle = Toggle,
                                     write = [append]},
                               Files8, Prefix, Dispatcher);
            true ->
                Files12
        end
    end, Files7, WriteAppendL),
    Timeout = cloudi_service:timeout_async(Dispatcher),
    Priority = cloudi_service:priority_default(Dispatcher),
    Files16 = lists:foldl(fun({PatternOne, NotifyNameOne}, Files14) ->
        true = is_list(PatternOne) andalso is_integer(hd(PatternOne)),
        true = is_list(NotifyNameOne) andalso is_integer(hd(NotifyNameOne)),
        true = lists:prefix(Prefix, PatternOne),
        case files_notify(#file_notify{send = send_async,
                                       service_name = NotifyNameOne,
                                       timeout = Timeout,
                                       priority = Priority},
                          PatternOne, Files14) of
            {ok, _, Files15} ->
                Files15;
            {error, Reason} ->
                ?LOG_ERROR("notification name does not exist: \"~s\"",
                           [PatternOne]),
                erlang:exit({Reason, PatternOne}),
                Files14
        end
    end, Files13, NotifyOneL),
    Files19 = lists:foldl(fun({PatternAll, NotifyNameAll}, Files17) ->
        true = is_list(PatternAll) andalso is_integer(hd(PatternAll)),
        true = is_list(NotifyNameAll) andalso is_integer(hd(NotifyNameAll)),
        true = lists:prefix(Prefix, PatternAll),
        case files_notify(#file_notify{send = mcast_async,
                                       service_name = NotifyNameAll,
                                       timeout = Timeout,
                                       priority = Priority},
                          PatternAll, Files17) of
            {ok, _, Files18} ->
                Files18;
            {error, Reason} ->
                ?LOG_ERROR("notification name does not exist: \"~s\"",
                           [PatternAll]),
                erlang:exit({Reason, PatternAll}),
                Files17
        end
    end, Files16, NotifyAllL),
    FilesN = lists:foldl(fun({Pattern, RedirectPattern}, Files20) ->
        true = UseHttpGetSuffix,
        true = cloudi_service_name:pattern(Pattern),
        PatternMethods = Pattern ++ "/*",
        Files23 = trie:fold_match(PatternMethods,
                                           fun(NameMethod, File, Files21) ->
            Files22 = if
                Files21 =:= undefined ->
                    Files20;
                true ->
                    Files21
            end,
            #file{path = FilePath,
                  redirect = undefined} = File,
            ParametersMethod = cloudi_service_name:parse(NameMethod,
                                                         PatternMethods),
            Parameters = lists:reverse(tl(lists:reverse(ParametersMethod))),
            RedirectName = case cloudi_service_name:new(RedirectPattern,
                                                        Parameters) of
                {ok, RedirectNameString} ->
                    erlang:list_to_binary(RedirectNameString);
                {error, Reason} ->
                    ?LOG_ERROR("redirect ~p: \"~s\" \"~s\"",
                               [Reason, Pattern, RedirectPattern]),
                    erlang:exit({Reason, {Pattern, RedirectPattern}}),
                    undefined
            end,
            FileNew = File#file{redirect = RedirectName},
            FileName = lists:nthtail(DirectoryLength, FilePath),
            file_refresh(FileName, FileNew,
                         Files22, true, Prefix)
        end, undefined, Files20),
        if
            Files23 =:= undefined ->
                ?LOG_ERROR("redirect pattern does not match: \"~s\" "
                           "(add empty files)",
                           [Pattern]),
                erlang:exit({enoent, Pattern});
            true ->
                Files23
        end
    end, Files19, RedirectL),
    if
        NotifyOnStart =:= true ->
            trie:foreach(fun(_,
                                      #file{contents = Contents,
                                            notify = NotifyL}) ->
                file_notify_send(NotifyL, Contents, Dispatcher)
            end, FilesN);
        true ->
            ok
    end,
    Service = cloudi_service:self(Dispatcher),
    if
        is_integer(Refresh) ->
            _ = erlang:send_after(Refresh * 1000, Service, refresh),
            ok;
        true ->
            ok
    end,
    {ok, #state{prefix = Prefix,
                prefix_length = erlang:length(Prefix),
                service = Service,
                process_index = ProcessIndex,
                directory = Directory,
                directory_length = DirectoryLength,
                files_size_limit = FilesSizeLimitN,
                files_size = FilesSizeN,
                refresh = Refresh,
                cache = CacheN,
                replace = ReplaceN,
                replace_index_used = ReplaceIndexUsed,
                replace_hit = ReplaceHitN,
                http_clock_skew_max = HTTPClockSkewMax,
                read = ReadLN,
                toggle = Toggle,
                files = FilesN,
                use_http_get_suffix = UseHttpGetSuffix,
                use_content_disposition = UseContentDisposition,
                use_expires = UseExpires,
                content_type_lookup = ContentTypeLookup,
                debug_level = DebugLogLevel}}.

cloudi_service_handle_request(_RequestType, Name, _Pattern,
                              RequestInfo, Request,
                              Timeout, _Priority, _TransId, _Source,
                              #state{files = Files,
                                     use_http_get_suffix = UseHttpGetSuffix
                                     } = State, Dispatcher) ->
    case trie:find(Name, Files) of
        {ok, #file{redirect = Redirect} = File} ->
            if
                UseHttpGetSuffix =:= true ->
                    if
                        Redirect =:= undefined ->
                            case cloudi_string:splitr($/, Name) of
                                {NamePath, "options"} ->
                                    request_options(NamePath, State);
                                {_, "head"} ->
                                    request_header(File, RequestInfo, State);
                                {_, "get"} ->
                                    request_read(File, RequestInfo, State);
                                {_, "put"} ->
                                    request_truncate(File,
                                                     RequestInfo, Request,
                                                     State, Dispatcher);
                                {_, "post"} ->
                                    request_append(File, Name,
                                                   RequestInfo, Request,
                                                   Timeout, State, Dispatcher)
                            end;
                        is_binary(Redirect) ->
                            {reply,
                             [{<<"status">>, <<"301">>},
                              {<<"location">>, Redirect}],
                             <<>>, State}
                    end;
                UseHttpGetSuffix =:= false ->
                    request_read(File, RequestInfo, State)
            end;
        error ->
            % possible if a sending service has stale service name lookup data
            % with a file that was removed during a refresh
            {reply,
             [{<<"status">>, <<"404">>}],
             <<>>, State}
    end.

cloudi_service_handle_info(refresh,
                           #state{prefix = Prefix,
                                  prefix_length = PrefixLength,
                                  service = Service,
                                  process_index = ProcessIndex,
                                  directory = Directory,
                                  directory_length = DirectoryLength,
                                  files_size_limit = FilesSizeLimit,
                                  files_size = FilesSize,
                                  refresh = Refresh,
                                  replace = Replace,
                                  replace_index_used = ReplaceIndexUsed,
                                  replace_hit = ReplaceHit,
                                  read = ReadL,
                                  toggle = Toggle,
                                  files = Files,
                                  use_http_get_suffix = UseHttpGetSuffix,
                                  use_content_disposition =
                                      UseContentDisposition,
                                  content_type_lookup =
                                      ContentTypeLookup,
                                  debug_level = DebugLogLevel} = State,
                           Dispatcher) ->
    ToggleNew = not Toggle,
    {ReplaceHitNew,
     ReplaceNew,
     FilesSizeNew,
     FilesNew} = read_files_refresh(ReplaceHit, Replace, ReplaceIndexUsed,
                                    ReadL, ToggleNew,
                                    FilesSize, Files, ContentTypeLookup,
                                    UseContentDisposition, UseHttpGetSuffix,
                                    FilesSizeLimit, ProcessIndex,
                                    DirectoryLength, Directory, PrefixLength,
                                    Prefix, Dispatcher),
    _ = erlang:send_after(Refresh * 1000, Service, refresh),
    if
        FilesSizeLimit =:= undefined ->
            ?LOG(DebugLogLevel,
                 "loaded files_size ~w bytes",
                 [FilesSizeNew]);
        is_integer(FilesSizeLimit) ->
            ?LOG(DebugLogLevel,
                 "loaded files_size ~w bytes <= ~w bytes",
                 [FilesSizeNew, FilesSizeLimit])
    end,
    {noreply, State#state{files_size = FilesSizeNew,
                          replace = ReplaceNew,
                          replace_hit = ReplaceHitNew,
                          toggle = ToggleNew,
                          files = FilesNew}};

cloudi_service_handle_info({append_clear, Name, Id},
                           #state{files = Files} = State, _Dispatcher) ->
    FilesNew = case trie:find(Name, Files) of
        {ok, #file{write_appends = Appends} = File} ->
            {value, _, AppendsNew} = request_append_take(Id, Appends),
            trie:store(Name,
                                File#file{write_appends = AppendsNew}, Files);
        error ->
            Files
    end,
    {noreply, State#state{files = FilesNew}};

cloudi_service_handle_info(Request, State, _Dispatcher) ->
    {stop, cloudi_string:format("Unknown info \"~w\"", [Request]), State}.

cloudi_service_terminate(_Reason, _Timeout, _State) ->
    ok.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

request_options(NamePath,
                #state{files = Files} = State) ->
    [_ | Methods] = trie:fold_match(NamePath ++ "/*",
                                             fun(Name, _, L) ->
        [", ", cloudi_string:uppercase(cloudi_string:afterr($/, Name)) | L]
    end, [], Files),
    Allow = erlang:list_to_binary(lists:reverse(Methods)),
    {reply,
     [{<<"allow">>, Allow} |
      contents_ranges_headers(true)], <<>>, State}.

request_header(#file{contents = Contents,
                     headers = FileHeaders,
                     mtime_i = MTimeI} = File, RequestInfo,
               #state{cache = undefined,
                      use_http_get_suffix = true} = State) ->
    TimeNative = cloudi_timestamp:native_monotonic(),
    NowTime = datetime_utc(TimeNative),
    KeyValues = cloudi_request_info:key_value_parse(RequestInfo),
    ETag = cache_header_etag(MTimeI),
    case contents_ranges_read(ETag, KeyValues, MTimeI) of
        {206, RangeList} ->
            case content_range_list_check(RangeList, Contents) of
                {206, Headers} ->
                    {reply,
                     Headers ++
                     cacheless_headers_data(NowTime, MTimeI, ETag, true),
                     <<>>,
                     replace_hit(File, TimeNative, State)};
                {416, Headers} ->
                    {reply, Headers, <<>>, State}
            end;
        {Status, undefined}
            when Status == 200;
                 Status == 410 ->
            {reply,
             FileHeaders ++
             cacheless_headers_data(NowTime, MTimeI, ETag, true),
             <<>>,
             replace_hit(File, TimeNative, State)};
        {416, undefined} ->
            {reply,
             [{<<"status">>, <<"416">>},
              contents_ranges_header_length(Contents) |
              contents_ranges_headers(true)],
             <<>>, State};
        {400, undefined} ->
            {reply, [{<<"status">>, <<"400">>}], <<>>, State}
    end;
request_header(#file{contents = Contents,
                     headers = FileHeaders,
                     mtime_i = MTimeI} = File, RequestInfo,
               #state{cache = Cache,
                      http_clock_skew_max = HTTPClockSkewMax,
                      use_expires = UseExpires,
                      use_http_get_suffix = true} = State) ->
    TimeNative = cloudi_timestamp:native_monotonic(),
    NowTime = datetime_utc(TimeNative),
    KeyValues = cloudi_request_info:key_value_parse(RequestInfo),
    InvalidTime = invalid_time(NowTime, HTTPClockSkewMax),
    ETag = cache_header_etag(MTimeI),
    case cache_status(ETag, KeyValues, MTimeI, InvalidTime) of
        200 ->
            case contents_ranges_read(ETag, KeyValues, MTimeI) of
                {206, RangeList} ->
                    case content_range_list_check(RangeList, Contents) of
                        {206, Headers} ->
                            {reply,
                             Headers ++
                             cache_headers_data(UseExpires, NowTime, MTimeI,
                                                ETag, Cache, true),
                             <<>>,
                             replace_hit(File, TimeNative, State)};
                        {416, Headers} ->
                            {reply, Headers, <<>>, State}
                    end;
                {Status, undefined}
                    when Status == 200;
                         Status == 410 ->
                    {reply,
                     FileHeaders ++
                     cache_headers_data(UseExpires, NowTime, MTimeI,
                                        ETag, Cache, true),
                     <<>>,
                     replace_hit(File, TimeNative, State)};
                {416, undefined} ->
                    {reply,
                     [{<<"status">>, <<"416">>},
                      contents_ranges_header_length(Contents) |
                      contents_ranges_headers(true)],
                     <<>>, State};
                {400, undefined} ->
                    {reply, [{<<"status">>, <<"400">>}], <<>>, State}
            end;
        Status ->
            % not modified due to caching
            {reply,
             [{<<"status">>, erlang:integer_to_binary(Status)} |
              cache_headers_empty(NowTime, MTimeI, true)],
             <<>>, State}
    end.

request_read(#file{contents = Contents,
                   headers = FileHeaders,
                   mtime_i = MTimeI} = File, RequestInfo,
             #state{cache = undefined,
                    use_http_get_suffix = UseHttpGetSuffix} = State) ->
    TimeNative = cloudi_timestamp:native_monotonic(),
    if
        UseHttpGetSuffix =:= true ->
            NowTime = datetime_utc(TimeNative),
            KeyValues = cloudi_request_info:
                        key_value_parse(RequestInfo),
            ETag = cache_header_etag(MTimeI),
            case contents_ranges_read(ETag, KeyValues, MTimeI) of
                {206, RangeList} ->
                    case content_range_read(RangeList, Contents) of
                        {206, Headers, Response} ->
                            {reply,
                             Headers ++
                             cacheless_headers_data(NowTime, MTimeI, ETag,
                                                    UseHttpGetSuffix),
                             Response,
                             replace_hit(File, TimeNative, State)};
                        {416, Headers, <<>>} ->
                            {reply, Headers, <<>>, State}
                    end;
                {Status, undefined}
                    when Status == 200;
                         Status == 410 ->
                    {reply,
                     FileHeaders ++
                     cacheless_headers_data(NowTime, MTimeI, ETag,
                                            UseHttpGetSuffix),
                     Contents,
                     replace_hit(File, TimeNative, State)};
                {416, undefined} ->
                    {reply,
                     [{<<"status">>, <<"416">>},
                      contents_ranges_header_length(Contents) |
                      contents_ranges_headers(true)],
                     <<>>, State};
                {400, undefined} ->
                    {reply, [{<<"status">>, <<"400">>}], <<>>, State}
            end;
        UseHttpGetSuffix =:= false ->
            {reply, Contents,
             replace_hit(File, TimeNative, State)}
    end;
request_read(#file{contents = Contents,
                   headers = FileHeaders,
                   mtime_i = MTimeI} = File, RequestInfo,
             #state{cache = Cache,
                    http_clock_skew_max = HTTPClockSkewMax,
                    use_expires = UseExpires,
                    use_http_get_suffix = UseHttpGetSuffix} = State) ->
    TimeNative = cloudi_timestamp:native_monotonic(),
    NowTime = datetime_utc(TimeNative),
    KeyValues = cloudi_request_info:key_value_parse(RequestInfo),
    InvalidTime = invalid_time(NowTime, HTTPClockSkewMax),
    ETag = cache_header_etag(MTimeI),
    case cache_status(ETag, KeyValues, MTimeI, InvalidTime) of
        200 ->
            if
                UseHttpGetSuffix =:= true ->
                    case contents_ranges_read(ETag, KeyValues, MTimeI) of
                        {206, RangeList} ->
                            case content_range_read(RangeList, Contents) of
                                {206, Headers, Response} ->
                                    {reply,
                                     Headers ++
                                     cache_headers_data(UseExpires,
                                                        NowTime, MTimeI,
                                                        ETag, Cache,
                                                        UseHttpGetSuffix),
                                     Response,
                                     replace_hit(File, TimeNative, State)};
                                {416, Headers, <<>>} ->
                                    {reply, Headers, <<>>, State}
                            end;
                        {Status, undefined}
                            when Status == 200;
                                 Status == 410 ->
                            {reply,
                             FileHeaders ++
                             cache_headers_data(UseExpires, NowTime, MTimeI,
                                                ETag, Cache, UseHttpGetSuffix),
                             Contents,
                             replace_hit(File, TimeNative, State)};
                        {416, undefined} ->
                            {reply,
                             [{<<"status">>, <<"416">>},
                              contents_ranges_header_length(Contents) |
                              contents_ranges_headers(true)],
                             <<>>, State};
                        {400, undefined} ->
                            {reply, [{<<"status">>, <<"400">>}], <<>>, State}
                    end;
                UseHttpGetSuffix =:= false ->
                    {reply,
                     cache_headers_data(UseExpires, NowTime, MTimeI,
                                        ETag, Cache, UseHttpGetSuffix),
                     Contents,
                     replace_hit(File, TimeNative, State)}
            end;
        Status ->
            % not modified due to caching
            {reply,
             [{<<"status">>, erlang:integer_to_binary(Status)} |
              cache_headers_empty(NowTime, MTimeI, UseHttpGetSuffix)],
             <<>>, State}
    end.

request_truncate(#file{size = ContentsSizeOld,
                       path = FilePath,
                       mtime_i = MTimeIOld,
                       write = Write,
                       notify = NotifyL} = File,
                 RequestInfo, Request,
                 #state{files_size_limit = FilesSizeLimit,
                        files_size = FilesSize,
                        use_http_get_suffix = true} = State, Dispatcher) ->
    case lists:member(truncate, Write) of
        true ->
            KeyValues = cloudi_request_info:
                        key_value_parse(RequestInfo),
            case cloudi_key_value:find(<<"range">>, KeyValues) of
                {ok, _} ->
                    {reply,
                     [{<<"status">>, <<"400">>}],
                     <<>>, State};
                error ->
                    ContentsNew = if
                        is_binary(Request) ->
                            Request;
                        is_list(Request) ->
                            erlang:iolist_to_binary(Request)
                    end,
                    case files_size_check(ContentsNew,
                                          FilesSize - ContentsSizeOld,
                                          FilesSizeLimit) of
                        {ok, ContentsSizeNew, FilesSizeNew} ->
                            case file:write_file(FilePath,
                                                 ContentsNew, [raw]) of
                                ok ->
                                    {ok, FileInfo} = read_file_info(FilePath),
                                    file_notify_send(NotifyL, ContentsNew,
                                                     Dispatcher),
                                    #file_info{mtime = MTime,
                                               access = Access} = FileInfo,
                                    MTimeI = mtime_i_update(MTimeIOld, MTime),
                                    request_truncate_file(
                                        File#file{contents = ContentsNew,
                                                  size = ContentsSizeNew,
                                                  mtime_i = MTimeI,
                                                  access = Access},
                                        State#state{files_size = FilesSizeNew});
                                {error, Reason} ->
                                    ?LOG_ERROR("file write ~s error: ~p",
                                               [FilePath, Reason]),
                                    {reply,
                                     [{<<"status">>, <<"500">>}],
                                     <<>>, State}
                            end;
                        {error, ContentsSizeNew} ->
                            ?LOG_WARN("file name ~s (size ~w KiB) truncate "
                                      "excluded due to ~w KiB files_size",
                                      [FilePath, ContentsSizeNew div 1024,
                                       FilesSizeLimit div 1024]),
                            {reply,
                             [{<<"status">>, <<"400">>}],
                             <<>>, State}
                    end
            end;
        false ->
            {reply,
             [{<<"status">>, <<"400">>}],
             <<>>, State}
    end.

request_truncate_file(#file{contents = Contents,
                            path = FilePath,
                            headers = FileHeaders,
                            mtime_i = {MTime, _} = MTimeI} = File,
                      #state{prefix = Prefix,
                             directory_length = DirectoryLength,
                             cache = Cache,
                             files = Files,
                             use_expires = UseExpires,
                             use_http_get_suffix = true} = State) ->
    FileName = lists:nthtail(DirectoryLength, FilePath),
    ETag = cache_header_etag(MTimeI),
    FilesNew = file_refresh(FileName, File, Files, true, Prefix),
    Headers = if
        Cache =:= undefined ->
            cacheless_headers_data(MTime, MTimeI, ETag, true);
        true ->
            cache_headers_data(UseExpires, MTime, MTimeI, ETag, Cache, true)
    end,
    {reply,
     FileHeaders ++ Headers, Contents,
     replace_hit(File, undefined,
                 State#state{files = FilesNew})}.

request_append(#file{contents = Contents,
                     mtime_i = MTimeI,
                     write = Write,
                     write_appends = Appends} = File,
               Name, RequestInfo, Request, Timeout,
               #state{service = Service,
                      files = Files,
                      use_http_get_suffix = true} = State, Dispatcher) ->
    case lists:member(append, Write) of
        true ->
            KeyValues = cloudi_request_info:
                        key_value_parse(RequestInfo),
            ETag = cache_header_etag(MTimeI),
            case contents_ranges_append(ETag, KeyValues, MTimeI) of
                {Status, {Range, Id, true, Index}} % last range
                    when Status == 200;
                         Status == 206 ->
                    AppendsNext = request_append_store(Id, Index,
                                                       Range, Request,
                                                       Appends),
                    {value,
                     RangeRequests,
                     AppendsNew} = request_append_take(Id, AppendsNext),
                    request_append_file(RangeRequests,
                                        File#file{write_appends = AppendsNew},
                                        State, Dispatcher);
                {Status, {Range, Id, false, Index}} % not the last range
                    when Status == 200;
                         Status == 206 ->
                    AppendsNew = request_append_store(Id, Index, Name,
                                                      Range, Request, Timeout,
                                                      Appends, Service),
                    FileNew = File#file{write_appends = AppendsNew},
                    FilesNew = trie:store(Name, FileNew, Files),
                    {reply, [], <<>>, State#state{files = FilesNew}};
                {416, undefined} ->
                    {reply,
                     [{<<"status">>, <<"416">>},
                      contents_ranges_header_length(Contents) |
                      contents_ranges_headers(true)],
                     <<>>, State};
                {Status, undefined}
                    when Status == 400;
                         Status == 410 ->
                    {reply,
                     [{<<"status">>, erlang:integer_to_binary(Status)}],
                     <<>>, State}
            end;
        false ->
            {reply,
             [{<<"status">>, <<"400">>}],
             <<>>, State}
    end.

request_append_take(Id, Appends) ->
    case lists:keytake(Id, 1, Appends) of
        {value, {_, L}, AppendsNew} ->
            Value = lists:map(fun({_Index, Tref, RangeRequest}) ->
                if
                    Tref /= undefined ->
                        ok = erlang:cancel_timer(Tref,
                                                 [{async, true},
                                                  {info, false}]);
                    true ->
                        ok
                end,
                RangeRequest
            end, L),
            {value, Value, AppendsNew};
        false ->
            false
    end.

request_append_store(Id, Index, Range, Request, Appends) ->
    case lists:keytake(Id, 1, Appends) of
        {value, {_, L}, AppendsNext} ->
            LNew = lists:umerge(L, [{Index, undefined, {Range, Request}}]),
            lists:umerge(AppendsNext, [{Id, LNew}]);
        false ->
            L = [{Index, undefined, {Range, Request}}],
            lists:umerge(Appends, [{Id, L}])
    end.

request_append_store(Id, Index,
                     Name, Range, Request, Timeout,
                     Appends, Service) ->
    case lists:keytake(Id, 1, Appends) of
        {value, {_, L}, AppendsNext} ->
            LNew = lists:umerge(L, [{Index, undefined, {Range, Request}}]),
            lists:umerge(AppendsNext, [{Id, LNew}]);
        false ->
            % first append multipart chunk creates a timer to enforce
            % the request timeout for all the multipart chunks
            % (associated with the single multipart id)
            Tref = erlang:send_after(Timeout, Service,
                                     {append_clear, Name, Id}),
            L = [{Index, Tref, {Range, Request}}],
            lists:umerge(Appends, [{Id, L}])
    end.

request_append_file([],
                    #file{contents = Contents,
                          size = ContentsSizeOld,
                          path = FilePath,
                          headers = FileHeaders,
                          mtime_i = MTimeIOld,
                          notify = NotifyL} = File,
                    #state{prefix = Prefix,
                           directory_length = DirectoryLength,
                           files_size_limit = FilesSizeLimit,
                           files_size = FilesSize,
                           cache = Cache,
                           files = Files,
                           use_expires = UseExpires,
                           use_http_get_suffix = true} = State, Dispatcher) ->
    case files_size_check(Contents,
                          FilesSize - ContentsSizeOld,
                          FilesSizeLimit) of
        {ok, ContentsSize, FilesSizeNew} ->
            case file:write_file(FilePath, Contents, [raw]) of
                ok ->
                    {ok, FileInfo} = read_file_info(FilePath),
                    file_notify_send(NotifyL, Contents, Dispatcher),
                    #file_info{mtime = MTime,
                               access = Access} = FileInfo,
                    MTimeI = mtime_i_update(MTimeIOld, MTime),
                    FileNew = File#file{size = ContentsSize,
                                        mtime_i = MTimeI,
                                        access = Access},
                    FileName = lists:nthtail(DirectoryLength, FilePath),
                    FilesNew = file_refresh(FileName, FileNew,
                                            Files, true, Prefix),
                    ETag = cache_header_etag(MTimeI),
                    Headers = if
                        Cache =:= undefined ->
                            cacheless_headers_data(MTime, MTimeI, ETag, true);
                        true ->
                            cache_headers_data(UseExpires, MTime, MTimeI,
                                               ETag, Cache, true)
                    end,
                    {reply,
                     FileHeaders ++ Headers, Contents,
                     replace_hit(FileNew, undefined,
                                 State#state{files_size = FilesSizeNew,
                                             files = FilesNew})};
                {error, Reason} ->
                    ?LOG_ERROR("file write ~s error: ~p",
                               [FilePath, Reason]),
                    {reply,
                     [{<<"status">>, <<"500">>}],
                     <<>>, State}
            end;
        {error, ContentsSize} ->
            ?LOG_WARN("file name ~s (size ~w KiB) append "
                      "excluded due to ~w KiB files_size",
                      [FilePath, ContentsSize div 1024,
                       FilesSizeLimit div 1024]),
            {reply,
             [{<<"status">>, <<"400">>}],
             <<>>, State}
    end;
request_append_file([{undefined, Request} | RangeRequests],
                    #file{contents = Contents} = File, State, Dispatcher) ->
    ContentsNew = if
        is_binary(Request) ->
            <<Contents/binary, Request/binary>>;
        is_list(Request) ->
            erlang:iolist_to_binary([Contents, Request])
    end,
    request_append_file(RangeRequests,
                        File#file{contents = ContentsNew}, State, Dispatcher);
request_append_file([{Range, Request} | RangeRequests],
                    #file{contents = Contents} = File, State, Dispatcher) ->
    RequestBin = if
        is_binary(Request) ->
            Request;
        is_list(Request) ->
            erlang:iolist_to_binary(Request)
    end,
    ContentLength = erlang:byte_size(Contents),
    {Start, End} = case Range of
        {I, infinity} ->
            ByteStart = if
                I < 0 ->
                    ContentLength + I;
                I >= 0 ->
                    I
            end,
            ByteEnd = ByteStart + erlang:byte_size(RequestBin) - 1,
            {ByteStart, ByteEnd};
        {IStart, IEnd} ->
            ByteStart = if
                IStart < 0 ->
                    ContentLength + IStart;
                IStart >= 0 ->
                    IStart
            end,
            ByteEnd = IEnd,
            {ByteStart, ByteEnd};
        I when I < 0 ->
            ByteStart = ContentLength + I,
            ByteEnd = ByteStart + erlang:byte_size(RequestBin) - 1,
            {ByteStart, ByteEnd}
    end,
    if
        Start =< End ->
            ContentsNew = if
                End < ContentLength ->
                    StartBinBits = Start * 8,
                    EndBinBits = (End - Start + 1) * 8,
                    <<StartBin:StartBinBits/bitstring,
                      _:EndBinBits,
                      EndBin/binary>> = Contents,
                    <<StartBin/binary,
                      RequestBin/binary,
                      EndBin/binary>>;
                Start < ContentLength ->
                    StartBinBits = Start * 8,
                    <<StartBin:StartBinBits/bitstring,
                      _/binary>> = Contents,
                    <<StartBin/binary,
                      RequestBin/binary>>;
                Start == ContentLength ->
                    <<Contents/binary,
                      RequestBin/binary>>;
                Start > ContentLength ->
                    GapBits = (Start - ContentLength) * 8,
                    <<Contents/binary,
                      0:GapBits,
                      RequestBin/binary>>
            end,
            request_append_file(RangeRequests,
                                File#file{contents = ContentsNew},
                                State, Dispatcher);
        true ->
            ContentLengthBin = erlang:integer_to_binary(ContentLength),
            {reply,
             [{<<"status">>, <<"416">>},
              {<<"content-range">>,
               <<(<<"bytes */">>)/binary, ContentLengthBin/binary>>} |
              contents_ranges_headers(true)],
             <<>>, State}
    end.

files_notify(#file_notify{} = Notify,
             Pattern, Files0) ->
    {ContentsN,
     FilesN} = trie:fold_match(Pattern,
                                        fun(Name, File, {Contents0, Files1}) ->
        Files2 = if
            Files1 =:= undefined ->
                Files0;
            true ->
                Files1
        end,
        #file{contents = Contents1,
              notify = NotifyL} = File,
        Files3 = trie:store(Name,
                                     File#file{notify = [Notify | NotifyL]},
                                     Files2),
        Contents2 = if
            Contents0 =:= undefined ->
                Contents1;
            true ->
                Contents0
        end,
        {Contents2, Files3}
    end, {undefined, undefined}, Files0),
    if
        FilesN =:= undefined ->
            {error, enoent};
        true ->
            {ok, ContentsN, FilesN}
    end.

service_name_suffix_read_root_file("index.htm") ->
    true;
service_name_suffix_read_root_file("index.html") ->
    true;
service_name_suffix_read_root_file(_) ->
    false.

service_name_suffix_read_root(FileName) ->
    [File | PathParts] = lists:reverse(filename:split(FileName)),
    case service_name_suffix_read_root_file(File) of
        true ->
            if
                PathParts == [] ->
                    "";
                true ->
                    filename:join(lists:reverse(PathParts)) ++ "/"
            end;
        false ->
            undefined
    end.

service_name_suffix_options(FileName) ->
    FileName ++ "/options".

service_name_suffix_header(FileName) ->
    FileName ++ "/head".

service_name_suffix_read(FileName, true) ->
    FileName ++ "/get";
service_name_suffix_read(FileName, false) ->
    FileName.

service_name_suffix_write_truncate(FileName) ->
    FileName ++ "/put".

service_name_suffix_write_append(FileName) ->
    FileName ++ "/post".

files_size_check(Contents, FilesSize, FilesSizeLimit) ->
    ContentsSize = byte_size(Contents),
    FilesSizeNew = ContentsSize + FilesSize,
    if
        FilesSizeLimit =:= undefined ->
            {ok, ContentsSize, FilesSizeNew};
        is_integer(FilesSizeLimit) ->
            if
                FilesSizeNew =< FilesSizeLimit ->
                    {ok, ContentsSize, FilesSizeNew};
                FilesSizeNew > FilesSizeLimit ->
                    {error, ContentsSize}
            end
    end.

file_add_read(FileName, File,
              Files0, UseHttpGetSuffix, Prefix, Dispatcher) ->
    Files3 = case service_name_suffix_read_root(FileName) of
        undefined ->
            Files0;
        SuffixRead ->
            Files2 = if
                UseHttpGetSuffix =:= true ->
                    Suffix0 = service_name_suffix_options(SuffixRead),
                    cloudi_service:subscribe(Dispatcher, Suffix0),
                    Files1 = trie:store(Prefix ++ Suffix0,
                                                 File, Files0),
                    Suffix1 = service_name_suffix_header(SuffixRead),
                    cloudi_service:subscribe(Dispatcher, Suffix1),
                    trie:store(Prefix ++ Suffix1, File, Files1);
                UseHttpGetSuffix =:= false ->
                    Files0
            end,
            Suffix2 = service_name_suffix_read(SuffixRead, UseHttpGetSuffix),
            cloudi_service:subscribe(Dispatcher, Suffix2),
            trie:store(Prefix ++ Suffix2, File, Files2)
    end,
    Suffix3 = service_name_suffix_read(FileName, UseHttpGetSuffix),
    cloudi_service:subscribe(Dispatcher, Suffix3),
    Files4 = trie:store(Prefix ++ Suffix3, File, Files3),
    if
        UseHttpGetSuffix =:= true ->
            Suffix4 = service_name_suffix_options(FileName),
            cloudi_service:subscribe(Dispatcher, Suffix4),
            Files5 = trie:store(Prefix ++ Suffix4,
                                         File, Files4),
            Suffix5 = service_name_suffix_header(FileName),
            cloudi_service:subscribe(Dispatcher, Suffix5),
            trie:store(Prefix ++ Suffix5, File, Files5);
        UseHttpGetSuffix =:= false ->
            Files4
    end.

file_add_write(FileName, #file{write = Write} = File,
               Files0, Prefix, Dispatcher) ->
    Files1 = file_add_read(FileName, File,
                           Files0, true, Prefix, Dispatcher),
    case Write of
        [truncate] ->
            file_add_write_truncate(FileName, File,
                                    Files1, Prefix, Dispatcher);
        [append] ->
            file_add_write_append(FileName, File,
                                  Files1, Prefix, Dispatcher)
    end.

file_add_write_truncate(FileName, #file{write = Write} = File,
                        Files0, Prefix, Dispatcher) ->
    Suffix0 = service_name_suffix_write_truncate(FileName),
    cloudi_service:subscribe(Dispatcher, Suffix0),
    case lists:delete(truncate, Write) of
        [] ->
            trie:store(Prefix ++ Suffix0, File, Files0);
        [append] ->
            file_refresh(FileName, File,
                         Files0, true, Prefix)
    end.

file_add_write_append(FileName, #file{write = Write} = File,
                      Files0, Prefix, Dispatcher) ->
    Suffix0 = service_name_suffix_write_append(FileName),
    cloudi_service:subscribe(Dispatcher, Suffix0),
    case lists:delete(append, Write) of
        [] ->
            trie:store(Prefix ++ Suffix0, File, Files0);
        [truncate] ->
            file_refresh(FileName, File,
                         Files0, true, Prefix)
    end.

file_refresh(FileName, #file{write = Write} = File,
             Files0, UseHttpGetSuffix, Prefix) ->
    Files3 = case service_name_suffix_read_root(FileName) of
        undefined ->
            Files0;
        SuffixRead ->
            Files2 = if
                UseHttpGetSuffix =:= true ->
                    Suffix0 = service_name_suffix_options(SuffixRead),
                    Files1 = trie:store(Prefix ++ Suffix0,
                                                 File, Files0),
                    Suffix1 = service_name_suffix_header(SuffixRead),
                    trie:store(Prefix ++ Suffix1, File, Files1);
                UseHttpGetSuffix =:= false ->
                    Files0
            end,
            Suffix2 = service_name_suffix_read(SuffixRead, UseHttpGetSuffix),
            trie:store(Prefix ++ Suffix2, File, Files2)
    end,
    Suffix3 = service_name_suffix_read(FileName, UseHttpGetSuffix),
    Files4 = trie:store(Prefix ++ Suffix3, File, Files3),
    if
        UseHttpGetSuffix =:= true ->
            Suffix4 = service_name_suffix_options(FileName),
            Files5 = trie:store(Prefix ++ Suffix4,
                                         File, Files4),
            Suffix5 = service_name_suffix_header(FileName),
            Files6 = trie:store(Prefix ++ Suffix5, File, Files5),
            Files7 = case lists:member(truncate, Write) of
                true ->
                    Suffix6 = service_name_suffix_write_truncate(FileName),
                    trie:store(Prefix ++ Suffix6, File, Files6);
                false ->
                    Files6
            end,
            case lists:member(append, Write) of
                true ->
                    Suffix7 = service_name_suffix_write_append(FileName),
                    trie:store(Prefix ++ Suffix7, File, Files7);
                false ->
                    Files7
            end;
        UseHttpGetSuffix =:= false ->
            Files4
    end.

file_remove_read(FileName, Files0, UseHttpGetSuffix, Prefix, Dispatcher) ->
    Files3 = case service_name_suffix_read_root(FileName) of
        undefined ->
            Files0;
        SuffixRead ->
            Files2 = if
                UseHttpGetSuffix =:= true ->
                    Suffix0 = service_name_suffix_options(SuffixRead),
                    cloudi_service:unsubscribe(Dispatcher, Suffix0),
                    Files1 = trie:erase(Prefix ++ Suffix0, Files0),
                    Suffix1 = service_name_suffix_header(SuffixRead),
                    cloudi_service:unsubscribe(Dispatcher, Suffix1),
                    trie:erase(Prefix ++ Suffix1, Files1);
                UseHttpGetSuffix =:= false ->
                    Files0
            end,
            Suffix2 = service_name_suffix_read(SuffixRead, UseHttpGetSuffix),
            cloudi_service:unsubscribe(Dispatcher, Suffix2),
            trie:erase(Prefix ++ Suffix2, Files2)
    end,
    Suffix3 = service_name_suffix_read(FileName, UseHttpGetSuffix),
    cloudi_service:unsubscribe(Dispatcher, Suffix3),
    Files4 = trie:erase(Prefix ++ Suffix3, Files3),
    if
        UseHttpGetSuffix =:= true ->
            Suffix4 = service_name_suffix_options(FileName),
            cloudi_service:unsubscribe(Dispatcher, Suffix4),
            Files5 = trie:erase(Prefix ++ Suffix4, Files4),
            Suffix5 = service_name_suffix_header(FileName),
            cloudi_service:unsubscribe(Dispatcher, Suffix5),
            trie:erase(Prefix ++ Suffix5, Files5);
        UseHttpGetSuffix =:= false ->
            Files4
    end.

file_exists(FileName, Files, UseHttpGetSuffix, Prefix) ->
    Suffix = service_name_suffix_read(FileName, UseHttpGetSuffix),
    trie:find(Prefix ++ Suffix, Files).

file_read_data_position(_, _, Size,
                        FilesSize, FilesSizeLimit)
    when is_integer(FilesSizeLimit),
         is_integer(Size), Size + FilesSize > FilesSizeLimit ->
    true = Size >= 0,
    {files_size, Size};
file_read_data_position(F, undefined, undefined,
                        FilesSize, FilesSizeLimit) ->
    case file:position(F, eof) of
        {ok, Size} ->
            file_read_data_position(F, 0, Size,
                                    FilesSize, FilesSizeLimit);
        {error, _} = Error ->
            Error
    end;
file_read_data_position(F, undefined, Size,
                        FilesSize, _)
    when is_integer(Size) ->
    case file:read(F, Size) of
        {ok, Contents} ->
            ContentsSize = byte_size(Contents),
            {ok, Contents, ContentsSize, ContentsSize + FilesSize};
        eof ->
            {error, eof};
        {error, _} = Error ->
            Error
    end;
file_read_data_position(F, I, undefined,
                        FilesSize, FilesSizeLimit)
    when is_integer(I) ->
    case file:position(F, eof) of
        {ok, Size} ->
            if
                I < 0 ->
                    AbsoluteI = Size + I,
                    if
                        AbsoluteI >= 0 ->
                            file_read_data_position(F, AbsoluteI, I * -1,
                                                    FilesSize, FilesSizeLimit);
                        true ->
                            file_read_data_position(F, 0, Size,
                                                    FilesSize, FilesSizeLimit)
                    end;
                I < Size ->
                    file_read_data_position(F, I, Size - I,
                                            FilesSize, FilesSizeLimit);
                I >= Size ->
                    {ok, <<>>, 0, FilesSize}
            end;
        {error, _} = Error ->
            Error
    end;
file_read_data_position(F, I, Size,
                        FilesSize, _)
    when is_integer(I), is_integer(Size) ->
    Location = if
        I < 0 ->
            {eof, I};
        true ->
            {bof, I}
    end,
    case file:position(F, Location) of
        {ok, _} ->
            case file:read(F, Size) of
                {ok, Contents} ->
                    ContentsSize = byte_size(Contents),
                    {ok, Contents, ContentsSize, ContentsSize + FilesSize};
                eof ->
                    {error, eof};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

% allow it to read from any non-directory/link type (device, other, regular)
file_read_data(#file_info{access = Access}, FilePath, I, Size,
               FilesSize, FilesSizeLimit)
    when Access =:= read; Access =:= read_write ->
    case file:open(FilePath, [raw, read, binary]) of
        {ok, F} ->
            Result = file_read_data_position(F, I, Size,
                                             FilesSize, FilesSizeLimit),
            _ = file:close(F),
            Result;
        {error, _} = Error ->
            Error
    end;
file_read_data(_, _, _, _, _, _) ->
    {error, enoent}.

file_header_content_disposition(FilePath, true) ->
    [{<<"content-disposition">>,
      erlang:iolist_to_binary(["attachment; filename=\"",
                               filename:basename(FilePath), "\""])}];
file_header_content_disposition(_, false) ->
    [].

file_headers(FilePath, undefined, UseContentDisposition) ->
    file_header_content_disposition(FilePath, UseContentDisposition);
file_headers(FilePath, ContentTypeLookup, UseContentDisposition) ->
    Headers = file_header_content_disposition(FilePath, UseContentDisposition),
    case filename:extension(FilePath) of
        [$. | _] = Extension ->
            case trie:find(Extension, ContentTypeLookup) of
                error ->
                    [{<<"content-type">>, <<"application/octet-stream">>} |
                     Headers];
                {ok, {_, ContentType}} ->
                    [{<<"content-type">>, ContentType} |
                     Headers]
            end;
        _ ->
            Headers
    end.

file_notify_send([], _, _) ->
    ok;
file_notify_send([#file_notify{send = Send,
                               service_name = Name,
                               timeout = Timeout,
                               priority = Priority} | NotifyL],
                 Contents, Dispatcher) ->
    cloudi_service:Send(Dispatcher, Name, <<>>, Contents, Timeout, Priority),
    file_notify_send(NotifyL, Contents, Dispatcher).

read_files_init(ReplaceHit0, Replace, ReadL, Toggle, ContentTypeLookup,
                UseContentDisposition, UseHttpGetSuffix,
                FilesSizeLimit, Directory, Prefix, Dispatcher) ->
    TimeNative = cloudi_timestamp:native_monotonic(),
    FilesSize0 = 0,
    Files0 = trie:new(),
    InitF = fun(FilePath, FileName, FileInfo, SegmentI, SegmentSize,
                {ReplaceHit1, FilesSize1, Files1}) ->
        case cloudi_service_name:pattern(FileName) of
            false ->
                ReplaceHit2 = replace_add(FileName, TimeNative,
                                          Replace, ReplaceHit1),
                #file_info{access = Access,
                           mtime = MTime} = FileInfo,
                case file_read_data(FileInfo, FilePath,
                                    SegmentI, SegmentSize,
                                    FilesSize1, FilesSizeLimit) of
                    {ok, Contents, ContentsSize, FilesSize2} ->
                        Headers = file_headers(FilePath,
                                               ContentTypeLookup,
                                               UseContentDisposition),
                        File = #file{contents = Contents,
                                     size = ContentsSize,
                                     path = FilePath,
                                     headers = Headers,
                                     mtime_i = {MTime, 0},
                                     access = Access,
                                     toggle = Toggle},
                        {ReplaceHit2, FilesSize2,
                         file_add_read(FileName, File, Files1,
                                       UseHttpGetSuffix, Prefix,
                                       Dispatcher)};
                    {files_size, ContentsSize} ->
                        ?LOG_WARN("file name ~s (size ~w KiB) "
                                  "excluded due to ~w KiB files_size",
                                  [FilePath, ContentsSize div 1024,
                                   FilesSizeLimit div 1024]),
                        {ReplaceHit2, FilesSize1, Files1};
                    {error, Reason} ->
                        ?LOG_ERROR("file read ~s error: ~p",
                                   [FilePath, Reason]),
                        {ReplaceHit2, FilesSize1, Files1}
                end;
            true ->
                ?LOG_ERROR("file name \"~s\" error: invalid character(s)",
                           [FilePath]),
                {ReplaceHit1, FilesSize1, Files1}
        end
    end,
    InitA = {ReplaceHit0, FilesSize0, Files0},
    if
        ReadL == [] ->
            fold_files(Directory, InitF, InitA);
        true ->
            fold_files_exact(ReadL, Directory, InitF, InitA)
    end.

read_files_refresh(ReplaceHit0, Replace0, ReplaceIndexUsed, ReadL, Toggle,
                   FilesSize0, Files0, ContentTypeLookup,
                   UseContentDisposition, UseHttpGetSuffix,
                   FilesSizeLimit, ProcessIndex, DirectoryLength, Directory,
                   PrefixLength, Prefix, Dispatcher) ->
    TimeNative = cloudi_timestamp:native_monotonic(),
    RefreshRemoveF = fun(FileName, _,
                         {ReplaceHit1, Replace1, FilesSize1, Files1}) ->
        case file_exists(FileName, Files1, UseHttpGetSuffix, Prefix) of
            {ok, #file{size = ContentsSizeOld,
                       write = []}} ->
                % file was removed
                {Replace2,
                 ReplaceHit2} = replace_remove(FileName,
                                               Replace1,
                                               ReplaceHit1),
                {ReplaceHit2, Replace2,
                 FilesSize1 - ContentsSizeOld,
                 file_remove_read(FileName, Files1,
                                  UseHttpGetSuffix, Prefix,
                                  Dispatcher)};
            _ ->
                {ReplaceHit1, Replace1, FilesSize1, Files1}
        end
    end,
    RefreshUpdateF = fun(FilePath, FileName, FileInfo, SegmentI, SegmentSize,
                         {ReplaceHit1, Replace1, FilesSize1, Files1}) ->
        #file_info{access = Access,
                   mtime = MTime} = FileInfo,
        case file_exists(FileName, Files1, UseHttpGetSuffix, Prefix) of
            {ok, #file{mtime_i = {MTime, _}} = File0} ->
                File1 = File0#file{toggle = Toggle},
                {ReplaceHit1, Replace1, FilesSize1,
                 file_refresh(FileName, File1, Files1,
                              UseHttpGetSuffix, Prefix)};
            {ok, #file{size = ContentsSizeOld,
                       mtime_i = MTimeIOld,
                       notify = NotifyL,
                       write = Write} = File0} ->
                case file_read_data(FileInfo, FilePath,
                                    SegmentI, SegmentSize,
                                    FilesSize1 - ContentsSizeOld,
                                    FilesSizeLimit) of
                    {ok, Contents, ContentsSize, FilesSize2} ->
                        file_notify_send(NotifyL, Contents, Dispatcher),
                        MTimeI = mtime_i_update(MTimeIOld, MTime),
                        File1 = File0#file{contents = Contents,
                                           size = ContentsSize,
                                           mtime_i = MTimeI,
                                           access = Access,
                                           toggle = Toggle},
                        ReplaceHit2 = replace_hit_update(FileName,
                                                         ContentsSize,
                                                         TimeNative,
                                                         Replace1,
                                                         ReplaceHit1),
                        {ReplaceHit2, Replace1, FilesSize2,
                         file_refresh(FileName, File1, Files1,
                                      UseHttpGetSuffix, Prefix)};
                    {files_size, ContentsSize} ->
                        ?LOG_WARN("file name ~s (size ~w KiB) update "
                                  "excluded due to ~w KiB files_size",
                                  [FilePath, ContentsSize div 1024,
                                   FilesSizeLimit div 1024]),
                        {ReplaceHit1, Replace1, FilesSize1, Files1};
                    {error, _} when Write =:= [] ->
                        % file was removed
                        {Replace2,
                         ReplaceHit2} = replace_remove(FileName,
                                                       Replace1,
                                                       ReplaceHit1),
                        {ReplaceHit2, Replace2,
                         FilesSize1 - ContentsSizeOld,
                         file_remove_read(FileName, Files1,
                                          UseHttpGetSuffix, Prefix,
                                          Dispatcher)};
                    {error, _} ->
                        File1 = File0#file{access = Access,
                                           toggle = Toggle},
                        {ReplaceHit1, Replace1, FilesSize1,
                         file_refresh(FileName, File1, Files1,
                                      UseHttpGetSuffix, Prefix)}
                end;
            error ->
                ReplaceHit2 = replace_add(FileName, TimeNative,
                                          Replace1, ReplaceHit1),
                case file_read_data(FileInfo, FilePath,
                                    SegmentI, SegmentSize,
                                    FilesSize1,
                                    FilesSizeLimit) of
                    {ok, Contents, ContentsSize, FilesSize2} ->
                        Headers = file_headers(FilePath,
                                               ContentTypeLookup,
                                               UseContentDisposition),
                        File = #file{contents = Contents,
                                     size = ContentsSize,
                                     path = FilePath,
                                     headers = Headers,
                                     mtime_i = {MTime, 0},
                                     access = Access,
                                     toggle = Toggle},
                        {ReplaceHit2, Replace1, FilesSize2,
                         file_add_read(FileName, File, Files1,
                                       UseHttpGetSuffix, Prefix,
                                       Dispatcher)};
                    {files_size, ContentsSize} ->
                        ?LOG_WARN("file name ~s (size ~w KiB) addition "
                                  "excluded due to ~w KiB files_size",
                                  [FilePath, ContentsSize div 1024,
                                   FilesSizeLimit div 1024]),
                        {ReplaceHit2, Replace1, FilesSize1, Files1};
                    {error, Reason} ->
                        ?LOG_ERROR("file read ~s error: ~p",
                                   [FilePath, Reason]),
                        {ReplaceHit2, Replace1, FilesSize1, Files1}
                end
        end
    end,
    RefreshA = {ReplaceHit0, Replace0, FilesSize0, Files0},
    {ReplaceHitN,
     ReplaceN,
     FilesSize3,
     Files3} = replace_fold(ReplaceHit0, Replace0, ReadL, Directory,
                            RefreshRemoveF, RefreshUpdateF, RefreshA),
    ok = replace_persist(ReplaceHitN, ReplaceN, ReplaceIndexUsed,
                         ProcessIndex, Directory),
    % remove anything not updated, since the file was removed
    {_,
     FilesSizeN,
     FilesN} = trie:fold(fun(Pattern,
                                      #file{size = ContentsSizeOld,
                                            path = FilePath,
                                            toggle = FileToggle,
                                            write = Write} = File,
                                      {Removed,
                                       FilesSize4, Files4}) ->
        if
            FileToggle =/= Toggle ->
                if
                    Write =:= [] ->
                        undefined = ReplaceN,
                        FileName = lists:nthtail(DirectoryLength,
                                                 FilePath),
                        Suffix = lists:nthtail(PrefixLength, Pattern),
                        cloudi_service:unsubscribe(Dispatcher, Suffix),
                        case trie:is_key(FileName, Removed) of
                            true ->
                                {Removed, FilesSize4,
                                 trie:erase(Pattern, Files4)};
                            false ->
                                {trie:store(FileName, Removed),
                                 FilesSize4 - ContentsSizeOld,
                                 trie:erase(Pattern, Files4)}
                        end;
                    true ->
                        {Removed, FilesSize4,
                         trie:store(Pattern,
                                             File#file{toggle = Toggle},
                                             Files4)}
                end;
            true ->
                {Removed, FilesSize4, Files4}
        end
    end, {trie:new(), FilesSize3, Files3}, Files3),
    {ReplaceHitN, ReplaceN, FilesSizeN, FilesN}.

-type fold_files_f() :: fun((string(), string(), #file_info{},
                             integer() | undefined,
                             non_neg_integer() | undefined,
                             any()) -> any()).

-spec fold_files_exact(ReadL :: read_list_exact(),
                       Directory :: string() | binary(),
                       F :: fold_files_f(),
                       A :: any()) ->
    any().

fold_files_exact(ReadL, Directory, F, A)
    when is_function(F, 6) ->
    fold_files_exact_element(ReadL, Directory, F, A).

fold_files_exact_element([], _, _, A) ->
    A;
fold_files_exact_element([{FileName, SegmentI, SegmentSize} | ReadL],
                         Directory, F, A) ->
    FilePath = filename:join(Directory, FileName),
    case read_file_info(FilePath) of
        {ok, #file_info{type = Type} = FileInfo} ->
            true = (Type /= directory) andalso
                   (Type /= device) andalso
                   (Type /= other) andalso
                   (Type /= undefined),
            fold_files_exact_element(ReadL, Directory, F,
                                     F(FilePath, FileName, FileInfo,
                                       SegmentI, SegmentSize, A));
        {error, Reason} ->
            ?LOG_WARN("file ~s error: ~p", [FilePath, Reason]),
            fold_files_exact_element(ReadL, Directory, F, A)
    end.

-spec fold_files(Directory :: string() | binary(),
                 F :: fold_files_f(),
                 A :: any()) ->
    any().

% similar to filelib:fold_files/5 but
% with recursive always true, with a regex of ".*",
% with links included, and with both the filename and file_info provided to F
fold_files(Directory, F, A)
    when is_function(F, 6) ->
    case file:list_dir_all(Directory) of
        {ok, FileNames0} ->
            FileNamesN = lists:filter(fun(FileName) ->
                not lists:prefix(?REPLACE_INDEX_FILENAME, FileName)
            end, FileNames0),
            fold_files_directory(FileNamesN, Directory, F, A);
        {error, Reason} ->
            ?LOG_WARN("directory ~s error: ~p", [Directory, Reason]),
            A
    end.

fold_files_list(Directory, Path, F, A)
    when is_function(F, 6) ->
    case file:list_dir_all(filename:join(Directory, Path)) of
        {ok, FileNames} ->
            fold_files_directory([filename:join(Path, FileName) ||
                                  FileName <- FileNames],
                                 Directory, F, A);
        {error, Reason} ->
            ?LOG_WARN("directory ~s path ~s error: ~p",
                      [Directory, Path, Reason]),
            A
    end.

fold_files_f(FilePath, FileName, FileInfo, F, A) ->
    FilePathString = if
        is_binary(FilePath) ->
            erlang:binary_to_list(FilePath);
        is_list(FilePath) ->
            FilePath
    end,
    FileNameString = if
        is_binary(FileName) ->
            erlang:binary_to_list(FileName);
        is_list(FileName) ->
            FileName
    end,
    SegmentI = undefined,
    SegmentSize = undefined,
    F(FilePathString, FileNameString, FileInfo, SegmentI, SegmentSize, A).

fold_files_directory([], _, _, A) ->
    A;
fold_files_directory([FileName | FileNames], Directory, F, A) ->
    FilePath = filename:join(Directory, FileName),
    case read_file_info(FilePath) of
        {ok, #file_info{type = directory}} ->
            fold_files_directory(FileNames, Directory, F,
                                 fold_files_list(Directory, FileName, F, A));
        {ok, #file_info{type = Type}}
            when Type =:= device;
                 Type =:= other;
                 Type =:= undefined ->
            ?LOG_WARN("file ~s type ~s", [FilePath, Type]),
            fold_files_directory(FileNames, Directory, F, A);
        {ok, FileInfo} ->
            fold_files_directory(FileNames, Directory, F,
                                 fold_files_f(FilePath, FileName, FileInfo,
                                              F, A));
        {error, Reason} ->
            ?LOG_WARN("file ~s error: ~p", [FilePath, Reason]),
            fold_files_directory(FileNames, Directory, F, A)
    end.

read_file_info(FilePath) ->
    file:read_file_info(FilePath, [raw, {time, universal}]).

cache_status(ETag, KeyValues, {MTime, _}, InvalidTime) ->
    cache_status_0(ETag, KeyValues, MTime, InvalidTime).

cache_status_0(ETag, KeyValues, MTime, InvalidTime) ->
    case cloudi_key_value:find(<<"if-none-match">>, KeyValues) of
        {ok, <<"*">>} ->
            cache_status_1(ETag, KeyValues, MTime, InvalidTime);
        error ->
            cache_status_1(ETag, KeyValues, MTime, InvalidTime);
        {ok, IfNoneMatch} ->
            case binary:match(IfNoneMatch, ETag) of
                nomatch ->
                    cache_status_1(ETag, KeyValues, MTime, InvalidTime);
                _ ->
                    304
            end
    end.

cache_status_1(ETag, KeyValues, MTime, InvalidTime) ->
    case cloudi_key_value:find(<<"if-match">>, KeyValues) of
        {ok, <<"*">>} ->
            cache_status_2(KeyValues, MTime, InvalidTime);
        error ->
            cache_status_2(KeyValues, MTime, InvalidTime);
        {ok, IfMatch} ->
            case binary:match(IfMatch, ETag) of
                nomatch ->
                    412;
                _ ->
                    cache_status_2(KeyValues, MTime, InvalidTime)
            end
    end.

cache_status_2(KeyValues, MTime, InvalidTime) ->
    case cloudi_key_value:find(<<"if-modified-since">>, KeyValues) of
        {ok, DateTimeBinary} ->
            try cow_date:parse_date(DateTimeBinary) of
                DateTime
                when (MTime > DateTime) orelse
                     ((InvalidTime /= undefined) andalso
                      (DateTime > InvalidTime)) ->
                    200;
                _ ->
                    304
            catch
                _:_ ->
                    cache_status_3(KeyValues, MTime, InvalidTime)
            end;
        error ->
            cache_status_3(KeyValues, MTime, InvalidTime)
    end.

cache_status_3(KeyValues, MTime, InvalidTime) ->
    case cloudi_key_value:find(<<"if-unmodified-since">>, KeyValues) of
        {ok, DateTimeBinary} ->
            try cow_date:parse_date(DateTimeBinary) of
                DateTime
                when (MTime =< DateTime) andalso
                     ((InvalidTime =:= undefined) orelse
                      (DateTime =< InvalidTime)) ->
                    412;
                _ ->
                    200
            catch
                _:_ ->
                    200
            end;
        error ->
            200
    end.

invalid_time(_, undefined) ->
    undefined;
invalid_time(NowTime, HTTPClockSkewMax) ->
    calendar:gregorian_seconds_to_datetime(
        calendar:datetime_to_gregorian_seconds(NowTime) + HTTPClockSkewMax).

mtime_i_update({MTime, I}, MTime) ->
    {MTime, I + 1};
mtime_i_update({_, _}, MTime) ->
    {MTime, 0}.

cache_header_etag({MTime, I}) ->
    Output = io_lib:format("\"~.16b~.16b\"",
                           [calendar:datetime_to_gregorian_seconds(MTime), I]),
    erlang:iolist_to_binary(Output).

cache_header_control(true, _) ->
    <<"public">>;
cache_header_control(false, Cache) ->
    Output = io_lib:format("public,max-age=~w", [Cache]),
    erlang:iolist_to_binary(Output).

cache_header_expires(ATime, Cache) ->
    Seconds = calendar:datetime_to_gregorian_seconds(ATime),
    Expires = calendar:gregorian_seconds_to_datetime(Seconds + Cache),
    rfc1123_format(Expires).

cache_headers_data(true = UseExpires, NowTime, {MTime, _},
                   ETag, Cache, UseHttpGetSuffix) ->
    [{<<"cache-control">>, cache_header_control(UseExpires, Cache)},
     {<<"expires">>, cache_header_expires(NowTime, Cache)},
     {<<"etag">>, ETag},
     {<<"last-modified">>, rfc1123_format(MTime)},
     {<<"date">>, rfc1123_format(NowTime)} |
     contents_ranges_headers(UseHttpGetSuffix)];
cache_headers_data(false = UseExpires, NowTime, {MTime, _},
                   ETag, Cache, UseHttpGetSuffix) ->
    [{<<"cache-control">>, cache_header_control(UseExpires, Cache)},
     {<<"etag">>, ETag},
     {<<"last-modified">>, rfc1123_format(MTime)},
     {<<"date">>, rfc1123_format(NowTime)} |
     contents_ranges_headers(UseHttpGetSuffix)].

cache_headers_empty(NowTime, {MTime, _}, UseHttpGetSuffix) ->
    [{<<"last-modified">>, rfc1123_format(MTime)},
     {<<"date">>, rfc1123_format(NowTime)} |
     contents_ranges_headers(UseHttpGetSuffix)].

cacheless_headers_data(NowTime, {MTime, _}, ETag, UseHttpGetSuffix) ->
    [{<<"etag">>, ETag},
     {<<"last-modified">>, rfc1123_format(MTime)},
     {<<"date">>, rfc1123_format(NowTime)} |
     contents_ranges_headers(UseHttpGetSuffix)].

contents_ranges_headers(true) ->
    [{<<"accept-ranges">>, <<"bytes">>}];
contents_ranges_headers(false) ->
    [].

contents_ranges_header_length(Contents) ->
    ContentLength = erlang:byte_size(Contents),
    ContentLengthBin = erlang:integer_to_binary(ContentLength),
    {<<"content-range">>,
     <<(<<"bytes */">>)/binary, ContentLengthBin/binary>>}.

contents_ranges_read(ETag, KeyValues, {MTime, _}) ->
    contents_ranges_read_0(ETag, KeyValues, MTime).

contents_ranges_read_0(ETag, KeyValues, MTime) ->
    case cloudi_key_value:find(<<"range">>, KeyValues) of
        {ok, RangeData} ->
            try cow_http_hd:parse_range(RangeData) of
                {bytes, RangeList} ->
                    contents_ranges_read_1(RangeList, ETag,
                                           KeyValues, MTime);
                {_, _} ->
                    {416, undefined}
            catch
                _:_ ->
                    {400, undefined}
            end;
        error ->
            {200, undefined}
    end.

contents_ranges_read_1(RangeList, ETag, KeyValues, MTime) ->
    case cloudi_key_value:find(<<"if-range">>, KeyValues) of
        {ok, ETag} ->
            {206, RangeList};
        {ok, IfRangeData} ->
            try cow_date:parse_date(IfRangeData) of
                MTime ->
                    {206, RangeList};
                _ ->
                    {410, undefined}
            catch
                _:_ ->
                    {410, undefined}
            end;
        error ->
            {206, RangeList}
    end.

contents_ranges_append(ETag, KeyValues, {MTime, _}) ->
    Id = case cloudi_key_value:find(<<"x-multipart-id">>, KeyValues) of
        {ok, MultipartId} ->
            MultipartId;
        error ->
            undefined
    end,
    Last = case cloudi_key_value:find(<<"x-multipart-last">>, KeyValues) of
        {ok, <<"true">>} ->
            true;
        error ->
            false
    end,
    Index = case cloudi_key_value:find(<<"x-multipart-index">>, KeyValues) of
        {ok, IndexBin} ->
            erlang:binary_to_integer(IndexBin);
        error ->
            0
    end,
    case contents_ranges_read(ETag, KeyValues, MTime) of
        {200, undefined} ->
            LastNew = Last orelse (Id =:= undefined),
            {200, {undefined, Id, LastNew, Index}};
        {206, [Range]} ->
            LastNew = Last orelse (Id =:= undefined),
            {206, {Range, Id, LastNew, Index}};
        {206, [_ | _] = RangeList} ->
            try lists:nth(Index + 1, RangeList) of
                Range ->
                    {206, {Range, Id, Last, Index}}
            catch
                _:_ ->
                    {400, undefined}
            end;
        {400, undefined} = BadRequest ->
            BadRequest;
        {410, undefined} = Gone ->
            Gone;
        {416, undefined} = RequestedRangeNotSatisfiable ->
            RequestedRangeNotSatisfiable
    end.

content_range_read_part_get(undefined,
                            ByteStart, ByteEnd, ContentLengthBin, Part) ->
    ByteStartBin = erlang:integer_to_binary(ByteStart),
    ByteEndBin = erlang:integer_to_binary(ByteEnd),
    {[{<<"content-range">>,
       <<(<<"bytes ">>)/binary,
         ByteStartBin/binary,(<<"-">>)/binary,
         ByteEndBin/binary,(<<"/">>)/binary,
         ContentLengthBin/binary>>}], Part};
content_range_read_part_get(Boundary,
                            ByteStart, ByteEnd, ContentLengthBin, Part) ->
    ByteStartBin = erlang:integer_to_binary(ByteStart),
    ByteEndBin = erlang:integer_to_binary(ByteEnd),
    [cow_multipart:part(Boundary,
                                 [{<<"content-range">>,
                                   <<(<<"bytes ">>)/binary,
                                     ByteStartBin/binary,(<<"-">>)/binary,
                                     ByteEndBin/binary,(<<"/">>)/binary,
                                     ContentLengthBin/binary>>}]),
     Part].

content_range_read_part_check(ByteStart, ByteEnd, RangeList, Output, Boundary,
                              ContentLengthBin, ContentLength, Contents) ->
    ByteSize = ByteEnd - ByteStart + 1,
    Valid = if
        ByteStart =< ByteEnd ->
            ByteSize =< (ContentLength - ByteStart);
        true ->
            false
    end,
    if
        Valid =:= true ->
            Part = binary:part(Contents, ByteStart, ByteSize),
            Entry = content_range_read_part_get(Boundary, ByteStart, ByteEnd,
                                                ContentLengthBin, Part),
            content_range_read(RangeList, [Entry | Output], Boundary,
                               ContentLengthBin, ContentLength, Contents);
        Valid =:= false ->
            {416,
             [{<<"status">>, <<"416">>},
              {<<"content-range">>,
               <<(<<"bytes */">>)/binary, ContentLengthBin/binary>>} |
              contents_ranges_headers(true)], <<>>}
    end.

content_range_read([_ | L] = RangeList, Contents) ->
    ContentLength = erlang:byte_size(Contents),
    ContentLengthBin = erlang:integer_to_binary(ContentLength),
    Boundary = if
        L == [] ->
            undefined;
        true ->
            % make a multipart/byteranges response
            cow_multipart:boundary()
    end,
    content_range_read(RangeList, [], Boundary,
                       ContentLengthBin, ContentLength, Contents).

content_range_read([], [{Headers, Response}], undefined, _, _, _) ->
    {206,
     [{<<"status">>, <<"206">>},
      {<<"content-type">>, <<"application/octet-stream">>} |
      Headers], Response};
content_range_read([], Output, Boundary, _, _, _) ->
    ResponseData = lists:reverse([cow_multipart:close(Boundary) |
                                  Output]),
    {206,
     [{<<"status">>, <<"206">>},
      {<<"content-type">>,
       <<(<<"multipart/byteranges; boundary=">>)/binary, Boundary/binary>>}],
     erlang:iolist_to_binary(ResponseData)};
content_range_read([{I, infinity} | RangeList], Output, Boundary,
                   ContentLengthBin, ContentLength, Contents) ->
    ByteStart = if
        I < 0 ->
            ContentLength + I;
        I >= 0 ->
            I
    end,
    ByteEnd = ContentLength - 1,
    content_range_read_part_check(ByteStart, ByteEnd,
                                  RangeList, Output, Boundary,
                                  ContentLengthBin, ContentLength, Contents);
content_range_read([{IStart, IEnd} | RangeList], Output, Boundary,
                   ContentLengthBin, ContentLength, Contents) ->
    ByteStart = if
        IStart < 0 ->
            ContentLength + IStart;
        IStart >= 0 ->
            IStart
    end,
    ByteEnd = IEnd,
    content_range_read_part_check(ByteStart, ByteEnd,
                                  RangeList, Output, Boundary,
                                  ContentLengthBin, ContentLength, Contents);
content_range_read([I | RangeList], Output, Boundary,
                   ContentLengthBin, ContentLength, Contents)
    when is_integer(I) ->
    content_range_read([{I, infinity} | RangeList], Output, Boundary,
                       ContentLengthBin, ContentLength, Contents).

content_range_list_check([_ | L] = RangeList, Contents) ->
    ContentLength = erlang:byte_size(Contents),
    ContentLengthBin = erlang:integer_to_binary(ContentLength),
    Boundary = if
        L == [] ->
            undefined;
        true ->
            % make a multipart/byteranges response
            cow_multipart:boundary()
    end,
    content_range_list_check(RangeList, Boundary,
                             ContentLengthBin, ContentLength).

content_range_list_check([], undefined, _, _) ->
    {206,
     [{<<"status">>, <<"206">>},
      {<<"content-type">>, <<"application/octet-stream">>}]};
content_range_list_check([], _, _, _) ->
    {206,
     [{<<"status">>, <<"206">>},
      {<<"content-type">>, <<"multipart/byteranges">>}]};
content_range_list_check([{I, infinity} | RangeList], Boundary,
                         ContentLengthBin, ContentLength) ->
    ByteStart = if
        I < 0 ->
            ContentLength + I;
        I >= 0 ->
            I
    end,
    ByteEnd = ContentLength - 1,
    if
        ByteStart =< ByteEnd ->
            content_range_list_check(RangeList, Boundary,
                                     ContentLengthBin, ContentLength);
        true ->
            {416,
             [{<<"status">>, <<"416">>},
              {<<"content-range">>,
               <<(<<"bytes */">>)/binary, ContentLengthBin/binary>>} |
              contents_ranges_headers(true)]}
    end;
content_range_list_check([{IStart, IEnd} | RangeList], Boundary,
                         ContentLengthBin, ContentLength) ->
    ByteStart = if
        IStart < 0 ->
            ContentLength + IStart;
        IStart >= 0 ->
            IStart
    end,
    ByteEnd = IEnd,
    if
        ByteStart =< ByteEnd ->
            content_range_list_check(RangeList, Boundary,
                                     ContentLengthBin, ContentLength);
        true ->
            {416,
             [{<<"status">>, <<"416">>},
              {<<"content-range">>,
               <<(<<"bytes */">>)/binary, ContentLengthBin/binary>>} |
              contents_ranges_headers(true)]}
    end;
content_range_list_check([I | RangeList], Boundary,
                         ContentLengthBin, ContentLength)
    when is_integer(I) ->
    content_range_list_check([{I, infinity} | RangeList], Boundary,
                             ContentLengthBin, ContentLength).

replace_type(#lfuda{policy = Policy}) ->
    if
        Policy =:= lfuda ->
            lfuda;
        Policy =:= gdsf ->
            lfuda_gdsf
    end;
replace_type(#lru{}) ->
    lru.

replace_index_filename(ProcessIndex) ->
    Suffix = erlang:integer_to_list(ProcessIndex),
    ?REPLACE_INDEX_FILENAME ++ Suffix.

replace_new(true, ReplaceIndexUsed, ProcessIndex, Directory) ->
    % default algorithm
    replace_new(lfuda, ReplaceIndexUsed, ProcessIndex, Directory);
replace_new(lfuda, ReplaceIndexUsed, ProcessIndex, Directory) ->
    replace_new_index(#lfuda{policy = lfuda},
                      ReplaceIndexUsed, ProcessIndex, Directory);
replace_new(lfuda_gdsf, ReplaceIndexUsed, ProcessIndex, Directory) ->
    replace_new_index(#lfuda{policy = gdsf},
                      ReplaceIndexUsed, ProcessIndex, Directory);
replace_new(lru, ReplaceIndexUsed, ProcessIndex, Directory) ->
    replace_new_index(#lru{start = erlang:system_info(start_time)},
                      ReplaceIndexUsed, ProcessIndex, Directory).

replace_new_index(Replace, false, _, _) ->
    {Replace, trie:new()};
replace_new_index(Replace, true, ProcessIndex, Directory) ->
    IndexPath = filename:join(Directory, replace_index_filename(ProcessIndex)),
    case file:consult(IndexPath) of
        {ok, IndexData} ->
            replace_new_index_data(IndexData, replace_type(Replace), Replace);
        {error, Reason} ->
            if
                Reason /= enoent ->
                    ?LOG_ERROR("Failed to load replace index file ~s: ~p",
                               [IndexPath, Reason]);
                true ->
                    ok
            end,
            {Replace, trie:new()}
    end.

replace_new_index_data([{ReplaceType, ReplaceIndex}], ReplaceType, Replace)
    when is_list(ReplaceIndex) ->
    replace_new_index_load(ReplaceIndex, Replace);
replace_new_index_data([{ReplaceTypeFile, _}], ReplaceType, Replace) ->
    ?LOG_WARN("Unable to use replace index file due to type mismatch ~s != ~s",
              [ReplaceTypeFile, ReplaceType]),
    {Replace, trie:new()};
replace_new_index_data(_, _, Replace) ->
    ?LOG_ERROR("Malformed replace index file!", []),
    {Replace, trie:new()}.

replace_new_index_load(ReplaceIndex, Replace) ->
    replace_new_index_load(ReplaceIndex,
                           trie:new(), undefined, Replace).

replace_new_index_load([], ReplaceHit, ReplaceIndexStatus, Replace) ->
    replace_new_index_loaded(ReplaceHit, ReplaceIndexStatus, Replace);
replace_new_index_load([ReplaceIndexValue | ReplaceIndex],
                       ReplaceHit, ReplaceIndexStatus, Replace) ->
    ReplaceIndexStatusNew = replace_new_index_load_status(ReplaceIndexValue,
                                                          ReplaceIndexStatus,
                                                          Replace),
    ReplaceHitNew = replace_new_index_load_value(ReplaceIndexValue,
                                                 ReplaceHit),
    replace_new_index_load(ReplaceIndex,
                           ReplaceHitNew, ReplaceIndexStatusNew, Replace).

replace_new_index_load_status({_, TimeNativeOld}, ReplaceIndexStatus,
                              #lru{}) ->
    if
        ReplaceIndexStatus =:= undefined ->
            TimeNativeOld;
        is_integer(ReplaceIndexStatus) ->
            erlang:max(ReplaceIndexStatus, TimeNativeOld)
    end;
replace_new_index_load_status(_, undefined, _) ->
    undefined.

replace_new_index_load_value({FileName, Value}, ReplaceHit) ->
    trie:store(FileName, Value, ReplaceHit).

replace_new_index_loaded(ReplaceHit, undefined, Replace) ->
    {Replace, ReplaceHit};
replace_new_index_loaded(ReplaceHit, TimeNativeOldMax,
                         #lru{start = Start} = Replace) ->
    TimeNativeOffset = TimeNativeOldMax - Start,
    StartNew = Start - TimeNativeOffset,
    ReplaceHitNew = trie:map(fun(_, TimeNativeOld) ->
        TimeNativeOld - TimeNativeOffset
    end, ReplaceHit),
    {Replace#lru{start = StartNew}, ReplaceHitNew}.

replace_persist(_, undefined, _, _, _) ->
    ok;
replace_persist(_, _, false, _, _) ->
    ok;
replace_persist(ReplaceHit,
                #lfuda{age = Age} = Replace, true,
                ProcessIndex, Directory) ->
    ReplaceIndex = trie:foldr(fun(FileName,
                                           {PriorityKey, HitsOld}, L) ->
        [{FileName, {PriorityKey - Age, HitsOld}} | L]
    end, [], ReplaceHit),
    replace_persist_index_data({replace_type(Replace), ReplaceIndex},
                               ProcessIndex, Directory);
replace_persist(ReplaceHit, Replace, true,
                ProcessIndex, Directory) ->
    ReplaceIndex = trie:to_list(ReplaceHit),
    replace_persist_index_data({replace_type(Replace), ReplaceIndex},
                               ProcessIndex, Directory).

replace_persist_index_data(IndexData, ProcessIndex, Directory) ->
    IndexPath = filename:join(Directory, replace_index_filename(ProcessIndex)),
    IndexPathTmp = IndexPath ++ "_tmp",
    IndexDataBin = unicode:characters_to_binary(io_lib:format("~tp.~n",
                                                              [IndexData])),
    Result = case file:write_file(IndexPathTmp, IndexDataBin, [raw]) of
        ok ->
            file:rename(IndexPathTmp, IndexPath);
        {error, _} = Error ->
            Error
    end,
    case Result of
        ok ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR("Failed to write replace index file ~s: ~p",
                       [IndexPath, Reason]),
            ok
    end.

replace_add(_, _, undefined, ReplaceHit) ->
    ReplaceHit;
replace_add(FileName, _,
            #lfuda{age = Age}, ReplaceHit) ->
    trie:update(FileName, fun(Value) ->
        Value
    end, {Age, 0}, ReplaceHit);
replace_add(FileName, TimeNative,
            #lru{}, ReplaceHit) ->
    trie:update(FileName, fun(Value) ->
        Value
    end, TimeNative, ReplaceHit).

replace_remove(_, undefined = Replace, ReplaceHit) ->
    {Replace,
     ReplaceHit};
replace_remove(FileName,
               #lfuda{age = Age} = Replace, ReplaceHit) ->
    case trie:take(FileName, ReplaceHit) of
        {{PriorityKey, _}, ReplaceHitNew} ->
            ReplaceNew = if
                Age < PriorityKey ->
                    Replace#lfuda{age = PriorityKey};
                true ->
                    Replace
            end,
            {ReplaceNew,
             ReplaceHitNew};
        error ->
            {Replace, ReplaceHit}
    end;
replace_remove(FileName,
               #lru{} = Replace, ReplaceHit) ->
    {Replace,
     trie:erase(FileName, ReplaceHit)}.

replace_hit(_, _,
            #state{replace = undefined} = State) ->
    State;
replace_hit(#file{size = ContentsSize,
                  path = FilePath}, TimeNativeOld,
            #state{directory_length = DirectoryLength,
                   replace = Replace,
                   replace_hit = ReplaceHit} = State) ->
    FileName = lists:nthtail(DirectoryLength, FilePath),
    State#state{replace_hit = replace_hit_update(FileName, ContentsSize,
                                                 TimeNativeOld,
                                                 Replace, ReplaceHit)}.

replace_hit_update(_, _, _,
                   undefined, ReplaceHit) ->
    ReplaceHit;
replace_hit_update(FileName, ContentsSize, _,
                   #lfuda{policy = Policy,
                          age = Age}, ReplaceHit) ->
    trie:update(FileName, fun({_, HitsOld}) ->
        Hits = HitsOld + 1,
        PriorityKey = if
            Policy =:= lfuda ->
                % Ki = Ci * Fi + L with Ci set to 1
                Hits + Age;
            Policy =:= gdsf ->
                % Ki = Fi * Ci / Si + L with Ci set to 1
                % (Si is in KiB because files_size is in KiB)
                Hits div kibibytes_consumed(ContentsSize) + Age
        end,
        % first tuple element is used as the sorting key in descending order
        % (when the cached data is refreshed from the filesystem)
        {PriorityKey, Hits}
    end, {Age, 1}, ReplaceHit);
replace_hit_update(FileName, _, TimeNativeOld,
                   #lru{}, ReplaceHit) ->
    TimeNative = if
        TimeNativeOld =:= undefined ->
            cloudi_timestamp:native_monotonic();
        is_integer(TimeNativeOld) ->
            TimeNativeOld
    end,
    trie:store(FileName, TimeNative, ReplaceHit).

replace_fold(_, undefined, ReadL, Directory,
             _, UpdateF, A) ->
    if
        ReadL == [] ->
            fold_files(Directory, UpdateF, A);
        true ->
            fold_files_exact(ReadL, Directory, UpdateF, A)
    end;
replace_fold(ReplaceHit, Replace, ReadL, Directory,
             RemoveF, UpdateF, A) ->
    PriorityKeyDefault = case Replace of
        #lfuda{age = Age} ->
            Age;
        #lru{start = Start} ->
            Start
    end,
    ReplaceRemove0 = ReplaceHit,
    ReplaceList0 = [],
    ReplaceF = fun(FilePath, FileName, FileInfo, SegmentI, SegmentSize,
                   {ReplaceRemove1, ReplaceList1}) ->
        {PriorityKey,
         ReplaceRemove3} = case trie:take(FileName, ReplaceRemove1) of
            {ReplaceValue, ReplaceRemove2} ->
                PriorityKeyValue = if
                    is_tuple(ReplaceValue) ->
                        element(1, ReplaceValue);
                    is_integer(ReplaceValue) ->
                        ReplaceValue
                end,
                {PriorityKeyValue,
                 ReplaceRemove2};
            error ->
                {PriorityKeyDefault,
                 ReplaceRemove1}
        end,
        ReplaceFile = {PriorityKey,
                       FilePath, FileName, FileInfo, SegmentI, SegmentSize},
        {ReplaceRemove3,
         replace_fold_sort(ReplaceList1, ReplaceFile)}
    end,
    ReplaceA = {ReplaceRemove0, ReplaceList0},
    {ReplaceRemoveN,
     ReplaceListN} = if
        ReadL == [] ->
            fold_files(Directory, ReplaceF, ReplaceA);
        true ->
            fold_files_exact(ReadL, Directory, ReplaceF, ReplaceA)
    end,
    UpdateA = trie:fold(RemoveF, A, ReplaceRemoveN),
    replace_fold_list(ReplaceListN, UpdateF, UpdateA).

replace_fold_sort([], ReplaceFileAdd) ->
    [ReplaceFileAdd];
replace_fold_sort([{PriorityKey, _, _,
                    #file_info{size = Size}, _, _} = ReplaceFile | ReplaceList],
                  {PriorityKeyAdd, _, _,
                   #file_info{size = SizeAdd}, _, _} = ReplaceFileAdd)
    when (PriorityKeyAdd < PriorityKey) orelse
         ((PriorityKeyAdd == PriorityKey) andalso (SizeAdd > Size)) ->
    % PriorityKey descending, Size ascending order
    [ReplaceFile | replace_fold_sort(ReplaceList, ReplaceFileAdd)];
replace_fold_sort(ReplaceList, ReplaceFileAdd) ->
    [ReplaceFileAdd | ReplaceList].

replace_fold_list([], _, A) ->
    A;
replace_fold_list([{_, FilePath, FileName, FileInfo, SegmentI, SegmentSize} |
                   ReplaceList], F, A) ->
    replace_fold_list(ReplaceList, F,
                      F(FilePath, FileName, FileInfo,
                        SegmentI, SegmentSize, A)).

datetime_utc(TimeNative) ->
    cloudi_timestamp:datetime_utc(TimeNative + erlang:time_offset()).

kibibytes_consumed(Bytes)
    when Bytes > 1024 ->
    RoundUp = if
        Bytes rem 1024 == 0 ->
            0;
        true ->
            1
    end,
    Bytes div 1024 + RoundUp;
kibibytes_consumed(_) ->
    1.

rfc1123_format_day(1) ->
    "Mon";
rfc1123_format_day(2) ->
    "Tue";
rfc1123_format_day(3) ->
    "Wed";
rfc1123_format_day(4) ->
    "Thu";
rfc1123_format_day(5) ->
    "Fri";
rfc1123_format_day(6) ->
    "Sat";
rfc1123_format_day(7) ->
    "Sun".

rfc1123_format_month(1) ->
    "Jan";
rfc1123_format_month(2) ->
    "Feb";
rfc1123_format_month(3) ->
    "Mar";
rfc1123_format_month(4) ->
    "Apr";
rfc1123_format_month(5) ->
    "May";
rfc1123_format_month(6) ->
    "Jun";
rfc1123_format_month(7) ->
    "Jul";
rfc1123_format_month(8) ->
    "Aug";
rfc1123_format_month(9) ->
    "Sep";
rfc1123_format_month(10) ->
    "Oct";
rfc1123_format_month(11) ->
    "Nov";
rfc1123_format_month(12) ->
    "Dec".

rfc1123_format({{Year, Month, Day}, {Hour, Minute, Second}}) ->
    % e.g., Sun, 06 Nov 1994 08:49:37 GMT
    %       Mon, 29 Apr 2013 21:44:55 GMT
    DayStr = rfc1123_format_day(calendar:day_of_the_week(Year, Month, Day)),
    MonthStr = rfc1123_format_month(Month),
    Output = io_lib:format("~s, ~2..0w ~s ~4..0w ~2..0w:~2..0w:~2..0w GMT",
                           [DayStr, Day, MonthStr, Year, Hour, Minute, Second]),
    erlang:iolist_to_binary(Output).

