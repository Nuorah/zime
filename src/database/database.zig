const std = @import("std");
const config = @import("config.zig");
const sqlite = @import("sqlite.zig");
const values = @import("value.zig");

pub const Database = struct {
    backend: Backend,

    const Backend = union(enum) {
        sqlite: sqlite.Database,
    };

    pub fn open(
        allocator: std.mem.Allocator,
        options: config.Config,
    ) !Database {
        return .{
            .backend = switch (options) {
                .sqlite => |sqlite_options| .{
                    .sqlite = try sqlite.Database.open(allocator, sqlite_options),
                },
            },
        };
    }

    pub fn deinit(self: *Database) void {
        switch (self.backend) {
            .sqlite => |*database| database.deinit(),
        }
    }

    pub fn execute(
        self: *Database,
        sql: []const u8,
        parameters: []const values.Value,
    ) !values.ExecuteResult {
        return switch (self.backend) {
            .sqlite => |*database| database.execute(sql, parameters),
        };
    }

    pub fn query(
        self: *Database,
        sql: []const u8,
        parameters: []const values.Value,
    ) !Query {
        return .{
            .backend = switch (self.backend) {
                .sqlite => |*database| .{
                    .sqlite = try database.query(sql, parameters),
                },
            },
        };
    }

    pub fn errorMessage(self: *const Database) []const u8 {
        return switch (self.backend) {
            .sqlite => |*database| database.errorMessage(),
        };
    }
};

pub const Query = struct {
    backend: Backend,

    const Backend = union(enum) {
        sqlite: sqlite.Query,
    };

    pub fn deinit(self: *Query) void {
        switch (self.backend) {
            .sqlite => |*query| query.deinit(),
        }
    }

    pub fn next(self: *Query) !?Row {
        return switch (self.backend) {
            .sqlite => |*query| if (try query.next()) |row|
                .{ .backend = .{ .sqlite = row } }
            else
                null,
        };
    }
};

pub const Row = struct {
    backend: Backend,

    const Backend = union(enum) {
        sqlite: sqlite.Row,
    };

    pub fn value(self: Row, index: usize) !values.Value {
        return switch (self.backend) {
            .sqlite => |row| row.value(index),
        };
    }

    pub fn integer(self: Row, index: usize) !i64 {
        return switch (try self.value(index)) {
            .integer => |result| result,
            else => error.ColumnTypeMismatch,
        };
    }

    pub fn text(self: Row, index: usize) ![]const u8 {
        return switch (try self.value(index)) {
            .text => |result| result,
            else => error.ColumnTypeMismatch,
        };
    }
};
