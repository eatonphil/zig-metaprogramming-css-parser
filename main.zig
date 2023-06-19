const std = @import("std");

const CSSProperty = union(enum) {
    unknown: u1,
    color: []const u8,
    background: []const u8,
};

fn match_property(
    property: *CSSProperty,
    name: []const u8,
    value: []const u8,
) !void {
    const cssPropertyInfo = @typeInfo(CSSProperty);

    inline for (cssPropertyInfo.Union.fields) |u_field| {
        if (comptime !std.mem.eql(u8, u_field.name, "unknown")) {
            if (std.mem.eql(u8, u_field.name, name)) {
                property.* = @unionInit(CSSProperty, u_field.name, value);
            }
        }
    }
}

const CSSRule = struct {
    selector: []const u8,
    properties: []CSSProperty,
};

const CSSSheet = struct {
    rules: []CSSRule,

    fn display(sheet: *CSSSheet) void {
        for (sheet.rules) |rule| {
            std.debug.print("selector: {s}\n", .{rule.selector});
            for (rule.properties) |property| {
                inline for (@typeInfo(CSSProperty).Union.fields) |u_field| {
                    if (comptime !std.mem.eql(u8, u_field.name, "unknown")) {
                        if (std.mem.eql(u8, u_field.name, @tagName(property))) {
                            std.debug.print("  {s}: {s}\n", .{
                                @tagName(property),
                                @field(property, u_field.name),
                            });
                        }
                    }
                }
            }
            std.debug.print("\n", .{});
        }
    }
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

const ParsePropertyResult = struct {
    property: CSSProperty,
    index: usize,
};

fn parse_property(
    css: []const u8,
    initial_index: usize,
) !ParsePropertyResult {
    var index = eat_whitespace(css, initial_index);

    // First parse property name.
    var name_res = parse_identifier(css, index) catch |e| {
        std.debug.print("Could not parse property name.\n", .{});
        return e;
    };
    index = name_res.index;

    index = eat_whitespace(css, index);

    // Then parse colon: :.
    index = try parse_syntax(css, index, ':');

    index = eat_whitespace(css, index);

    // Then parse property value.
    var value_res = parse_identifier(css, index) catch |e| {
        std.debug.print("Could not parse property value.\n", .{});
        return e;
    };
    index = value_res.index;

    // Finally parse semi-colon: ;.
    index = try parse_syntax(css, index, ';');

    var property: CSSProperty = CSSProperty{ .unknown = 1 };
    try match_property(&property, name_res.identifier, value_res.identifier);

    if (std.mem.eql(u8, @tagName(property), "unknown")) {
        debug_at(css, initial_index, "Unknown property: '{s}'.", .{name_res.identifier});
        return error.UnknownProperty;
    }

    return ParsePropertyResult{
        .property = property,
        .index = index,
    };
}

const ParseRuleResult = struct {
    rule: CSSRule,
    index: usize,
};
fn parse_rule(
    arena: *std.heap.ArenaAllocator,
    css: []const u8,
    initial_index: usize,
) !ParseRuleResult {
    var index = eat_whitespace(css, initial_index);

    // First parse selector(s).
    var selector_res = try parse_identifier(css, index);
    index = selector_res.index;

    index = eat_whitespace(css, index);

    // Then parse opening curly brace: {.
    index = try parse_syntax(css, index, '{');

    index = eat_whitespace(css, index);

    var properties = std.ArrayList(CSSProperty).init(arena.allocator());
    // Then parse any number of properties.
    while (index < css.len) {
        index = eat_whitespace(css, index);
        if (index < css.len and css[index] == '}') {
            break;
        }

        var attr_res = try parse_property(css, index);
        index = attr_res.index;

        try properties.append(attr_res.property);
    }

    index = eat_whitespace(css, index);

    // Then parse closing curly brace: }.
    index = try parse_syntax(css, index, '}');

    return ParseRuleResult{
        .rule = CSSRule{
            .selector = selector_res.identifier,
            .properties = properties.items,
        },
        .index = index,
    };
}

fn parse(
    arena: *std.heap.ArenaAllocator,
    css: []const u8,
) !CSSSheet {
    var index: usize = 0;
    var rules = std.ArrayList(CSSRule).init(arena.allocator());

    // Parse rules until EOF.
    while (index < css.len) {
        var res = try parse_rule(arena, css, index);
        index = res.index;
        try rules.append(res.rule);
        index = eat_whitespace(css, index);
    }

    return CSSSheet{
        .rules = rules.items,
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

    var sheet = parse(&arena, css_file) catch return;
    sheet.display();
}
