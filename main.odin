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

    ctx.debug = false
    return ctx
}
destroy_context :: proc(ctx: ^Context) {
    virtual.arena_destroy(&ctx.arena)
    free(ctx)
}



handle_file :: proc(file_name: string) {
    ctx := get_ctx()

    // Normalized so the entry file has the same module key an import
    // of it would produce (this is what catches "a imports main").
    path := normalize_path(file_name)

    data, err := os.read_entire_file(path, ctx.allocator)
    if err != io.Error.None {
        panic("Failed to read file")
    }

    debugln("file size:", len(data));

    // Lexes, parses and resolves the file, recursively loading
    // everything it imports.
    mod := load_module_source(path, data)
    ctx.current_file = path

    debugln("RUNNING");
    run_module(mod)
}


main :: proc() {
    // os.args[0] is the program name, os.args[1] is the first real argument
    if len(os.args) < 2 {
        panicf("usage: %s <file.fio>", os.args[0])
    }
    file_name := os.args[1]

    context.user_ptr = cast(rawptr)init_context()
    handle_file(file_name)
    destroy_context(get_ctx())
}
