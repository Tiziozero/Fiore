package main

import "core:mem/virtual"
import "core:mem"
import "core:fmt"
import "core:os"
import "core:io"
panic :: proc(args: ..any) -> ! {
    fmt.println(..args)
    os.exit(1);
}
panicf :: proc(f: string, args: ..any) -> ! {
    fmt.printfln(f, ..args)
    os.exit(1);
}

init_context :: proc() -> ^Context {
    ctx := new(Context)

    aerr := virtual.arena_init_growing(&ctx.arena)
    assert(aerr == virtual.Allocator_Error.None)
    ctx.allocator = virtual.arena_allocator(&ctx.arena)
    al := ctx.allocator

    ctx.files = make(map[string]string, allocator = al)

    ctx.debug = true
    return ctx
}
destroy_context :: proc(ctx: ^Context) {
    virtual.arena_destroy(&ctx.arena)
    free(ctx)
}



handle_file :: proc(file_name: string) {
    ctx := get_ctx()
    data, err := os.read_entire_file(file_name, ctx.allocator)
    if err != io.Error.None {
        panic("Failed to read file")
    }
    ctx.files[file_name] = string(data)
    ctx.current_file = file_name

    debugln("file size:", len(data));

    tokens := lex_file(data)
    defer delete(tokens)

    debugln("PARSING FILE");
    ast := parse_tokens(string(data), tokens[:])

    debugln("RESOLVING SYMBOLS");
    // builtin_names() reads off interpreter.odin's builtins_registry
    // -- "print", "len", "type_of", and anything else registered
    // there -- so this list never needs editing by hand here again.
    decs := resolve_module_ast(&ast, builtin_names())

    debugln("RUNNING");
    run_program(&ast, decs)
}


main :: proc() {
    context.user_ptr = cast(rawptr)init_context()
    handle_file("example.fio")
    destroy_context(get_ctx())
}
