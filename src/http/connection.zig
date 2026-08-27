const std = @import("std");
const Request = @import("request.zig");
const Response = @import("response.zig");

pub const Connection = @This();

io: std.Io,
stream: std.Io.net.Stream,
reader_buffer: [Request.max_header_line_len + 1]u8 = undefined,
writer_buffer: [1024]u8 = undefined,

pub fn init(io: std.Io, stream: std.Io.net.Stream) Connection {
    return .{
        .io = io,
        .stream = stream,
    };
}

pub fn deinit(self: *Connection) void {
    self.stream.close(self.io);
}

pub fn receive(
    self: *Connection,
    allocator: std.mem.Allocator,
) !Request {
    var reader = self.stream.reader(self.io, &self.reader_buffer);
    return Request.parse(&reader.interface, allocator);
}

pub fn send(self: *Connection, response: *const Response) !void {
    var writer = self.stream.writer(self.io, &self.writer_buffer);
    try response.write(&writer.interface);
    try writer.interface.flush();
}
