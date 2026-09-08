const std = @import("std");
const http = @import("http");
const Context = @import("context.zig");

pub const max_path_parameters = 16;

pub const PathParameter = struct {
    name: []const u8,
    value: []const u8,
};

pub const Handler = *const fn (
    context: *Context,
    request: *const http.Request,
    parameters: []const PathParameter,
) anyerror!http.Response;

pub const Route = struct {
    method: http.Request.Method,
    path: []const u8,
    handler: Handler,
    user_data: ?*anyopaque,
    parameter_count: u8,
};

pub const Match = struct {
    route: *const Route,
    captures: []const PathParameter,
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(Route) = .empty,
    frozen: bool = false,

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |route|
            self.allocator.free(route.path);
        self.routes.deinit(self.allocator);
    }

    pub fn add(
        self: *Router,
        method: http.Request.Method,
        path: []const u8,
        handler: Handler,
    ) !void {
        try self.addWithUserData(method, path, handler, null);
    }

    pub fn addWithUserData(
        self: *Router,
        method: http.Request.Method,
        path: []const u8,
        handler: Handler,
        user_data: ?*anyopaque,
    ) !void {
        if (self.frozen)
            return error.RouterFrozen;
        const parameter_count = try analyzeRoutePath(path);

        for (self.routes.items) |route| {
            if (route.method != method)
                continue;
            if (std.mem.eql(u8, route.path, path) or
                (parameter_count != 0 and
                    route.parameter_count != 0 and
                    haveSamePatternShape(route.path, path)))
            {
                return error.DuplicateRoute;
            }
        }

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.routes.append(self.allocator, .{
            .method = method,
            .path = owned_path,
            .handler = handler,
            .user_data = user_data,
            .parameter_count = parameter_count,
        });
    }

    pub fn match(
        self: *const Router,
        method: http.Request.Method,
        path: []const u8,
        capture_buffer: *[max_path_parameters]PathParameter,
    ) ?Match {
        for (self.routes.items) |*route| {
            if (route.method == method and
                route.parameter_count == 0 and
                std.mem.eql(u8, route.path, path))
            {
                return .{ .route = route, .captures = capture_buffer[0..0] };
            }
        }

        for (self.routes.items) |*route| {
            if (route.method != method or route.parameter_count == 0)
                continue;

            if (matchParameterizedPath(route.path, path, capture_buffer)) |capture_count| {
                return .{
                    .route = route,
                    .captures = capture_buffer[0..capture_count],
                };
            }
        }

        return null;
    }

    pub fn freeze(self: *Router) void {
        self.frozen = true;
    }
};

fn analyzeRoutePath(path: []const u8) !u8 {
    if (!isValidRoutePath(path))
        return error.InvalidRoutePath;

    var names: [max_path_parameters][]const u8 = undefined;
    var parameter_count: usize = 0;
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or segment[0] != ':')
            continue;

        const name = segment[1..];
        if (!isValidParameterName(name))
            return error.InvalidParameterName;
        if (parameter_count == max_path_parameters)
            return error.TooManyPathParameters;
        for (names[0..parameter_count]) |existing_name| {
            if (std.mem.eql(u8, existing_name, name))
                return error.DuplicateParameterName;
        }

        names[parameter_count] = name;
        parameter_count += 1;
    }

    return @intCast(parameter_count);
}

fn isValidRoutePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/')
        return false;

    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        const byte = path[index];

        if (std.ascii.isAlphanumeric(byte) or
            std.mem.indexOfScalar(u8, "!$&'()*+,-./:;=@_~", byte) != null)
        {
            continue;
        }

        if (byte == '%') {
            if (index + 2 >= path.len or
                !std.ascii.isHex(path[index + 1]) or
                !std.ascii.isHex(path[index + 2]))
            {
                return false;
            }
            index += 2;
            continue;
        }

        return false;
    }

    return true;
}

fn isValidParameterName(name: []const u8) bool {
    if (name.len == 0 or
        !(std.ascii.isAlphabetic(name[0]) or name[0] == '_'))
    {
        return false;
    }

    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_'))
            return false;
    }
    return true;
}

fn haveSamePatternShape(left: []const u8, right: []const u8) bool {
    var left_segments = std.mem.splitScalar(u8, left, '/');
    var right_segments = std.mem.splitScalar(u8, right, '/');

    while (left_segments.next()) |left_segment| {
        const right_segment = right_segments.next() orelse return false;
        const left_is_parameter = left_segment.len != 0 and left_segment[0] == ':';
        const right_is_parameter = right_segment.len != 0 and right_segment[0] == ':';

        if (left_is_parameter and right_is_parameter)
            continue;
        if (left_is_parameter != right_is_parameter or
            !std.mem.eql(u8, left_segment, right_segment))
        {
            return false;
        }
    }

    return right_segments.next() == null;
}

fn matchParameterizedPath(
    pattern: []const u8,
    path: []const u8,
    captures: *[max_path_parameters]PathParameter,
) ?usize {
    var pattern_segments = std.mem.splitScalar(u8, pattern, '/');
    var path_segments = std.mem.splitScalar(u8, path, '/');
    var capture_count: usize = 0;

    while (pattern_segments.next()) |pattern_segment| {
        const path_segment = path_segments.next() orelse return null;
        if (pattern_segment.len != 0 and pattern_segment[0] == ':') {
            if (path_segment.len == 0)
                return null;
            captures[capture_count] = .{
                .name = pattern_segment[1..],
                .value = path_segment,
            };
            capture_count += 1;
        } else if (!std.mem.eql(u8, pattern_segment, path_segment)) {
            return null;
        }
    }

    if (path_segments.next() != null)
        return null;
    return capture_count;
}

fn testHandlerOne(_: *Context, _: *const http.Request, _: []const PathParameter) anyerror!http.Response {
    return .{ .body = "one" };
}

fn testHandlerTwo(_: *Context, _: *const http.Request, _: []const PathParameter) anyerror!http.Response {
    return .{ .body = "two" };
}

fn testHandlerThree(_: *Context, _: *const http.Request, _: []const PathParameter) anyerror!http.Response {
    return .{ .body = "three" };
}

fn testHandlerFour(_: *Context, _: *const http.Request, _: []const PathParameter) anyerror!http.Response {
    return .{ .body = "four" };
}

test "match exact method and path routes" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try router.add(.GET, "/items", testHandlerOne);
    try router.add(.POST, "/items", testHandlerTwo);
    try router.add(.GET, "/health", testHandlerThree);

    var captures: [max_path_parameters]PathParameter = undefined;
    try std.testing.expect(router.match(.GET, "/items", &captures).?.route.handler == testHandlerOne);
    try std.testing.expect(router.match(.POST, "/items", &captures).?.route.handler == testHandlerTwo);
    try std.testing.expect(router.match(.GET, "/health", &captures).?.route.handler == testHandlerThree);
    try std.testing.expect(router.match(.POST, "/health", &captures) == null);
    try std.testing.expect(router.match(.GET, "/missing", &captures) == null);
}

test "capture one or more path parameters" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();
    try router.add(.GET, "/users/:user_id/posts/:post_id", testHandlerOne);

    var captures: [max_path_parameters]PathParameter = undefined;
    const result = router.match(.GET, "/users/42/posts/a%2Fb", &captures).?;

    try std.testing.expectEqual(@as(usize, 2), result.captures.len);
    try std.testing.expectEqualStrings("user_id", result.captures[0].name);
    try std.testing.expectEqualStrings("42", result.captures[0].value);
    try std.testing.expectEqualStrings("post_id", result.captures[1].name);
    try std.testing.expectEqualStrings("a%2Fb", result.captures[1].value);
}

test "prefer exact route over parameterized route" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();
    try router.add(.GET, "/users/:id", testHandlerOne);
    try router.add(.GET, "/users/new", testHandlerTwo);

    var captures: [max_path_parameters]PathParameter = undefined;
    const result = router.match(.GET, "/users/new", &captures).?;
    try std.testing.expect(result.route.handler == testHandlerTwo);
    try std.testing.expectEqual(@as(usize, 0), result.captures.len);
}

test "parameterized routes require non-empty matching segment count" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();
    try router.add(.GET, "/users/:id", testHandlerOne);

    var captures: [max_path_parameters]PathParameter = undefined;
    try std.testing.expect(router.match(.GET, "/users", &captures) == null);
    try std.testing.expect(router.match(.GET, "/users/", &captures) == null);
    try std.testing.expect(router.match(.GET, "/users/42/more", &captures) == null);
    try std.testing.expect(router.match(.POST, "/users/42", &captures) == null);
}

test "reject duplicate method and pattern shape" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try router.add(.GET, "/items/:id", testHandlerOne);
    try std.testing.expectError(error.DuplicateRoute, router.add(.GET, "/items/:id", testHandlerTwo));
    try std.testing.expectError(error.DuplicateRoute, router.add(.GET, "/items/:name", testHandlerThree));
    try router.add(.POST, "/items/:name", testHandlerFour);
}

test "validate route paths and parameter names" {
    const valid = [_][]const u8{
        "/",
        "/health",
        "/items/:id",
        "/users/:user_id/posts/:post_id",
        "/encoded/%2F",
        "/semi;value",
    };
    for (valid) |path| {
        var router = Router.init(std.testing.allocator);
        defer router.deinit();
        try router.add(.GET, path, testHandlerOne);
    }

    const invalid_paths = [_][]const u8{
        "",
        "health",
        "/query?value=1",
        "/fragment#part",
        "/bad path",
        "/back\\slash",
        "/%",
        "/%GG",
    };
    for (invalid_paths) |path| {
        var router = Router.init(std.testing.allocator);
        defer router.deinit();
        try std.testing.expectError(error.InvalidRoutePath, router.add(.GET, path, testHandlerOne));
    }

    const invalid_parameter_names = [_][]const u8{
        "/users/:",
        "/users/:42",
        "/users/:user-name",
        "/users/:first/:first",
    };
    for (invalid_parameter_names) |path| {
        var router = Router.init(std.testing.allocator);
        defer router.deinit();
        const result = router.add(.GET, path, testHandlerOne);
        try std.testing.expectError(switch (std.mem.count(u8, path, ":first")) {
            2 => error.DuplicateParameterName,
            else => error.InvalidParameterName,
        }, result);
    }
}

test "reject too many path parameters" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try std.testing.expectError(
        error.TooManyPathParameters,
        router.add(
            .GET,
            "/:a/:b/:c/:d/:e/:f/:g/:h/:i/:j/:k/:l/:m/:n/:o/:p/:q",
            testHandlerOne,
        ),
    );
}

test "reject route registration after freeze" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try router.add(.GET, "/", testHandlerOne);
    router.freeze();

    try std.testing.expectError(error.RouterFrozen, router.add(.GET, "/later", testHandlerTwo));

    var captures: [max_path_parameters]PathParameter = undefined;
    try std.testing.expect(router.match(.GET, "/", &captures).?.route.handler == testHandlerOne);
}
