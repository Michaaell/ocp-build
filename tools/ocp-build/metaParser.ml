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

open MetaTypes
open MetaLexer

let verbose = DebugVerbosity.verbose ["B"] "MetaParser"

let string_of_token = function
STRING s -> Printf.sprintf "STRING %S" s
  | IDENT  s -> Printf.sprintf "IDENT %S" s
  | LPAREN -> "LPAREN"
| RPAREN -> "RPAREN"
| EQUAL -> "EQUAL"
| PLUSEQUAL -> "PLUSEQUAL"
| MINUS -> "MINUS"
| EOF -> "EOF"

let split_simplify s =
  let bs = Bytes.of_string s in
  for i = 0 to String.length s - 1 do
    match s.[i] with
    | ',' -> bs.[i] <- ' '
    | _ -> ()
  done;
  let s = Bytes.to_string bs in
  OcpString.split_simplify s ' '

let rec tokens_of_file verbose filename =
  try
  let ic = open_in filename in
  let lexbuf = Lexing.from_channel ic in
  let tokens = ref [] in
  let rec iter lexbuf =
    let token = MetaLexer.token lexbuf in
    if verbose then
      Printf.fprintf stderr "[%s]\n%!" (string_of_token token);
    match token with
    | EQUAL
    | STRING  _
    | IDENT  _
    | LPAREN
    | RPAREN
    | MINUS
    | PLUSEQUAL
      ->
      tokens := token :: !tokens;
        iter lexbuf
    | EOF -> ()

  in
  begin try
  iter lexbuf;
    with MetaLexer.Error ->
      let loc = Lexing.lexeme_start lexbuf in
      Printf.fprintf stderr "Syntax error at pos %d\n%!"
        loc;
      if not verbose then
        ignore (tokens_of_file true filename : MetaLexer.token list)
      else
        raise MetaLexer.Error
  end;
  close_in ic;
  List.rev !tokens
  with e ->
    Printf.fprintf stderr "Exception %S while parsing %S\n%!" (Printexc.to_string e) filename;
    raise e

let parse_file filename =
  let tokens = tokens_of_file false filename in

  let rec iter meta path tokens =
    match tokens with
      [] ->
        begin
          match path with
            [] -> meta
          | (name, _) :: _ ->
            failwith (
              Printf.sprintf "missing right parenthesis for package %s" name)
        end
    | IDENT name :: EQUAL :: STRING str :: tokens ->
(*      Printf.fprintf stderr "IDENT[%s]\n%!" name; *)
      begin
        match name with
          "version" -> meta.meta_version <- Some str
        | "description" -> meta.meta_description <- Some str
        | "exists_if" -> meta.meta_exists_if <- split_simplify str
        | "directory" -> meta.meta_directory <- Some str
        | "preprocessor" -> meta.meta_preprocessor <- Some str
        | "name" -> meta.meta_name <- Some str
        | "linkopts" -> meta.meta_linkopts <- Some str

        | "requires" ->
          MetaFile.add_requires meta [] (split_simplify str)
        | "archive" ->
          MetaFile.add_archive meta [] (split_simplify str)
        | _ ->
          if verbose 4 then
            Printf.fprintf stderr "MetaParser.parse_file: discarding %S\n%!"
              name
      end;
      iter meta path tokens

    | IDENT name :: PLUSEQUAL :: STRING str :: tokens ->
      begin
        match name with
          "requires" ->
          MetaFile.add_requires meta [] (split_simplify str)
        | "archive" ->
          MetaFile.add_archive meta [] (split_simplify str)
        | _ ->
          if verbose 4 then
            Printf.fprintf stderr "MetaParser.parse_file: discarding %S\n%!"
              name
      end;
      iter meta path tokens

    | IDENT name :: LPAREN :: tokens ->
(*      Printf.fprintf stderr "IDENT()[%s]\n%!" name; *)
      iter_precond meta path name [] tokens

    | IDENT "package" :: STRING package_name :: LPAREN :: tokens ->
      let new_meta = MetaFile.empty () in
      meta.meta_package <- (package_name, new_meta) :: meta.meta_package;
      iter new_meta ( (package_name,meta) :: path) tokens

    | RPAREN :: tokens ->
      begin
        match path with
        | (_name, old_meta) :: path ->
          iter old_meta path tokens
        | [] -> failwith "Right parenthesis without matching left"
      end

    | _ ->
      print_remaining "iter" tokens

  and print_remaining msg tokens =
    Printf.fprintf stderr "%s: Don't know what to do with:\n%!" msg;
    begin try
            let num = ref 0 in
            List.iter (fun token ->
              if !num = 3 then begin
                Printf.eprintf "   ...\n%!";
                raise Exit
              end;
              Printf.fprintf stderr "  %s\n%!" (string_of_token token);
              incr num;
            ) tokens;
      with Exit -> ()
    end;
    failwith "Unexpected tokens"

  and iter_precond meta path name preconds tokens =
    match tokens with
    | RPAREN ::EQUAL :: STRING str :: tokens ->
      begin
        match name with
        | "requires" ->
          MetaFile.add_requires meta (List.rev preconds)
            (OcpString.split_simplify str ' ')
        | "archive" ->
          MetaFile.add_archive meta (List.rev preconds)
            (OcpString.split_simplify str ' ')
       | _ ->
         if verbose 4 then
          Printf.fprintf stderr "MetaParser.parse_file: discarding %S\n%!"
            name

      end;
      iter meta path tokens
    | RPAREN ::PLUSEQUAL :: STRING _str :: tokens ->
      iter meta path tokens
    | IDENT ident :: tokens ->
      iter_precond meta path name ((ident, true) :: preconds) tokens
    | MINUS :: IDENT ident :: tokens ->
      iter_precond meta path name ((ident, false) :: preconds) tokens
    | _ ->
      print_remaining "iter_precond" tokens

  in
  let meta = MetaFile.empty () in
  iter meta [] tokens

let name_of_META filename =
  let basename = Filename.basename filename in
  let long_name =
    if basename = "META" then
      Filename.basename (Filename.dirname filename)
    else
      if OcpString.starts_with basename "META." then
        String.sub basename 5 (String.length basename - 5)
      else
        failwith (Printf.sprintf
                    "MetaParser.name_of_META: incorrect filename %S"
                    filename)
  in
  let (name, _version) = OcpString.cut_at long_name '.' in
  name
