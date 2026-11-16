%% The BEAM twin of IO.js: read the sources and talk to a local daemon.
%%
%% YAML is read by yamerl (pure Erlang, fetched and built by beam/build.sh) and
%% converted to the same `Json` js-yaml would give node. beam/conformance.sh
%% holds the two readers to each other over every compose file in fixtures/.
%% A path ending in `.json` is read as JSON, which needs no YAML library.
-module(bosun_cLI_iO@foreign).
-export([readYamlImpl/0, readJsonImpl/0, readJsonUrlImpl/0, getJsonUrlImpl/0, postJsonUrlImpl/0, argv/0]).

run(Line, Ms) -> bosun_cLI_exec@foreign:run(Line, Ms).

%% ${BOSUN_ROOT} expansion, as in IO.js: the portable-fixture seam.
expand(Text) ->
    Root = case os:getenv("BOSUN_ROOT") of
               false -> {ok, Cwd} = file:get_cwd(), Cwd;
               R -> R
           end,
    binary:replace(Text, <<"${BOSUN_ROOT}">>, unicode:characters_to_binary(Root), [global]).

parse(Text) ->
    (data_argonaut_parser@foreign:'_jsonParser'())(
      fun(Problem) -> {error, Problem} end, fun(Json) -> {ok, Json} end, Text).

parse_or_crash(What, Text) ->
    case parse(Text) of
        {ok, Json} -> Json;
        {error, Problem} -> erlang:error({not_json, What, Problem})
    end.

read_json(Path) ->
    case file:read_file(Path) of
        {ok, Text} -> parse_or_crash(Path, expand(Text));
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

readYamlImpl() ->
    fun(Path) ->
        case filename:extension(Path) of
            <<".json">> -> read_json(Path);
            _ -> read_yaml(Path)
        end
    end.

read_yaml(Path) ->
    case code:ensure_loaded(yamerl_constr) of
        {module, _} -> ok;
        _ -> erlang:error({no_yaml_reader, Path,
                           <<"yamerl is not on the code path: run beam/build.sh, or give a .json path">>})
    end,
    {ok, _} = application:ensure_all_started(yamerl),
    case file:read_file(Path) of
        {ok, Text} ->
            %% yamerl 0.10.0 misreads an anchor on a FLOW collection
            %% (`&name {a: 1}` or `&name [1, 2]`): the anchor lands on the
            %% first element, so an alias to it yields that element. Nothing
            %% in the parsed tree shows it happened. A loud refusal beats a
            %% silent misreading; an anchor on a block collection is fine.
            case re:run(Text, "&[A-Za-z0-9_-]+[ \t]*[\[{]", [{capture, none}]) of
                match -> erlang:error({yaml_anchor_on_a_flow_collection, Path,
                                       <<"yamerl misreads these: write the collection in block style">>});
                nomatch -> ok
            end,
            %% detailed_constr: every node is tagged, so an empty sequence and
            %% an empty mapping, or a string and a list, cannot be confused.
            case yamerl_constr:string(expand(Text), [{detailed_constr, true}, {str_node_as_binary, true}]) of
                [] -> null;
                [{yamerl_doc, Root} | _] -> from_yaml(Root)
            end;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

%% A yamerl node -> a `Json` (see Data.Argonaut.Core for the representation).
%% Mappings keep document order, as js-yaml's objects do.
%%
%% The merge key `<<` is YAML 1.1; js-yaml applies it and yamerl does not, so
%% it is applied here, js-yaml's way: a merged key lands where the `<<` stood
%% unless the mapping already has it, and a key written out in the mapping
%% itself always wins.
from_yaml({yamerl_map, _, _, _, Pairs}) ->
    Explicit = [yaml_key(K) || {K, _} <- Pairs],
    lists:foldl(
      fun({K, V}, Acc) ->
          case {yaml_key(K), from_yaml(V)} of
              {<<"<<">>, Source} -> merge(sources(Source), Explicit, Acc);
              {Key, Value} -> foreign_object@foreign:put(Key, Value, Acc)
          end
      end, [], Pairs);
from_yaml({yamerl_seq, _, _, _, Items, _}) -> array:from_list([from_yaml(I) || I <- Items]);
from_yaml({yamerl_str, _, _, _, Text}) -> Text;
from_yaml({yamerl_int, _, _, _, N}) -> float(N);
from_yaml({yamerl_float, _, _, _, N}) when is_float(N) -> N;
from_yaml({yamerl_bool, _, _, _, B}) -> B;
from_yaml({yamerl_null, _, _, _}) -> null;
from_yaml(Other) -> erlang:error({yaml_node_with_no_json_form, Other}).

%% `<<: *one` or `<<: [*one, *two]`; earlier sources win over later ones.
sources(Source) when is_list(Source) -> [Source];
sources(Source) when is_tuple(Source) ->
    Items = array:to_list(Source),
    case lists:all(fun is_list/1, Items) of
        true -> Items;
        false -> erlang:error({yaml_merge_needs_mappings, Source})
    end;
sources(Source) -> erlang:error({yaml_merge_needs_mappings, Source}).

merge(Sources, Explicit, Acc0) ->
    lists:foldl(
      fun(Source, Acc1) ->
          lists:foldl(
            fun({K, V}, Acc) ->
                case lists:member(K, Explicit) orelse lists:keymember(K, 1, Acc) of
                    true -> Acc;
                    false -> foreign_object@foreign:put(K, V, Acc)
                end
            end, Acc1, Source)
      end, Acc0, Sources).

%% A key that is not a string is written the way JavaScript would name the
%% property: 3082 -> "3082", true -> "true".
yaml_key({yamerl_str, _, _, _, Text}) -> Text;
yaml_key(Node) ->
    case from_yaml(Node) of
        null -> <<"null">>;
        true -> <<"true">>;
        false -> <<"false">>;
        N when is_float(N) -> data_argonaut_core@foreign:stringify(N);
        Other -> erlang:error({yaml_key_with_no_string_form, Other})
    end.

readJsonImpl() -> fun(Path) -> read_json(Path) end.

readJsonUrlImpl() ->
    fun(Url) ->
        case run(<<"curl -sS -f --max-time 10 ", Url/binary>>, 15000) of
            {0, Out, _} -> parse_or_crash(Url, Out);
            {Code, _, Err} -> erlang:error({cannot_fetch, Url, Code, Err})
        end
    end.

%% A talk-to-a-local-daemon result that does not throw: {ok, body, error}.
json_curl(Args) ->
    fun(Url) ->
        case run(<<"curl -sS --max-time 8 ", Args/binary, " ", Url/binary>>, 12000) of
            {0, Out, _} ->
                case string:trim(Out) of
                    <<>> -> #{ok => true, body => null, error => <<>>};
                    Body ->
                        case parse(Body) of
                            {ok, Json} -> #{ok => true, body => Json, error => <<>>};
                            {error, Problem} -> #{ok => false, body => null, error => Problem}
                        end
                end;
            {_, _, Err} -> #{ok => false, body => null, error => string:trim(Err)}
        end
    end.

getJsonUrlImpl() -> json_curl(<<>>).
postJsonUrlImpl() -> json_curl(<<"-X POST">>).

%% The arguments after `-extra` on the erl command line.
argv() ->
    fun() -> array:from_list([unicode:characters_to_binary(A) || A <- init:get_plain_arguments()]) end.
