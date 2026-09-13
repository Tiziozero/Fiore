package main

import "core:strconv"

BinopKind :: enum {
    Addition,
    Subtraction,
    Multiply,
    Divide,
    Modulo,
    Equal,
    NotEqual,
    LessEqual,
    GreaterEqual,
    Less,
    Greater,
    LogicalAnd,
    LogicalOr,
    BitAnd,
    BitOr,
    BitXor,
};
UnaryKind :: enum {
    Negative,
    Not,
};

Node_Kind :: enum {
    Number,
    String,
    Name,

    Binary,
    Unary,
    Assign,

    Call,
    Function,

    Array,
    Object,

    If,
    While,
    Return,
    Block,
}

Node :: struct {
    kind: Node_Kind,
    pos:  Span,

    data: union {
        Node_Number,
        Node_String,
        Node_Name,
        Node_Binary,
        Node_Unary,
        Node_Assign,
        Node_Call,
        Node_Function,
        Node_Array,
        Node_Object,
        Node_If,
        Node_Return,
        Node_Block,
    },
}

// value is nil for a bare "return;" / "return" with no expression.
// Multiple return values aren't a separate case -- "return [1, 2]"
// just puts an .Array node here, and whoever consumes Node_Return
// (typechecker / codegen) is responsible for treating an array value
// as a multi-return when the function signature says so.
Node_Return :: struct {
    value: ^Node,
}

Node_Number :: struct {
    value: f64,
}

Node_String :: struct {
    value: string,
}

// resolved is filled in by the resolver pass (nil until then). It's
// the SAME Symbol object as any other reference to this variable --
// identity is what lets the resolver mark "captured" on a symbol found
// via one Node_Name and have that stick when codegen later looks at
// the same symbol via a different Node_Name.
Node_Name :: struct {
    name:     string,
    resolved: ^Symbol,
    hops:     int,
}

Node_Binary :: struct {
    op:     BinopKind,
    left:   ^Node,
    right:  ^Node,
}

Node_Unary :: struct {
    op:   UnaryKind,
    expr: ^Node,
}

Node_Assign :: struct {
    target: ^Node,
    value:  ^Node,
    op:     Maybe(BinopKind),
}

// name is nil for a positional argument ("f(1, 2)"), and set for a
// named/keyword argument ("f(b = 2)"). Matching a named arg to a
// param is a later (typecheck/codegen) concern -- the parser just
// records the name that was given.
Node_Arg :: struct {
    name:  Maybe(string),
    value: ^Node,
}

Node_Call :: struct {
    function: ^Node,
    args:     []Node_Arg,
}

Node_Param :: struct {
    name:     string,
    default:  ^Node, // nil if no default value
    resolved: ^Symbol,
}

// captures is populated by the resolver: every Symbol OWNED by this
// function that some nested function literal ended up referencing.
// Empty for a function that doesn't create any closures over its own
// locals. Codegen uses this to know what a closure object allocated
// for THIS function needs to carry pointers to.
//
// num_slots is also filled in by the resolver (resolve_function),
// once every name in this function's body (including nested blocks,
// which share this function's slot counter) has been hoisted: it's
// the total count of local-variable slots this function's activation
// needs, i.e. what the interpreter/codegen sizes each call frame to.
Node_Function :: struct {
    params:    []Node_Param,
    body:      ^Node, // .Block node, or an expression node if is_arrow
    is_arrow:  bool,
    captures:  []^Symbol,
    num_slots: int,
}

Node_Array :: struct {
    elements: []^Node,
}

Node_Object_Field :: struct {
    name:  string,
    value: ^Node,
}

Node_Object :: struct {
    fields: []Node_Object_Field,
}

Node_If :: struct {
    condition:   ^Node,
    then_body:   ^Node,
    else_body:   ^Node,
}

Node_Block :: struct {
    statements: []^Node,
}

Parser :: struct {
    tokens: []Token,
    pos:    int,
}

AST :: struct {
    nodes: []^Node,
}

parse_tokens :: proc(buf: string, tokens: []Token) -> AST {
    p := new(Parser)
    p.tokens = tokens
    p.pos = 0

    nodes := make([dynamic]^Node, context.temp_allocator)
    for !is_at_end(p) {
        n := parse_stmt(p)
        append(&nodes, n)
    }
    return AST{nodes = nodes[:]}
}

new_node :: proc(p: ^Parser, kind: Node_Kind) -> ^Node {
    node := new(Node, context.temp_allocator)
    node.kind = kind
    return node
}

// ---------------------------------------------------------------------
// Token navigation
// ---------------------------------------------------------------------

current_token :: proc(p: ^Parser) -> Token {
    if p.pos >= len(p.tokens) {
        return p.tokens[len(p.tokens) - 1]
    }
    return p.tokens[p.pos]
}

peek_token :: proc(p: ^Parser, offset: int = 1) -> Token {
    idx := p.pos + offset
    if idx >= len(p.tokens) {
        return p.tokens[len(p.tokens) - 1]
    }
    if idx < 0 {
        return p.tokens[0]
    }
    return p.tokens[idx]
}

previous_token :: proc(p: ^Parser) -> Token {
    if p.pos == 0 {
        return p.tokens[0]
    }
    return p.tokens[p.pos - 1]
}

is_at_end :: proc(p: ^Parser) -> bool {
    return p.pos >= len(p.tokens) || current_token(p).kind == .EOF
}

advance_token :: proc(p: ^Parser) -> Token {
    tok := current_token(p)
    if !is_at_end(p) {
        p.pos += 1
    }
    return tok
}

check_token :: proc(p: ^Parser, kind: TokenKind) -> bool {
    if is_at_end(p) {
        return kind == .EOF
    }
    return current_token(p).kind == kind
}

match_token :: proc(p: ^Parser, kind: TokenKind) -> bool {
    if check_token(p, kind) {
        advance_token(p)
        return true
    }
    return false
}

match_any :: proc(p: ^Parser, kinds: ..TokenKind) -> (Token, bool) {
    for kind in kinds {
        if check_token(p, kind) {
            return advance_token(p), true
        }
    }
    return Token{}, false
}

expect_token :: proc(p: ^Parser, kind: TokenKind) -> Token {
    if check_token(p, kind) {
        return advance_token(p)
    }
    tok := current_token(p)
    highlight_lines(tok.span)
    panicf("parse error: expected token kind %v, got %v", kind, tok.kind)
}

is_symbol :: proc(t: Token, s: string) -> bool {
    if t.kind == .Symbol && t.text == s { return true }
    return false
}

expect_symbol :: proc(p: ^Parser, s: string) -> Token {
    t := current_token(p)
    if !is_symbol(t, s) {
        highlight_lines(t.span)
        panicf("parse error: expected symbol \"%s\", got \"%s\"", s, t.text)
    }
    return advance_token(p)
}

// Assumes Token has kind == .Keyword and a `kw: Keyword` field, mirroring
// gala's is_kw. If your lexer represents keywords differently (e.g.
// plain .Ident with text == "return"), change this one proc.
is_kw :: proc(t: Token, k: Keyword) -> bool {
    if t.kind == .Keyword && t.kw == k { return true }
    return false
}

// Eats a trailing ";" if present. Semicolons are optional in this
// grammar, so this is never required -- just consumed when present.
maybe_consume_semicolon :: proc(p: ^Parser) {
    if is_symbol(current_token(p), ";") {
        advance_token(p)
    }
}

// ---------------------------------------------------------------------
// Operator tables
// ---------------------------------------------------------------------

op_kind :: proc(t: Token) -> (kind: BinopKind, ok: bool) {
    switch t.text {
    case "+":  return .Addition,     true
    case "-":  return .Subtraction,  true
    case "*":  return .Multiply,     true
    case "/":  return .Divide,       true
    case "%":  return .Modulo,       true
    case "==": return .Equal,        true
    case "!=": return .NotEqual,     true
    case "<=": return .LessEqual,    true
    case ">=": return .GreaterEqual, true
    case "<":  return .Less,         true
    case ">":  return .Greater,      true
    case "&&": return .LogicalAnd,   true
    case "||": return .LogicalOr,    true
    case "&":  return .BitAnd,       true
    case "~":  return .BitXor,       true
    case "|":  return .BitOr,        true
    }
    return {}, false
}

op_precedence :: proc(t: Token) -> int {
    switch t.text {
    case "||":
        return 1
    case "&&":
        return 2
    case "|":
        return 3
    case "~":
        return 4
    case "&":
        return 5
    case "==", "!=", "<=", ">=", "<", ">":
        return 6
    case "+", "-":
        return 7
    case "*", "/", "%":
        return 8
    }
    return -1
}

op_is_right_assoc :: proc(t: Token) -> bool {
    return false // extend for ** etc.
}

// Maps a compound-assignment token ("+=", "-=", ...) to the BinopKind
// it desugars to. `target += value` becomes `target = target + value`.
compound_assign_op :: proc(t: Token) -> (kind: BinopKind, ok: bool) {
    switch t.text {
    case "+=": return .Addition,    true
    case "-=": return .Subtraction, true
    case "*=": return .Multiply,    true
    case "/=": return .Divide,      true
    case "%=": return .Modulo,      true
    case "&=": return .BitAnd,      true
    case "|=": return .BitOr,       true
    case "~=": return .BitXor,      true
    }
    return {}, false
}

// ---------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------

// Only .Name is a valid assignment target for now. Once field access
// and indexing exist as expression nodes, add their kinds here.
is_assignable_target :: proc(n: ^Node) -> bool {
    return n.kind == .Name
}

parse_stmt :: proc(p: ^Parser) -> ^Node {
    if is_kw(current_token(p), .Return) {
        tok := advance_token(p) // "return"

        node := new_node(p, .Return)
        node.pos = tok.span

        // Bare "return;" / "return" at end of block -- no value.
        if is_symbol(current_token(p), ";") || is_symbol(current_token(p), "}") || is_at_end(p) {
            node.data = Node_Return{value = nil}
            maybe_consume_semicolon(p)
            return node
        }

        value := parse_expr(p) // "return [1, 2]" is just an array-literal value here
        node.data = Node_Return{value = value}
        maybe_consume_semicolon(p)
        return node
    }

    expr := parse_expr(p)

    if is_symbol(current_token(p), "=") {
        advance_token(p) // "="
        if !is_assignable_target(expr) {
            highlight_lines(expr.pos)
            panicf("parse error: invalid assignment target (kind %v)", expr.kind)
        }
        value := parse_expr(p)
        node := new_node(p, .Assign)
        node.pos = expr.pos
        node.data = Node_Assign{target = expr, value = value, op = nil}
        maybe_consume_semicolon(p)
        return node
    }

    if kind, ok := compound_assign_op(current_token(p)); ok {
        advance_token(p) // e.g. "+="
        if !is_assignable_target(expr) {
            highlight_lines(expr.pos)
            panicf("parse error: invalid assignment target (kind %v)", expr.kind)
        }
        value := parse_expr(p)
        node := new_node(p, .Assign)
        node.pos = expr.pos
        node.data = Node_Assign{target = expr, value = value, op = kind}
        maybe_consume_semicolon(p)
        return node
    }

    maybe_consume_semicolon(p)
    return expr
}

// ---------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------

parse_expr :: proc(p: ^Parser) -> ^Node {
    return parse_binop(p, 0)
}

parse_binop :: proc(p: ^Parser, min_prec: int) -> ^Node {
    lhs := parse_unary(p)

    for {
        op := current_token(p)
        prec := op_precedence(op)
        if prec < min_prec { break }

        advance_token(p)

        next_min := prec + (0 if op_is_right_assoc(op) else 1)
        rhs := parse_binop(p, next_min)

        kind, _ := op_kind(op)
        node := new_node(p, .Binary)
        node.pos = lhs.pos
        node.data = Node_Binary{op = kind, left = lhs, right = rhs}
        lhs = node
    }

    return lhs
}

parse_unary :: proc(p: ^Parser) -> ^Node {
    if is_symbol(current_token(p), "-") {
        tok := advance_token(p) // "-"
        expr := parse_unary(p)
        node := new_node(p, .Unary)
        node.pos = tok.span
        node.data = Node_Unary{op = .Negative, expr = expr}
        return node
    } else if is_symbol(current_token(p), "!") {
        tok := advance_token(p) // "!"
        expr := parse_unary(p)
        node := new_node(p, .Unary)
        node.pos = tok.span
        node.data = Node_Unary{op = .Not, expr = expr}
        return node
    }
    return parse_postfix(p)
}

parse_postfix :: proc(p: ^Parser) -> ^Node {
    t := parse_primary(p)

    for {
        if is_symbol(current_token(p), "(") {
            advance_token(p) // "("
            args := make([dynamic]Node_Arg, context.temp_allocator)
            for !is_symbol(current_token(p), ")") {
                // Named argument: IDENT "=" expr. One-token lookahead --
                // if it's not this exact shape, fall through to a plain
                // positional expression. "==" is a distinct token from
                // your lexer so this can't misfire on a comparison.
                if current_token(p).kind == .Ident && is_symbol(peek_token(p), "=") {
                    name := advance_token(p) // ident
                    advance_token(p)         // "="
                    value := parse_expr(p)
                    append(&args, Node_Arg{name = name.text, value = value})
                } else {
                    value := parse_expr(p)
                    append(&args, Node_Arg{name = nil, value = value})
                }

                if is_symbol(current_token(p), ",") {
                    advance_token(p)
                } else {
                    break
                }
            }
            expect_symbol(p, ")")

            node := new_node(p, .Call)
            node.pos = t.pos
            node.data = Node_Call{function = t, args = args[:]}
            t = node
        } else if is_symbol(current_token(p), ".") {
            // TODO: field access node once you settle the field-access AST shape
            break
        } else if is_symbol(current_token(p), "[") {
            // TODO: index node once you settle the index AST shape
            break
        } else {
            break
        }
    }

    return t
}

// looks_like_function_literal assumes current_token(p) is "(".
// Scans forward at the TOKEN level (not text) to find the matching ")",
// then checks whether the token right after it is "=>" or "{". No
// backtracking, no speculative parsing -- just a depth count.
looks_like_function_literal :: proc(p: ^Parser) -> bool {
    depth := 0
    i := p.pos
    for i < len(p.tokens) {
        t := p.tokens[i]
        if is_symbol(t, "(") {
            depth += 1
        } else if is_symbol(t, ")") {
            depth -= 1
            if depth == 0 {
                if i + 1 < len(p.tokens) {
                    next := p.tokens[i + 1]
                    return is_symbol(next, "=>") || is_symbol(next, "{")
                }
                return false
            }
        }
        i += 1
    }
    return false
}

parse_function_literal :: proc(p: ^Parser) -> ^Node {
    open := expect_symbol(p, "(")

    params := make([dynamic]Node_Param, context.temp_allocator)
    for !is_symbol(current_token(p), ")") {
        name := current_token(p)
        if name.kind != .Ident {
            highlight_lines(name.span)
            panicf("parse error: expected parameter name, got %v", name.kind)
        }
        advance_token(p)

        default: ^Node = nil
        if is_symbol(current_token(p), "=") {
            advance_token(p) // "="
            default = parse_expr(p)
        }

        append(&params, Node_Param{name = name.text, default = default})

        if is_symbol(current_token(p), ",") {
            advance_token(p)
        } else {
            break
        }
    }
    expect_symbol(p, ")")

    node := new_node(p, .Function)
    node.pos = open.span

    if is_symbol(current_token(p), "=>") {
        advance_token(p) // "=>"
        body := parse_expr(p)
        node.data = Node_Function{params = params[:], body = body, is_arrow = true}
    } else {
        body := parse_block(p)
        node.data = Node_Function{params = params[:], body = body, is_arrow = false}
    }

    return node
}

parse_block :: proc(p: ^Parser) -> ^Node {
    open := expect_symbol(p, "{")

    stmts := make([dynamic]^Node, context.temp_allocator)
    for !is_symbol(current_token(p), "}") && current_token(p).kind != .EOF {
        append(&stmts, parse_stmt(p))
    }
    expect_symbol(p, "}")

    node := new_node(p, .Block)
    node.pos = open.span
    node.data = Node_Block{statements = stmts[:]}
    return node
}

parse_array_literal :: proc(p: ^Parser) -> ^Node {
    open := expect_symbol(p, "[")

    elements := make([dynamic]^Node, context.temp_allocator)
    for !is_symbol(current_token(p), "]") {
        append(&elements, parse_expr(p))
        if is_symbol(current_token(p), ",") {
            advance_token(p)
        } else {
            break
        }
    }
    expect_symbol(p, "]")

    node := new_node(p, .Array)
    node.pos = open.span
    node.data = Node_Array{elements = elements[:]}
    return node
}

parse_object_literal :: proc(p: ^Parser) -> ^Node {
    open := expect_symbol(p, "{")

    fields := make([dynamic]Node_Object_Field, context.temp_allocator)
    for !is_symbol(current_token(p), "}") {
        name := current_token(p)
        if name.kind != .Ident {
            highlight_lines(name.span)
            panicf("parse error: expected field name, got %v", name.kind)
        }
        advance_token(p)
        expect_symbol(p, "=")
        value := parse_expr(p)
        append(&fields, Node_Object_Field{name = name.text, value = value})
        if is_symbol(current_token(p), ",") {
            advance_token(p)
        } else {
            break
        }
    }
    expect_symbol(p, "}")

    node := new_node(p, .Object)
    node.pos = open.span
    node.data = Node_Object{fields = fields[:]}
    return node
}

parse_primary :: proc(p: ^Parser) -> ^Node {
    tok := current_token(p)

    if tok.kind == .Number {
        advance_token(p)
        val, ok := strconv.parse_f64(tok.text)
        if !ok {
            highlight_lines(tok.span)
            panicf("parse error: invalid number literal \"%s\"", tok.text)
        }
        node := new_node(p, .Number)
        node.pos = tok.span
        node.data = Node_Number{value = val}
        return node
    } else if tok.kind == .String {
        advance_token(p)
        node := new_node(p, .String)
        node.pos = tok.span
        node.data = Node_String{value = tok.text}
        return node
    } else if tok.kind == .Ident {
        advance_token(p)
        node := new_node(p, .Name)
        node.pos = tok.span
        node.data = Node_Name{name = tok.text}
        return node
    } else if is_symbol(tok, "(") {
        if looks_like_function_literal(p) {
            return parse_function_literal(p)
        }
        advance_token(p) // "("
        e := parse_expr(p)
        expect_symbol(p, ")")
        return e
    } else if is_symbol(tok, "[") {
        return parse_array_literal(p)
    } else if is_symbol(tok, "{") {
        return parse_object_literal(p)
    }

    highlight_lines(tok.span)
    panicf("parse error: invalid primary token %v", tok.kind)
}
