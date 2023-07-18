const std = @import("std");

pub const CSS = struct {
    pub const Property = union(enum) {
        color: []const u8,
        background: []const u8,

        pub const Tag = std.meta.Tag(Property);
    };
    pub const Rule = struct {
        selector: []const u8,
        properties: []Property,
    };
    pub const Sheet = struct {
        rules: []Rule,

        pub fn format(sheet: Sheet, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            for (sheet.rules) |rule| {
                try writer.print("selector: {s}\n", .{rule.selector});
                for (rule.properties) |property| {
                    switch (property) {
                        inline else => |payload, tag| {
                            try writer.print("  {s}: {s}\n", .{ @tagName(tag), payload });
                        },
                    }
                }
                try writer.print("\n", .{});
            }
        }
    };
};

fn match_property(
    name: []const u8,
    value: []const u8,
) !CSS.Property {
    const ptag = std.meta.stringToEnum(CSS.Property.Tag, name) orelse
        return error.UnknownProperty;
    switch (ptag) {
        inline else => |tag| return @unionInit(CSS.Property, @tagName(tag), value),
    }
}

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

pub fn Result(comptime T: type) type {
    return struct {
        value: T,
        index: usize,
    };
}

fn parse_identifier(
    css: []const u8,
    initial_index: usize,
) !Result([]const u8) {
    var index = initial_index;
    while (index < css.len and std.ascii.isAlphabetic(css[index])) {
        index += 1;
    }

    if (index == initial_index) {
        debug_at(css, initial_index, "Expected valid identifier.", .{});
        return error.InvalidIdentifier;
    }

    return .{
        .value = css[initial_index..index],
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

fn parse_property(
    css: []const u8,
    initial_index: usize,
) !Result(CSS.Property) {
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

    var property = match_property(name_res.value, value_res.value) catch |e| {
        debug_at(css, initial_index, "Unknown property: '{s}'.", .{name_res.value});
        return e;
    };

    return .{
        .value = property,
        .index = index,
    };
}

fn parse_rule(
    allocator: std.mem.Allocator,
    css: []const u8,
    initial_index: usize,
) !Result(CSS.Rule) {
    var index = eat_whitespace(css, initial_index);

    // First parse selector(s).
    var selector_res = try parse_identifier(css, index);
    index = selector_res.index;

    index = eat_whitespace(css, index);

    // Then parse opening curly brace: {.
    index = try parse_syntax(css, index, '{');

    index = eat_whitespace(css, index);

    var properties = std.ArrayList(CSS.Property).init(allocator);
    // Then parse any number of properties.
    while (index < css.len) {
        index = eat_whitespace(css, index);
        if (index < css.len and css[index] == '}') {
            break;
        }

        const attr_res = try parse_property(css, index);
        index = attr_res.index;

        try properties.append(attr_res.value);
    }

    index = eat_whitespace(css, index);

    // Then parse closing curly brace: }.
    index = try parse_syntax(css, index, '}');

    return .{
        .value = .{
            .selector = selector_res.value,
            .properties = properties.items,
        },
        .index = index,
    };
}

fn parse(
    allocator: std.mem.Allocator,
    css: []const u8,
) !CSS.Sheet {
    var index: usize = 0;
    var rules = std.ArrayList(CSS.Rule).init(allocator);

    // Parse rules until EOF.
    while (index < css.len) {
        const res = try parse_rule(allocator, css, index);
        try rules.append(res.value);
        index = eat_whitespace(css, res.index);
    }

    return .{
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

    const file_name = args.next() orelse {
        std.debug.print("First argument missing. Should be a css file path\n", .{});
        std.process.exit(1);
    };

    const file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    const css_file = try file.readToEndAlloc(allocator, std.math.maxInt(u32));

    var sheet = parse(allocator, css_file) catch return;
    std.debug.print("{}", .{sheet});
}
