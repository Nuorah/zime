const std = @import("std");

pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const BodyFraming = union(enum) {
    none,
    content_length: u64,
};

pub const ParsedHeaders = struct {
    items: []const Header,
    framing: BodyFraming,
    connection_close: bool,
    host: []const u8,
};

pub const Request = @This();

pub const max_request_line_len = 8 * 1024;
pub const max_header_line_len = 8 * 1024;
pub const max_header_bytes = 32 * 1024;
pub const max_header_count = 100;
pub const max_body_len = 1024 * 1024;

method: Method,
target: []const u8,
headers: ParsedHeaders,
body: []const u8,
allocator: std.mem.Allocator,

pub fn parse(reader: *std.Io.Reader, allocator: std.mem.Allocator) !Request {
    const raw_request_line = (try reader.takeDelimiter('\n')) orelse
        return error.IncompleteRequestLine;

    if (raw_request_line.len > max_request_line_len)
        return error.RequestLineTooLong;

    if (raw_request_line.len == 0 or raw_request_line[raw_request_line.len - 1] != '\r')
        return error.InvalidRequestLine;
    const request_line = raw_request_line[0 .. raw_request_line.len - 1];
    var parts = std.mem.splitScalar(u8, request_line, ' ');

    const method_text = parts.next() orelse return error.InvalidRequestLine;
    const target_text = parts.next() orelse return error.InvalidRequestLine;
    const version_text = parts.next() orelse return error.InvalidRequestLine;

    if (method_text.len == 0 or target_text.len == 0 or version_text.len == 0)
        return error.InvalidRequestLine;
    if (parts.next() != null)
        return error.InvalidRequestLine;

    const method = std.meta.stringToEnum(Method, method_text) orelse
        return error.MethodNotSupported;

    if (!std.mem.eql(u8, version_text, "HTTP/1.1"))
        return error.HttpVersionNotSupported;
    if (!isValidTarget(target_text))
        return error.InvalidRequestTarget;

    const target = try allocator.dupe(u8, target_text);
    errdefer allocator.free(target);

    var items: std.ArrayList(Header) = .empty;
    errdefer deinitHeaderList(&items, allocator);

    var host: ?[]const u8 = null;
    var content_length: ?u64 = null;
    var connection_close = false;
    var header_bytes: usize = 0;

    while (true) {
        const raw_line = (try reader.takeDelimiter('\n')) orelse
            return error.IncompleteHeaders;

        if (raw_line.len > max_header_line_len)
            return error.HeaderLineTooLong;
        if (raw_line.len > max_header_bytes - header_bytes)
            return error.HeadersTooLarge;
        header_bytes += raw_line.len;

        if (raw_line.len == 0 or raw_line[raw_line.len - 1] != '\r')
            return error.InvalidHeaderLine;
        const line = raw_line[0 .. raw_line.len - 1];
        if (line.len == 0)
            break;

        if (items.items.len == max_header_count)
            return error.TooManyHeaders;
        if (line[0] == ' ' or line[0] == '\t')
            return error.HeaderContinuationUnsupported;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse
            return error.InvalidHeaderLine;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (!isValidHeaderName(name))
            return error.InvalidHeaderName;
        if (!isValidHeaderValue(value))
            return error.InvalidHeaderValue;

        const owned_header = try appendOwnedHeader(&items, allocator, name, value);

        if (std.ascii.eqlIgnoreCase(name, "host")) {
            if (host != null)
                return error.DuplicateHost;
            if (!isSaneHost(value))
                return error.InvalidHost;
            host = owned_header.value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (content_length != null)
                return error.DuplicateContentLength;
            if (value.len == 0)
                return error.InvalidContentLength;
            for (value) |byte| {
                if (byte < '0' or byte > '9')
                    return error.InvalidContentLength;
            }
            content_length = std.fmt.parseInt(u64, value, 10) catch
                return error.InvalidContentLength;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            return error.TransferEncodingUnsupported;
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            return error.ExpectationUnsupported;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (connectionContainsClose(value))
                connection_close = true;
        }
    }

    const host_value = host orelse return error.MissingHost;
    const body_len_u64 = content_length orelse 0;
    if (body_len_u64 > max_body_len)
        return error.BodyTooLarge;

    const body_len = std.math.cast(usize, body_len_u64) orelse
        return error.BodyTooLarge;
    const body = try allocator.alloc(u8, body_len);
    errdefer allocator.free(body);
    try reader.readSliceAll(body);

    const framing: BodyFraming = if (content_length) |length|
        .{ .content_length = length }
    else
        .none;

    const owned_items = try items.toOwnedSlice(allocator);

    return .{
        .method = method,
        .target = target,
        .headers = .{
            .items = owned_items,
            .framing = framing,
            .connection_close = connection_close,
            .host = host_value,
        },
        .body = body,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Request) void {
    for (self.headers.items) |item| {
        self.allocator.free(item.name);
        self.allocator.free(item.value);
    }
    self.allocator.free(self.headers.items);
    self.allocator.free(self.target);
    self.allocator.free(self.body);
}

pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
    for (self.headers.items) |item| {
        if (std.ascii.eqlIgnoreCase(item.name, name))
            return item.value;
    }
    return null;
}

fn appendOwnedHeader(
    items: *std.ArrayList(Header),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
) !Header {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);

    const owned_header: Header = .{
        .name = owned_name,
        .value = owned_value,
    };
    try items.append(allocator, owned_header);
    return owned_header;
}

fn deinitHeaderList(items: *std.ArrayList(Header), allocator: std.mem.Allocator) void {
    for (items.items) |item| {
        allocator.free(item.name);
        allocator.free(item.value);
    }
    items.deinit(allocator);
}

fn isValidTarget(target: []const u8) bool {
    if (target.len == 0 or target[0] != '/')
        return false;

    var index: usize = 0;
    while (index < target.len) : (index += 1) {
        const byte = target[index];

        if (std.ascii.isAlphanumeric(byte) or
            std.mem.indexOfScalar(u8, "!$&'()*+,-./:;=?@_~", byte) != null)
        {
            continue;
        }

        if (byte == '%') {
            if (index + 2 >= target.len or
                !std.ascii.isHex(target[index + 1]) or
                !std.ascii.isHex(target[index + 2]))
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

fn isValidHeaderValue(value: []const u8) bool {
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

fn isSaneHost(host: []const u8) bool {
    if (host.len == 0)
        return false;

    for (host) |byte| {
        if (byte <= 0x20 or byte >= 0x7f)
            return false;

        switch (byte) {
            '/', '\\', '?', '#', '@', ',' => return false,
            else => {},
        }
    }

    return true;
}

fn connectionContainsClose(value: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t");
        if (std.ascii.eqlIgnoreCase(token, "close"))
            return true;
    }
    return false;
}

// TESTS

fn parseTestRequest(input: []const u8) !Request {
    var reader = std.Io.Reader.fixed(input);
    return parse(&reader, std.testing.allocator);
}

fn expectRequestError(expected: anyerror, input: []const u8) !void {
    var reader = std.Io.Reader.fixed(input);
    const result = parse(&reader, std.testing.allocator);
    if (result) |request_value| {
        var request = request_value;
        request.deinit();
        return error.ExpectedRequestError;
    } else |actual| {
        try std.testing.expectEqual(expected, actual);
    }
}

test "parse minimal GET request" {
    var request = try parseTestRequest(
        "GET / HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "\r\n",
    );
    defer request.deinit();

    try std.testing.expectEqual(Method.GET, request.method);
    try std.testing.expectEqualStrings("/", request.target);
    try std.testing.expectEqualStrings("example.com", request.headers.host);
    try std.testing.expectEqual(@as(usize, 0), request.body.len);
    try std.testing.expect(!request.headers.connection_close);
    switch (request.headers.framing) {
        .none => {},
        else => return error.UnexpectedBodyFraming,
    }
}

test "parse POST request with fixed binary body" {
    var request = try parseTestRequest(
        "POST /submit?source=test HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "\x00\x01\x7f\x80\xff",
    );
    defer request.deinit();

    try std.testing.expectEqual(Method.POST, request.method);
    try std.testing.expectEqualStrings("/submit?source=test", request.target);
    try std.testing.expectEqualSlices(u8, "\x00\x01\x7f\x80\xff", request.body);
    switch (request.headers.framing) {
        .content_length => |length| try std.testing.expectEqual(@as(u64, 5), length),
        else => return error.UnexpectedBodyFraming,
    }
}

test "preserve generic headers, duplicates, casing, and colons in values" {
    var request = try parseTestRequest(
        "GET / HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "X-Thing: one\r\n" ++
            "x-thing: two\r\n" ++
            "X-Address: example.com:8080\r\n" ++
            "X-Empty:   \r\n" ++
            "\r\n",
    );
    defer request.deinit();

    try std.testing.expectEqual(@as(usize, 5), request.headers.items.len);
    try std.testing.expectEqualStrings("X-Thing", request.headers.items[1].name);
    try std.testing.expectEqualStrings("one", request.headers.items[1].value);
    try std.testing.expectEqualStrings("x-thing", request.headers.items[2].name);
    try std.testing.expectEqualStrings("two", request.headers.items[2].value);
    try std.testing.expectEqualStrings("one", request.header("X-THING").?);
    try std.testing.expectEqualStrings("example.com:8080", request.header("x-address").?);
    try std.testing.expectEqualStrings("", request.header("x-empty").?);
    try std.testing.expect(request.header("missing") == null);
}

test "reject malformed request lines" {
    const cases = [_][]const u8{
        "\r\n",
        "GET\r\nHost: example.com\r\n\r\n",
        "GET /\r\nHost: example.com\r\n\r\n",
        "GET HTTP/1.1\r\nHost: example.com\r\n\r\n",
        "GET  HTTP/1.1\r\nHost: example.com\r\n\r\n",
        "GET /  HTTP/1.1\r\nHost: example.com\r\n\r\n",
        " GET / HTTP/1.1\r\nHost: example.com\r\n\r\n",
        "GET / HTTP/1.1 extra\r\nHost: example.com\r\n\r\n",
        "GET\t/\tHTTP/1.1\r\nHost: example.com\r\n\r\n",
        "GET / HTTP/1.1\nHost: example.com\r\n\r\n",
    };

    for (cases) |input|
        try expectRequestError(error.InvalidRequestLine, input);

    try expectRequestError(error.IncompleteRequestLine, "");
}

test "accept supported HTTP methods" {
    const methods = [_]Method{ .GET, .POST, .PUT, .PATCH, .DELETE };
    for (methods) |method| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(std.testing.allocator);
        try input.appendSlice(std.testing.allocator, @tagName(method));
        try input.appendSlice(std.testing.allocator, " / HTTP/1.1\r\nHost: example.com\r\n\r\n");

        var request = try parseTestRequest(input.items);
        defer request.deinit();
        try std.testing.expectEqual(method, request.method);
    }
}

test "methods are case-sensitive and HTTP version is exactly 1.1" {
    const bad_methods = [_][]const u8{ "get", "post", "GeT", "UNKNOWN" };
    for (bad_methods) |method| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(std.testing.allocator);
        try input.appendSlice(std.testing.allocator, method);
        try input.appendSlice(std.testing.allocator, " / HTTP/1.1\r\nHost: example.com\r\n\r\n");
        try expectRequestError(error.MethodNotSupported, input.items);
    }

    const versions = [_][]const u8{ "HTTP/1.0", "HTTP/2", "http/1.1", "HTTP/1.2" };
    for (versions) |version| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(std.testing.allocator);
        try input.appendSlice(std.testing.allocator, "GET / ");
        try input.appendSlice(std.testing.allocator, version);
        try input.appendSlice(std.testing.allocator, "\r\nHost: example.com\r\n\r\n");
        try expectRequestError(error.HttpVersionNotSupported, input.items);
    }
}

test "accept valid origin-form request targets without normalizing them" {
    const targets = [_][]const u8{
        "/",
        "/users/42",
        "/users?name=bob&active=true",
        "/search?q=hello%20world",
        "/%2f/%2F",
        "/a/b/../c",
        "//double/slash",
        "/path;parameter=value",
    };

    for (targets) |target| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(std.testing.allocator);
        try input.appendSlice(std.testing.allocator, "GET ");
        try input.appendSlice(std.testing.allocator, target);
        try input.appendSlice(std.testing.allocator, " HTTP/1.1\r\nHost: example.com\r\n\r\n");

        var request = try parseTestRequest(input.items);
        defer request.deinit();
        try std.testing.expectEqualStrings(target, request.target);
    }
}

test "reject invalid or unsupported request targets" {
    const targets = [_][]const u8{
        "users",
        "*",
        "http://example.com/path",
        "example.com:443",
        "/fragment#part",
        "/back\\slash",
        "/%",
        "/%1",
        "/%GG",
        "/%0G",
    };

    for (targets) |target| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(std.testing.allocator);
        try input.appendSlice(std.testing.allocator, "GET ");
        try input.appendSlice(std.testing.allocator, target);
        try input.appendSlice(std.testing.allocator, " HTTP/1.1\r\nHost: example.com\r\n\r\n");
        try expectRequestError(error.InvalidRequestTarget, input.items);
    }
}

test "validate header line syntax and values" {
    const cases = [_]struct {
        expected: anyerror,
        line: []const u8,
    }{
        .{ .expected = error.InvalidHeaderLine, .line = "No-Colon\r\n" },
        .{ .expected = error.InvalidHeaderName, .line = ": value\r\n" },
        .{ .expected = error.InvalidHeaderName, .line = "Bad Name: value\r\n" },
        .{ .expected = error.InvalidHeaderName, .line = "Bad(Name): value\r\n" },
        .{ .expected = error.InvalidHeaderName, .line = "Name : value\r\n" },
        .{ .expected = error.HeaderContinuationUnsupported, .line = " Name: value\r\n" },
        .{ .expected = error.HeaderContinuationUnsupported, .line = "\tName: value\r\n" },
        .{ .expected = error.InvalidHeaderValue, .line = "Name: value\x00here\r\n" },
        .{ .expected = error.InvalidHeaderValue, .line = "Name: value\x1fhere\r\n" },
        .{ .expected = error.InvalidHeaderValue, .line = "Name: value\x7fhere\r\n" },
        .{ .expected = error.InvalidHeaderLine, .line = "Name: value\n" },
    };

    for (cases) |case| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(std.testing.allocator);
        try input.appendSlice(std.testing.allocator, "GET / HTTP/1.1\r\n");
        try input.appendSlice(std.testing.allocator, case.line);
        try input.appendSlice(std.testing.allocator, "Host: example.com\r\n\r\n");
        try expectRequestError(case.expected, input.items);
    }

    try expectRequestError(
        error.IncompleteHeaders,
        "GET / HTTP/1.1\r\nHost: example.com\r\n",
    );
}

test "accept visible, tab, and opaque bytes in generic header values" {
    var request = try parseTestRequest(
        "GET / HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "X-Value:\t visible: text \t\r\n" ++
            "X-Opaque: \x80\xff\r\n" ++
            "\r\n",
    );
    defer request.deinit();

    try std.testing.expectEqualStrings("visible: text", request.header("x-value").?);
    try std.testing.expectEqualSlices(u8, "\x80\xff", request.header("x-opaque").?);
}

test "require exactly one nonempty sane Host header" {
    try expectRequestError(
        error.MissingHost,
        "GET / HTTP/1.1\r\nUser-Agent: test\r\n\r\n",
    );
    try expectRequestError(
        error.InvalidHost,
        "GET / HTTP/1.1\r\nHost:   \r\n\r\n",
    );
    try expectRequestError(
        error.DuplicateHost,
        "GET / HTTP/1.1\r\nHost: one.example\r\nhOsT: two.example\r\n\r\n",
    );

    const invalid_hosts = [_][]const u8{
        "bad host",
        "example.com/path",
        "user@example.com",
        "example.com?query",
        "example.com#fragment",
        "one.example,two.example",
    };
    for (invalid_hosts) |host| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(std.testing.allocator);
        try input.appendSlice(std.testing.allocator, "GET / HTTP/1.1\r\nHost: ");
        try input.appendSlice(std.testing.allocator, host);
        try input.appendSlice(std.testing.allocator, "\r\n\r\n");
        try expectRequestError(error.InvalidHost, input.items);
    }
}

test "parse strict Content-Length values" {
    const cases = [_]struct {
        value: []const u8,
        expected: u64,
    }{
        .{ .value = "0", .expected = 0 },
        .{ .value = "1", .expected = 1 },
        .{ .value = "0005", .expected = 5 },
    };

    for (cases) |case| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(std.testing.allocator);
        try input.appendSlice(std.testing.allocator, "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: ");
        try input.appendSlice(std.testing.allocator, case.value);
        try input.appendSlice(std.testing.allocator, "\r\n\r\n");
        for (0..case.expected) |_|
            try input.append(std.testing.allocator, 'x');

        var request = try parseTestRequest(input.items);
        defer request.deinit();
        switch (request.headers.framing) {
            .content_length => |length| try std.testing.expectEqual(case.expected, length),
            else => return error.UnexpectedBodyFraming,
        }
        try std.testing.expectEqual(@as(usize, @intCast(case.expected)), request.body.len);
    }
}

test "reject malformed, duplicate, oversized, and truncated Content-Length" {
    const malformed = [_][]const u8{
        "",
        "+1",
        "-1",
        "1.0",
        "1x",
        "0x10",
        "1, 1",
        "18446744073709551616",
    };

    for (malformed) |value| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(std.testing.allocator);
        try input.appendSlice(std.testing.allocator, "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: ");
        try input.appendSlice(std.testing.allocator, value);
        try input.appendSlice(std.testing.allocator, "\r\n\r\n");
        try expectRequestError(error.InvalidContentLength, input.items);
    }

    try expectRequestError(
        error.DuplicateContentLength,
        "POST / HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "Content-Length: 1\r\n" ++
            "content-length: 1\r\n" ++
            "\r\n" ++
            "x",
    );
    try expectRequestError(
        error.BodyTooLarge,
        "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 1048577\r\n\r\n",
    );
    try expectRequestError(
        error.EndOfStream,
        "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nabc",
    );
}

test "reject Transfer-Encoding and Expect" {
    const lines = [_]struct {
        expected: anyerror,
        line: []const u8,
    }{
        .{ .expected = error.TransferEncodingUnsupported, .line = "Transfer-Encoding: chunked\r\n" },
        .{ .expected = error.TransferEncodingUnsupported, .line = "transfer-encoding: GZIP\r\n" },
        .{ .expected = error.ExpectationUnsupported, .line = "Expect: 100-continue\r\n" },
        .{ .expected = error.ExpectationUnsupported, .line = "expect: something-else\r\n" },
    };

    for (lines) |case| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(std.testing.allocator);
        try input.appendSlice(std.testing.allocator, "POST / HTTP/1.1\r\nHost: example.com\r\n");
        try input.appendSlice(std.testing.allocator, case.line);
        try input.appendSlice(std.testing.allocator, "\r\n");
        try expectRequestError(case.expected, input.items);
    }
}

test "detect close as a case-insensitive Connection token" {
    const closing = [_][]const u8{
        "close",
        "CLOSE",
        "keep-alive, close",
        "upgrade,\tClOsE",
        " close ",
    };
    for (closing) |value| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(std.testing.allocator);
        try input.appendSlice(std.testing.allocator, "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: ");
        try input.appendSlice(std.testing.allocator, value);
        try input.appendSlice(std.testing.allocator, "\r\n\r\n");

        var request = try parseTestRequest(input.items);
        defer request.deinit();
        try std.testing.expect(request.headers.connection_close);
    }

    const persistent = [_][]const u8{ "keep-alive", "upgrade", "closed", "x-close" };
    for (persistent) |value| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(std.testing.allocator);
        try input.appendSlice(std.testing.allocator, "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: ");
        try input.appendSlice(std.testing.allocator, value);
        try input.appendSlice(std.testing.allocator, "\r\n\r\n");

        var request = try parseTestRequest(input.items);
        defer request.deinit();
        try std.testing.expect(!request.headers.connection_close);
    }
}

test "consume exactly Content-Length bytes and leave the next request" {
    const input =
        "POST /one HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Length: 3\r\n" ++
        "\r\n" ++
        "abc" ++
        "GET /two HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    var reader = std.Io.Reader.fixed(input);
    var first = try parse(&reader, std.testing.allocator);
    defer first.deinit();
    try std.testing.expectEqualStrings("abc", first.body);

    var second = try parse(&reader, std.testing.allocator);
    defer second.deinit();
    try std.testing.expectEqual(Method.GET, second.method);
    try std.testing.expectEqualStrings("/two", second.target);
}

test "request owns target headers host and body independently of input" {
    var input = ("POST /owned HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Test: preserved\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "hello").*;

    var reader = std.Io.Reader.fixed(&input);
    var request = try parse(&reader, std.testing.allocator);
    defer request.deinit();

    @memset(&input, 'x');

    try std.testing.expectEqualStrings("/owned", request.target);
    try std.testing.expectEqualStrings("example.com", request.headers.host);
    try std.testing.expectEqualStrings("preserved", request.header("x-test").?);
    try std.testing.expectEqualStrings("hello", request.body);
}

test "clean up allocations when parsing fails after owned headers" {
    try expectRequestError(
        error.InvalidHeaderName,
        "GET /owned HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "X-Owned: value\r\n" ++
            "Bad Name: rejected\r\n" ++
            "\r\n",
    );

    try expectRequestError(
        error.EndOfStream,
        "POST /owned HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "X-Owned: value\r\n" ++
            "Content-Length: 10\r\n" ++
            "\r\n" ++
            "short",
    );
}

test "enforce request line limit" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "GET /");
    for (0..max_request_line_len) |_|
        try input.append(std.testing.allocator, 'a');
    try input.appendSlice(std.testing.allocator, " HTTP/1.1\r\nHost: example.com\r\n\r\n");

    try expectRequestError(error.RequestLineTooLong, input.items);
}

test "enforce individual header line limit" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "GET / HTTP/1.1\r\nHost: example.com\r\nX-Long: ");
    for (0..max_header_line_len) |_|
        try input.append(std.testing.allocator, 'a');
    try input.appendSlice(std.testing.allocator, "\r\n\r\n");

    try expectRequestError(error.HeaderLineTooLong, input.items);
}

test "enforce header count limit" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "GET / HTTP/1.1\r\nHost: example.com\r\n");
    for (0..max_header_count) |_|
        try input.appendSlice(std.testing.allocator, "X-Test: value\r\n");
    try input.appendSlice(std.testing.allocator, "\r\n");

    try expectRequestError(error.TooManyHeaders, input.items);
}

test "enforce total header byte limit" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "GET / HTTP/1.1\r\nHost: example.com\r\n");
    for (0..5) |_| {
        try input.appendSlice(std.testing.allocator, "X-Long: ");
        for (0..7000) |_|
            try input.append(std.testing.allocator, 'a');
        try input.appendSlice(std.testing.allocator, "\r\n");
    }
    try input.appendSlice(std.testing.allocator, "\r\n");

    try expectRequestError(error.HeadersTooLarge, input.items);
}
