const std = @import("std");

pub fn decode(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
) !T {
    return decodeInternal(T, allocator, input, false);
}

pub fn decodeWithUnknownFields(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
) !T {
    return decodeInternal(T, allocator, input, true);
}

fn decodeInternal(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    ignore_unknown_fields: bool,
) !T {
    return std.json.parseFromSliceLeaky(T, allocator, input, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = ignore_unknown_fields,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
}

pub fn encode(
    allocator: std.mem.Allocator,
    value: anytype,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

test "decode strict typed JSON into arena memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Input = struct {
        name: []const u8,
        active: bool,
    };

    const input = try decode(
        Input,
        arena.allocator(),
        "{\"name\":\"anon\",\"active\":true}",
    );

    try std.testing.expectEqualStrings("anon", input.name);
    try std.testing.expect(input.active);
}

test "decode rejects malformed and unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Input = struct { name: []const u8 };

    try std.testing.expectError(
        error.InvalidJson,
        decode(Input, arena.allocator(), "{"),
    );
    try std.testing.expectError(
        error.InvalidJson,
        decode(Input, arena.allocator(), "{\"name\":\"anon\",\"extra\":1}"),
    );
}

test "decode with unknown fields accepts extra data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Input = struct { name: []const u8 };
    const input = try decodeWithUnknownFields(
        Input,
        arena.allocator(),
        "{\"name\":\"anon\",\"future_field\":42}",
    );

    try std.testing.expectEqualStrings("anon", input.name);
}

test "encode compact JSON" {
    const encoded = try encode(std.testing.allocator, .{
        .id = @as(i64, 42),
        .name = "anon",
    });
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("{\"id\":42,\"name\":\"anon\"}", encoded);
}
