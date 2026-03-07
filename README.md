# Zenx

⚠️ This project is under active development and not ready for production use.



>| Feature           | Props | Slots | Nested |
>| ----------------- | ----- | ----- | ------ |
>| components        | ✅    | ✅    | ✅     |
>| layouts           | ✅    | ✅    | ✅     |

>| slots     | Default | Named |
>| --------- | ------- | ----- |
>| ✅        | ✅      | ✅    |


# Installation Guide

1️⃣ Add Zenix as a dependency in your build.zig.zon:

> [!TIP]
>
> ```bash
> zig fetch --save https://github.com/a-mok-youb/zenix/archive/refs/heads/main.tar.gz
> ```

2️⃣ In your build.zig, add the zenix module as a dependency to your program:

> [!TIP]
> **build.zig**
>
> ```bash
> const zenix = b.dependency("zenix", .{
>    .target = target,
>    .optimize = optimize,
>  });
>
>  exe.root_module.addImport("zenix", zenix.module("zenix"));
> ```

The library tracks Zig master. If you're using a specific version of Zig, use the appropriate branch.

add file **zenx.config.zon** in your project folder

> [!TIP]
> **zenx.config.zon**
>
> ```bash
> .{
>    .port = 8080,
>    .paths = .{
>        .pages = "src/pages",
>        .components = "src/components",
>        .layouts = "src/layouts",
>    },
> }
> ```

# Example Guide

```bash
const std = @import("std");
const Zenix = @import("zenix").Zenix;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try Zenix.init(allocator);
    defer app.deinit();

    _ = try app.config.Zon();

    const html = try app.Page(200, "index", &.{
            .{ .key = "title", .value = "Welcome to Zenix!" },
            .{ .key = "content", .value = "This is a sample page rendered with Zenix." },
        
    });

    std.debug.print("{s}\n", .{html});
}

```

# whit [http.zig](https://github.com/karlseguin/http.zig)

```bash
const std = @import("std");
const httpz = @import("httpz");
const zenix = @import("zenix");

const Zenix = zenix.Zenix;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    var app = try Zenix.init(allocator);
    defer app.deinit();

    const cfg = try app.config.Zon();

    const server_config = httpz.Config{
        .port = cfg.server.port,
        .address = cfg.server.address,
    };

    var handler = Handler{
        .allocator = allocator,
        .app = app,
    };

    var server = try httpz.Server(*Handler).init(allocator, server_config, &handler);
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.get("/", index, .{});
    router.get("/error", @"error", .{});

    std.debug.print("listening http://localhost:{d}/\n", .{cfg.server.port});
    try server.listen();
}

const Handler = struct {
    allocator: std.mem.Allocator,
    app: *Zenix,
    _hits: usize = 0,

    pub fn notFound(self: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
        res.status = 404;
        const body = try self.app.Page(404, "error", &.{
                .{ .key = "status", .value = "404" },
                .{ .key = "message", .value = "page not found" },
            },
        );
        res.body = body;
    }

    pub fn uncaughtError(
        self: *Handler,
        req: *httpz.Request,
        res: *httpz.Response,
        err: anyerror,
    ) void {
        std.debug.print("uncaught http error at {s}: {}\n", .{ req.url.path, err });
        res.status = 500;
        if (self.app.Page(500, "error", &.{
                .{ .key = "status", .value = "500" },
                .{ .key = "message", .value = "Internal Server Error" },
        })) |body| {
            res.body = body;
        } else |_| {
            res.body = "Internal Server Error";
        }
    }
};

fn index(self: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    const body = try self.app.Page(200, .{"index", &.{
            .{ .key = "username", .value = "ayoub" },
            .{ .key = "items", .value = "<li>Rust</li><li>Zig</li>" },
            .{ .key = "title", .value = "Card Title" },
            .{ .key = "description", .value = "product description" },
    });
    res.body = body;
}
fn @"error"(_: *Handler, _: *httpz.Request, _: *httpz.Response) !void {
    return error.ActionError;
}



```

## License

[MIT](https://choosealicense.com/licenses/mit/)
