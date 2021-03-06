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




module StringCompat = struct

  module Bytes = Bytes
  module Buffer = Buffer

  module String = struct
    include String
    let set = Bytes.set
  end

end

module StringSet = Set.Make(String)

module StringMap = struct
  module M = Map.Make(String)
  include M
  let of_list list =
    let map = ref empty in
    List.iter (fun (x,y) -> map := add x y !map) list;
    !map

  let to_list map =
    let list = ref [] in
    iter (fun x y -> list := (x,y) :: !list) map;
    List.rev !list

  let to_list_of_keys map =
    let list = ref [] in
    iter (fun x _ -> list := x :: !list) map;
    List.rev !list
end

module Compat = struct

  let with_location_error ppf f =
    try
      f ()
    with x ->
      Location.report_exception ppf x;
      exit 2

  open Parser

  let mk_string s = STRING (s,None)
  let get_STRING = function
    | STRING (s,_) -> s
    | _ -> assert false

  let name_of_token = function
    | LBRACKETPERCENT|LBRACKETPERCENTPERCENT
    | LBRACKETAT|LBRACKETATAT|LBRACKETATATAT|PERCENT|PLUSEQ -> "4.02.1 token"
    | STRING (s,_) -> Printf.sprintf "STRING(%S,_)" s
    | NATIVEINT(nativeint ) -> Printf.sprintf "NATIVEINT(%nd)" nativeint
    | INT int -> Printf.sprintf "INT(%d)" int
    | INT32(int32) -> Printf.sprintf "INT32(%ld)" int32
    | INT64(int64) -> Printf.sprintf "INT64(%Ld)" int64
    | FLOAT float -> Printf.sprintf "FLOAT(%s)" float
    | _  -> assert false

  let string_of_token = function
    | LBRACKETPERCENT|LBRACKETPERCENTPERCENT
    | LBRACKETAT|LBRACKETATAT|LBRACKETATATAT|PERCENT|PLUSEQ -> "4.02.1 token"
    | STRING (s,_) -> Printf.sprintf "%S" s
    | NATIVEINT nativeint -> Printf.sprintf "%nd" nativeint
    | INT int -> Printf.sprintf "%d" int
    | INT32(int32) -> Printf.sprintf "%ld" int32
    | INT64(int64) -> Printf.sprintf "%Ld" int64
    | FLOAT float -> float
    | _  -> assert false

  let int_of_token = function
    | INT n -> n
    | _ -> assert false
  let token_of_int n = INT n

end

module Location = Location
