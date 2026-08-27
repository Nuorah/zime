const Database = @import("database").Database;
const Client = @import("http").Client;

pub const Context = @This();

client: *Client,
database: *Database,
