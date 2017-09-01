open Utils
module Ctx = Typecheck_ctx
module A = Ast
module P = String_of_ast

module StringSet = Set.Make(String)

(* TODO: use Ephemerons to prevent memory leaks. *)
module E2T: sig
  val get: A.expr -> A.etype
  val set: A.expr -> A.etype -> unit
end = struct
  module HashedExpr = struct
    type t = A.expr
    let equal = (==)
    let hash = Hashtbl.hash
  end
  module ExprHashtbl = Hashtbl.Make(HashedExpr)
  let tbl: A.etype ExprHashtbl.t = ExprHashtbl.create (37)
  let get (e:A.expr) = ExprHashtbl.find tbl e
  let set (e:A.expr) t = ExprHashtbl.add tbl e t
end

let retrieve_type ctx e =
  let t = E2T.get e in
  Ctx.expand_type ctx t

let _DEBUG_ = true
let debug_indent = ref 0

let rec typecheck_expr ctx expr =
  if _DEBUG_ then begin
    (* print_endline ("\n"^String.make 80 '*'); *)
    print_endline (String.make (2 * !debug_indent) ' '^"Typing "^P.string_of_expr expr);
    (* print_endline ("In context: "^Ctx.string_of_t ctx); *)
    incr debug_indent
  end;

  let ctx, t = try match expr with
  | A.ENat n  -> ctx, A.tprim0 "nat"
  | A.EInt n  -> ctx, A.tprim0 "int"
  | A.EString _ -> ctx, A.tprim0 "string"
  | A.ETez _  -> ctx, A.tprim0 "tez"
  | A.ESig _  -> ctx, A.tprim0 "sig"
  | A.ETime _ -> ctx, A.tprim0 "time"
  | A.EId(id) ->
    let scheme = Ctx.scheme_of_evar ctx id in
    ctx, Ctx.instantiate_scheme (scheme)

  | A.ELambda(id, (t_params, t_arg), e) ->
    (if t_params <> [] then unsupported "parametric parameter types");
    (* TODO fail if id is bound by default ctx? *)
    (* Type e supposing that id has type t_arg. *)
    let ctx, prev = Ctx.push_evar id (t_params, t_arg) ctx in
    let ctx, te = typecheck_expr ctx e in
    (* TODO let-generalization? *)
    let ctx = Ctx.pop_evar prev ctx in
    ctx , A.TLambda(t_arg, te)

  | A.ELetIn(id, t_id, e0, e1) ->
    (* TODO fail if id is bound by default ctx? *)
    let ctx, t0 = typecheck_expr ctx e0 in
    let ctx, t0 = Ctx.unify ctx t_id t0 in
    (* TODO: generalize t0? *)
    let ctx, prev = Ctx.push_evar id ([], t0) ctx in
    let ctx, t1 = typecheck_expr ctx e1 in
    let ctx = Ctx.pop_evar prev ctx in
    ctx, t1

  | A.EApp(f, arg) ->
    let ctx, t_f = typecheck_expr ctx f in
    let ctx, t_arg = typecheck_expr ctx arg in
    let ctx, t_param, t_result = match t_f with
      | A.TLambda(t_param, t_result) -> ctx, t_param, t_result
      | A.TId("contract-call") ->
        (* TODO contract-call is a variable name, not a type name, this test is wrong! *)
        (* TODO check that other variables aren't used after this. *)
        (* TODO check that storage argument type == contract storage type *)
        (* TODO check that we aren't in a lambda. *)
        not_impl "contract-call typing"
      | A.TId(id) ->
         let t_param, t_result = A.fresh_tvar(), A.fresh_tvar() in
         let ctx, _ = Ctx.unify ctx t_f (A.TLambda(t_param, t_result)) in
         ctx, t_param, t_result
      | _ -> type_error "Applying a non-function" in
    let ctx, _ = Ctx.unify ctx t_param t_arg in
    ctx, t_result

  | A.ETypeAnnot(e, t) ->
    let ctx, te = typecheck_expr ctx e in Ctx.unify ctx t te

  | A.ETuple exprs ->
    (* Every element must typecheck_expr, the total type is their product. *)
    let ctx, types = list_fold_map typecheck_expr ctx exprs in
    ctx, A.TTuple(types)

  | A.ETupleGet(e, n) ->
    (* Can't use simply unification: we wouldn't know how many elements are in the tuple. *)
    let ctx, t_e = typecheck_expr ctx e in
    begin match t_e with
    | A.TTuple types ->
      (try ctx, List.nth types n with Failure _ -> type_error "Out of tuple index")
    | _ -> type_error "Not known to be a tuple"
    end

  | A.EProduct pairs -> typecheck_EProduct ctx pairs
  | A.EProductGet(e, tag) -> typecheck_EProductGet ctx e tag
  | A.EProductSet(e0, tag, e1) -> typecheck_EProductSet ctx e0 tag e1
  | A.EStoreSet(v, e0, e1) -> typecheck_EStoreSet ctx v e0 e1
  | A.ESum(tag, e) -> typecheck_ESum ctx tag e
  | A.ESumCase(e, cases) -> typecheck_ESumCase ctx e cases
  | A.EBinOp(a, op, b) -> typecheck_EBinOp ctx a op b
  | A.EUnOp(op, a) -> typecheck_EUnOp ctx op a
  with
  | Typing(msg) ->
    print_endline ("\n"^msg^": While typing "^P.string_of_expr expr^"\nContext:\n"^Ctx.string_of_t ctx);
    raise Exit
  in
  let t = Ctx.expand_type ctx t in
  E2T.set expr t;
  if _DEBUG_ then begin
    decr debug_indent;
    print_endline (String.make (2 * !debug_indent) ' '^"Result: val "^P.string_of_expr expr^": "^P.string_of_type t);
  end;
  ctx, t

and typecheck_EProduct ctx e_pairs =
  let tag0 = fst (List.hd e_pairs) in
  let name = Ctx.name_of_product_tag ctx tag0 in
  let t_result, t_items = Ctx.instantiate_composite name (Ctx.product_of_name ctx name) in
  let ctx, t_pairs = list_fold_map
    (fun ctx (tag, e) ->
      let ctx, t = typecheck_expr ctx e in
      let ctx, t = Ctx.unify ctx t (List.assoc tag t_items) in
      ctx, (tag, t))
    ctx e_pairs in
  ctx, t_result

and typecheck_ESumCase ctx e e_cases =
  let tag0, _ = List.hd e_cases in
  let name = try Ctx.name_of_sum_tag ctx tag0 with Not_found -> type_error(tag0^" is not a sum tag") in
  let t_sum, case_types = Ctx.instantiate_composite name (Ctx.sum_of_name ctx name) in
  let ctx, t_e = typecheck_expr ctx e in
  let ctx, _ = Ctx.unify ctx t_sum t_e in
  (* TODO check that declaration and case domains are equal. *)
  let ctx, t_pairs = list_fold_map
    (fun ctx (tag, (v, e)) ->
      (* TODO fail if v is bound by default ctx? *)
      let ctx, prev = Ctx.push_evar v ([], List.assoc tag case_types) ctx in
      let ctx, t = typecheck_expr ctx e in
      let ctx = Ctx.pop_evar prev ctx in
      ctx, (tag, t))
    ctx e_cases in
  let ctx, t = List.fold_left
    (fun (ctx, t) (tag, t') -> Ctx.unify ctx t t')
    (ctx, snd(List.hd t_pairs)) (List.tl t_pairs) in
  ctx, t

and typecheck_EProductGet ctx e_product tag =
  let name = try Ctx.name_of_product_tag ctx tag with Not_found -> type_error(tag^" is not a product tag") in
  let t_product0, field_types = Ctx.instantiate_composite name (Ctx.product_of_name ctx name) in
  let ctx, t_product1 = typecheck_expr ctx e_product in
  let ctx, _ = Ctx.unify ctx t_product0 t_product1 in
  let t = List.assoc tag field_types in
  ctx, t

and typecheck_EProductSet ctx e_product tag e_field =
  let name = try Ctx.name_of_product_tag ctx tag with Not_found -> type_error(tag^" is not a product tag") in
  let t_product0, field_types = Ctx.instantiate_composite name (Ctx.product_of_name ctx name) in
  let ctx, t_product1 = typecheck_expr ctx e_product in
  let ctx, t_product2 = Ctx.unify ctx t_product0 t_product1 in
  let t_field0 = List.assoc tag field_types in
  let ctx, t_field1 = typecheck_expr ctx e_field in
  let ctx, _ = Ctx.unify ctx t_field0 t_field1 in
  ctx, t_product2

and typecheck_EStoreSet ctx v e_field e =
  let _, field_types = Ctx.instantiate_composite "@" (Ctx.product_of_name ctx "@") in
  let t_field0 = List.assoc v field_types in
  let ctx, t_field1 = typecheck_expr ctx e_field in
  let ctx, _ = Ctx.unify ctx t_field0 t_field1 in
  typecheck_expr ctx e

and typecheck_ESum ctx tag e =
  let name = try Ctx.name_of_sum_tag ctx tag with Not_found -> type_error(tag^" is not a sum tag") in
  let t_sum, case_types = Ctx.instantiate_composite name (Ctx.sum_of_name ctx name) in
  let ctx, t_e = typecheck_expr ctx e in
  let ctx, _ = Ctx.unify ctx t_e (List.assoc tag case_types) in
  ctx, t_sum

and typecheck_EBinOp ctx a op b =
  let prims_in candidates responses = List.for_all (fun t-> List.mem t responses) candidates in
  let p n = A.TApp(n, []) in
  let ctx, ta = typecheck_expr ctx a in
  let ctx, tb = typecheck_expr ctx b in
  let error op = type_error("Cannot "^op^" "^P.string_of_type ta^" and "^P.string_of_type tb) in
  match op with
  | A.BConcat ->
    let ctx, _ = Ctx.unify ctx ta (p "string") in
    let ctx, _ = Ctx.unify ctx tb (p "string") in
    ctx, A.TApp("string", [])

  | A.BAdd ->
    (* nat² -> nat | (nat|int)² -> int | nat time -> time | tez² -> tez *)
    begin match ta, tb with
    | A.TApp("nat", []), A.TApp("nat", []) -> ctx, p "nat"
    | A.TApp(t0, []), A.TApp(t1, []) when prims_in [t0; t1] ["int"; "nat"] -> ctx, p "int"
    (* TODO shouldn't this be time int->time instead? *)
    | A.TApp("nat", []), A.TApp("time", []) | A.TApp("time", []), A.TApp("nat", []) -> ctx, p "time"
    | A.TApp("tez", []), A.TApp("tez", []) -> ctx, p "tez"
    | A.TId id, A.TApp("nat", []) | A.TApp("nat", []), A.TId id ->
      type_error ("Need more type annotation to determine wether  addition is "^
                 "(nat, int) -> int, (nat, nat) -> nat or (nat, time) -> time.")
      (* let ctx, _ = Ctx.unify ctx (A.TId id) (p "int") in ctx, p "int" *)
    | A.TId id, A.TApp("int", []) | A.TApp("int", []), A.TId id ->
      let ctx, _ = Ctx.unify ctx (A.TId id) (p "int") in ctx, p "int"
    | A.TId id, A.TApp("tez", []) | A.TApp("tez", []), A.TId id ->
      let ctx, _ = Ctx.unify ctx (A.TId id) (p "tez") in ctx, p "tez"
    | A.TId id, A.TApp("time", []) | A.TApp("time", []), A.TId id ->
      let ctx, _ = Ctx.unify ctx (A.TId id) (p "nat") in ctx, p "nat"
    | A.TId id0, A.TId id1 ->
      type_error ("Need more type annotation to determine addition type.")
    | _ -> error "add"
    end

  | A.BSub ->
    (* (int|nat)² -> int | tez² -> tez *)
    begin match ta, tb with
    | A.TApp(t0, []), A.TApp(t1, []) when prims_in [t0; t1] ["int"; "nat"] -> ctx, p "int"
    | A.TApp("tez", []), A.TApp("tez", []) -> ctx, p "tez"
    | A.TId id, A.TApp(t, []) | A.TApp(t, []), A.TId id when prims_in [t] ["nat"; "int"] ->
      let ctx, _ = Ctx.unify ctx (A.TId id) (p "int") in ctx, p "int"
    | A.TId id, A.TApp("tez", []) | A.TApp("tez", []), A.TId id ->
      let ctx, _ = Ctx.unify ctx (A.TId id) (p "tez") in ctx, p "tez"
    | A.TId id0, A.TId id1 ->
      type_error("Need more annotations to determine substraction type.")
      (* let ctx, _ = Ctx.unify ctx ta (p "int") in
         let ctx, _ = Ctx.unify ctx tb (p "int") in *)
      ctx, p "int"
    | _ -> error "substract"
    end

  | A.BMul ->
    (* nat² -> nat | (int|nat)² -> int | tez nat -> tez*)
    begin match ta, tb with
    | A.TApp("nat", []), A.TApp("nat", []) -> ctx, p "nat"
    | A.TApp(t0, []), A.TApp(t1, []) when prims_in [t0; t1] ["int"; "nat"] -> ctx, p "int"
    | A.TApp("tez", []), A.TApp("nat", []) | A.TApp("nat", []), A.TApp("tez", []) -> ctx, p "tez"
    | A.TId id, A.TApp("nat", []) | A.TApp("nat", []), A.TId id  ->
      type_error ("Need more type annotation to determine wether  multiplication is "^
                 "(nat, int) -> int, (nat, nat) -> nat or (nat, tez) -> tez.")
      (* let ctx, _ = Ctx.unify ctx (A.TId id) (p "int") in ctx, p "int" *)
    | A.TId id, A.TApp("int", []) | A.TApp("int", []), A.TId id ->
      let ctx, _ = Ctx.unify ctx (A.TId id) (p "int") in ctx, p "int"
    | A.TId id, A.TApp("tez", []) | A.TApp("tez", []), A.TId id ->
      let ctx, _ = Ctx.unify ctx (A.TId id) (p "nat") in ctx, p "tez"
    | A.TId id0, A.TId id1 ->
      type_error("Need more annotations to determine multiplication type.")
      (* let ctx, _ = Ctx.unify ctx ta (p "int") in
      let ctx, _ = Ctx.unify ctx tb (p "int") in
      ctx, p "int"  *)
    | _ -> error "multiply"
    end

  | A.BDiv ->
    (* nat² -> option (nat*nat) | (nat|int)² -> option(int*nat)
     | tez nat -> option(tez*tez) | tez tez -> option(nat*tez) *)
    let op x y = A.TApp("option", [A.TTuple[A.TApp(x, []); A.TApp(y, [])]]) in
    begin match ta, tb with
    | A.TApp("nat", []), A.TApp("nat", []) -> ctx, op "nat" "nat"
    | A.TApp(t0, []), A.TApp(t1, []) when prims_in [t0; t1] ["int"; "nat"] -> ctx, op "int" "nat"
    | A.TApp("tez", []), A.TApp("nat", []) -> ctx, op "tez" "tez"
    | A.TApp("tez", []), A.TApp("tez", []) -> ctx, op "nat" "tez"
    | A.TId id, A.TApp(t, []) | A.TApp(t, []), (A.TId id) when prims_in [t] ["int"; "nat"] ->
      let ctx, _ = Ctx.unify ctx (A.TId id) (p "int") in ctx, op "int" "nat"
    | A.TId id, A.TApp("tez", []) ->
      let ctx, _ = Ctx.unify ctx (A.TId id) (p "tez") in ctx, op "nat" "tez"
    | A.TApp("tez", []), A.TId id -> (* `t1` Could be either tez or nat; let's arbitrarily pick nat *)
      let ctx, _ = Ctx.unify ctx (A.TId id) (p "nat") in ctx, op "tez" "tez"
    | A.TId id0, A.TId id1 ->
      let ctx, _ = Ctx.unify ctx ta (p "int") in
      let ctx, _ = Ctx.unify ctx tb (p "int") in
      ctx, p "int"
    | _ -> error "divide"
    end

  | A.BEq | A.BNeq | A.BLt | A.BLe | A.BGt | A.BGe ->
    (* a² -> bool *)
    let ctx, _ = Ctx.unify ctx ta tb in ctx, p "bool"

  | A.BOr | A.BAnd | A.BXor ->
    (* bool² -> bool | nat² -> nat *)
    begin match ta, tb with
    | A.TApp("bool", []), A.TApp("bool", []) -> ctx, p "bool"
    | A.TApp("nat", []), A.TApp("nat", []) -> ctx, p "nat"
    | A.TId id, A.TApp(t, []) | A.TApp(t, []), A.TId id when prims_in [t] ["nat"; "bool"] ->
      let ctx, _ = Ctx.unify ctx ta tb in ctx, p t
    | A.TId id0, A.TId id1 -> (* have to choose arbitrarily between bool and nat *)
      let ctx, _ = Ctx.unify ctx ta (p "bool") in
      let ctx, _ = Ctx.unify ctx tb (p "bool") in
      ctx, p "bool"
    | _ -> error "apply logical operator"
    end

  | A.BLsl | A.BLsr ->
    (* nat² -> nat *)
    begin match ta, tb with
    | A.TApp("nat", []), A.TApp("nat", []) -> ctx, p "nat"
    | A.TId id, A.TApp("nat", []) | A.TApp("nat", []), A.TId id ->
      let ctx, _ = Ctx.unify ctx ta tb in ctx, p "nat"
    | A.TId id0, A.TId id1 -> (* have to choose arbitrarily between bool and nat *)
      let ctx, _ = Ctx.unify ctx ta (p "nat") in
      let ctx, _ = Ctx.unify ctx tb (p "nat") in
      ctx, p "nat"
    | _ -> error "bit-shift"
    end

and typecheck_EUnOp ctx op a =
  let p n = A.TApp(n, []) in
  let ctx, ta = typecheck_expr ctx a in
  match op with

  | A.UAbs ->
    (* int -> nat *)
    begin match ta with
    | A.TApp("int", []) -> ctx, p "nat"
    | A.TApp("nat", []) -> type_error "no point in getting the absolute val of a nat"
    | A.TId id -> let ctx, _ = Ctx.unify ctx ta (p "int") in ctx, p "nat"
    | _ -> type_error "Cannot get abs of that"
    end

  | A.UNot ->
    (* bool -> bool | (nat|int) -> int *)
    begin match ta with
    | A.TApp("int", []) | A.TApp("nat", []) -> ctx, p "int"
    | A.TApp("bool", []) -> ctx, p "bool"
    | A.TId id -> let ctx, _ = Ctx.unify ctx ta (p "bool") in ctx, p "bool"
    | _ -> type_error "Cannot get opposite of that"
    end

  | A.UNeg ->
    (* (nat|int) -> int *)
    begin match ta with
    | A.TApp("int", []) | A.TApp("nat", []) -> ctx, p "int"
    | A.TId id -> let ctx, _ = Ctx.unify ctx ta (p "int") in ctx, p "int"
    | _ -> type_error "Cannot get the negation of that"
    end

let typecheck_decl ctx = function
  | A.DPrim(var, params) -> Ctx.add_prim var params ctx
  | A.DAlias(var, params, t) -> Ctx.add_alias var (params, t) ctx
  | A.DProduct(var, params, cases) -> Ctx.add_product var params cases ctx
  | A.DSum(var, params, cases) -> Ctx.add_sum var params cases ctx

let typecheck_store (ctx, fields) (tag, t) =
  if List.mem_assoc tag fields then unsound("Storage field "^tag^" redefined");
  (ctx, (tag, t)::fields)

let typecheck_contract ctx (declarations, storage_fields, code) =
  (* TODO is the arity of A.TApp() type properly checked? *)
  let ctx = List.fold_left typecheck_decl ctx declarations in
  let ctx, store_fields = List.fold_left typecheck_store (ctx, []) storage_fields in
  let ctx = Ctx.add_product "@" [] store_fields ctx in
  let ctx = Ctx.add_evar "@" ([], A.TApp("@", [])) ctx in
  let ctx, t = typecheck_expr ctx code in
  let param = A.fresh_tvar ~prefix:"param" () in
  let result = A.fresh_tvar ~prefix:"result" () in
  let ctx, t =  Ctx.unify ctx t (A.tlambda [param; result]) in
  ctx, Ctx.expand_type ctx (A.TId "@"), t