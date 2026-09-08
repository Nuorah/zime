const std = @import("std");
const database_api = @import("database");
const http = @import("http");
const Context = @import("context.zig");
const middleware = @import("middleware.zig");
const response_tools = @import("response.zig");
const routing = @import("router.zig");

pub fn RouteScope(comptime State: type) type {
    return struct {
        application: *Application,
        state: *State,

        const Self = @This();
        const StateHandler = fn (
            *Context,
            *const http.Request,
            []const routing.PathParameter,
            *State,
        ) anyerror!http.Response;

        pub fn route(
            self: *Self,
            method: http.Request.Method,
            path: []const u8,
            comptime handler: StateHandler,
        ) !void {
            try self.application.registerRoute(
                method,
                path,
                middleware.withState(State, handler),
                self.state,
            );
        }

        pub fn get(
            self: *Self,
            path: []const u8,
            comptime handler: StateHandler,
        ) !void {
            try self.route(.GET, path, handler);
        }

        pub fn post(
            self: *Self,
            path: []const u8,
            comptime handler: StateHandler,
        ) !void {
            try self.route(.POST, path, handler);
        }
    };
}

pub const Application = struct {
    pub const Config = struct {
        database: database_api.Config,
        user_data: ?*anyopaque = null,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    router: routing.Router,
    client: http.Client,
    database: database_api.Database,
    user_data: ?*anyopaque,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
    ) !Application {
        var router = routing.Router.init(allocator);
        errdefer router.deinit();

        var client = http.Client.init(allocator, io);
        errdefer client.deinit();

        const database = try database_api.Database.open(allocator, config.database);

        return .{
            .allocator = allocator,
            .io = io,
            .router = router,
            .client = client,
            .database = database,
            .user_data = config.user_data,
        };
    }

    pub fn deinit(self: *Application) void {
        self.database.deinit();
        self.client.deinit();
        self.router.deinit();
    }

    fn registerRoute(
        self: *Application,
        method: http.Request.Method,
        path: []const u8,
        handler: routing.Handler,
        user_data: ?*anyopaque,
    ) !void {
        try self.router.addWithUserData(method, path, handler, user_data);
    }

    pub fn route(
        self: *Application,
        method: http.Request.Method,
        path: []const u8,
        handler: routing.Handler,
    ) !void {
        try self.registerRoute(method, path, handler, null);
    }

    pub fn get(
        self: *Application,
        path: []const u8,
        handler: routing.Handler,
    ) !void {
        try self.route(.GET, path, handler);
    }

    pub fn post(
        self: *Application,
        path: []const u8,
        handler: routing.Handler,
    ) !void {
        try self.route(.POST, path, handler);
    }

    pub fn mount(
        self: *Application,
        comptime State: type,
        state: *State,
        comptime register: fn (*RouteScope(State)) anyerror!void,
    ) !void {
        var scope: RouteScope(State) = .{
            .application = self,
            .state = state,
        };
        try register(&scope);
    }

    pub fn freeze(self: *Application) void {
        self.router.freeze();
    }

    pub fn run(self: *Application, config: http.Server.Config) !void {
        self.freeze();

        std.log.info("Starting server on {s}:{d}", .{ config.host, config.port });

        var server = try http.Server.listen(self.io, config);
        defer server.deinit();

        var connection_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer connection_arena.deinit();
        const connection_allocator = connection_arena.allocator();

        while (true) {
            _ = connection_arena.reset(.retain_capacity);

            var connection = try server.accept();
            defer connection.deinit();

            var request = connection.receive(connection_allocator) catch |err| {
                std.log.warn("Invalid HTTP request: {s}", .{@errorName(err)});

                const response: http.Response = .{ .status = .bad_request };
                connection.send(&response) catch |send_err| {
                    std.log.warn("Failed to send error response: {s}", .{@errorName(send_err)});
                };
                continue;
            };
            defer request.deinit();

            std.log.info("Method: {any}", .{request.method});
            std.log.info("Target: {s}", .{request.target});
            std.log.info("Host: {s}", .{request.headers.host});
            std.log.info("Body length: {d}", .{request.body.len});

            const response: http.Response = self.dispatch(&request) catch |err| fallback: {
                std.log.err("Controller failed: {s}", .{@errorName(err)});
                break :fallback .{ .status = .internal_server_error };
            };

            connection.send(&response) catch |err| {
                std.log.warn("Failed to send response: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn dispatch(
        self: *Application,
        request: *const http.Request,
    ) anyerror!http.Response {
        const path_end = std.mem.indexOfScalar(u8, request.target, '?') orelse
            request.target.len;
        const path = request.target[0..path_end];

        var parameter_buffer: [routing.max_path_parameters]routing.PathParameter = undefined;
        const match = self.router.match(request.method, path, &parameter_buffer) orelse
            return .{ .status = .not_found };

        var context: Context = .{
            .client = &self.client,
            .database = &self.database,
            .user_data = match.route.user_data orelse self.user_data,
        };
        return match.route.handler(&context, request, match.captures);
    }
};

fn testHealth(
    _: *Context,
    _: *const http.Request,
    _: []const routing.PathParameter,
) anyerror!http.Response {
    return response_tools.body(.ok, .json, "{\"status\":\"ok\"}");
}

fn testEcho(
    _: *Context,
    request: *const http.Request,
    _: []const routing.PathParameter,
) anyerror!http.Response {
    return response_tools.body(.ok, .binary, request.body);
}

const TestState = struct {
    handler_calls: usize = 0,
};

fn testState(
    context: *Context,
    _: *const http.Request,
    _: []const routing.PathParameter,
) anyerror!http.Response {
    const state = context.state(TestState) orelse return error.MissingApplicationState;
    state.handler_calls += 1;
    return .{ .status = .ok };
}

fn testRequest(
    method: http.Request.Method,
    target: []const u8,
    body: []const u8,
) http.Request {
    return .{
        .method = method,
        .target = target,
        .headers = .{
            .items = &.{},
            .framing = .none,
            .connection_close = false,
            .host = "localhost",
        },
        .body = body,
        .allocator = std.testing.allocator,
    };
}

fn initTestApplication() !Application {
    return Application.init(std.testing.allocator, std.testing.io, .{
        .database = .{
            .sqlite = .{ .path = ":memory:" },
        },
    });
}

test "user data defaults to null" {
    var application = try initTestApplication();
    defer application.deinit();

    try std.testing.expect(application.user_data == null);
}

test "handler receives and mutates configured user data" {
    var state: TestState = .{};
    var application = try Application.init(std.testing.allocator, std.testing.io, .{
        .database = .{
            .sqlite = .{ .path = ":memory:" },
        },
        .user_data = &state,
    });
    defer application.deinit();
    try application.get("/state", testState);

    const request = testRequest(.GET, "/state", "");
    const response = try application.dispatch(&request);

    try std.testing.expectEqual(http.Response.Status.ok.code, response.status.code);
    try std.testing.expectEqual(@as(usize, 1), state.handler_calls);
}

test "register and dispatch route without treating query as path" {
    var application = try initTestApplication();
    defer application.deinit();
    try application.get("/health", testHealth);

    const request = testRequest(.GET, "/health?verbose=true", "");
    const response = try application.dispatch(&request);

    try std.testing.expectEqual(http.Response.Status.ok.code, response.status.code);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", response.body);
    try std.testing.expectEqualStrings("application/json", response.headers[0].value);
}

test "registered controller receives the request" {
    var application = try initTestApplication();
    defer application.deinit();
    try application.post("/echo", testEcho);

    const request = testRequest(.POST, "/echo", "hello\x00zig");
    const response = try application.dispatch(&request);

    try std.testing.expectEqualSlices(u8, request.body, response.body);
    try std.testing.expectEqualStrings("application/octet-stream", response.headers[0].value);
}

test "return not found for an unmatched method or path" {
    var application = try initTestApplication();
    defer application.deinit();
    try application.post("/echo", testEcho);

    const wrong_method = testRequest(.GET, "/echo", "");
    const missing_path = testRequest(.GET, "/missing", "");

    try std.testing.expectEqual(
        http.Response.Status.not_found.code,
        (try application.dispatch(&wrong_method)).status.code,
    );
    try std.testing.expectEqual(
        http.Response.Status.not_found.code,
        (try application.dispatch(&missing_path)).status.code,
    );
}

const FirstScopeState = struct {
    calls: usize = 0,
};

const SecondScopeState = struct {
    calls: usize = 0,
};

fn firstScopeHandler(
    _: *Context,
    _: *const http.Request,
    _: []const routing.PathParameter,
    state: *FirstScopeState,
) anyerror!http.Response {
    state.calls += 1;
    return .{ .status = .ok };
}

fn secondScopeHandler(
    _: *Context,
    _: *const http.Request,
    _: []const routing.PathParameter,
    state: *SecondScopeState,
) anyerror!http.Response {
    state.calls += 1;
    return .{ .status = .ok };
}

fn mountFirstScope(scope: *RouteScope(FirstScopeState)) anyerror!void {
    try scope.get("/first", firstScopeHandler);
}

fn mountSecondScope(scope: *RouteScope(SecondScopeState)) anyerror!void {
    try scope.post("/second", secondScopeHandler);
}

test "mount independently typed route scopes" {
    var application = try initTestApplication();
    defer application.deinit();

    var first_state: FirstScopeState = .{};
    var second_state: SecondScopeState = .{};
    try application.mount(FirstScopeState, &first_state, mountFirstScope);
    try application.mount(SecondScopeState, &second_state, mountSecondScope);

    const first_request = testRequest(.GET, "/first", "");
    const second_request = testRequest(.POST, "/second", "");
    try std.testing.expectEqual(
        http.Response.Status.ok.code,
        (try application.dispatch(&first_request)).status.code,
    );
    try std.testing.expectEqual(@as(usize, 1), first_state.calls);
    try std.testing.expectEqual(@as(usize, 0), second_state.calls);

    try std.testing.expectEqual(
        http.Response.Status.ok.code,
        (try application.dispatch(&second_request)).status.code,
    );
    try std.testing.expectEqual(@as(usize, 1), first_state.calls);
    try std.testing.expectEqual(@as(usize, 1), second_state.calls);
}
