package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------
// Runtime values
// ---------------------------------------------------------------------

Builtin_Proc :: proc(args: []Value) -> Value

Builtin :: struct {
    name: string,
    fn:   Builtin_Proc,
}

// A callable created from a Node_Function literal. env is the frame
// that was current at the moment this literal was EVALUATED -- not
// the frame it's called from. That's what makes it a closure rather
// than just a function pointer: nested/self calls later on will walk
// Frame.parent starting from env, and that chain mirrors the static
// Scope.parent chain the resolver walked, so captured variables
// resolve correctly no matter how deeply this closure gets passed
// around before it's actually invoked.
Closure :: struct {
    fn_node: ^Node, // node.kind == .Function
    env:     ^Frame,
}

Value_Array :: struct {
    elements: [dynamic]Value,
}

Value_Object :: struct {
    fields: map[string]Value,
}

Value :: union {
    f64,
    string,
    bool,
    ^Value_Array,
    ^Value_Object,
    ^Closure,
    ^Builtin,
}
// A Value that's nil (no variant set) represents "no value" -- an
// uninitialized local before its first assignment, or the result of
// a function that fell off the end of its body without a `return`.

// ---------------------------------------------------------------------
// Environments
// ---------------------------------------------------------------------

// Every local lives in a heap-allocated Cell so a closure capturing a
// variable and the frame that owns it are always looking at the same
// storage. The resolver's Symbol.captured flag exists so codegen can
// skip this indirection for locals nobody ever closes over; a
// tree-walker doesn't bother with that optimization yet -- box
// everything, keep it simple.
Cell :: struct {
    value: Value,
}

// One Frame per function ACTIVATION (per call, not per function).
// slots is indexed by Symbol.slot and sized to Node_Function.num_slots
// (or ModuleDecs.num_slots for the implicit top-level frame).
//
// parent is the LEXICALLY enclosing frame: whatever frame was current
// when this activation's function literal was evaluated (see
// Closure.env above). That's exactly the chain find_cell walks.
Frame :: struct {
    fn_node: ^Node, // nil for the implicit top-level "function"
    slots:   []^Cell,
    parent:  ^Frame,
}

alloc_frame :: proc(fn_node: ^Node, num_slots: int, parent: ^Frame) -> ^Frame {
    f := new(Frame)
    f.fn_node = fn_node
    f.parent = parent
    slots := make([]^Cell, num_slots)
    for i in 0 ..< num_slots {
        slots[i] = new(Cell)
    }
    f.slots = slots
    return f
}

// Finds the Cell backing sym, by walking outward from `from` until a
// frame belonging to sym's owner function turns up. sym.owner_fn is
// nil for a module-level global, which matches the implicit top
// frame's fn_node (also nil) -- so globals just fall out of the same
// walk instead of needing a separate case.
//
// Every module has its own top frame with parent == nil, so this walk
// can never cross from one module's frames into another's: an imported
// name is found because the importer's slot was aliased to the
// exporter's Cell (see run_program), not by searching across modules.
find_cell :: proc(from: ^Frame, sym: ^Symbol) -> ^Cell {
    f := from
    for f != nil {
        if f.fn_node == sym.owner_fn {
            return f.slots[sym.slot]
        }
        f = f.parent
    }
    panicf("internal error: no frame found for symbol \"%s\"", sym.name)
}

// ---------------------------------------------------------------------
// Interpreter state
// ---------------------------------------------------------------------

Interp :: struct {
    frame: ^Frame,
}

// Threaded back up through exec_stmt/exec_block instead of a real
// exception mechanism -- a `return` needs to unwind out of however
// many nested Blocks/Ifs it's inside, but no further than the
// enclosing function CALL (call_closure is what stops propagating it
// and turns it into the call's result).
Exec_Result :: struct {
    value:      Value,
    did_return: bool,
}

// ---------------------------------------------------------------------
// Builtins registry
// ---------------------------------------------------------------------

// The single place that lists every name->Odin-proc predeclared into
// global scope. To add a new builtin: write a Builtin_Proc-shaped
// proc anywhere below, then add one line here. Nothing else needs to
// change -- builtin_names() feeds the resolver so the name resolves
// like any other global, and run_program below wires this same list
// into runtime Cells.
builtins_registry := []Builtin_Def{
    {"exec",          builtin_exec},
    {"print",         builtin_print},
    {"len",           builtin_len},
    {"type_of",       builtin_type_of},
    {"sqrt",          builtin_sqrt},
    {"string",        builtin_string},
    {"json_parse",    builtin_json_parse},
    {"json_marshal",  builtin_json_marshal},
    {"json_marshall", builtin_json_marshal}, // alias for the other spelling
}

Builtin_Def :: struct {
    name: string,
    fn:   Builtin_Proc,
}

// Names to hand to resolve_module_ast so these get predeclared before
// user code is resolved -- see resolver.odin's builtin_names param.
builtin_names :: proc() -> []string {
    names := make([dynamic]string, context.temp_allocator)
    for def in builtins_registry {
        append(&names, def.name)
    }
    return names[:]
}

builtin_sqrt :: proc(args: []Value) -> Value {
    if len(args) != 1 {
        panicf("sqrt: expected 1 argument, got %d", len(args))
    }
    return math.sqrt(as_number(args[0]))
}

// With one argument, the command is passed through the platform shell,
// preserving pipes, redirects and quoting.
// With multiple arguments, the first is the executable and the rest are
// passed as literal arguments.
builtin_exec :: proc(args: []Value) -> Value {
    if len(args) < 1 {
        panicf("exec: expected at least 1 argument, got 0")
    }

    for arg, i in args {
        if _, ok := arg.(string); !ok {
            panicf("exec: argument %d must be a string, got %s", i, value_to_string(arg))
        }
    }

    shell_cmd: []string

    if len(args) == 1 {
        cmd := args[0].(string)

        when ODIN_OS == .Windows {
            shell_cmd = []string{"cmd", "/c", cmd}
        } else {
            shell_cmd = []string{"/bin/sh", "-c", cmd}
        }
    } else {
        shell_cmd = make([]string, len(args))

        for arg, i in args {
            shell_cmd[i] = arg.(string)
        }
    }

    state, stdout, stderr, err := os.process_exec(
        {command = shell_cmd},
        context.allocator,
    )

    if err != nil {
        panicf("exec: failed to run \"%s\": %v", shell_cmd[0], err)
    }

    fields := make(map[string]Value)
    fields["stdout"] = string(stdout)
    fields["stderr"] = string(stderr)
    fields["code"]   = f64(state.exit_code)

    return new_clone(Value_Object{fields = fields})
}

// string(x) -> converts any value to its string form.
builtin_string :: proc(args: []Value) -> Value {
    if len(args) != 1 {
        panicf("string: expected 1 argument, got %d", len(args))
    }
    if s, ok := args[0].(string); ok {
        return s
    }
    return strings.clone(value_to_string(args[0]))
}

builtin_print :: proc(args: []Value) -> Value {
    for a, i in args {
        if i > 0 { fmt.print(" ") }
        fmt.print(value_to_string(a))
    }
    fmt.println()
    return nil
}

builtin_len :: proc(args: []Value) -> Value {
    if len(args) != 1 {
        panicf("len: expected 1 argument, got %d", len(args))
    }
    #partial switch v in args[0] {
    case string:
        return f64(len(v))
    case ^Value_Array:
        return f64(len(v.elements))
    case ^Value_Object:
        return f64(len(v.fields))
    case:
        panicf("len: expected a string, array or object, got %s", value_to_string(args[0]))
    }
    return nil
}

builtin_type_of :: proc(args: []Value) -> Value {
    if len(args) != 1 {
        panicf("type_of: expected 1 argument, got %d", len(args))
    }
    switch v in args[0] {
    case f64:                return "number"
    case string:              return "string"
    case bool:                return "bool"
    case ^Value_Array:        return "array"
    case ^Value_Object:       return "object"
    case ^Closure, ^Builtin:  return "function"
    case:                     return "nil"
    }
}

// ---------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------

// json_parse("{\"a\": [1, 2, {\"b\": null}]}") -> object / array / number /
// string / bool / nil. All JSON numbers become f64. Strict JSON (no
// comments, no trailing commas).
builtin_json_parse :: proc(args: []Value) -> Value {
    if len(args) != 1 {
        panicf("json_parse: expected 1 argument, got %d", len(args))
    }
    text, ok := args[0].(string)
    if !ok {
        panicf("json_parse: expected a string, got %s", value_to_string(args[0]))
    }

    jv, err := json.parse(transmute([]byte)text, .JSON)
    if err != .None {
        panicf("json_parse: invalid JSON (%v)", err)
    }
    return json_to_value(jv)
}

json_to_value :: proc(jv: json.Value) -> Value {
    switch v in jv {
    case json.Null:
        return nil
    case json.Integer:
        return f64(v)
    case json.Float:
        return f64(v)
    case json.Boolean:
        return bool(v)
    case json.String:
        return string(v)
    case json.Array:
        elems := make([dynamic]Value)
        for e in v {
            append(&elems, json_to_value(e))
        }
        return new_clone(Value_Array{elements = elems})
    case json.Object:
        fields := make(map[string]Value)
        for k, e in v {
            fields[k] = json_to_value(e)
        }
        return new_clone(Value_Object{fields = fields})
    case:
        return nil
    }
}

// json_marshal(value)        -> compact JSON string
// json_marshal(value, true)  -> pretty-printed (2-space indent)
// Object keys are sorted so the output is deterministic. NaN/Infinity
// become null; functions can't be serialized and panic.
builtin_json_marshal :: proc(args: []Value) -> Value {
    if len(args) < 1 || len(args) > 2 {
        panicf("json_marshal: expected 1 or 2 arguments, got %d", len(args))
    }
    pretty := len(args) == 2 && is_truthy(args[1])

    b := strings.builder_make()
    json_write(&b, args[0], pretty, 0)
    return strings.to_string(b)
}

json_newline :: proc(b: ^strings.Builder, pretty: bool, depth: int) {
    if !pretty { return }
    strings.write_byte(b, '\n')
    for _ in 0 ..< depth {
        strings.write_string(b, "  ")
    }
}

json_escape :: proc(b: ^strings.Builder, s: string) {
    strings.write_byte(b, '"')
    for c in transmute([]byte)s {
        switch c {
        case '"':  strings.write_string(b, "\\\"")
        case '\\': strings.write_string(b, "\\\\")
        case '\n': strings.write_string(b, "\\n")
        case '\r': strings.write_string(b, "\\r")
        case '\t': strings.write_string(b, "\\t")
        case:
            if c < 0x20 {
                fmt.sbprintf(b, "\\u%04x", int(c))
            } else {
                strings.write_byte(b, c) // bytes >= 0x80 pass through, keeping UTF-8 intact
            }
        }
    }
    strings.write_byte(b, '"')
}

json_write :: proc(b: ^strings.Builder, v: Value, pretty: bool, depth: int) {
    if depth > 200 {
        panicf("json_marshal: value nested too deeply (cyclic structure?)")
    }

    switch val in v {
    case f64:
        if math.is_nan(val) || math.is_inf(val) {
            strings.write_string(b, "null")
        } else if val == math.floor(val) && abs(val) < 1e15 {
            fmt.sbprintf(b, "%d", i64(val))
        } else {
            fmt.sbprintf(b, "%v", val)
        }

    case string:
        json_escape(b, val)

    case bool:
        strings.write_string(b, "true" if val else "false")

    case ^Value_Array:
        if len(val.elements) == 0 {
            strings.write_string(b, "[]")
            return
        }
        strings.write_byte(b, '[')
        for e, i in val.elements {
            if i > 0 { strings.write_byte(b, ',') }
            json_newline(b, pretty, depth + 1)
            json_write(b, e, pretty, depth + 1)
        }
        json_newline(b, pretty, depth)
        strings.write_byte(b, ']')

    case ^Value_Object:
        if len(val.fields) == 0 {
            strings.write_string(b, "{}")
            return
        }
        keys := make([dynamic]string, context.temp_allocator)
        for k in val.fields {
            append(&keys, k)
        }
        slice.sort(keys[:])

        strings.write_byte(b, '{')
        for k, i in keys {
            if i > 0 { strings.write_byte(b, ',') }
            json_newline(b, pretty, depth + 1)
            json_escape(b, k)
            strings.write_byte(b, ':')
            if pretty { strings.write_byte(b, ' ') }
            json_write(b, val.fields[k], pretty, depth + 1)
        }
        json_newline(b, pretty, depth)
        strings.write_byte(b, '}')

    case ^Closure, ^Builtin:
        panicf("json_marshal: cannot serialize a function")

    case:
        strings.write_string(b, "null")
    }
}

// ---------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------

// Runs one module's top level and returns its top-level Frame (the
// caller -- run_module in modules.odin -- stores it so importers can
// find this module's exported Cells).
//
// Imports run first, before any statement of this module's own body:
// each imported module is executed (once, however many places import
// it), then this module's slot for each imported name is pointed at
// the exporting module's Cell. Both sides share that Cell, so these
// are live bindings -- if the exporter reassigns the variable later,
// importers see the new value.
//
// Typical wiring once you have a lexer: see handle_file in main.odin
// (load_module_source, then run_module).
run_program :: proc(ast: ^AST, decs: ModuleDecs) -> ^Frame {
    top := alloc_frame(nil, decs.num_slots, nil)
    interp := Interp{frame = top}

    for def in builtins_registry {
        if sym, ok := decs.builtins[def.name]; ok {
            cell := find_cell(top, sym)
            cell.value = new_clone(Builtin{name = def.name, fn = def.fn})
        }
    }

    for stmt in ast.nodes {
        if stmt.kind != .Import {
            continue
        }
        imp := &stmt.data.(Node_Import)
        run_module(imp.module)
        for n in imp.names {
            top.slots[n.resolved.slot] = find_cell(imp.module.frame, n.exported)
        }
    }

    for stmt in ast.nodes {
        res := exec_stmt(&interp, stmt)
        if res.did_return {
            break // a bare top-level `return` just ends the program
        }
    }

    return top
}

value_to_string :: proc(v: Value) -> string {
    switch val in v {
    case f64:
        return fmt.tprintf("%v", val)

    case string:
        return val

    case bool:
        return val ? "true" : "false"

    case ^Value_Array:
        parts: [dynamic]string
        defer delete_dynamic_array(parts)

        for elem in val.elements {
            append(&parts, value_to_string(elem))
        }

        return fmt.tprintf("[%s]", strings.join(parts[:], ", ", context.temp_allocator))

    case ^Value_Object:
        parts: [dynamic]string
        defer delete_dynamic_array(parts)

        for name, field in val.fields {
            append(&parts, fmt.tprintf("%s = %s", name, value_to_string(field)))
        }

        // Built with concatenate rather than a format string so the
        // literal braces can't be mistaken for format syntax.
        joined := strings.join(parts[:], ", ", context.temp_allocator)
        return strings.concatenate({"{ ", joined, " }"}, context.temp_allocator)

    case ^Closure:
        return "<function>"

    case ^Builtin:
        return fmt.tprintf("<builtin %s>", val.name)

    case:
        return "nil"
    }
}

// ---------------------------------------------------------------------
// Field access and indexing
// ---------------------------------------------------------------------

// Converts an index Value to an int, requiring a whole number. Range
// checking is the caller's job (set_index allows idx == len to append).
index_to_int :: proc(idx: Value, what: string) -> int {
    n, ok := idx.(f64)
    if !ok {
        panicf("%s index must be a number, got %s", what, value_to_string(idx))
    }
    i := int(n)
    if f64(i) != n {
        panicf("%s index must be a whole number, got %v", what, n)
    }
    return i
}

check_index_range :: proc(i: int, length: int, what: string) {
    if i < 0 || i >= length {
        panicf("%s index %d out of range (length %d)", what, i, length)
    }
}

// obj.name -- a missing field reads as nil.
get_field :: proc(obj: Value, name: string) -> Value {
    #partial switch o in obj {
    case ^Value_Object:
        if v, ok := o.fields[name]; ok {
            return v
        }
        return nil
    case:
        panicf("cannot read field \"%s\" of %s", name, value_to_string(obj))
    }
    return nil
}

// obj[idx] -- arrays take a number, objects take a string key, strings
// take a number and return a 1-byte string.
get_index :: proc(obj: Value, idx: Value) -> Value {
    #partial switch o in obj {
    case ^Value_Array:
        i := index_to_int(idx, "array")
        check_index_range(i, len(o.elements), "array")
        return o.elements[i]

    case string:
        i := index_to_int(idx, "string")
        check_index_range(i, len(o), "string")
        return o[i:i + 1]

    case ^Value_Object:
        key, ok := idx.(string)
        if !ok {
            panicf("object key must be a string, got %s", value_to_string(idx))
        }
        if v, found := o.fields[key]; found {
            return v
        }
        return nil

    case:
        panicf("cannot index into %s", value_to_string(obj))
    }
    return nil
}

// obj.name = val
set_field :: proc(obj: Value, name: string, val: Value) {
    #partial switch o in obj {
    case ^Value_Object:
        o.fields[name] = val
    case:
        panicf("cannot set field \"%s\" on %s", name, value_to_string(obj))
    }
}

// obj[idx] = val -- on an array, idx == len appends.
set_index :: proc(obj: Value, idx: Value, val: Value) {
    #partial switch o in obj {
    case ^Value_Array:
        i := index_to_int(idx, "array")
        if i == len(o.elements) {
            append(&o.elements, val)
        } else {
            check_index_range(i, len(o.elements), "array")
            o.elements[i] = val
        }

    case ^Value_Object:
        key, ok := idx.(string)
        if !ok {
            panicf("object key must be a string, got %s", value_to_string(idx))
        }
        o.fields[key] = val

    case:
        panicf("cannot assign into an index of %s", value_to_string(obj))
    }
}

// ---------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------

exec_stmt :: proc(interp: ^Interp, node: ^Node) -> Exec_Result {
    #partial switch node.kind {
    case .Assign:
        a := &node.data.(Node_Assign)

        #partial switch a.target.kind {
        case .Name:
            sym := a.target.data.(Node_Name).resolved
            cell := find_cell(interp.frame, sym)

            val := eval_expr(interp, a.value)
            if op, has_op := a.op.?; has_op {
                // The parser desugars "x += v" only as far as recording
                // the op alongside the plain value -- do the actual fold
                // (x = x op v) here, using the CURRENT value of x.
                val = apply_binop(op, cell.value, val)
            }
            cell.value = val

        case .Field:
            t := &a.target.data.(Node_Field)
            obj := eval_expr(interp, t.object)
            val := eval_expr(interp, a.value)
            if op, has_op := a.op.?; has_op {
                val = apply_binop(op, get_field(obj, t.name), val)
            }
            set_field(obj, t.name, val)

        case .Index:
            t := &a.target.data.(Node_Index)
            obj := eval_expr(interp, t.object)
            idx := eval_expr(interp, t.index)
            val := eval_expr(interp, a.value)
            if op, has_op := a.op.?; has_op {
                val = apply_binop(op, get_index(obj, idx), val)
            }
            set_index(obj, idx, val)

        case:
            panicf("exec_stmt: invalid assignment target (kind %v)", a.target.kind)
        }
        return {}

    case .Return:
        ret := &node.data.(Node_Return)
        v: Value = nil
        if ret.value != nil {
            v = eval_expr(interp, ret.value)
        }
        return Exec_Result{value = v, did_return = true}

    case .Block:
        return exec_block(interp, node)

    case .Import:
        // Already handled before the first statement ran -- see
        // run_program. Nothing to do at the statement's own position.
        return {}

    case .If:
        f := &node.data.(Node_If)
        if is_truthy(eval_expr(interp, f.condition)) {
            return exec_stmt(interp, f.then_body)
        } else if f.else_body != nil {
            return exec_stmt(interp, f.else_body)
        }
        return {}

    // TODO: .While -- there's no Node_While yet (see the parser's
    // TODOs), so there's nothing to execute here yet either. Once you
    // add the AST node, this is just: loop calling exec_stmt(body)
    // while the condition's truthy, propagating did_return the same
    // way .If does, and (once you add break/continue) threading those
    // through Exec_Result the same way.

    case:
        eval_expr(interp, node)
        return {}
    }
}

exec_block :: proc(interp: ^Interp, node: ^Node) -> Exec_Result {
    b := &node.data.(Node_Block)
    for stmt in b.statements {
        res := exec_stmt(interp, stmt)
        if res.did_return {
            return res
        }
    }
    return {}
}

// ---------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------

eval_expr :: proc(interp: ^Interp, node: ^Node) -> Value {
    #partial switch node.kind {
    case .Number:
        n := &node.data.(Node_Number)
        return n.value

    case .String:
        s := &node.data.(Node_String)
        return s.value

    case .Name:
        n := &node.data.(Node_Name)
        cell := find_cell(interp.frame, n.resolved)
        return cell.value

    case .Binary:
        b := &node.data.(Node_Binary)
        // && / || short-circuit -- the right side must not be
        // evaluated at all when it's not needed.
        if b.op == .LogicalAnd {
            if !is_truthy(eval_expr(interp, b.left)) { return false }
            return is_truthy(eval_expr(interp, b.right))
        }
        if b.op == .LogicalOr {
            if is_truthy(eval_expr(interp, b.left)) { return true }
            return is_truthy(eval_expr(interp, b.right))
        }
        l := eval_expr(interp, b.left)
        r := eval_expr(interp, b.right)
        return apply_binop(b.op, l, r)

    case .Unary:
        u := &node.data.(Node_Unary)
        v := eval_expr(interp, u.expr)
        if u.op == .Negative {
            return -as_number(v)
        }
        return !is_truthy(v) // .Not

    case .Call:
        c := &node.data.(Node_Call)
        callee := eval_expr(interp, c.function)
        args := make([dynamic]Value, context.temp_allocator)
        arg_names := make([dynamic]Maybe(string), context.temp_allocator)
        for a in c.args {
            append(&args, eval_expr(interp, a.value))
            append(&arg_names, a.name)
        }
        return call_value(interp, callee, args[:], arg_names[:])

    case .Array:
        arr := &node.data.(Node_Array)
        elems := make([dynamic]Value)
        for e in arr.elements {
            append(&elems, eval_expr(interp, e))
        }
        return new_clone(Value_Array{elements = elems})

    case .Object:
        obj := &node.data.(Node_Object)
        fields := make(map[string]Value)
        for f in obj.fields {
            fields[f.name] = eval_expr(interp, f.value)
        }
        return new_clone(Value_Object{fields = fields})

    case .Field:
        f := &node.data.(Node_Field)
        return get_field(eval_expr(interp, f.object), f.name)

    case .Index:
        i := &node.data.(Node_Index)
        obj := eval_expr(interp, i.object)
        idx := eval_expr(interp, i.index)
        return get_index(obj, idx)

    case .Function:
        return new_clone(Closure{fn_node = node, env = interp.frame})

    case:
        panicf("eval_expr: unhandled node kind %v", node.kind)
    }
    return nil
}

apply_binop :: proc(op: BinopKind, l: Value, r: Value) -> Value {
    #partial switch op {
    case .Equal:
        return values_equal(l, r)
    case .NotEqual:
        return !values_equal(l, r)
    case .Addition:
        // string + string concatenates; if only one side is a string,
        // the other is converted first ("n = " + 5 -> "n = 5").
        if is_string(l) || is_string(r) {
            return strings.concatenate({value_to_string(l), value_to_string(r)})
        }
        return as_number(l) + as_number(r)
    case .Subtraction:
        return as_number(l) - as_number(r)
    case .Multiply:
        return as_number(l) * as_number(r)
    case .Divide:
        return as_number(l) / as_number(r)
    case .Modulo:
        return math.mod(as_number(l), as_number(r))
    case .LessEqual:
        return as_number(l) <= as_number(r)
    case .GreaterEqual:
        return as_number(l) >= as_number(r)
    case .Less:
        return as_number(l) < as_number(r)
    case .Greater:
        return as_number(l) > as_number(r)
    case .BitAnd:
        return f64(i64(as_number(l)) & i64(as_number(r)))
    case .BitOr:
        return f64(i64(as_number(l)) | i64(as_number(r)))
    case .BitXor:
        return f64(i64(as_number(l)) ~ i64(as_number(r)))
    }
    panicf("internal error: %v should be short-circuited in eval_expr, not reach apply_binop", op)
}

values_equal :: proc(l: Value, r: Value) -> bool {
    switch lv in l {
    case f64:
        rv, ok := r.(f64)
        return ok && lv == rv
    case string:
        rv, ok := r.(string)
        return ok && lv == rv
    case bool:
        rv, ok := r.(bool)
        return ok && lv == rv
    case ^Value_Array, ^Value_Object, ^Closure, ^Builtin:
        return l == r // identity comparison
    case:
        return l == nil && r == nil
    }
}

as_number :: proc(v: Value) -> f64 {
    n, ok := v.(f64)
    if !ok {
        panicf("expected a number, got %s", value_to_string(v))
    }
    return n
}

is_string :: proc(v: Value) -> bool {
    _, ok := v.(string)
    return ok
}

is_truthy :: proc(v: Value) -> bool {
    #partial switch val in v {
    case bool:
        return val
    case f64:
        return val != 0
    case string:
        return len(val) > 0
    case:
        return v != nil
    }
}

// ---------------------------------------------------------------------
// Calling
// ---------------------------------------------------------------------

call_value :: proc(interp: ^Interp, callee: Value, args: []Value, arg_names: []Maybe(string)) -> Value {
    #partial switch fn in callee {
    case ^Closure:
        return call_closure(interp, fn, args, arg_names)
    case ^Builtin:
        return fn.fn(args)
    case:
        panicf("attempt to call a non-function value (%s)", value_to_string(callee))
    }
    return nil
}

// Binds args to params (positional first, then by name, then
// defaults), runs the body in a fresh Frame parented at the closure's
// captured env, and returns the result. This binding logic is
// deliberately simple -- no arity checking, no rest params -- treat
// it as a starting point rather than the final word on calling
// convention.
call_closure :: proc(interp: ^Interp, closure: ^Closure, args: []Value, arg_names: []Maybe(string)) -> Value {
    f := &closure.fn_node.data.(Node_Function)
    frame := alloc_frame(closure.fn_node, f.num_slots, closure.env)

    positional_idx := 0
    for param in f.params {
        bound := false

        // A named argument ("f(b = 2)") can fill any param, out of order.
        for a, ai in args {
            if name, has_name := arg_names[ai].?; has_name && name == param.name {
                frame.slots[param.resolved.slot].value = a
                bound = true
                break
            }
        }

        // Otherwise take the next unclaimed positional argument.
        if !bound {
            for positional_idx < len(args) {
                if _, has_name := arg_names[positional_idx].?; has_name {
                    positional_idx += 1 // named args don't consume a positional slot
                    continue
                }
                frame.slots[param.resolved.slot].value = args[positional_idx]
                positional_idx += 1
                bound = true
                break
            }
        }

        // Still nothing? Fall back to the default, evaluated in the
        // NEW frame so a later default can refer to an earlier param.
        if !bound && param.default != nil {
            prev := interp.frame
            interp.frame = frame
            frame.slots[param.resolved.slot].value = eval_expr(interp, param.default)
            interp.frame = prev
        }
    }

    prev := interp.frame
    interp.frame = frame
    defer interp.frame = prev

    if f.is_arrow {
        return eval_expr(interp, f.body)
    }
    res := exec_block(interp, f.body)
    return res.value // nil (no return) if the body fell off the end
}
