const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const http_mod = b.addModule("http", .{
        .root_source_file = b.path("src/http/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const database_mod = b.addModule("database", .{
        .root_source_file = b.path("src/database/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    database_mod.linkSystemLibrary("sqlite3", .{
        .preferred_link_mode = .dynamic,
    });

    const zime_mod = b.addModule("zime", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "database", .module = database_mod },
            .{ .name = "http", .module = http_mod },
        },
    });

    const http_tests = b.addTest(.{
        .root_module = http_mod,
        .use_llvm = true, // TODO: Remove in Zig 0.17.
    });
    const run_http_tests = b.addRunArtifact(http_tests);

    const database_tests = b.addTest(.{
        .root_module = database_mod,
        .use_llvm = true, // TODO: Remove in Zig 0.17.
    });
    const run_database_tests = b.addRunArtifact(database_tests);

    const zime_tests = b.addTest(.{
        .root_module = zime_mod,
        .use_llvm = true, // TODO: Remove in Zig 0.17.
    });
    const run_zime_tests = b.addRunArtifact(zime_tests);

    const test_step = b.step("test", "Run all module tests");
    test_step.dependOn(&run_http_tests.step);
    test_step.dependOn(&run_database_tests.step);
    test_step.dependOn(&run_zime_tests.step);
}
