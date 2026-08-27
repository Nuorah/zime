pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

pub const ExecuteResult = struct {
    affected_rows: u64,
};
