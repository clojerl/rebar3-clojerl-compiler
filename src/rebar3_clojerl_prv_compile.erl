-module(rebar3_clojerl_prv_compile).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, compile).
-define(NAMESPACE, clojerl).
-define(DEPS, [{default, app_discovery}, {default, compile}]).
-define(DEFAULT_SRC_DIRS, ["src"]).

-define(CLOJERL, <<"clojerl">>).

%% =============================================================================
%% Public API
%% =============================================================================

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
  Provider = providers:create([ {namespace,  ?NAMESPACE}
                              , {name,       ?PROVIDER}
                              , {module,     ?MODULE}
                              , {bare,       true}
                              , {deps,       ?DEPS}
                              , {example,    "rebar3 clojerl compile"}
                              , {opts,       []}
                              , {short_desc, "Compile clojerl project"}
                              , {desc,       "Compile clojerl project"}
                              ]),
  {ok, rebar_state:add_provider(State, Provider)}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
  ok     = ensure_clojerl(State),
  Apps   = lists:filter(is_not_dep_name_fun(?CLOJERL), all_apps(State)),
  Config = [{protocols_out_dir, protocols_out_dir(State)}],
  [compile(AppInfo, Config) || AppInfo <- Apps],
  {ok, State}.

-spec format_error(any()) -> iolist().
format_error(Reason) ->
  io_lib:format("~p", [Reason]).

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec all_apps(rebar_state:t()) -> [rebar_app_info:t()].
all_apps(State) ->
  lists:usort(rebar_state:all_deps(State)) ++ rebar_state:project_apps(State).

-spec protocols_out_dir(rebar_state:t()) -> file:name().
protocols_out_dir(State) ->
  %% Get the first application from this project.
  [AppInfo | _] = rebar_state:project_apps(State),
  ProtoDir      = rebar_app_info:ebin_dir(AppInfo),
  rebar_api:debug("Protocols dir: ~s", [ProtoDir]),
  list_to_binary(ProtoDir).

-spec ensure_clojerl(rebar_state:t()) -> ok.
ensure_clojerl(State) ->
  case find_dep(State, ?CLOJERL) of
    notfound ->
      rebar_api:abort("Clojerl was not found as a dependency", []);
    {ok, DepInfo} ->
      EbinDir  = rebar_app_info:ebin_dir(DepInfo),
      rebar_api:debug("Add Clojerl path: ~s", [EbinDir]),
      true     = code:add_pathz(EbinDir),
      ok       = clojerl:start()
  end.

-spec find_dep(rebar_state:t(), binary()) -> notfound | {ok, any()}.
find_dep(State, Name) ->
  Deps  = rebar_state:all_deps(State),
  case lists:filter(is_dep_name_fun(Name), Deps) of
    [] -> notfound;
    [DepInfo] -> {ok, DepInfo}
  end.

-spec is_dep_name_fun(binary()) -> boolean().
is_dep_name_fun(Name) ->
  fun(Dep) -> Name =:= rebar_app_info:name(Dep) end.

-spec is_not_dep_name_fun(binary()) -> boolean().
is_not_dep_name_fun(Name) ->
  IsDepName = is_dep_name_fun(Name),
  fun(Dep) -> not IsDepName(Dep) end.

-spec compile(rebar_app_info:t(), [any()]) -> ok.
compile(AppInfo, Config0) ->
  rebar_api:info("Clojerl Compiling ~s", [rebar_app_info:name(AppInfo)]),
  BaseDir      = rebar_app_info:out_dir(AppInfo),
  EbinDir      = rebar_app_info:ebin_dir(AppInfo),
  RebarOpts    = rebar_app_info:opts(AppInfo),
  CljeSrcDirs  = rebar_opts:get(RebarOpts, clje_src_dirs, ?DEFAULT_SRC_DIRS),

  rebar_api:debug("Add path: ~s", [EbinDir]),
  %% TODO: ensure dir
  ok           = code:add_pathsa([EbinDir]),

  Config1      = [{out_dir, list_to_binary(EbinDir)} | Config0],

  [compile_dir(BaseDir, SrcDir, EbinDir, Config1) || SrcDir <- CljeSrcDirs],

  ok.

-spec compile_dir(file:name(), string(), file:name(), [any()]) -> ok.
compile_dir(BaseDir, Dir, EbinDir, Config) ->
  SrcDir   = filename:join(BaseDir, Dir),
  SrcFiles = find_files(SrcDir),

  rebar_api:debug("Source Dir ~s", [SrcDir]),
  rebar_api:debug("Source Files ~p", [SrcFiles]),
  rebar_api:debug("Ebin Dir ~s", [EbinDir]),

  %% TODO: ensure dir
  true     = code:add_patha(SrcDir),

  [compile_file(Src, SrcDir, EbinDir, Config) || Src <- SrcFiles],
  ok.

-spec compile_file(file:name(), file:name(), file:name(), [any()]) ->
  ok | skipped.
compile_file(Source, SrcDir, EbinDir, Config) ->
  Target = target_file(Source, SrcDir, EbinDir),
  case should_compile(Target, Source) of
    true  -> compile_clje(Source, Config);
    false -> skipped
  end.

-spec compile_clje(file:name(), [any()]) -> ok.
compile_clje(Source, Config) ->
  rebar_api:debug("Compiling ~s...", [Source]),

  EbinDir   = proplists:get_value(out_dir, Config),
  ProtoDir  = proplists:get_value(protocols_out_dir, Config),
  Bindings  = #{ <<"#'clojure.core/*compile-files*">>          => true
               , <<"#'clojure.core/*compile-path*">>           => EbinDir
               , <<"#'clojure.core/*compile-protocols-path*">> => ProtoDir
               },
  try
    ok = 'clojerl.Var':push_bindings(Bindings),
    clj_compiler:compile_file(list_to_binary(Source))
  catch
    _:Reason ->
      Stacktrace = erlang:get_stacktrace(),
      rebar_api:debug( "Stacktrace:~n~s"
                     , [clj_utils:stacktrace(Stacktrace)]
                     ),
      rebar_api:abort( "Error while compiling ~s: ~s"
                     , [Source, clj_rt:str(Reason)]
                     )
  after
    ok = 'clojerl.Var':pop_bindings()
  end.

-spec find_files(file:name()) -> [file:name()].
find_files(Path) ->
  ExtRegex = "clj[ce]",
  rebar_utils:find_files(Path, ExtRegex, true).

-spec target_file(file:name(), file:name(), file:name()) -> file:name().
target_file(Source, SrcDir, OutDir) ->
  Target1   = re:replace(Source, ["^", SrcDir, "/"], "", [global]),
  Target2   = re:replace(Target1, "/", ".", [global, {return, binary}]),
  Target3   = re:replace(Target2, "_", "-", [global, {return, binary}]),
  Target4   = filename:basename(Target3, filename:extension(Source)),
  Target5   = [OutDir, "/", Target4, ".beam"],
  iolist_to_binary(Target5).

-spec should_compile(file:name(), file:name()) -> boolean().
should_compile(Target, Source) ->
  not filelib:is_file(Target)
    orelse filelib:last_modified(Target) < filelib:last_modified(Source).
