const std = @import("std");

const CSSAttribute = union(enum) {
    unknown: u1,
    color: []const u8,
    background: []const u8,
};

fn match_attribute(
    attribute: *CSSAttribute,
    name: []const u8,
    value: []const u8,
) !void {
    const cssAttributeInfo = @typeInfo(CSSAttribute);

    inline for (cssAttributeInfo.Union.fields) |u_field| {
        if (comptime !std.mem.eql(u8, u_field.name, "unknown")) {
            if (std.mem.eql(u8, u_field.name, name)) {
                attribute.* = @unionInit(CSSAttribute, u_field.name, value);
                //@field(attribute.*, u_field.name) = value;
            }
        }
    }
}

const CSSBlock = struct {
    selector: []const u8,
    attributes: []CSSAttribute,
};

const CSSTree = struct {
    blocks: []CSSBlock,
};

fn eat_whitespace(
    css: []const u8,
    initial_index: usize,
) usize {
    var index = initial_index;
    while (index < css.len and std.ascii.isWhitespace(css[index])) {
        index += 1;
    }

    return index;
}

fn debug_at(
    css: []const u8,
    index: usize,
    comptime msg: []const u8,
    args: anytype,
) void {
    var line_no: usize = 1;
    var col_no: usize = 0;

    var i: usize = 0;
    var line_beginning: usize = 0;
    var found_line = false;
    while (i < css.len) : (i += 1) {
        if (css[i] == '\n') {
            if (!found_line) {
                col_no = 0;
                line_beginning = i;
                line_no += 1;
                continue;
            } else {
                break;
            }
        }

        if (i == index) {
            found_line = true;
        }

        if (!found_line) {
            col_no += 1;
        }
    }

    std.debug.print("Error at line {}, column {}. ", .{ line_no, col_no });
    std.debug.print(msg ++ "\n\n", args);
    std.debug.print("{s}\n", .{css[line_beginning..i]});
    while (col_no > 0) : (col_no -= 1) {
        std.debug.print(" ", .{});
    }
    std.debug.print("^ Near here.\n", .{});
}

const ParseIdentifierResult = struct {
    identifier: []const u8,
    index: usize,
};
fn parse_identifier(
    css: []const u8,
    initial_index: usize,
) !ParseIdentifierResult {
    var index = initial_index;
    while (index < css.len and std.ascii.isAlphabetic(css[index])) {
        index += 1;
    }

    if (index == initial_index) {
        debug_at(css, initial_index, "Expected valid identifier.", .{});
        return error.InvalidIdentifier;
    }

    return ParseIdentifierResult{
        .identifier = css[initial_index..index],
        .index = index,
    };
}

fn parse_syntax(
    css: []const u8,
    initial_index: usize,
    syntax: u8,
) !usize {
    if (initial_index < css.len and css[initial_index] == syntax) {
        return initial_index + 1;
    }

    debug_at(css, initial_index, "Expected syntax: '{c}'.", .{syntax});
    return error.NoSuchSyntax;
}

const ParseAttributeResult = struct {
    attribute: CSSAttribute,
    index: usize,
};

fn parse_attribute(
    css: []const u8,
    initial_index: usize,
) !ParseAttributeResult {
    var index = eat_whitespace(css, initial_index);

    // First parse attribute name.
    var name_res = parse_identifier(css, index) catch |e| {
        std.debug.print("Could not parse attribute name.\n", .{});
        return e;
    };
    index = name_res.index;

    index = eat_whitespace(css, index);

    // Then parse colon: :.
    index = try parse_syntax(css, index, ':');

    index = eat_whitespace(css, index);

    // Then parse attribute value.
    var value_res = parse_identifier(css, index) catch |e| {
        std.debug.print("Could not parse attribute value.\n", .{});
        return e;
    };
    index = value_res.index;

    // Finally parse semi-colon: ;.
    index = try parse_syntax(css, index, ';');

    var attribute: CSSAttribute = CSSAttribute{ .unknown = 1 };
    try match_attribute(&attribute, name_res.identifier, value_res.identifier);

    if (std.mem.eql(u8, @tagName(attribute), "unknown")) {
        debug_at(css, initial_index, "Unknown attribute: '{s}'.", .{name_res.identifier});
        return error.UnknownAttribute;
    }

    return ParseAttributeResult{
        .attribute = attribute,
        .index = index,
    };
}

const ParseBlockResult = struct {
    block: CSSBlock,
    index: usize,
};
fn parse_block(
    arena: *std.heap.ArenaAllocator,
    css: []const u8,
    initial_index: usize,
) !ParseBlockResult {
    var index = eat_whitespace(css, initial_index);

    // First parse selector(s).
    var selector_res = try parse_identifier(css, index);
    index = selector_res.index;

    index = eat_whitespace(css, index);

    // Then parse opening curly brace: {.
    index = try parse_syntax(css, index, '{');

    index = eat_whitespace(css, index);

    var attributes = std.ArrayList(CSSAttribute).init(arena.allocator());
    // Then parse any number of attributes.
    while (index < css.len) {
        index = eat_whitespace(css, index);
        if (index < css.len and css[index] == '}') {
            break;
        }

        var attr_res = try parse_attribute(css, index);
        index = attr_res.index;

        try attributes.append(attr_res.attribute);
    }

    index = eat_whitespace(css, index);

    // Then parse closing curly brace: }.
    index = try parse_syntax(css, index, '}');

    return ParseBlockResult{
        .block = CSSBlock{
            .selector = selector_res.identifier,
            .attributes = attributes.items,
        },
        .index = index,
    };
}

fn parse(
    arena: *std.heap.ArenaAllocator,
    css: []const u8,
) !CSSTree {
    var index: usize = 0;
    var blocks = std.ArrayList(CSSBlock).init(arena.allocator());

    // Parse blocks until EOF.
    while (index < css.len) {
        var res = try parse_block(arena, css, index);
        index = res.index;
        try blocks.append(res.block);
        index = eat_whitespace(css, index);
    }

    return CSSTree{
        .blocks = blocks.items,
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // Let's read in a CSS file.
    var args = std.process.args();

    // Skips the program name.
    _ = args.next();

    var file_name: []const u8 = "";
    if (args.next()) |f| {
        file_name = f;
    }

    const file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    var css_file = try allocator.alloc(u8, file_size);
    _ = try file.read(css_file);

    var tree = parse(&arena, css_file) catch return;

    for (tree.blocks) |block| {
        std.debug.print("selector: {s}\n", .{block.selector});
        for (block.attributes) |attribute| {
            inline for (@typeInfo(CSSAttribute).Union.fields) |u_field| {
                if (comptime !std.mem.eql(u8, u_field.name, "unknown")) {
                    if (std.mem.eql(u8, u_field.name, @tagName(attribute))) {
                        std.debug.print("  {s}: {s}\n", .{
                            @tagName(attribute),
                            @field(attribute, u_field.name),
                        });
                    }
                }
            }
        }
        std.debug.print("\n", .{});
    }
}
