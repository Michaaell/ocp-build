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


open StringCompat
open BuildTypes
open BuildOCPTypes

open BuildEngineContext
open BuildEngineRules
open BuildEngineTypes


let verbose = DebugVerbosity.verbose ["B"] "BuildGlobals"

(* Under Windows, we cannot use dot-prefixed directories *)
let homedir = try Sys.getenv "HOME" with Not_found -> "."

let time_arg = ref false
(*
let byte_arg = ref false
let asm_arg = ref false
*)
let clean_arg = ref false

let distclean_arg = ref false
let fake_arg = ref false
let save_config_arg = ref false

let stop_on_error_arg = ref true
let verbosity_arg = ref (None : int option)
let targets_arg = ref ([]: string list)
let distrib_arg = ref false
let conf_arg = ref false
let global_arg = ref false
let no_global_arg = ref false
let autogen_arg = ref false
let list_ocp_files = ref false

let new_builder_context b = {
  build_context = b;
  packages_by_name = StringMap.empty;
  all_projects = Hashtbl.create 113;
  config_filename_validated_table = Hashtbl.create 113;
  uniq_rules = Hashtbl.create 113;
}

let config_filename_validated bc lib_loc (filename, digest_o) =
  try
    Hashtbl.find bc.config_filename_validated_table filename
  with Not_found ->
    let b = bc.build_context in
    let basename = Filename.basename filename in
    let dirname = Filename.dirname filename in
    let dir = add_directory b dirname in
    let file = add_file b dir basename in
    let file_checked = add_virtual_file b dir (basename ^ " checked") in
    let file_validated = add_virtual_file b dir (basename ^ " validated") in
    let r_checker = new_rule b lib_loc file_checked [] in
    let r_validator = new_rule b lib_loc file_validated [] in
    add_rule_source r_checker file;
    add_rule_source r_validator file_checked;

    Hashtbl.add bc.config_filename_validated_table filename file_validated;
    let function_name = Printf.sprintf "check %S/%s" filename
        (match digest_o with
           None -> "" | Some digest -> OcpDigest.to_hex digest) in
    add_rule_command r_checker (BuildEngineTypes.Function (function_name, (fun b -> Buffer.add_string b function_name),
        (function () ->
          let digest2_o = try
            let content = File.string_of_file filename in
            Some (Digest.string content)
          with _ -> None
          in
          if digest2_o <> digest_o then begin
            r_validator.rule_missing_sources <- r_validator.rule_missing_sources + 1;
            b.build_should_restart <- true;
            Printf.eprintf "NEED REBOOT\n%!";
          end else begin
(*            Printf.eprintf "%s checked and validated\n%!" filename *)
          end
        )));

    file_validated

let new_library bc pk package_dirname src_dir dst_dir mut_dir =
  let b = bc.build_context in
  let envs = [ pk.package_options ] in

  let lib_name = pk.package_name in
  let lib_loc = (pk.package_filename, pk.package_loc, pk.package_name) in
  let lib_installed = BuildValue.is_already_installed envs in
  let lib_install =
    not lib_installed &&
    (match pk.package_type with
        TestPackage -> false
      | ProgramPackage
      | LibraryPackage
      | ObjectsPackage
      | RulesPackage
      | SyntaxPackage -> true
    ) &&
    BuildValue.get_bool_with_default [pk.package_options] "install" true in


  let lib_ready =
    if lib_installed then [] else
      let file_ready = add_virtual_file b dst_dir (lib_name ^ " validated") in
      let r = new_rule b lib_loc file_ready [] in
      List.iter (fun filename ->
        add_rule_source r (config_filename_validated bc lib_loc filename)
      ) pk.package_filenames;
      [file_ready]
  in


  let lib =
    {
      lib_builder_context = bc;
      lib_context = b;
      lib_id = pk.package_id;
      lib_name = pk.package_name;
      lib_installed;
      lib_install;
      lib_ready;
      lib_loc;
      lib_options = pk.package_options;
      lib_source_kind = pk.package_source_kind;

      lib_meta = BuildValue.get_bool_with_default [pk.package_options] "meta" false;
      lib_version = pk.package_version;
      lib_dirname = File.of_string package_dirname;
      lib_provides = pk.package_provides ;
      lib_type = pk.package_type ;
      lib_tag = "";
      lib_filename = pk.package_filename;
      lib_node = pk.pi.package_node;
      lib_requires = List.map (fun dep ->
        let pd = try
                 (* Printf.eprintf "Adding dep %d to %S (link = %b)\n%!"
             dep.dep_project.package_id pk.package_name dep.dep_link; *)
                   Hashtbl.find bc.all_projects dep.dep_project.package_id
          with Not_found ->
            Printf.eprintf "Unknown dependency %d (%s) of package %S\n%!"
              dep.dep_project.package_id
              dep.dep_project.package_name
              pk.package_name;
            BuildMisc.clean_exit 2
        in
        { dep with dep_project = pd }
      ) pk.pi.package_requires;
      lib_added = pk.pi.package_added;

      lib_src_dir = src_dir;
      lib_dst_dir = dst_dir;
      lib_mut_dir = mut_dir;
      lib_bundles = [];
    } in

  Hashtbl.add bc.all_projects lib.lib_id lib;
  bc.packages_by_name <- StringMap.add lib.lib_name lib bc.packages_by_name;
  if verbose 5 then begin
    Printf.eprintf "BuildGlobals.new_library %S\n" lib.lib_name;
    Printf.eprintf "  lib_install = %b\n%!" lib.lib_install;
  end;
  lib

let absolute_filename dirname =
  if Filename.is_relative dirname then
    Filename.concat (BuildMisc.getcwd ()) dirname
  else dirname
