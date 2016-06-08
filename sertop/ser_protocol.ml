(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2016     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(************************************************************************)
(* Coq serialization API/Plugin                                         *)
(* Copyright 2016 MINES ParisTech                                       *)
(************************************************************************)
(* Status: Very Experimental                                            *)
(************************************************************************)

open Sexplib
open Sexplib.Std

open Ser_goptions
open Ser_stateid
(* open Ser_names *)
open Ser_richpp
open Ser_feedback
open Ser_constr
open Ser_constrexpr
(* open Ser_glob_term *)

(* New protocol plus interpreter *)

type control_cmd =
  | StmInit                        (* Init Coq      *)
  | StmState                       (* Get the state *)
  | StmAdd     of stateid * string (* Stm.add       *)
  | StmQuery   of stateid * string (* Stm.query     *)
  | StmEdit    of stateid          (* Stm.edit_at   *)
  | StmObserve of stateid          (* Stm.observe   *)
  | SetOpt     of unit             (* set_option    *)
  | LibAdd     of string list * string * bool
  | Quit
  [@@deriving of_sexp]

(* We'd like to use GADTs here, but we'd need to pack them somehow to
 * support serialization both ways, see Jérémie Dimino comment here:
 *
 * https://github.com/janestreet/ppx_sexp_conv/issues/8
 *
 * type _ query_cmd =
 *   | Option : string query_cmd
 *   | Search : string query_cmd
 *   | Goals  : constr query_cmd
 *   [@@deriving sexp]
 *)

type pp_opt = PpSexp | PpStr
  [@@deriving of_sexp]

(** Max number of results to return, 0 will return a summary *)
type query_limit = int option
  [@@deriving of_sexp]

type query_opt = query_limit * pp_opt
  [@@deriving of_sexp]

type query_cmd =
  | Option of string            (* Search for the value of an option *)
  | Search of string            (* Search vernacular *)
  | Goals                       (* Return goals [TODO: Add filtering/limiting options] *)
  [@@deriving of_sexp]

type coq_object =
  | CoqString  of string
  | CoqRichpp  of richpp
  (* XXX: For xml-like printing, should be moved to an option... *)
  | CoqRichXml of richpp
  | CoqOption  of option_state
  | CoqConstr  of constr
  | CoqExpr    of constr_expr
  (* Fixme *)
  | CoqGoal    of richpp list * constr_expr * string
  [@@deriving sexp]

let pp_tag xtag att pp =
  let open Pp in
  let s_att   att   = pr_sequence (fun (t,v) -> str t ++ str "=" ++ str v) att in
  let s_open  s att = str "<"  ++ str s ++ s_att att ++ str ">" in
  let s_close s     = str "</" ++ str s              ++ str ">" in
  s_open xtag att ++ pp ++ s_close xtag

let rec pp_xml (xml : Xml_datatype.xml) = match xml with
  | Xml_datatype.Element (tag, des, more) ->
    pp_tag tag des ((Pp.pr_sequence pp_xml) more)
  | Xml_datatype.PCData str -> Pp.str str

let obj_printer fmt (obj : coq_object) =
  let pr obj = Format.fprintf fmt "%a" (Pp.pp_with ?pp_tag:None) obj in
  match obj with
  | CoqString  s -> pr (Pp.str s)
  | CoqRichpp  s -> pr (Pp.str (Richpp.raw_print s))
  | CoqRichXml x-> pr (pp_xml (Richpp.repr x))
  | CoqOption  _ -> failwith "Fix goptions.mli in Coq to export the proper interface"
  | CoqConstr  c -> pr (Printer.pr_constr c)
  | CoqExpr    e -> pr (Ppconstr.pr_lconstr_expr e)
  (* Fixme *)
  | CoqGoal (_,g,_) -> pr (Ppconstr.pr_lconstr_expr g)
  (* | CoqGlob   g -> pr (Printer.pr_glob_constr g) *)

type answer_kind =
  | Ack
  | StmInfo of stateid
  | ObjList of coq_object list
  | CoqExn  of exn
  [@@deriving sexp_of]

let obj_print obj =
  let open Format in
  fprintf str_formatter "@[%a@]" obj_printer obj;
  CoqString (flush_str_formatter ())

let exec_query (_limit, pp) (cmd : query_cmd) = match cmd with
  | Option _ -> failwith "Query option TODO"
  | Search _ -> failwith "Query Search TODO"
  | Goals    ->
    let goals = List.map (fun (h,g,i) -> CoqGoal(h,g,i)) (Ser_goals.get_goals Ser_goals.FgGoals) in
    match pp with
    | PpStr  -> List.map obj_print goals
    | PpSexp -> goals

type cmd =
  | Control    of control_cmd
  | Query      of query_opt * query_cmd
  | Print      of coq_object
  [@@deriving of_sexp]

(* type focus = { start : Stateid.t; stop : Stateid.t; tip : Stateid.t } *)
(* val edit_at : Stateid.t -> [ `NewTip | `Focus of focus ] *)
(*     Stateid.t * [ `NewTip | `Unfocus of Stateid.t ] *)

type answer =
  | Answer   of int * answer_kind
  | Feedback of feedback
  | SexpError
  [@@deriving sexp_of]

let out_answer fmt a =
  Format.fprintf fmt "@[%a@]@\n%!" Sexp.pp (sexp_of_answer a)

(* XXX: remove the std_formatter ??? *)
let fb_handler fb = out_answer Format.std_formatter (Feedback fb)

let read_cmd in_channel out_fmt =
  let rec read_loop () =
    let cmd_sexp = Sexplib.Sexp.input_sexp in_channel in
    try cmd_of_sexp cmd_sexp
    with _ -> out_answer out_fmt SexpError;
              read_loop ()
  in read_loop ()

(* XXX *)
let verb = true

let coq_protect e =
  try  e ()
  with exn -> [CoqExn exn]

let exec_ctrl cmd_id (ctrl : control_cmd) = match ctrl with
  | StmInit        -> let st = Ser_init.coq_init { Ser_init.fb_handler = fb_handler; } in
                      [StmInfo st]

  | StmState       -> [StmInfo (Stm.get_current_state ())]
  | StmAdd (st, s) -> coq_protect @@ fun () ->
                      let new_st, _ = Stm.add ~ontop:st verb (-cmd_id) s in
                      [StmInfo new_st]
  | StmQuery(st, s)-> coq_protect (fun () -> Stm.query ~at:st s; [])
  | StmEdit st     -> coq_protect (fun () -> ignore (Stm.edit_at st); [])
  | StmObserve st  -> coq_protect (fun () -> Stm.observe st; [])

  | LibAdd(lib, lib_path, has_ml) ->
                      let open Names in
                      let coq_path = DirPath.make @@ List.rev @@ List.map Id.of_string lib in
                      Loadpath.add_load_path lib_path coq_path ~implicit:false;
                      if has_ml then Mltop.add_ml_dir lib_path; []

  | SetOpt _       -> failwith "TODO"
  | Quit           -> []

let exec_cmd cmd_id (cmd : cmd) = match cmd with
  | Control ctrl      -> exec_ctrl cmd_id ctrl
  | Query (opt, qry)  -> [ObjList (exec_query opt qry)]
  | Print obj         -> let open Format in
                         fprintf str_formatter "@[%a@]" obj_printer obj;
                         [ObjList [CoqString (flush_str_formatter ())]]

let ser_loop in_c out_c =
  let open Format in
  let out_fmt    = formatter_of_out_channel out_c            in
  let ack cmd_id = out_answer out_fmt (Answer (cmd_id, Ack)) in
  let rec loop cmd_id =
    let cmd = read_cmd in_c out_fmt                          in
    ack cmd_id;
    List.iter (out_answer out_fmt) @@ List.map (fun a -> Answer (cmd_id, a)) (exec_cmd cmd_id cmd);
    loop (cmd_id + 1)
  in loop 0

let ser_prelude coq_path : cmd list =
  let mk_path prefix l = coq_path ^ "/" ^ prefix ^ "/" ^ String.concat "/" l in
  [ Control StmInit ] @
  List.map (fun p -> Control (LibAdd ("Coq" :: p, mk_path "plugins"  p, true))) Ser_init.coq_init_plugins  @
  List.map (fun p -> Control (LibAdd ("Coq" :: p, mk_path "theories" p, true))) Ser_init.coq_init_theories @
  [ Control (StmAdd (Stateid.of_int 1, "Require Import Coq.Init.Prelude. "));
    Control (StmObserve (Stateid.of_int 2))
  ]

let do_prelude coq_path =
  List.iter (fun cmd -> ignore (exec_cmd 0 cmd)) (ser_prelude coq_path)
