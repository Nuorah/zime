const std = @import("std");
const SqliteConfig = @import("config.zig").SqliteConfig;
const Value = @import("value.zig").Value;
const ExecuteResult = @import("value.zig").ExecuteResult;

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Database = struct {
    handle: *c.sqlite3,

    pub fn open(
        allocator: std.mem.Allocator,
        config: SqliteConfig,
    ) !Database {
        if (config.busy_timeout_ms > std.math.maxInt(c_int))
            return error.InvalidBusyTimeout;

        const path = try allocator.dupeZ(u8, config.path);
        defer allocator.free(path);

        var handle: ?*c.sqlite3 = null;
        var flags: c_int = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_FULLMUTEX;
        if (config.create_if_missing)
            flags |= c.SQLITE_OPEN_CREATE;

        const open_result = c.sqlite3_open_v2(path.ptr, &handle, flags, null);
        if (open_result != c.SQLITE_OK) {
            if (handle) |opened_handle|
                _ = c.sqlite3_close_v2(opened_handle);
            return error.DatabaseOpenFailed;
        }

        const database: Database = .{ .handle = handle.? };
        errdefer database.close();

        if (c.sqlite3_busy_timeout(
            database.handle,
            @intCast(config.busy_timeout_ms),
        ) != c.SQLITE_OK) {
            return error.BusyTimeoutFailed;
        }

        return database;
    }

    pub fn deinit(self: *Database) void {
        self.close();
    }

    fn close(self: *const Database) void {
        _ = c.sqlite3_close_v2(self.handle);
    }

    pub fn execute(
        self: *Database,
        sql: []const u8,
        parameters: []const Value,
    ) !ExecuteResult {
        const statement = try prepare(self.handle, sql, parameters);
        defer _ = c.sqlite3_finalize(statement);

        while (true) {
            switch (c.sqlite3_step(statement)) {
                c.SQLITE_ROW => continue,
                c.SQLITE_DONE => break,
                else => return error.ExecuteFailed,
            }
        }

        const affected_rows = c.sqlite3_changes64(self.handle);
        return .{
            .affected_rows = std.math.cast(u64, affected_rows) orelse 0,
        };
    }

    pub fn query(
        self: *Database,
        sql: []const u8,
        parameters: []const Value,
    ) !Query {
        return .{ .statement = try prepare(self.handle, sql, parameters) };
    }

    pub fn errorMessage(self: *const Database) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }
};

pub const Query = struct {
    statement: *c.sqlite3_stmt,

    pub fn deinit(self: *Query) void {
        _ = c.sqlite3_finalize(self.statement);
    }

    pub fn next(self: *Query) !?Row {
        return switch (c.sqlite3_step(self.statement)) {
            c.SQLITE_ROW => .{ .statement = self.statement },
            c.SQLITE_DONE => null,
            else => error.QueryFailed,
        };
    }
};

pub const Row = struct {
    statement: *c.sqlite3_stmt,

    pub fn value(self: Row, index: usize) !Value {
        const column_index = try self.columnIndex(index);
        return switch (c.sqlite3_column_type(self.statement, column_index)) {
            c.SQLITE_NULL => .null,
            c.SQLITE_INTEGER => .{
                .integer = c.sqlite3_column_int64(self.statement, column_index),
            },
            c.SQLITE_FLOAT => .{
                .real = c.sqlite3_column_double(self.statement, column_index),
            },
            c.SQLITE_TEXT => .{
                .text = try self.text(column_index),
            },
            c.SQLITE_BLOB => .{
                .blob = try self.blob(column_index),
            },
            else => error.UnsupportedColumnType,
        };
    }

    fn columnIndex(self: Row, index: usize) !c_int {
        if (index >= @as(usize, @intCast(c.sqlite3_column_count(self.statement))))
            return error.ColumnOutOfBounds;
        return @intCast(index);
    }

    fn text(self: Row, index: c_int) ![]const u8 {
        const length = c.sqlite3_column_bytes(self.statement, index);
        if (length < 0)
            return error.InvalidColumnLength;

        const pointer = c.sqlite3_column_text(self.statement, index);
        if (pointer == null)
            return if (length == 0) "" else error.InvalidColumnPointer;
        return pointer[0..@intCast(length)];
    }

    fn blob(self: Row, index: c_int) ![]const u8 {
        const length = c.sqlite3_column_bytes(self.statement, index);
        if (length < 0)
            return error.InvalidColumnLength;

        const pointer = c.sqlite3_column_blob(self.statement, index);
        if (pointer == null)
            return if (length == 0) "" else error.InvalidColumnPointer;
        const bytes: [*]const u8 = @ptrCast(pointer);
        return bytes[0..@intCast(length)];
    }
};

fn prepare(
    handle: *c.sqlite3,
    sql: []const u8,
    parameters: []const Value,
) !*c.sqlite3_stmt {
    if (sql.len > std.math.maxInt(c_int))
        return error.SqlTooLong;

    var statement: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(
        handle,
        sql.ptr,
        @intCast(sql.len),
        &statement,
        null,
    ) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }

    const prepared = statement orelse return error.EmptyStatement;
    errdefer _ = c.sqlite3_finalize(prepared);

    if (parameters.len != @as(usize, @intCast(c.sqlite3_bind_parameter_count(prepared))))
        return error.ParameterCountMismatch;

    for (parameters, 1..) |parameter, index| {
        if (index > std.math.maxInt(c_int))
            return error.TooManyParameters;
        try bind(prepared, @intCast(index), parameter);
    }

    return prepared;
}

fn bind(statement: *c.sqlite3_stmt, index: c_int, value: Value) !void {
    const result = switch (value) {
        .null => c.sqlite3_bind_null(statement, index),
        .integer => |integer| c.sqlite3_bind_int64(statement, index, integer),
        .real => |real| c.sqlite3_bind_double(statement, index, real),
        .text => |text| bind_text: {
            if (text.len > std.math.maxInt(c_int))
                return error.ParameterTooLarge;
            break :bind_text c.sqlite3_bind_text(
                statement,
                index,
                text.ptr,
                @intCast(text.len),
                c.SQLITE_STATIC,
            );
        },
        .blob => |blob| bind_blob: {
            if (blob.len > std.math.maxInt(c_int))
                return error.ParameterTooLarge;
            break :bind_blob c.sqlite3_bind_blob(
                statement,
                index,
                blob.ptr,
                @intCast(blob.len),
                c.SQLITE_STATIC,
            );
        },
    };

    if (result != c.SQLITE_OK)
        return error.BindFailed;
}
