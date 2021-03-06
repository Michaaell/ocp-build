(**************************************************************************)
(*                                                                        *)
(*                              OCamlPro TypeRex                          *)
(*                                                                        *)
(*   Copyright OCamlPro 2011-2016. All rights reserved.                   *)
(*   This file is distributed under the terms of the GPL v3.0             *)
(*      (GNU Public Licence version 3.0).                                 *)
(*                                                                        *)
(*     Contact: <typerex@ocamlpro.com> (http://www.ocamlpro.com/)         *)
(*                                                                        *)
(*  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,       *)
(*  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES       *)
(*  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND              *)
(*  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS   *)
(*  BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN    *)
(*  ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN     *)
(*  CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE      *)
(*  SOFTWARE.                                                             *)
(**************************************************************************)


(* TODO: we should save the version of ocaml used to build a project,
   so that we can detect changes and ask for a clean before building.
   Can we access the magic used by every compiler ? (we can compile an
   empty file in bytecode and native code) We could cache this
   information using the uniq identifier of the executable (would not
   work with wrappers).
*)

(* TODO
   We could force packages with missing dependencies to still be compiaboutled,
   since it is still possible that these missing dependencies arbue not used
   in a particular compilation scheme.
*)

open StringCompat

open SimpleConfig

open BuildOCamlConfig.TYPES
open BuildEngineTypes
open BuildOCPTypes

open BuildTypes
open BuildGlobals
open BuildOptions
open BuildArgs
open BuildTerm
open BuildActions
open BuildValue.Types

let max_stage = ref 20

type target =
  | TargetPackage of package_info

let build_max = ref false

let arg_ocp_dirs = ref []
let load_installed_ocp = ref true

let make_build_targets = ref false
let make_doc_targets = ref false
let make_test_targets = ref false

let _ = DebugVerbosity.add_submodules "B" [ "BuildMain" ]

let print_installed install_where =
  let open BuildUninstall in
  Printf.printf "Installed packages:\n";
  List.iter (fun un ->
    Printf.printf "\t%s . %s (%s)\n%!"
      un.un_name un.un_version un.un_type;
    Printf.printf "\t\tin %s\n%!" un.un_directory;
  ) (BuildUninstall.list_installed install_where);
  ()

let move_to_project = ref true

let finally_do = ref []
let add_finally action =
  finally_do := action :: !finally_do

let do_load_project_files cin project_dir state =
  let open ProjectOptions in

  let force_scan = ref cin.cin_autoscan in

  (* if we didn't find any .ocp files before, we should retry ! *)
  if !!root_files = [] then force_scan := true;

  if ! add_external_projects_arg <> [] then begin
    List.iter (fun dir ->
      if not (List.mem dir !!project_external_dirs_option) then begin
        must_save_project ();
        project_external_dirs_option =:= !!project_external_dirs_option @
            [ dir ];
        force_scan := true;
      end
    ) (List.rev !add_external_projects_arg)
  end;

  if !!project_ocpbuild_version != BuildVersion.version then begin
    must_save_project ();
    project_ocpbuild_version =:= BuildVersion.version;
  end;

  let nerrors =
    if !oasis_arg then
      BuildOasis.load_project state "_oasis"
    else
      begin
      if !force_scan then begin
        save_project := true;
        time_step "Scanning project for .ocp files ...";
        root_files =:= [];
        List.iter (fun dir ->
          let files = BuildOCP.scan_root dir in
          root_files =:= !!root_files @ files
        ) (project_dir ::
            (List.map File.of_string !!project_external_dirs_option));
        time_step "   Done scanning project for .ocp files";
      end;

      if !!root_files = [] then begin
        Printf.eprintf "Error: no known .ocp files\n";
        Printf.eprintf "\tHave you run ocp-build with -scan to find them ?\n%!";
        BuildMisc.clean_exit 2
      end;

      time_step "Loading project .ocp files...";
      let nerrors =
        let config = BuildOCP.empty_config () in
        BuildOCP.load_ocp_files config state !!root_files
      in
      time_step "   Done loading project .ocp files";
      nerrors
      end
  in
  if nerrors > 0 then BuildMisc.clean_exit 2


let do_print_project_info pj =

  BuildOCP.print_conflicts pj !print_conflicts_arg;
  let string_of_package pj =
    Printf.sprintf "   %s (%s,%s)\n     in %s\n"
      pj.package_name
      (BuildOCPTree.string_of_package_type pj.package_type)
      pj.package_source_kind
      pj.package_dirname
  in
  let print_package pj =
    Printf.eprintf "%s\tdeps:" (string_of_package pj);
    List.iter (fun s ->
      Printf.eprintf " %s" s;
    ) (BuildValue.get_strings_with_default [pj.package_options] "requires" []);
    Printf.eprintf "\n%!";
  in
  if verbose 5 || !list_projects_arg then begin

    let print_package_array array =
      let list = ref [] in
      Array.iter (fun pj ->
        list := string_of_package pj :: !list) array;
      List.iter (fun s ->
        Printf.printf "%s%!" s)
        (List.sort compare !list)
    in

    Printf.eprintf "Validated packages:\n";
    print_package_array pj.project_sorted;

    Printf.eprintf "Disabled packages:\n";
    print_package_array pj.project_disabled;

  end;

  begin
    let incomplete_packages = Hashtbl.create  13 in
    if pj.project_incomplete <> [||] then begin
      Printf.eprintf "Warning: %d incomplete packages (will not be built):\n"
        (Array.length pj.project_incomplete);
      let meta_need = ref 0 in
      Array.iter (fun pk ->
        Hashtbl.add incomplete_packages pk.package_name pk;
        if !meta_verbose_arg ||
           pk.package_source_kind <> "meta" then (* TODO ? *)
          print_package pk
        else
          incr meta_need
      )
        pj.project_incomplete;
      if !meta_need > 0 then
        Printf.eprintf
          "  Hidden: %d incomplete packages in META files (use -print-incomplete-meta).\n%!" !meta_need
    end;

    if pj.project_missing <> [] then
      let absent_packages = ref [] in
      let other_packages = ref [] in
      List.iter (fun (name, list) ->
        let non_meta_need = ref false in
        if !meta_verbose_arg then
          non_meta_need := true
        else
          List.iter (fun pk ->
            if pk.package_source_kind <> "meta" then non_meta_need := true
          ) list;
        if !non_meta_need then begin
          let packages =
            if Hashtbl.mem incomplete_packages name then
              other_packages else absent_packages in
          packages := (name, list) :: !packages
        end;
      ) pj.project_missing;
      if !absent_packages <> [] then begin
        Printf.eprintf "Warning: %d needed packages are missing !\n%!"
          (List.length !absent_packages);
        List.iter (fun (name, list) ->
          Printf.eprintf "   ABSENT package %S missed by %d packages\n"
            name (List.length list);
          List.iter print_package list;
        ) !absent_packages
      end;
      List.iter (fun (name, list) ->
        Printf.eprintf "   Incomplete package %S missed by %d packages\n"
          name
          (List.length list);
        List.iter print_package list;
      ) !other_packages

  end

(* TODO: we should return two lists:
  * the list of targets that can be built
  * the list of targets that cannot be built
 *)

let do_print_fancy_project_info pj =
  BuildOCP.print_conflicts pj !print_conflicts_arg;

  let cantbuild = [] in
  let missing =
    List.filter
      (fun (_name, pkgs) ->
        List.exists (fun pk -> pk.package_source_kind <> "meta") pkgs)
      pj.project_missing
  in
  (* don't complain if there is no problem with the selected targets *)
  if
    !build_max ||
      (!targets_arg <> []
       && List.for_all
         (fun (name,_) -> not (List.mem name !targets_arg)) missing
       && List.for_all
         (fun pk -> not (List.mem pk.package_name !targets_arg))
         (Array.to_list pj.project_incomplete))
  then []
  else
    let missing_roots =
    (* remove all missing pkgs that depend on another to get the missing roots *)
      List.filter
        (fun (name,pkgs) ->
          not
            (List.exists
               (fun (_,pks) ->
                 List.exists (fun pk -> name = pk.package_name) pks)
               missing))
        missing
    in
    let cantbuild =
      if missing = [] then cantbuild
      else if missing_roots = [] then begin (* no roots ! *)
        let rec find_cycle acc = function
          | [] -> None
          | name :: _ when List.mem name acc -> Some acc
          | name :: r ->
            let provides =
              List.map (fun pk -> pk.package_name)
                (try List.assoc name missing with Not_found -> [])
            in
            match find_cycle (name::acc) provides with
            | Some _ as r -> r
            | None -> find_cycle acc r
        in
        let cycle = List.map fst missing in
        let cycle =
          match find_cycle [] cycle with
          | Some l -> l
          | None -> assert false
        in
      (*TODO: these are only errors if the corresponding packages have
        been specified as targets. *)
        Printf.eprintf
          "%sERROR%s: circular dependency between:\n"
          term.esc_red_text term.esc_end;
        List.iter
          (fun (n1,n2) -> Printf.eprintf "  - %s%s%s depends on %s\n"
            term.esc_bold n1 term.esc_end n2)
          (List.combine cycle (List.tl cycle @ [List.hd cycle]));
        cycle @ cantbuild
      end else begin
        Printf.eprintf
          "%sERROR%s: the following packages are %smissing%s:\n"
          term.esc_red_text term.esc_end  term.esc_bold term.esc_end;
        List.iter (fun (name,_) ->
          Printf.eprintf "  - %s%s%s\n" term.esc_bold name term.esc_end
        ) missing_roots;
        List.map fst missing_roots @ cantbuild
      end
    in
    let cantbuild =
      if pj.project_incomplete = [||] then cantbuild
      else begin
        let additional =
          List.filter
            (fun pk -> pk.package_source_kind <> "meta"
              && not (List.mem pk.package_name cantbuild))
            (Array.to_list pj.project_incomplete)
        in
        if additional <> [] then
          Printf.eprintf
            "Additional packages %s can't be built.\n"
            (String.concat ", "
               (List.map (fun pk -> Printf.sprintf "%s%s%s"
                 term.esc_bold pk.package_name term.esc_end)
                  additional));
        List.map (fun pk -> pk.package_name) additional @ cantbuild
      end
    in
    cantbuild

let print_build_context = ref false
let do_init_project_building p pj =
  let build_dir_basename = !build_dir_basename_arg in

  let build_dir_filename = (* absolute_filename *) build_dir_basename in

  let build_dir_filename =
    match !arch_arg with
    | Arch host -> Filename.concat build_dir_filename host
    | ArchNone -> build_dir_filename
  in

  BuildMisc.safe_mkdir build_dir_filename;

  time_step "Saving raw project info...";
  BuildOCP.save_project_state pj
    (File.add_basename (File.of_string build_dir_filename) "ocp.ocpx");
  time_step "   Done saving raw project info";

  let b =
    BuildEngineContext.create (File.to_string p.project_dir)
      build_dir_filename in

  begin match p.cout.cout_ocamlbin with
  | None -> ()
  | Some ocamlbin ->
    ignore (BuildEngineContext.add_directory b ocamlbin);
  end;

  let bc = new_builder_context b in
  b.stop_on_error_arg <- !stop_on_error_arg;

  let packages = BuildOCamlRules.create p.cin bc pj in

  if !print_build_context then
    BuildEngineDisplay.eprint_context b;
  (bc, packages)



let chdir_to_project p =
  let dir = File.to_string p.project_dir in
  if MinUnix.getcwd () <> dir then begin
    BuildMisc.chdir dir;
    Printf.fprintf stdout "ocp-build: Entering directory `%s'\n%!"
      (File.to_string p.project_dir);
(* TODO: move at_exit to add_finally *)
    let final_handler_executed = ref false in
    let final_handler () =
      if not !final_handler_executed then begin
        final_handler_executed := true;
        Printf.printf
          "ocp-build: Leaving directory `%s'\n%!"
          (File.to_string p.project_dir)
      end
    in
    add_finally final_handler;
    at_exit final_handler
  end;
  ()


let load_initial_project p state targets =

  do_load_project_files p.cin p.project_dir state;

  (*    end; *)

  (* [ocp-build configure] stops here, so it will not scan
     for .ocp files at this point. Instead, it will be done the
     first time the project is compiled, because [root_files] is
     empty. *)

  if !configure_arg then save_project := true;

  if !save_project then begin
    Printf.fprintf stderr "Updating ocp-build.root\n%!";
    BuildOptions.must_save_project ()
  end;


  if !conf_arg || !distrib_arg || !autogen_arg then BuildMisc.clean_exit 0;

  let use_digests = p.cin.cin_digest in

  if use_digests then BuildMtime.use_digests true;

  time_step "Sorting packages...";
  let pj = BuildOCP.verify_packages state in

  time_step "   Done sorting packages";

  (*
    do_reply_to_queries pj;
  *)

  if !query_global then begin
    Printf.eprintf "Error: reached query-global end point.\n%!";
    BuildMisc.clean_exit 0
  end;

  BuildOptions.maybe_save ();

  if !configure_arg then BuildMisc.clean_exit 0;

  if !clean_arg then begin
    Printf.eprintf "Removing build target directory\n%!";

    BuildActions.delete_file_or_directory !build_dir_basename_arg;
    BuildMisc.clean_exit 0;
  end;

  if verbose 1 && term.esc_ansi then begin
    let cantbuild = do_print_fancy_project_info pj in
    if cantbuild <> [] then begin
      BuildMisc.non_fatal_errors :=
        "Some package dependencies are missing" :: !BuildMisc.non_fatal_errors
    end
  end
  else
    do_print_project_info pj;

  let (bc, packages) = do_init_project_building p pj in

  let package_map =
    let h = ref StringMap.empty in
    Array.iter (fun p ->
      let module P = (val p : Package) in
      h := StringMap.add P.name p !h;
    ) packages;
    !h
  in
  let projects =
    (* build the list of projects considered by the current command *)
    let projects = ref [] in
    match targets with
      [] ->
        StringMap.iter (fun _ pj ->
          projects := pj :: !projects) package_map;
        !projects
    | list ->
      List.iter (fun name ->
        try
          let pj = StringMap.find name package_map in
          projects := pj :: !projects
        with Not_found ->
          Printf.eprintf
            "Error: Could not find target project %s\n%!" name;
          BuildMisc.clean_exit 2
      ) list;
      !projects
  in

  (*
  let packages2 =
    let projects = ref [] in
    StringMap.iter (fun _ pj ->
      projects := pj :: !projects) bc.packages_by_name;
    Array.of_list !projects
  in
  begin
    let packages1 = Array.map (fun p ->
      let module P = (val p : Package) in
      P.name) packages in
    Array.sort compare packages1;
    Printf.eprintf "packages1: %s\n%!"
      (String.concat "," (Array.to_list packages1));

    let packages2 = Array.map (fun p -> p.lib_name) packages2 in
    Array.sort compare packages2;
    Printf.eprintf "packages2: %s\n%!"
      (String.concat "," (Array.to_list packages2));
  end;
  *)
  (bc, projects, package_map)

let rec do_compile stage p ncores  env_state arg_targets =

  let (bc, projects, package_map) = load_initial_project p
      (BuildOCPInterp.copy_state env_state) arg_targets in
  let b = bc.build_context in

  (* build the list of targets *)
  let build_targets = ref [] in
  let map = ref StringMap.empty in
  let rec add_project_targets
      (make_build_targets, make_doc_targets, make_test_targets)
      p =
    let module P = (val p : Package) in
    let lib = P.info in
    if not (StringMap.mem lib.lib_name !map) then begin

        (* prevent second pass *)
        map := StringMap.add lib.lib_name lib !map;

        let add_project_targets pj =
          let p = StringMap.find pj.lib_name package_map in
          add_project_targets (true, false, false) p in
        if make_build_targets then begin
          let { targets; depends } = P.build_targets () in
          build_targets := targets @ !build_targets;
          List.iter add_project_targets depends
        end;
        if make_doc_targets then begin
          let { targets; depends } = P.doc_targets () in
          build_targets := targets @ !build_targets;
          List.iter add_project_targets depends
        end;
        if make_test_targets then begin
          let { targets; depends } = P.test_targets () in
          build_targets := targets @ !build_targets;
          List.iter add_project_targets depends
        end;
    end
  in
  List.iter (add_project_targets
               (!make_build_targets, !make_doc_targets, !make_test_targets)
  ) projects;

  if !build_targets = [] then begin
    Printf.eprintf "Error: project contains no targets\n%!";
    Printf.eprintf "\tAre your .ocp files empty ?\n%!";
    BuildMisc.clean_exit 2
  end;

  (*
        List.iter (fun s ->
        Printf.eprintf "TARGET %S\n%!" (File.to_string s.file_file)
        ) !targets;
      *)



  if !build_targets <> [] then begin
    time_step "Initializing build engine...";
    begin

      try
        BuildEngine.init b !build_targets
      with BuildEngine.MissingSourceWithNoBuildingRule (r, filename) ->
        let (rule_filename, rule_loc, rule_name) = r.rule_loc in
        BuildMisc.print_loc rule_filename rule_loc;
        Printf.eprintf "Error: in project \"%s\", the source filename\n"
          rule_name;
        Printf.eprintf "\t\"%s\" does not exist\n" filename;
        BuildEngineRules.print_rule r;
        BuildMisc.clean_exit 2
    end;
    time_step "   Build Engine Initialized";
    time_step "Checking remaining artefacts...";
    let orphans = BuildEngine.sanitize b !delete_orphans_arg
        (fun basename ->
          match basename with
            "_tests" -> true
          | _ -> false)
    in
    if orphans > 0 then begin
      Printf.eprintf "Error: found %d orphan files in %s. You must remove them.\n" orphans !build_dir_basename_arg;
      Printf.eprintf "\n";
      Printf.eprintf "   You can add the -sanitize argument to automatically remove\n";
      Printf.eprintf "   orphan files\n";
      Printf.eprintf "\n";
      BuildMisc.clean_exit 2;
    end else
    if orphans < 0 then
      Printf.eprintf
        "Warning: deleted %d orphan files in %s\n" (-orphans) !build_dir_basename_arg;
    time_step "   Done sanitizing";

    time_step "Building packages...";
    BuildEngine.parallel_loop b ncores;
    time_step "   Done building packages";

    let errors = BuildEngine.fatal_errors b @
                 BuildEngineDisplay.errors b in
    let t1 = MinUnix.gettimeofday () in

    let nerrors = List.length errors in
    Printf.eprintf
      "%s in %.2fs. %d jobs (parallelism %.1fx), %d files generated.\n%!"
      (if errors = [] then
         if term.esc_ansi then
           Printf.sprintf "%sBuild Successful%s"
             term.esc_green_text term.esc_end
         else "Build Successful"
       else
         Printf.sprintf "%s%d error%s%s" term.esc_red_text
           nerrors
           (if nerrors > 1 then "s" else "")
           term.esc_end)
      (t1 -. t0)
      b.stats_command_executed
      (b.stats_total_time /. (t1 -. t0))
      b.stats_files_generated;
    if errors <> [] (* && not (verbose 1 && term.esc_ansi) *) then begin
      Printf.eprintf "Error log:\n";
      List.iter (fun lines ->
        Printf.eprintf "Error:\n";
        List.iter (fun line ->
          Printf.eprintf "%s\n" line
        ) lines
      ) errors;
    end;
    if errors <> [] then BuildMisc.clean_exit 2
  end;
  Printf.eprintf "%!";
  if b.build_should_restart then
    if stage = !max_stage then begin
      Printf.eprintf "Error: build restarted too many times (%d times). Aborting\n%!" stage;
      BuildMisc.clean_exit 2
    end else begin
      Printf.eprintf "Some configuration files were changed. Restarting build\n%!";
      do_compile (stage+1) p ncores  env_state arg_targets
    end else
    (bc, projects)

let do_read_env p =

  let cin = p.cin in
  let cout = p.cout in

  BuildOCamlConfig.set_global_config cout;

  (* Don't modify default values from now on, since they have been included
     in the default configuration ! *)

  let env_ocp_dirs = ref cin.cin_ocps_dirnames in
  let env_ocp_files = ref [] in
  let state = BuildOCP.init_packages () in
  begin
    match cout.cout_ocamllib with
    None -> ()
    | Some ocamllib ->
      if cin.cin_ocps_in_ocamllib then begin
        env_ocp_dirs := ocamllib :: !env_ocp_dirs;
      end;

      time_step "Scanning env for .ocp files...";
      if !load_installed_ocp then
        List.iter (fun dir ->
          if verbose 3 then
            Printf.eprintf "Scanning installed .ocp files in %S\n%!" dir;
          let dir = File.of_string dir in
          env_ocp_files := ( BuildOCP.scan_root dir) @ !env_ocp_files
        ) !env_ocp_dirs;
        List.iter (fun dir ->
          if verbose 3 then
            Printf.eprintf "Scanning installed .ocp files in %S\n%!" dir;
          let dir = File.of_string dir in
          env_ocp_files := ( BuildOCP.scan_root dir) @ !env_ocp_files
        ) !arg_ocp_dirs;
      time_step "   Done scanning env for .ocp files";
      time_step "Loading METAs...";
      List.iter (fun dirname ->
        BuildOCamlMeta.load_META_files state ocamllib dirname
      ) cout.cout_meta_dirnames;
  end;

  time_step "   Done Loading METAs";

  time_step "Loading .ocp files from env...";

  let _nerrors1 =
    let config = BuildOCP.generated_config () in
    BuildOCP.load_ocp_files config state  !env_ocp_files
  in

  time_step "   Done Loading .ocp files from env";

  state

let get_ncores cin =
  let ncores = cin.cin_njobs in
  if ncores < 1 then
    BuildConfig.number_of_cores () + 1
  else
    ncores


let print_env_arg = ref false
(* Also called from BuildActionTests.action () *)
let do_build p =
  let targets = List.rev !targets_arg in
  time_step "Arguments parsed.";

  let env_state = do_read_env p in
  let env_pj = BuildOCP.verify_packages env_state in
  if !print_env_arg then begin
    BuildOCPPrinter.eprint_project "Environment packages" env_pj;
    exit 0;
  end;
  time_step "Environment read and checked.";
  (* TODO: we could check that all the packages are indeed installed ! *)

  BuildOCamlVariables.packages_option.set
    (VList (Array.to_list (Array.map (fun pk ->
        let dirname = absolute_filename pk.package_dirname in
        List.iter (fun suffix ->
          BuildSubst.add_to_global_subst (pk.package_name ^ suffix) dirname)
          [ "_SRC_DIR"; "_DST_DIR"; "_FULL_SRC_DIR"; "_FULL_DST_DIR" ];
        VPair (VString pk.package_name, VObject pk.package_options)
      ) env_pj.project_sorted)));


  if !query_global then move_to_project := false;


  if !list_installed_arg then begin
    let state =
      let open BuildOCamlInstall in
      let where = install_where p in
      BuildUninstall.init where.install_destdir where.install_libdirs
    in
    print_installed state;
    BuildMisc.clean_exit 0
  end;


  if !uninstall_arg && targets <> [] then begin
    let state =
      let open BuildOCamlInstall in
      let where = install_where p in
      BuildUninstall.init where.install_destdir where.install_libdirs
    in
    List.iter (BuildUninstall.uninstall state) targets;
    BuildUninstall.finish state;
    BuildMisc.clean_exit 0
  end;

  begin match !query_install_dir with
      None -> ()
    | Some package ->
      let state =
        let open BuildOCamlInstall in
        let where = install_where p in
        BuildUninstall.init where.install_destdir where.install_libdirs
      in
      List.iter (fun un ->
        let open BuildUninstall in
        if un.un_name = package then begin
          Printf.printf "%s\n%!" un.un_directory;
          BuildMisc.clean_exit 0
        end
      ) (BuildUninstall.list_installed state);
      Printf.eprintf "Package %S is not installed\n%!" package;
      BuildMisc.clean_exit 2
  end;

  chdir_to_project p;

  do_compile 0 p (get_ncores p.cin) env_state targets


let action () =

(* Nothing specified, make build targets: *)
  if not !make_doc_targets && not !make_test_targets then make_build_targets := true;
(* Test targets require build targets ? *)
  if !make_test_targets then make_build_targets := true;
  if !make_doc_targets then make_build_targets := true;

  let p = BuildActions.load_project () in
  let (_b, _projects) = do_build p in
  ()

let arg_list = [
  (* This option should be shared with -install and -tests, no ? *)
  "-arch", Arg.String (fun s ->
    arch_arg := Arch ("_other_archs/" ^ s)),
  "ARCH Set arch sub-directory of _obuild";

  "-max", Arg.Set build_max, " Build as many packages as possible";

  "-I", Arg.String (fun dir ->
    arg_ocp_dirs := !arg_ocp_dirs @ [ dir ]),
  "DIR Include files from DIR";

  "-max-stage", Arg.Int (fun n -> max_stage := n),
  "NUM Maximal number of times compilation can be restarted";
  "-print-loaded-ocp-files", Arg.Set
    BuildOCP.print_loaded_ocp_files,
  " Print loaded ocp files";
 "-print-loaded-env", Arg.Set
    print_env_arg,
 " Print the loaded environment and exit.";
 "-print-package-deps", Arg.Set
    BuildOCP.print_package_deps,
 " Print package dependencies";
 "-print-missing", Arg.Set
    BuildOCP.print_missing_deps, " Print missing dependencies";
 "-print-conflicts", Arg.Set
    print_conflicts_arg,
 " Print conflicts between package definitions";
   "-no-installed-ocp", Arg.Clear load_installed_ocp,
  " Do not load installed .ocp files";
  "-print-build-context", Arg.Set print_build_context,
  " Print full build context";

  "-doc", Arg.Set make_doc_targets, " Make doc targets";
  "-test", Arg.Set make_test_targets, " Make tests targets";
  "-build", Arg.Set make_build_targets, " Make build targets";

  "-continue-on-ocp-error", Arg.Set BuildOCPInterp.continue_on_ocp_error, " Continue after finding a syntax error in an ocp file";

  "-init", Arg.Unit (fun () ->
    BuildActionInit.action ();
    exit 0),
  " Set the root of a project in the current directory and exit.";

  "-version", Arg.Unit (fun () ->
    Printf.printf "%s\n%!" BuildVersion.version;
    BuildMisc.clean_exit 0
  ),
  " Print version information";

] @ arg_list1

let add_synomyms arg_list1 synonyms =
  arg_list1 @ List.map (fun (s1, s2) ->
    let rec iter list =
      match list with
      [] -> assert false
      | (s, action, help) :: tail when s = s2 -> (s1, action, help)
      | _ :: tail -> iter tail
    in
    iter arg_list1
  ) synonyms

let arg_list = add_synomyms arg_list
    [ "-v", "-verbosity";
      "-j", "-njobs";
    ]

let arg_usage = [ "Build" ]

let subcommand = {
  sub_name = "make";
  sub_help = "Build the project";
  sub_arg_list = arg_list;
  sub_arg_anon = Some arg_anon;
  sub_arg_usage = arg_usage;
  sub_action = action;
}

let old_subcommand =
  {
  sub_name = "build";
  sub_help = "(deprecated, use 'ocp-build make' subcommand)";
  sub_arg_list = arg_list;
  sub_arg_anon = Some arg_anon;
  sub_arg_usage = arg_usage;
  sub_action = action;
}
