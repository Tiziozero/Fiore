package main

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

Module_State :: enum {
    Loading,  // lex/parse/resolve in progress -- seeing this again means a cycle
    Resolved,
}

// One per distinct .fio file in the program, keyed by normalized path.
// ast/decs live here (not on the stack) because other modules point
// into them: Node_Import.module, and the exports map in decs.
Module :: struct {
    path:  string,
    state: Module_State,
    ast:   AST,
    decs:  ModuleDecs,

    // Runtime: set the first time run_module executes this module, so
    // a module imported from several places only runs once.
    ran:   bool,
    frame: ^Frame, // the module's top-level frame, valid once ran
}

modules: map[string]^Module

// Root directory that non-relative imports ("internal/fio/file.fio")
// resolve against. Placeholder for now: the directory containing the
// executable. Change this one proc when you decide on a real stdlib
// location.
get_fio_internal_path :: proc() -> string {
    return path_dir(os.args[0])
}

path_dir :: proc(path: string) -> string {
    i := strings.last_index_byte(path, '/')
    if i < 0 { return "." }
    if i == 0 { return "/" }
    return path[:i]
}

// Collapses "." and ".." segments and duplicate slashes so the same
// file always produces the same module key (needed for the cache and
// for cycle detection). Purely textual -- doesn't touch the disk or
// follow symlinks.
normalize_path :: proc(path: string) -> string {
    absolute := len(path) > 0 && path[0] == '/'
    parts := strings.split(path, "/", context.temp_allocator)
    out := make([dynamic]string, context.temp_allocator)
    for part in parts {
        switch part {
        case "", ".":
            continue
        case "..":
            if len(out) > 0 && out[len(out) - 1] != ".." {
                pop(&out)
            } else if !absolute {
                append(&out, "..")
            }
        case:
            append(&out, part)
        }
    }
    joined := strings.join(out[:], "/", context.temp_allocator)
    if absolute {
        return strings.clone(fmt.tprintf("/%s", joined))
    }
    if len(joined) == 0 {
        return "."
    }
    return strings.clone(joined)
}

// "./x" and "../x" are relative to the importing file; "/x" is
// absolute; anything else is looked up under get_fio_internal_path().
resolve_import_path :: proc(importer: string, spec: string) -> string {
    if strings.has_prefix(spec, "/") {
        return normalize_path(spec)
    }
    if strings.has_prefix(spec, "./") || strings.has_prefix(spec, "../") {
        return normalize_path(fmt.tprintf("%s/%s", path_dir(importer), spec))
    }
    return normalize_path(fmt.tprintf("%s/%s", get_fio_internal_path(), spec))
}

// Lex + parse + resolve one file's source into a Module, registering
// it as Loading first so an import cycle back to it is detected.
// Shared by the entry file (handle_file) and every import.
load_module_source :: proc(path: string, data: []byte) -> ^Module {
    ctx := get_ctx()

    // highlight_lines reports against ctx.current_file, so point it at
    // the file being loaded and put it back afterwards -- errors in the
    // IMPORTING file raised after this returns must still highlight
    // the right source.
    prev_file := ctx.current_file
    ctx.files[path] = string(data)
    ctx.current_file = path

    mod := new(Module)
    mod.path = path
    mod.state = .Loading
    modules[path] = mod

    tokens := lex_file(data)
    defer delete(tokens)

    debugln("PARSING FILE", path)
    mod.ast = parse_tokens(string(data), tokens[:])

    debugln("RESOLVING SYMBOLS", path)
    // builtin_names() reads off interpreter.odin's builtins_registry
    // -- "print", "len", "type_of", and anything else registered
    // there -- so this list never needs editing by hand here again.
    mod.decs = resolve_module_ast(&mod.ast, builtin_names())

    mod.state = .Resolved
    ctx.current_file = prev_file
    return mod
}

// Called by the resolver for each import statement. `pos` is the
// import's span, for error reporting in the importing file.
load_module :: proc(spec: string, pos: Span) -> ^Module {
    ctx := get_ctx()
    path := resolve_import_path(ctx.current_file, spec)

    if mod, ok := modules[path]; ok {
        if mod.state == .Loading {
            highlight_lines(pos)
            panicf("circular import of \"%s\"", spec)
        }
        return mod // already loaded via some other import
    }

    data, err := os.read_entire_file(path, ctx.allocator)
    if err != io.Error.None {
        highlight_lines(pos)
        panicf("cannot read module \"%s\" (looked for %s)", spec, path)
    }
    return load_module_source(path, data)
}

// Executes a module's top level exactly once. Its imports are run
// first, from inside run_program.
run_module :: proc(mod: ^Module) {
    if mod.ran { return }
    mod.ran = true
    mod.frame = run_program(&mod.ast, mod.decs)
}
