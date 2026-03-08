const std = @import("std");
const types = @import("types.zig");
const Zpage = @import("core.zig").Zpage;
const loadFile = @import("utils/loadfile.zig").loadFile;

pub const Config = struct {
    Zpage: *Zpage,
    const Self = @This();

    pub fn Zon(self: *Self) !types.config_zon {
        const comp_template = try loadFile(self.Zpage.allocator, "zpage.config.zon");

        const source = try self.Zpage.allocator.dupeZ(u8, comp_template);
        defer self.Zpage.allocator.free(source);

        const config = try std.zon.parse.fromSlice(
            types.config_zon,
            self.Zpage.allocator,
            source,
            null,
            .{},
        );
        self.Zpage.config_zon = config;
        return config;
    }
};
