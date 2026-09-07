const std = @import("std");
const Handler = @import("router.zig").Handler;
const Context = @import("context.zig");
const Request = @import("http").Request;
const Response = @import("http").Response;
const PathParameter = @import("router.zig").PathParameter;

pub fn withState(
    comptime State: type,
    comptime handler: fn (
        *Context,
        *const Request,
        []const PathParameter,
        *State,
    ) anyerror!Response,
) Handler {
    return struct {
        fn call(
            context: *Context,
            request: *const Request,
            parameters: []const PathParameter,
        ) anyerror!Response {
            const state = context.state(State) orelse return error.MissingApplicationState;
            return handler(context, request, parameters, state);
        }
    }.call;
}

const TestState = struct {
    handler_calls: usize = 0,
};

fn testHandler(
    _: *Context,
    request: *const Request,
    parameters: []const PathParameter,
    state: *TestState,
) anyerror!Response {
    state.handler_calls += 1;
    try std.testing.expectEqualStrings("/items/42", request.target);
    try std.testing.expectEqual(@as(usize, 1), parameters.len);
    try std.testing.expectEqualStrings("id", parameters[0].name);
    try std.testing.expectEqualStrings("42", parameters[0].value);
    return .{ .status = .ok };
}

fn testRequest() Request {
    return .{
        .method = .GET,
        .target = "/items/42",
        .headers = .{
            .items = &.{},
            .framing = .none,
            .connection_close = false,
            .host = "localhost",
        },
        .body = "",
        .allocator = std.testing.allocator,
    };
}

test "withState injects state and forwards handler arguments" {
    var state: TestState = .{};
    var context: Context = .{
        .client = undefined,
        .database = undefined,
        .user_data = &state,
    };
    const request = testRequest();
    const parameters = [_]PathParameter{.{ .name = "id", .value = "42" }};

    const response = try withState(TestState, testHandler)(
        &context,
        &request,
        &parameters,
    );

    try std.testing.expectEqual(@as(usize, 1), state.handler_calls);
    try std.testing.expectEqual(Response.Status.ok.code, response.status.code);
}

test "withState rejects missing application state" {
    var context: Context = .{
        .client = undefined,
        .database = undefined,
        .user_data = null,
    };
    const request = testRequest();

    try std.testing.expectError(
        error.MissingApplicationState,
        withState(TestState, testHandler)(&context, &request, &.{}),
    );
}
