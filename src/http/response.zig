const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Status = struct {
    code: u16,
    reason: []const u8,

    pub const ok: Status = .{ .code = 200, .reason = "OK" };
    pub const created: Status = .{ .code = 201, .reason = "Created" };
    pub const no_content: Status = .{ .code = 204, .reason = "No Content" };
    pub const bad_request: Status = .{ .code = 400, .reason = "Bad Request" };
    pub const unauthorized: Status = .{ .code = 401, .reason = "Unauthorized" };
    pub const forbidden: Status = .{ .code = 403, .reason = "Forbidden" };
    pub const not_found: Status = .{ .code = 404, .reason = "Not Found" };
    pub const method_not_allowed: Status = .{ .code = 405, .reason = "Method Not Allowed" };
    pub const content_too_large: Status = .{ .code = 413, .reason = "Content Too Large" };
    pub const expectation_failed: Status = .{ .code = 417, .reason = "Expectation Failed" };
    pub const internal_server_error: Status = .{
        .code = 500,
        .reason = "Internal Server Error",
    };
    pub const not_implemented: Status = .{ .code = 501, .reason = "Not Implemented" };
    pub const http_version_not_supported: Status = .{
        .code = 505,
        .reason = "HTTP Version Not Supported",
    };

    pub fn fromCode(code: u16) !Status {
        return switch (code) {
            200 => .ok,
            201 => .created,
            204 => .no_content,
            400 => .bad_request,
            401 => .unauthorized,
            403 => .forbidden,
            404 => .not_found,
            405 => .method_not_allowed,
            413 => .content_too_large,
            417 => .expectation_failed,
            500 => .internal_server_error,
            501 => .not_implemented,
            505 => .http_version_not_supported,
            else => error.UnsupportedStatusCode,
        };
    }
};

pub const Response = @This();

pub const max_reason_len = 128;
pub const max_header_count = 100;
pub const max_header_bytes = 32 * 1024;

status: Status = .ok,
headers: []const Header = &.{},
body: []const u8 = "",

pub fn write(self: *const Response, writer: *std.Io.Writer) !void {
    try self.validate();

    try writer.print("HTTP/1.1 {d} {s}\r\n", .{
        self.status.code,
        self.status.reason,
    });

    for (self.headers) |item| {
        try writer.writeAll(item.name);
        try writer.writeAll(": ");
        try writer.writeAll(item.value);
        try writer.writeAll("\r\n");
    }

    if (!statusForbidsBody(self.status.code))
        try writer.print("Content-Length: {d}\r\n", .{self.body.len});

    try writer.writeAll(
        "Connection: close\r\n" ++
            "\r\n",
    );

    if (!statusForbidsBody(self.status.code))
        try writer.writeAll(self.body);
}

pub fn validate(self: *const Response) !void {
    if (self.status.code < 200 or self.status.code > 599)
        return error.InvalidStatusCode;
    if (self.status.reason.len > max_reason_len or !isValidFieldValue(self.status.reason))
        return error.InvalidReasonPhrase;
    if (statusForbidsBody(self.status.code) and self.body.len != 0)
        return error.BodyNotAllowedForStatus;
    if (self.headers.len > max_header_count)
        return error.TooManyHeaders;

    var header_bytes: usize = 0;
    for (self.headers) |item| {
        if (!isValidHeaderName(item.name))
            return error.InvalidHeaderName;
        if (!isValidFieldValue(item.value))
            return error.InvalidHeaderValue;
        if (isReservedHeader(item.name))
            return error.ReservedHeader;

        const line_bytes = std.math.add(usize, item.name.len, item.value.len + 4) catch
            return error.HeadersTooLarge;
        if (line_bytes > max_header_bytes - header_bytes)
            return error.HeadersTooLarge;
        header_bytes += line_bytes;
    }
}

fn statusForbidsBody(code: u16) bool {
    return code == 204 or code == 304;
}

fn isReservedHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "trailer");
}

fn isValidHeaderName(name: []const u8) bool {
    if (name.len == 0)
        return false;

    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null)
        {
            return false;
        }
    }

    return true;
}

fn isValidFieldValue(value: []const u8) bool {
    for (value) |byte| {
        if (byte == '\t' or
            (byte >= 0x20 and byte <= 0x7e) or
            byte >= 0x80)
        {
            continue;
        }
        return false;
    }

    return true;
}

fn expectWire(response: Response, expected: []const u8) !void {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try response.write(&writer);
    try std.testing.expectEqualSlices(u8, expected, writer.buffered());
}

test "write minimal empty 200 response" {
    try expectWire(.{},
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 0\r\n" ++
            "Connection: close\r\n" ++
            "\r\n");
}

test "write text body with byte-accurate Content-Length" {
    try expectWire(.{ .body = "YES SIR" },
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 7\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "YES SIR");
}

test "write binary body" {
    try expectWire(.{ .body = "\x00\x80\xff" },
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 3\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "\x00\x80\xff");
}

test "preserve custom header spelling order and duplicates" {
    const headers = [_]Header{
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "X-Thing", .value = "one" },
        .{ .name = "x-thing", .value = "two" },
    };

    try expectWire(.{ .headers = &headers, .body = "ok" },
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "X-Thing: one\r\n" ++
            "x-thing: two\r\n" ++
            "Content-Length: 2\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "ok");
}

test "map supported numeric status codes" {
    const cases = [_]Status{
        .ok,
        .created,
        .no_content,
        .bad_request,
        .unauthorized,
        .forbidden,
        .not_found,
        .method_not_allowed,
        .content_too_large,
        .expectation_failed,
        .internal_server_error,
        .not_implemented,
        .http_version_not_supported,
    };

    for (cases) |expected| {
        const actual = try Status.fromCode(expected.code);
        try std.testing.expectEqual(expected.code, actual.code);
        try std.testing.expectEqualStrings(expected.reason, actual.reason);
    }

    try std.testing.expectError(error.UnsupportedStatusCode, Status.fromCode(418));
    try std.testing.expectError(error.UnsupportedStatusCode, Status.fromCode(599));
}

test "reject invalid final status codes" {
    const codes = [_]u16{ 0, 100, 199, 600, 999 };
    for (codes) |code| {
        const response: Response = .{
            .status = .{ .code = code, .reason = "Invalid" },
        };
        try std.testing.expectError(error.InvalidStatusCode, response.validate());
    }
}

test "reject controls and excessive reason phrases" {
    const reasons = [_][]const u8{
        "Bad\rReason",
        "Bad\nReason",
        "Bad\x00Reason",
        "Bad\x1fReason",
        "Bad\x7fReason",
    };
    for (reasons) |reason| {
        const response: Response = .{
            .status = .{ .code = 500, .reason = reason },
        };
        try std.testing.expectError(error.InvalidReasonPhrase, response.validate());
    }

    const long_reason = [_]u8{'x'} ** (max_reason_len + 1);
    const response: Response = .{
        .status = .{ .code = 500, .reason = &long_reason },
    };
    try std.testing.expectError(error.InvalidReasonPhrase, response.validate());
}

test "reject invalid header names and values" {
    const invalid_names = [_][]const u8{
        "",
        "Bad Name",
        "Bad(Name)",
        "Name:",
        "Name/Part",
    };
    for (invalid_names) |name| {
        const headers = [_]Header{.{ .name = name, .value = "value" }};
        const response: Response = .{ .headers = &headers };
        try std.testing.expectError(error.InvalidHeaderName, response.validate());
    }

    const invalid_values = [_][]const u8{
        "injected\r\nX-Evil: yes",
        "bad\x00value",
        "bad\x1fvalue",
        "bad\x7fvalue",
    };
    for (invalid_values) |value| {
        const headers = [_]Header{.{ .name = "X-Test", .value = value }};
        const response: Response = .{ .headers = &headers };
        try std.testing.expectError(error.InvalidHeaderValue, response.validate());
    }
}

test "reject application-controlled framing headers" {
    const names = [_][]const u8{
        "Content-Length",
        "content-length",
        "Transfer-Encoding",
        "CONNECTION",
        "Trailer",
    };
    for (names) |name| {
        const headers = [_]Header{.{ .name = name, .value = "value" }};
        const response: Response = .{ .headers = &headers };
        try std.testing.expectError(error.ReservedHeader, response.validate());
    }
}

test "write bodyless 204 without Content-Length" {
    try expectWire(.{ .status = .no_content },
        "HTTP/1.1 204 No Content\r\n" ++
            "Connection: close\r\n" ++
            "\r\n");
}

test "reject body for status that forbids content" {
    const response: Response = .{
        .status = .no_content,
        .body = "not allowed",
    };
    try std.testing.expectError(error.BodyNotAllowedForStatus, response.validate());
}

test "enforce response header count" {
    const headers = [_]Header{.{ .name = "X-Test", .value = "value" }} ** (max_header_count + 1);
    const response: Response = .{ .headers = &headers };
    try std.testing.expectError(error.TooManyHeaders, response.validate());
}

test "enforce total response header bytes" {
    const large_value = [_]u8{'x'} ** max_header_bytes;
    const headers = [_]Header{.{ .name = "X-Test", .value = &large_value }};
    const response: Response = .{ .headers = &headers };
    try std.testing.expectError(error.HeadersTooLarge, response.validate());
}

test "propagate writer failure" {
    var buffer: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const response: Response = .{};
    try std.testing.expectError(error.WriteFailed, response.write(&writer));
}
