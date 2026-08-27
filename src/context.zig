const Database = @import("database").Database;
const Client = @import("http").Client;

pub const Context = @This();

client: *Client,
database: *Database,
user_data: ?*anyopaque,

pub fn state(self: *Context, comptime T: type) ?*T {
    const pointer = self.user_data orelse return null;
    return @ptrCast(@alignCast(pointer));
}
