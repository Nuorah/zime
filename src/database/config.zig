pub const Config = union(enum) {
    sqlite: SqliteConfig,
};

pub const SqliteConfig = struct {
    path: []const u8,
    create_if_missing: bool = true,
    busy_timeout_ms: u32 = 5000,
};
