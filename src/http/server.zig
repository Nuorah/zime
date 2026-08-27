const std = @import("std");
const Connection = @import("connection.zig");

pub const Server = @This();

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    kernel_backlog: u31 = 1024,
};

io: std.Io,
listener: std.Io.net.Server,

pub fn listen(io: std.Io, config: Config) !Server {
    const address = try std.Io.net.IpAddress.parse(config.host, config.port);
    return .{
        .io = io,
        .listener = try address.listen(io, .{
            .reuse_address = true,
            .kernel_backlog = config.kernel_backlog,
        }),
    };
}

pub fn deinit(self: *Server) void {
    self.listener.deinit(self.io);
}

pub fn accept(self: *Server) !Connection {
    return Connection.init(self.io, try self.listener.accept(self.io));
}
