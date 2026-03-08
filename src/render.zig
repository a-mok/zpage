const std = @import("std");
const loadFile = @import("utils/loadfile.zig").loadFile;
const types = @import("types.zig");
const Data = types.Data;

fn extractNamedSlot(allocator: std.mem.Allocator, input: []const u8, name: []const u8) !?[]const u8 {
    const open_tag = try std.fmt.allocPrint(allocator, "<slot:{s}>", .{name});
    defer allocator.free(open_tag);
    const close_tag = try std.fmt.allocPrint(allocator, "</slot:{s}>", .{name});
    defer allocator.free(close_tag);

    const start = std.mem.indexOf(u8, input, open_tag) orelse return null;
    const content_start = start + open_tag.len;
    const end = std.mem.indexOf(u8, input[content_start..], close_tag) orelse return null;

    return input[content_start .. content_start + end];
}

fn extractDefaultSlot(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try allocator.dupe(u8, input);

    var i: usize = 0;
    while (i < result.len) {
        if (std.mem.startsWith(u8, result[i..], "<slot:")) {
            const tag_end = std.mem.indexOfPos(u8, result, i + 6, ">") orelse break;
            const slot_name = result[i + 6 .. tag_end];
            const close_tag = try std.fmt.allocPrint(allocator, "</slot:{s}>", .{slot_name});
            defer allocator.free(close_tag);

            const close_pos = std.mem.indexOfPos(u8, result, tag_end, close_tag) orelse break;
            const full_end = close_pos + close_tag.len;

            const new_result = try std.mem.concat(allocator, u8, &.{
                result[0..i],
                result[full_end..],
            });
            allocator.free(result);
            result = new_result;
            continue;
        }
        i += 1;
    }

    const trimmed = std.mem.trim(u8, result, " \t\n\r");
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(result);
    return owned;
}

pub fn parseProps(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(Data) {
    var props = try std.ArrayList(Data).initCapacity(allocator, 4);

    var i: usize = 0;
    while (i < input.len) {
        while (i < input.len and (input[i] == ' ' or input[i] == '\t' or
            input[i] == '\n' or input[i] == '\r')) : (i += 1)
        {}
        if (i >= input.len) break;

        const key_start = i;
        while (i < input.len and input[i] != '=') : (i += 1) {}
        if (i >= input.len) break;
        const key = std.mem.trim(u8, input[key_start..i], " \t");
        i += 1;
        if (i >= input.len) break;

        if (input[i] == '"') {
            i += 1;
            const val_start = i;
            while (i < input.len and input[i] != '"') : (i += 1) {}
            if (i >= input.len) break;
            const val = input[val_start..i];
            i += 1;
            try props.append(allocator, .{ .key = key, .value = val });
            continue;
        }

        if (std.mem.startsWith(u8, input[i..], "{{")) {
            const tok_end = std.mem.indexOfPos(u8, input, i + 2, "}}") orelse break;
            const val = input[i .. tok_end + 2];
            i = tok_end + 2;
            try props.append(allocator, .{ .key = key, .value = val });
            continue;
        }

        const val_start = i;
        while (i < input.len and input[i] != ' ' and input[i] != '/' and
            input[i] != '>' and input[i] != '\t') : (i += 1)
        {}
        const val = input[val_start..i];
        try props.append(allocator, .{ .key = key, .value = val });
    }
    return props;
}

pub fn Template(allocator: std.mem.Allocator, template: []const u8, data: []const Data) ![]const u8 {
    var result = template;
    var owns = false;

    for (data) |r| {
        const replaced = try std.mem.replaceOwned(u8, allocator, result, r.key, r.value);
        if (owns) allocator.free(result);
        result = replaced;
        owns = true;
    }

    if (!owns) return try allocator.dupe(u8, template);
    return result;
}

// ─── If / Else ───────────────────────────────────────────────────────────────

fn renderIf(allocator: std.mem.Allocator, input: []const u8, data: []const Data) anyerror![]u8 {
    var result = try allocator.dupe(u8, input);

    while (true) {
        const if_start = std.mem.indexOf(u8, result, "{{#if ") orelse break;
        const if_key_end = std.mem.indexOfPos(u8, result, if_start + 6, "}}") orelse break;
        const key_name = result[if_start + 6 .. if_key_end];
        const if_tag_end = if_key_end + 2;

        const endif_tag = "{{/if}}";
        const else_tag = "{{#else}}";

        const endif_pos = std.mem.indexOfPos(u8, result, if_tag_end, endif_tag) orelse break;

        // هل يوجد {{#else}} بين {{#if}} و {{/if}}؟
        const else_pos = blk: {
            const ep = std.mem.indexOfPos(u8, result, if_tag_end, else_tag) orelse break :blk null;
            if (ep < endif_pos) break :blk ep;
            break :blk null;
        };

        // تحقق من قيمة الـ key
        const key_token = try std.fmt.allocPrint(allocator, "{{{{{s}}}}}", .{key_name});
        defer allocator.free(key_token);

        const is_true = blk: {
            for (data) |d| {
                if (std.mem.eql(u8, d.key, key_token)) {
                    // فارغ أو "false" أو "0" = false
                    if (d.value.len == 0) break :blk false;
                    if (std.mem.eql(u8, d.value, "false")) break :blk false;
                    if (std.mem.eql(u8, d.value, "0")) break :blk false;
                    break :blk true;
                }
            }
            break :blk false;
        };

        const replacement = if (else_pos) |ep| blk: {
            if (is_true) {
                break :blk result[if_tag_end..ep];
            } else {
                break :blk result[ep + else_tag.len .. endif_pos];
            }
        } else blk: {
            if (is_true) {
                break :blk result[if_tag_end..endif_pos];
            } else {
                break :blk @as([]const u8, "");
            }
        };

        const new_result = try std.mem.concat(allocator, u8, &.{
            result[0..if_start],
            replacement,
            result[endif_pos + endif_tag.len ..],
        });
        allocator.free(result);
        result = new_result;
    }

    return result;
}

// ─── Each ────────────────────────────────────────────────────────────────────

// parse بسيط لـ JSON array: [{"key":"val",...},...]
fn parseJsonArray(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(std.StringHashMap([]const u8)) {
    var list = try std.ArrayList(std.StringHashMap([]const u8)).initCapacity(allocator, 4);

    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '[') return list;

    var i: usize = 1;
    while (i < trimmed.len) {
        while (i < trimmed.len and trimmed[i] != '{') : (i += 1) {}
        if (i >= trimmed.len) break;

        const obj_end = std.mem.indexOfPos(u8, trimmed, i, "}") orelse break;
        const obj_str = trimmed[i + 1 .. obj_end];

        var map = std.StringHashMap([]const u8).init(allocator);

        var j: usize = 0;
        while (j < obj_str.len) {
            while (j < obj_str.len and obj_str[j] != '"') : (j += 1) {}
            if (j >= obj_str.len) break;
            j += 1;
            const key_start = j;
            while (j < obj_str.len and obj_str[j] != '"') : (j += 1) {}
            const key = obj_str[key_start..j];
            j += 1;

            while (j < obj_str.len and obj_str[j] != '"') : (j += 1) {}
            if (j >= obj_str.len) break;
            j += 1;
            const val_start = j;
            while (j < obj_str.len and obj_str[j] != '"') : (j += 1) {}
            const val = obj_str[val_start..j];
            j += 1;

            try map.put(key, val);
        }

        try list.append(allocator, map);
        i = obj_end + 1;
    }

    return list;
}

fn renderEach(allocator: std.mem.Allocator, input: []const u8, data: []const Data) anyerror![]u8 {
    var result = try allocator.dupe(u8, input);

    while (true) {
        const each_start = std.mem.indexOf(u8, result, "{{#each ") orelse break;
        const each_key_end = std.mem.indexOfPos(u8, result, each_start + 8, "}}") orelse break;
        const key_name = result[each_start + 8 .. each_key_end];
        const each_tag_end = each_key_end + 2;

        const endeach_tag = "{{/each}}";

        // ✅ ابحث عن {{/each}} المطابق — تجاهل الـ nested
        var depth: usize = 1;
        var search_pos = each_tag_end;
        const endeach_pos_opt: ?usize = blk: {
            while (search_pos < result.len) {
                if (std.mem.startsWith(u8, result[search_pos..], "{{#each ")) {
                    depth += 1;
                    search_pos += 8;
                } else if (std.mem.startsWith(u8, result[search_pos..], endeach_tag)) {
                    depth -= 1;
                    if (depth == 0) break :blk search_pos;
                    search_pos += endeach_tag.len;
                } else {
                    search_pos += 1;
                }
            }
            break :blk null;
        };
        const endeach_pos = endeach_pos_opt orelse break;

        const block_template = result[each_tag_end..endeach_pos];

        const key_token = try std.fmt.allocPrint(allocator, "{{{{{s}}}}}", .{key_name});
        defer allocator.free(key_token);

        const value = blk: {
            for (data) |d| {
                if (std.mem.eql(u8, d.key, key_token)) break :blk d.value;
            }
            break :blk @as([]const u8, "");
        };

        var rendered_block = try std.ArrayList(u8).initCapacity(allocator, 256);
        defer rendered_block.deinit(allocator);

        if (value.len > 0) {
            if (std.mem.startsWith(u8, std.mem.trim(u8, value, " \t"), "[{")) {
                var objects = try parseJsonArray(allocator, value);
                defer {
                    for (objects.items) |*map| map.deinit();
                    objects.deinit(allocator);
                }

                for (objects.items, 0..) |map, idx| {
                    var item_data = try std.ArrayList(Data).initCapacity(allocator, 8);
                    defer item_data.deinit(allocator);

                    const idx_str = try std.fmt.allocPrint(allocator, "{d}", .{idx});
                    defer allocator.free(idx_str);
                    try item_data.append(allocator, .{ .key = "{{index}}", .value = idx_str });

                    var allocated_keys = try std.ArrayList([]u8).initCapacity(allocator, 8);
                    defer {
                        for (allocated_keys.items) |k| allocator.free(k);
                        allocated_keys.deinit(allocator);
                    }

                    var it = map.iterator();
                    while (it.next()) |entry| {
                        const item_key = try std.fmt.allocPrint(allocator, "{{{{item.{s}}}}}", .{entry.key_ptr.*});
                        try allocated_keys.append(allocator, item_key);
                        try item_data.append(allocator, .{ .key = item_key, .value = entry.value_ptr.* });
                    }

                    // ✅ أضف global_data للـ item_data حتى تعمل nested each
                    for (data) |d| {
                        try item_data.append(allocator, .{ .key = d.key, .value = d.value });
                    }

                    const rendered = try Template(allocator, block_template, item_data.items);
                    defer allocator.free(rendered);

                    // ✅ طبّق directives على كل block — يحل nested {{#each}}
                    const with_nested = try renderDirectives(allocator, rendered, data);
                    defer allocator.free(with_nested);

                    try rendered_block.appendSlice(allocator, with_nested);
                }
            } else {
                var items = std.mem.splitScalar(u8, value, ',');
                var idx: usize = 0;
                while (items.next()) |item| {
                    const trimmed_item = std.mem.trim(u8, item, " \t");
                    const idx_str = try std.fmt.allocPrint(allocator, "{d}", .{idx});
                    defer allocator.free(idx_str);

                    var item_data = try std.ArrayList(Data).initCapacity(allocator, data.len + 2);
                    defer item_data.deinit(allocator);

                    try item_data.append(allocator, .{ .key = "{{item}}", .value = trimmed_item });
                    try item_data.append(allocator, .{ .key = "{{index}}", .value = idx_str });

                    // ✅ أضف global_data
                    for (data) |d| {
                        try item_data.append(allocator, .{ .key = d.key, .value = d.value });
                    }

                    const rendered = try Template(allocator, block_template, item_data.items);
                    defer allocator.free(rendered);

                    // ✅ طبّق directives على كل block
                    const with_nested = try renderDirectives(allocator, rendered, data);
                    defer allocator.free(with_nested);

                    try rendered_block.appendSlice(allocator, with_nested);
                    idx += 1;
                }
            }
        }

        const new_result = try std.mem.concat(allocator, u8, &.{
            result[0..each_start],
            rendered_block.items,
            result[endeach_pos + endeach_tag.len ..],
        });
        allocator.free(result);
        result = new_result;
    }

    return result;
}
// ─── Directives ──────────────────────────────────────────────────────────────

fn renderDirectives(allocator: std.mem.Allocator, input: []const u8, data: []const Data) anyerror![]u8 {
    const after_if = try renderIf(allocator, input, data);
    defer allocator.free(after_if);

    return try renderEach(allocator, after_if, data);
}

// ─── Cache ────────────────────────────────────────────────────────────────────

pub const ComponentCache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) ComponentCache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ComponentCache) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.map.deinit();
    }

    pub fn get(self: *ComponentCache, name: []const u8) ![]const u8 {
        if (self.map.get(name)) |v| return v;

        const path = try std.fmt.allocPrint(self.allocator, "src/components/{s}.html", .{name});
        defer self.allocator.free(path);

        const content = loadFile(self.allocator, path) catch {
            const missing = try std.fmt.allocPrint(
                self.allocator,
                "<div>Component {s} missing</div>",
                .{name},
            );
            try self.map.put(name, missing);
            return missing;
        };

        try self.map.put(name, content);
        return content;
    }
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

fn hasKey(list: std.ArrayList(Data), key: []const u8) bool {
    for (list.items) |r| {
        if (std.mem.eql(u8, r.key, key)) return true;
    }
    return false;
}

fn buildReplacements(
    allocator: std.mem.Allocator,
    props: std.ArrayList(Data),
    extra: []const Data,
    global_data: []const Data,
) !std.ArrayList(Data) {
    var list = try std.ArrayList(Data).initCapacity(allocator, props.items.len + extra.len);

    for (props.items) |p| {
        const wrapped_key = try std.fmt.allocPrint(allocator, "{{{{{s}}}}}", .{p.key});

        const resolved_value = blk: {
            if (std.mem.startsWith(u8, p.value, "{{") and
                std.mem.endsWith(u8, p.value, "}}"))
            {
                for (global_data) |g| {
                    if (std.mem.eql(u8, g.key, p.value)) break :blk g.value;
                }
            }
            break :blk p.value;
        };

        try list.append(allocator, .{ .key = wrapped_key, .value = resolved_value });
    }
    for (extra) |e| {
        const key = try allocator.dupe(u8, e.key);
        try list.append(allocator, .{ .key = key, .value = e.value });
    }
    return list;
}

fn freeReplacements(allocator: std.mem.Allocator, list: *std.ArrayList(Data)) void {
    for (list.items) |r| allocator.free(r.key);
    list.deinit(allocator);
}

fn clearUnresolvedTokens(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);

    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "{{")) {
            const end = std.mem.indexOfPos(u8, input, i + 2, "}}") orelse {
                try result.append(allocator, input[i]);
                i += 1;
                continue;
            };
            i = end + 2;
            continue;
        }
        try result.append(allocator, input[i]);
        i += 1;
    }
    return result.toOwnedSlice(allocator);
}

fn removeBlankLines(allocator: std.mem.Allocator, input: []u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, input.len);

    var i: usize = 0;
    while (i < input.len) {
        const line_start = i;
        while (i < input.len and input[i] != '\n') : (i += 1) {}
        const line_end = i;
        if (i < input.len) i += 1;

        const line = input[line_start..line_end];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }

    return out.toOwnedSlice(allocator);
}

fn removeEmptyTags(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try allocator.dupe(u8, input);

    const void_tags = [_][]const u8{
        "meta",  "link", "br",  "hr",    "img",   "input",
        "area",  "base", "col", "embed", "param", "source",
        "track", "wbr",
    };

    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < result.len) {
            if (result[i] != '<') {
                i += 1;
                continue;
            }

            if (i + 1 < result.len and (result[i + 1] == '/' or
                result[i + 1] == '!' or result[i + 1] == '?'))
            {
                i += 1;
                continue;
            }

            var j = i + 1;
            while (j < result.len and result[j] != ' ' and
                result[j] != '>' and result[j] != '/') : (j += 1)
            {}
            const tag_name = result[i + 1 .. j];
            if (tag_name.len == 0) {
                i += 1;
                continue;
            }

            var is_void = false;
            for (void_tags) |vt| {
                if (std.mem.eql(u8, tag_name, vt)) {
                    is_void = true;
                    break;
                }
            }
            if (is_void) {
                i += 1;
                continue;
            }

            const open_end = std.mem.indexOfPos(u8, result, j, ">") orelse {
                i += 1;
                continue;
            };
            if (open_end > 0 and result[open_end - 1] == '/') {
                i += 1;
                continue;
            }

            const close_tag = try std.fmt.allocPrint(allocator, "</{s}>", .{tag_name});
            defer allocator.free(close_tag);

            const close_pos = std.mem.indexOfPos(u8, result, open_end + 1, close_tag) orelse {
                i += 1;
                continue;
            };

            const content = result[open_end + 1 .. close_pos];
            const trimmed_content = std.mem.trim(u8, content, " \t\n\r");

            if (trimmed_content.len == 0) {
                const new_result = try std.mem.concat(allocator, u8, &.{
                    result[0..i],
                    result[close_pos + close_tag.len ..],
                });
                allocator.free(result);
                result = new_result;
                changed = true;
                break;
            }
            i += 1;
        }
    }

    const cleaned = try removeBlankLines(allocator, result);
    allocator.free(result);
    return cleaned;
}

// ─── Component Render ─────────────────────────────────────────────────────────

pub fn ComponentRender(
    allocator: std.mem.Allocator,
    cache: *ComponentCache,
    input: []const u8,
    global_data: []const Data,
) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, input.len);

    var i: usize = 0;
    while (i < input.len) {
        if (!std.mem.startsWith(u8, input[i..], "<component:")) {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        }

        const name_start = i + 11;
        var j = name_start;
        while (j < input.len and input[j] != ' ' and input[j] != '/' and input[j] != '>') : (j += 1) {}
        const comp_name = input[name_start..j];

        const self_close_pos = std.mem.indexOfPos(u8, input, j, "/>");
        const open_close_pos = std.mem.indexOfPos(u8, input, j, ">");

        const is_self_closing = if (self_close_pos) |sc|
            if (open_close_pos) |oc| sc <= oc else true
        else
            false;

        if (is_self_closing) {
            const sc = self_close_pos.?;
            const props_str = input[j..sc];

            var props = try parseProps(allocator, props_str);
            defer props.deinit(allocator);

            const comp_template = try cache.get(comp_name);

            var replacements = try buildReplacements(allocator, props, &.{
                .{ .key = "{{slot}}", .value = "" },
            }, global_data);
            defer freeReplacements(allocator, &replacements);

            var k: usize = 0;
            while (k < comp_template.len) {
                if (std.mem.startsWith(u8, comp_template[k..], "{{slot:")) {
                    const sn_start = k + 7;
                    const sn_end = std.mem.indexOfPos(u8, comp_template, sn_start, "}}") orelse break;
                    const slot_token = try allocator.dupe(u8, comp_template[k .. sn_end + 2]);
                    if (!hasKey(replacements, slot_token)) {
                        try replacements.append(allocator, .{ .key = slot_token, .value = "" });
                    } else {
                        allocator.free(slot_token);
                    }
                    k = sn_end + 2;
                    continue;
                }
                k += 1;
            }

            const templated = try Template(allocator, comp_template, replacements.items);
            defer allocator.free(templated);
            // ✅ طبّق directives على الـ component
            const with_directives = try renderDirectives(allocator, templated, replacements.items);
            defer allocator.free(with_directives);
            const final = try ComponentRender(allocator, cache, with_directives, global_data);
            defer allocator.free(final);
            try out.appendSlice(allocator, final);

            i = sc + 2;
            continue;
        }

        const tag_close = open_close_pos orelse {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        };

        const props_str = input[j..tag_close];
        const children_start = tag_close + 1;

        const close_tag = try std.fmt.allocPrint(allocator, "</component:{s}>", .{comp_name});
        defer allocator.free(close_tag);

        const close_pos = std.mem.indexOfPos(u8, input, children_start, close_tag) orelse {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        };

        const children = input[children_start..close_pos];

        var props = try parseProps(allocator, props_str);
        defer props.deinit(allocator);

        const comp_template = try cache.get(comp_name);

        const default_slot = try extractDefaultSlot(allocator, children);
        defer allocator.free(default_slot);

        var replacements = try buildReplacements(allocator, props, &.{
            .{ .key = "{{slot}}", .value = default_slot },
        }, global_data);
        defer freeReplacements(allocator, &replacements);

        {
            var k: usize = 0;
            while (k < comp_template.len) {
                if (std.mem.startsWith(u8, comp_template[k..], "{{slot:")) {
                    const sn_start = k + 7;
                    const sn_end = std.mem.indexOfPos(u8, comp_template, sn_start, "}}") orelse break;
                    const slot_name = comp_template[sn_start..sn_end];
                    const slot_token = try allocator.dupe(u8, comp_template[k .. sn_end + 2]);
                    const slot_content = try extractNamedSlot(allocator, children, slot_name);
                    try replacements.append(allocator, .{
                        .key = slot_token,
                        .value = slot_content orelse "",
                    });
                    k = sn_end + 2;
                    continue;
                }
                k += 1;
            }
        }

        const templated = try Template(allocator, comp_template, replacements.items);
        defer allocator.free(templated);
        // ✅ طبّق directives على الـ component
        const with_directives = try renderDirectives(allocator, templated, replacements.items);
        defer allocator.free(with_directives);
        const final = try ComponentRender(allocator, cache, with_directives, global_data);
        defer allocator.free(final);
        try out.appendSlice(allocator, final);

        i = close_pos + close_tag.len;
    }

    return out.toOwnedSlice(allocator);
}

// ─── Layout ───────────────────────────────────────────────────────────────────

pub fn LayoutTag(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, input, "<layout:") orelse return try allocator.dupe(u8, input);
    const name_start = start + 8;

    var j = name_start;
    while (j < input.len and input[j] != ' ' and input[j] != '>') : (j += 1) {}
    const layout_name = input[name_start..j];

    const open_end = std.mem.indexOfPos(u8, input, j, ">") orelse return try allocator.dupe(u8, input);
    const props_str = input[j..open_end];

    const close_tag = "</layout>";
    const close_pos = std.mem.indexOf(u8, input[open_end..], close_tag) orelse
        return try allocator.dupe(u8, input);
    const content = input[open_end + 1 .. open_end + close_pos];

    const layout_path = try std.fmt.allocPrint(allocator, "src/layouts/{s}.html", .{layout_name});
    defer allocator.free(layout_path);

    const layout_template = loadFile(allocator, layout_path) catch |err| {
        std.debug.print("Layout error: {}\n", .{err});
        return try std.fmt.allocPrint(
            allocator,
            "<div>layout {s} not found</div>",
            .{layout_name},
        );
    };
    defer allocator.free(layout_template);

    var props = try parseProps(allocator, props_str);
    defer props.deinit(allocator);

    var replacements = try buildReplacements(allocator, props, &.{
        .{ .key = "{{content}}", .value = content },
    }, &.{});
    defer freeReplacements(allocator, &replacements);

    return try Template(allocator, layout_template, replacements.items);
}

// ─── Render Page ──────────────────────────────────────────────────────────────

pub fn renderPage(
    allocator: std.mem.Allocator,
    cache: *ComponentCache,
    page: []const u8,
    data: []const Data,
) ![]const u8 {
    const page_content = try loadFile(allocator, page);
    defer allocator.free(page_content);

    const with_layout = try LayoutTag(allocator, page_content);
    defer allocator.free(with_layout);

    var wrapped = try std.ArrayList(Data).initCapacity(allocator, data.len);
    defer {
        for (wrapped.items) |r| allocator.free(r.key);
        wrapped.deinit(allocator);
    }
    for (data) |d| {
        const wk = try std.fmt.allocPrint(allocator, "{{{{{s}}}}}", .{d.key});
        try wrapped.append(allocator, .{ .key = wk, .value = d.value });
    }

    // 1. render components أولاً
    const rendered = try ComponentRender(allocator, cache, with_layout, wrapped.items);
    defer allocator.free(rendered);

    // 2. استبدل global tokens
    const templated = try Template(allocator, rendered, wrapped.items);
    defer allocator.free(templated);

    // 3. ✅ طبّق directives بعد كل الاستبدالات
    const with_directives = try renderDirectives(allocator, templated, wrapped.items);
    defer allocator.free(with_directives);

    // 4. امسح tokens غير محلولة
    const cleared = try clearUnresolvedTokens(allocator, with_directives);
    defer allocator.free(cleared);

    // 5. احذف tags فارغة
    return try removeEmptyTags(allocator, cleared);
}
