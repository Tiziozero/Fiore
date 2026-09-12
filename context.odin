package main

import "core:mem"
import "core:mem/virtual"
import "core:fmt"
import "core:os"
import "core:strings"


Context :: struct {
    arena:              virtual.Arena,
    allocator:          mem.Allocator,
    debug:              bool,

    current_file:       string,
    files:              map[string]string,
}
get_ctx :: proc() -> ^Context {
    return cast(^Context)context.user_ptr;
}
debug :: proc(args: ..any) {
    if !get_ctx().debug do return
    fmt.print(..args)
}

debugln :: proc(args: ..any) {
    if !get_ctx().debug do return
    fmt.println(..args)
}

debugf :: proc(format: string, args: ..any) {
    if !get_ctx().debug do return
    fmt.printf(format, ..args)
}

debugfln :: proc(format: string, args: ..any) {
    if !get_ctx().debug do return
    fmt.printfln(format, ..args)
}

highlight_lines_file_name :: proc(file_name:string, span:Span) {
    f := file_name
    lines := get_file_lines(f, span);
    print_lines(lines, span);
}
highlight_lines_span :: proc(span:Span) {
    f := get_ctx().current_file
    lines := get_file_lines(f, span);
    print_lines(lines, span);
}
highlight_lines :: proc {
    highlight_lines_span,
    highlight_lines_file_name,
}
print_lines :: proc(lines: []FileLine, highlight: Span = {0, 0}) {
    has_highlight := highlight.start != highlight.end

    for l in lines {
        fmt.printfln(" %5d | %s", l.line_number, l.line)
        if !has_highlight do continue

        // does the highlight span touch this line at all?
        overlaps := highlight.start < l.end && highlight.end > l.start
        if !overlaps do continue

        // clip the span to this line's bounds, then convert to column offsets
        col_start := max(highlight.start, l.start) - l.start
        col_end   := min(highlight.end, l.end) - l.start
        if col_end <= col_start {
            col_end = col_start + 1 // guarantee at least one caret
        }

        gutter := "       | " // 5 digits + " | " prefix width, matches "%5d | "
        builder := strings.builder_make(get_ctx().allocator)
        strings.write_string(&builder, gutter)
        for _ in 0..<col_start {
            strings.write_rune(&builder, ' ')
        }
        for _ in 0..<(col_end - col_start) {
            strings.write_rune(&builder, '^')
        }
        fmt.println(strings.to_string(builder))
    }
}
get_file_lines :: proc(file_name: string, span: Span) -> []FileLine {
    allocator := get_ctx().allocator;
    src, ok := get_ctx().files[file_name]
    if !ok {
        panic(fmt.tprintf("get_file_lines: unknown file %q", file_name))
    }
    if span.start < 0 || span.end > len(src) || span.start > span.end {
        panic(fmt.tprintf("get_file_lines: invalid span %v for file %q (len %d)", span, file_name, len(src)))
    }

    lines := make([dynamic]FileLine, allocator)
    line_no := 1
    line_start := 0

    for i := 0; i <= len(src); i += 1 {
        at_end := i == len(src)
        is_newline := !at_end && src[i] == '\n'

        if is_newline || at_end {
            line_end := i
            byte_range_hits_span := line_start <= span.end && line_end >= span.start
            if byte_range_hits_span {
                append(&lines, FileLine{line_no, src[line_start:line_end], line_start, line_end})
            }
            if at_end do break
            line_no += 1
            line_start = i + 1
        }
    }

    return lines[:]
}
FileLine :: struct {
    line_number: int,
    line:        string,
    start:       int, // byte offset of this line's first char in the source
    end:         int, // byte offset one past this line's last char (exclusive, no \n)
}

