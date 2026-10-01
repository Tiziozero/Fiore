package main

// ---------------------------------------------------------------------
// Symbols and scopes
// ---------------------------------------------------------------------

Scope_Kind :: enum {
    Global,
    Function,
    Block, // if/while bodies -- new declarations don't leak out of these,
           // but lookups still search straight through them into the
           // owning function (and beyond, into enclosing functions).
}

// One Symbol per distinct variable in the whole program. Identity
// matters here, not just the name -- this is the object codegen and
// the interpreter point back to whenever they need "where does this
// variable's storage actually live", so it has to persist as long as
// the AST does (same lifetime concern as the AST arena itself).
Symbol :: struct {
    name:     string,
    // The Node_Function this variable's storage belongs to. nil = global.
    owner_fn: ^Node,
    // Flipped to true the moment ANY nested function is found to
    // reference this symbol from inside its own body. Consumed later
    // by codegen to decide "does this local need to be a heap cell
    // instead of a plain stack slot".
    captured: bool,
    // Index into owner_fn's locals array, assigned once at
    // declaration time. Pure storage-layout bookkeeping, not type
    // info -- lets the interpreter/codegen use array-indexed
    // environments instead of a hash map on every name access.
    slot:     int,
    // Set once this symbol's own assignment has actually been
    // sequentially resolved (as opposed to merely predeclared by
    // predeclare_names). Only enforced for same-function references
    // (hops == 0) -- a reference that crosses a function boundary is
    // a closure over storage that will exist by call time, so it's
    // allowed to see a declared-but-not-yet-defined symbol.
    defined:  bool,
    // True for a name brought in by "import { name } from ...". Its
    // storage is the exporting module's own cell (the interpreter
    // aliases the slot), so assigning to it here is an error.
    imported: bool,
}

Scope :: struct {
    kind:   Scope_Kind,
    parent: ^Scope,

    // Nearest enclosing scope with kind == .Function (or itself, if
    // this scope IS one). Fresh declarations always attach here -- a
    // Block scope never owns its own declaration set; it exists only
    // so a variable declared inside an if/while body doesn't leak out
    // once the block ends.
    function_scope: ^Scope,

    // The Node_Function this scope belongs to (only meaningful when
    // kind == .Function; nil at global scope).
    owning_fn: ^Node,

    // Linear list, not a map. Functions/blocks have a handful of
    // locals in practice -- a linear scan is simpler and plenty fast.
    symbols: [dynamic]^Symbol,

    // Shared slot counter for the owning function. Lives on the
    // Function-kind scope; nested Block scopes point at the SAME
    // counter (via pointer) so slot numbers keep incrementing across
    // nested blocks instead of restarting or colliding.
    next_slot: ^int,
}

Resolver :: struct {
    current: ^Scope,

    // While resolving the VALUE of a non-function-literal assignment
    // ("x = <expr>", where <expr> isn't directly a function"), this
    // points at x's own Symbol. Any reference to that exact symbol
    // found anywhere inside <expr> -- including buried inside a
    // nested closure -- is an error: x doesn't have a value yet, and
    // unlike an ordinary forward reference to some OTHER symbol
    // (which will exist by the time any closure referencing it is
    // actually invoked), a name can't meaningfully see its own
    // not-yet-computed value. nil when not currently resolving such
    // a value. Saved/restored around each assignment via the call
    // stack, so nested assignments (a function body inside this RHS
    // that contains its own separate "y = ..." statements) nest
    // correctly for free.
    //
    // Deliberately NOT set for a direct function-literal RHS
    // ("f = () { ... f() ... }") -- that's the one shape allowed to
    // see its own target, which is what makes named self-recursion
    // possible.
    resolving_target: ^Symbol,
}

// ---------------------------------------------------------------------
// Scope stack management
// ---------------------------------------------------------------------

enter_function_scope :: proc(r: ^Resolver, owning_fn: ^Node) -> ^Scope {
    s := new(Scope)
    s.kind = .Function
    s.parent = r.current
    s.owning_fn = owning_fn
    s.symbols = make([dynamic]^Symbol)
    slot := new(int)
    slot^ = 0
    s.next_slot = slot
    s.function_scope = s
    r.current = s
    return s
}

enter_block_scope :: proc(r: ^Resolver) -> ^Scope {
    s := new(Scope)
    s.kind = .Block
    s.parent = r.current
    s.function_scope = r.current.function_scope
    s.owning_fn = s.function_scope.owning_fn
    s.symbols = make([dynamic]^Symbol)
    s.next_slot = s.function_scope.next_slot // shared counter
    r.current = s
    return s
}

exit_scope :: proc(r: ^Resolver) {
    r.current = r.current.parent
}

// Declares a brand-new symbol, always attached to the current
// FUNCTION scope (never a Block scope -- see .function_scope above),
// and assigns it the next slot in that function. Starts out
// "declared but not defined" -- see Symbol.defined.
declare_symbol :: proc(r: ^Resolver, name: string) -> ^Symbol {
    fs := r.current.function_scope
    sym := new(Symbol)
    sym.name = name
    sym.owner_fn = fs.owning_fn
    sym.slot = fs.next_slot^
    fs.next_slot^ += 1
    sym.defined = false
    append(&fs.symbols, sym)
    return sym
}

// Searches outward from the current scope. Returns how many FUNCTION
// boundaries were crossed to find it: 0 = declared in the current
// function (a plain local), >0 = declared in an enclosing function
// (this is a capture -- an upvalue).
lookup_symbol :: proc(r: ^Resolver, name: string) -> (sym: ^Symbol, fn_hops: int, found: bool) {
    cur := r.current
    hops := 0
    for cur != nil {
        for s in cur.symbols {
            if s.name == name {
                return s, hops, true
            }
        }
        if cur.kind == .Function {
            hops += 1
        }
        cur = cur.parent
    }
    return nil, 0, false
}

// ---------------------------------------------------------------------
// Predeclaration (hoisting)
// ---------------------------------------------------------------------

// Scans a function body up front for every plain assignment target
// ("name = ..."), REGARDLESS of what kind the value is, declaring
// each ONCE in the CURRENT function's scope -- declared, but not yet
// defined. Recurses into nested Block nodes (if/while bodies, once
// those exist) since a Block scope doesn't own its own declarations
// anyway (see Scope.function_scope). Stops dead at Function
// boundaries: a nested function literal's own locals get predeclared
// separately, when THAT function's body is resolved.
//
// Field / index targets ("a.b = ...", "a[i] = ...") never declare
// anything -- they mutate an object that must already exist -- so
// they're skipped here.
//
// Two things fall out of hoisting every target up front like this,
// matching how Python decides local-vs-outer per function:
//
//   - Forward references across SIBLING statements work, e.g.
//       e = () { print(1) }
//       print = () => {}
//     print is predeclared before e's body is ever resolved, so the
//     reference inside e finds it (hops > 0, so it's an ordinary
//     closure over a binding that will exist by call time -- see
//     Symbol.defined). Same mechanism gives you mutual recursion
//     between two function literals in the same scope.
//
//   - A plain assignment can no longer reach OUTWARD past its own
//     function to mutate an enclosing variable of the same name --
//     "c = a + b" inside a function finds that function's own
//     (predeclared) local c before the search ever reaches an outer
//     c, exactly like Python: assigned anywhere in a function =
//     local to that function, full stop.
//
// What this does NOT do is let a statement's value see ITS OWN
// target early -- that's a separate, narrower restriction; see
// Resolver.resolving_target and resolve_stmt's .Assign case.
predeclare_names :: proc(r: ^Resolver, node: ^Node) {
    #partial switch node.kind {
    case .Assign:
        a := &node.data.(Node_Assign)
        if a.target.kind != .Name {
            return
        }
        name := a.target.data.(Node_Name).name
        fs := r.current.function_scope
        for s in fs.symbols {
            if s.name == name {
                return // already predeclared (e.g. reassigned later in the same body)
            }
        }
        declare_symbol(r, name)

    case .Block:
        b := &node.data.(Node_Block)
        for stmt in b.statements {
            predeclare_names(r, stmt)
        }

    // TODO: .If, .While once parse_stmt actually produces them --
    // recurse into every branch/body the same way .Block does.

    case:
        // Anything else (a bare expression statement, a Return, ...)
        // can't itself be a name-declaring assignment at this level.
    }
}

// ---------------------------------------------------------------------
// Resolving names
// ---------------------------------------------------------------------

// Used for a NAME REFERENCE (reading a variable, calling it, etc).
// Never declares -- referencing a name that doesn't exist ANYWHERE in
// the enclosing chain is a compile-time error. Referencing a name that
// exists in the CURRENT function but hasn't been sequentially defined
// yet (predeclared only) is also an error -- "used before assignment".
// A reference that crosses a function boundary to reach an outer,
// predeclared-but-not-yet-defined symbol is fine: that's an ordinary
// forward reference to a closure, and by the time this code actually
// runs the outer assignment will have executed.
resolve_name_ref :: proc(r: ^Resolver, node: ^Node) {
    n := &node.data.(Node_Name)
    sym, hops, found := lookup_symbol(r, n.name)
    if !found {
        highlight_lines(node.pos)
        panicf("undefined variable \"%s\"", n.name)
    }
    // Checked BEFORE the hops/defined check below, and regardless of
    // hops: a name referencing itself inside its own not-yet-finished
    // initializer is nonsense no matter how deeply it's nested (even
    // inside a closure created as part of that same initializer) --
    // it doesn't have a value to close over yet. This is what makes
    //   g = f(() => 1 + 2*b*g, b = 2)
    // an error: g is mid-initialization when that arrow function is
    // resolved, so the reference to g inside it hits this check even
    // though it crosses a function boundary (hops > 0).
    if sym == r.resolving_target {
        highlight_lines(node.pos)
        panicf("variable \"%s\" referenced in its own initializer", n.name)
    }
    if hops == 0 && !sym.defined {
        highlight_lines(node.pos)
        panicf("variable \"%s\" used before assignment", n.name)
    }
    if hops > 0 {
        sym.captured = true
    }
    n.resolved = sym
}

// Used for an ASSIGNMENT TARGET. Because predeclare_names has already
// walked this function's body up front, the target should almost
// always already exist as a LOCAL symbol (hops == 0) by the time we
// get here -- this just looks it up and marks it defined. The
// declare_symbol fallback below only matters for shapes
// predeclare_names doesn't see and should not normally trigger for
// plain names.
//
// Note this is now intentionally NOT "search outward and mutate
// whatever's found": predeclaration means a same-named symbol in an
// enclosing function is never what gets hit here, so plain assignment
// can no longer reach through a function boundary to mutate an outer
// variable. Want that back later (Lua-style upvalue mutation)? Add an
// explicit keyword (e.g. "nonlocal x") rather than relying on the
// generic search.
//
// (Mutating THROUGH an outer variable -- "outer.field = 1" -- is fine:
// that's a read of "outer", handled by resolve_name_ref.)
resolve_assign_target :: proc(r: ^Resolver, node: ^Node) -> ^Symbol {
    n := &node.data.(Node_Name)
    sym, hops, found := lookup_symbol(r, n.name)
    if !found {
        sym = declare_symbol(r, n.name) // fallback; predeclare_names should normally cover this
    } else if hops > 0 {
        sym.captured = true // vestigial for plain Name targets now that predeclare shadows first
    }
    if sym.imported {
        highlight_lines(node.pos)
        panicf("cannot assign to imported name \"%s\"", n.name)
    }
    sym.defined = true
    n.resolved = sym
    return sym
}

// ---------------------------------------------------------------------
// Imports
// ---------------------------------------------------------------------

// Loads (lex/parse/resolve, recursively) the module an import points
// at, then declares one local symbol in the importing module per
// imported name. The local symbol is just a placeholder with its own
// slot; at runtime the interpreter points that slot at the exporting
// module's cell, so both modules share storage.
//
// If the name is already declared at this level -- a builtin like
// "print" -- the import takes it over, the same way an ordinary
// "print = ..." would.
resolve_import :: proc(r: ^Resolver, node: ^Node) {
    imp := &node.data.(Node_Import)
    mod := load_module(imp.path, node.pos)
    imp.module = mod

    fs := r.current.function_scope
    for &n in imp.names {
        exported, ok := mod.decs.exports[n.name]
        if !ok {
            highlight_lines(n.pos)
            panicf("module \"%s\" has no export \"%s\"", imp.path, n.name)
        }

        existing: ^Symbol = nil
        for s in fs.symbols {
            if s.name == n.name {
                existing = s
                break
            }
        }

        sym: ^Symbol
        if existing != nil {
            if existing.imported {
                highlight_lines(n.pos)
                panicf("name \"%s\" is imported more than once", n.name)
            }
            sym = existing
        } else {
            sym = declare_symbol(r, n.name)
        }
        sym.imported = true
        sym.defined = true
        n.resolved = sym
        n.exported = exported
    }
}

// ---------------------------------------------------------------------
// AST traversal
// ---------------------------------------------------------------------

// num_slots mirrors Node_Function.num_slots but for the implicit
// top-level "function" -- module code isn't itself a Node_Function,
// so there's nowhere else to hang this number. The interpreter needs
// it to size the top-level Frame.
//
// builtins hands the interpreter the Symbols for whatever names in
// builtin_names got predeclared here before user code was resolved,
// so it can find the right Cell to install each builtin's runtime
// value into -- see run_program in interpreter.odin. The resolver
// deliberately doesn't know what any of these names DO (that's
// interpreter.odin's builtins_registry) -- it just reserves the
// names, the same way it would for anything else predeclared ahead
// of user code.
//
// exports maps each name declared with "export x = ..." to its Symbol,
// so a module that imports this one can find the right Cell.
ModuleDecs :: struct {
    num_slots: int,
    builtins:  map[string]^Symbol,
    exports:   map[string]^Symbol,
}

resolve_module_ast :: proc(ast: ^AST, builtin_names: []string) -> ModuleDecs {
    r := Resolver{}
    enter_function_scope(&r, nil) // implicit top-level "function"

    // Builtins are predeclared exactly like any hoisted name, just
    // before user code gets a chance to declare anything -- so
    // ordinary lookup_symbol calls find e.g. "print" like any other
    // global, and shadowing one with "print = ..." works the same way
    // shadowing any other predeclared name would.
    builtins := make(map[string]^Symbol)
    for name in builtin_names {
        sym := declare_symbol(&r, name)
        sym.defined = true
        builtins[name] = sym
    }

    // Imports are hoisted: every one is resolved before anything else
    // in the module, regardless of where it appears among the
    // top-level statements. (Imports nested inside a block or function
    // are rejected later, in resolve_stmt.)
    for stmt in ast.nodes {
        if stmt.kind == .Import {
            resolve_import(&r, stmt)
        }
    }

    for stmt in ast.nodes {
        predeclare_names(&r, stmt)
    }
    for stmt in ast.nodes {
        resolve_stmt(&r, stmt)
    }

    // Only top-level "export x = ..." statements get here -- anywhere
    // else resolve_stmt already rejected them. (The parser guarantees
    // an exported target is a plain Name.)
    exports := make(map[string]^Symbol)
    for stmt in ast.nodes {
        if stmt.kind == .Assign {
            a := &stmt.data.(Node_Assign)
            if a.exported {
                sym := a.target.data.(Node_Name).resolved
                exports[sym.name] = sym
            }
        }
    }

    fs := r.current.function_scope
    num_slots := fs.next_slot^

    exit_scope(&r)
    return ModuleDecs{num_slots = num_slots, builtins = builtins, exports = exports}
}

resolve_stmt :: proc(r: ^Resolver, node: ^Node) {
    #partial switch node.kind {
    case .Assign:
        a := &node.data.(Node_Assign)

        // At module top level r.current is the global Function scope;
        // inside any block or function it's something else.
        if a.exported && (r.current.kind != .Function || r.current.owning_fn != nil) {
            highlight_lines(node.pos)
            panicf("\"export\" is only allowed at the top level of a module")
        }

        // "a.b = v" / "a[i] = v": nothing is declared. The target
        // expression (object + index) is resolved like any other
        // read, so "a" must already exist and be defined.
        if a.target.kind != .Name {
            resolve_expr(r, a.target)
            resolve_expr(r, a.value)
            return
        }

        // The target is already a known LOCAL symbol (declared, not
        // yet defined) by this point -- predeclare_names hoisted it
        // before this scope's statements were resolved at all. So
        // finding it here is just a lookup, not a fresh declaration.
        target_sym, _, target_found := lookup_symbol(r, a.target.data.(Node_Name).name)

        if a.value.kind == .Function {
            // Named-recursive-function idiom: this is the one shape
            // allowed to see its own target while resolving its
            // value, so "f = () { ... f() ... }" can call itself.
            // Don't touch resolving_target here.
            resolve_expr(r, a.value)
        } else {
            // Every other RHS shape: the target must be invisible to
            // ANY reference inside the value, at any nesting depth,
            // for as long as the value is being resolved -- see
            // resolving_target's doc comment and the check in
            // resolve_name_ref. Saved/restored so a nested assignment
            // inside this value (e.g. a statement inside a closure
            // literal passed as an argument) can't leak its own
            // resolving_target out to the wrong scope.
            prev := r.resolving_target
            if target_found {
                r.resolving_target = target_sym
            }
            resolve_expr(r, a.value)
            r.resolving_target = prev
        }

        resolve_assign_target(r, a.target)

    case .Return:
        ret := &node.data.(Node_Return)
        if ret.value != nil {
            resolve_expr(r, ret.value)
        }

    case .Block:
        resolve_block(r, node)

    case .Import:
        // Top-level imports were already fully handled up front in
        // resolve_module_ast. Reaching one anywhere else means it's
        // nested inside a block or function.
        if r.current.kind != .Function || r.current.owning_fn != nil {
            highlight_lines(node.pos)
            panicf("imports are only allowed at the top level of a module")
        }

    // TODO: .If, .While once parse_stmt actually produces them.

    case:
        resolve_expr(r, node)
    }
}

resolve_block :: proc(r: ^Resolver, node: ^Node) {
    b := &node.data.(Node_Block)
    enter_block_scope(r)
    for stmt in b.statements {
        predeclare_names(r, stmt)
    }
    for stmt in b.statements {
        resolve_stmt(r, stmt)
    }
    exit_scope(r)
}

resolve_expr :: proc(r: ^Resolver, node: ^Node) {
    #partial switch node.kind {
    case .Number, .String:
        // no names involved

    case .Name:
        resolve_name_ref(r, node)

    case .Binary:
        b := &node.data.(Node_Binary)
        resolve_expr(r, b.left)
        resolve_expr(r, b.right)

    case .Unary:
        u := &node.data.(Node_Unary)
        resolve_expr(r, u.expr)

    case .Call:
        c := &node.data.(Node_Call)
        resolve_expr(r, c.function)
        for arg in c.args {
            resolve_expr(r, arg.value)
        }

    case .Array:
        arr := &node.data.(Node_Array)
        for e in arr.elements {
            resolve_expr(r, e)
        }

    case .Object:
        obj := &node.data.(Node_Object)
        for f in obj.fields {
            resolve_expr(r, f.value)
        }

    case .Field:
        f := &node.data.(Node_Field)
        resolve_expr(r, f.object)

    case .Index:
        i := &node.data.(Node_Index)
        resolve_expr(r, i.object)
        resolve_expr(r, i.index)

    case .Function:
        resolve_function(r, node)

    case:
        panicf("resolve_expr: unhandled node kind %v", node.kind)
    }
}

resolve_function :: proc(r: ^Resolver, node: ^Node) {
    f := &node.data.(Node_Function)

    enter_function_scope(r, node)
    for &param in f.params {
        sym := declare_symbol(r, param.name)
        sym.defined = true // params are bound the instant the call happens
        param.resolved = sym
        if param.default != nil {
            resolve_expr(r, param.default)
        }
    }

    if f.is_arrow {
        resolve_expr(r, f.body)
    } else {
        // resolve_block predeclares f.body's own statements into this
        // function scope itself (declare_symbol always attaches to
        // r.current.function_scope, regardless of whether r.current
        // is the function scope directly or a block nested inside
        // it) -- no need to predeclare again here first.
        resolve_block(r, f.body)
    }

    // Collect every symbol OWNED by this function that some nested
    // function ended up capturing -- codegen needs this list to know
    // which locals get heap cells, and what pointers a closure
    // literal created here needs to carry if IT is itself captured by
    // something further out.
    fn_scope := r.current // still the function scope entered above
    captures := make([dynamic]^Symbol)
    for s in fn_scope.symbols {
        if s.captured {
            append(&captures, s)
        }
    }
    f.captures = captures[:]

    // How many local slots this activation needs, total -- includes
    // params, every hoisted name in the body, and everything hoisted
    // in nested blocks (they share this function's slot counter, see
    // Scope.next_slot). The interpreter sizes each call's Frame.slots
    // to this.
    f.num_slots = fn_scope.next_slot^

    exit_scope(r)
}
