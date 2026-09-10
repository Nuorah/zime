pub const Config = @import("config.zig").Config;
pub const Database = @import("database.zig").Database;
pub const ExecuteResult = @import("value.zig").ExecuteResult;
pub const Query = @import("database.zig").Query;
pub const Row = @import("database.zig").Row;
pub const SqliteConfig = @import("config.zig").SqliteConfig;
pub const Value = @import("value.zig").Value;

const std = @import("std");

test "open in-memory database and execute parameterized SQL" {
    var database = try Database.open(std.testing.allocator, .{
        .sqlite = .{ .path = ":memory:" },
    });
    defer database.deinit();

    _ = try database.execute(
        "create table values_test (i integer, r real, t text, b blob, n text)",
        &.{},
    );

    const result = try database.execute(
        "insert into values_test (i, r, t, b, n) values (?, ?, ?, ?, ?)",
        &.{
            .{ .integer = 42 },
            .{ .real = 3.5 },
            .{ .text = "hello" },
            .{ .blob = "\x00\xff" },
            .null,
        },
    );

    try std.testing.expectEqual(@as(u64, 1), result.affected_rows);

    var query = try database.query(
        "select i, r, t, b, n from values_test",
        &.{},
    );
    defer query.deinit();

    const row = (try query.next()).?;
    try std.testing.expectEqual(@as(i64, 42), try row.integer(0));
    try std.testing.expectEqual(@as(f64, 3.5), switch (try row.value(1)) {
        .real => |real| real,
        else => return error.UnexpectedColumnType,
    });
    try std.testing.expectEqualStrings("hello", try row.text(2));
    try std.testing.expectEqual(@as(?i64, 42), try row.optionalInteger(0));
    try std.testing.expectEqualStrings("hello", (try row.optionalText(2)).?);
    try std.testing.expectEqualSlices(u8, "\x00\xff", switch (try row.value(3)) {
        .blob => |blob| blob,
        else => return error.UnexpectedColumnType,
    });
    try std.testing.expect(try row.value(4) == .null);
    try std.testing.expect((try row.optionalText(4)) == null);
    try std.testing.expect((try row.optionalInteger(4)) == null);
    try std.testing.expect((try query.next()) == null);
}

test "reject mismatched parameter count" {
    var database = try Database.open(std.testing.allocator, .{
        .sqlite = .{ .path = ":memory:" },
    });
    defer database.deinit();

    try std.testing.expectError(
        error.ParameterCountMismatch,
        database.execute("select ?", &.{}),
    );
}
