const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const server_target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    } });

    const host_target = b.resolveTargetQuery(.{});

    const server = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = server_target,
            .optimize = optimize,
            .strip = true,
        }),
    });
    b.installArtifact(server);

    const lb = b.addExecutable(.{
        .name = "lb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lb.zig"),
            .target = server_target,
            .optimize = optimize,
            .single_threaded = true,
            .strip = true,
        }),
    });
    b.installArtifact(lb);

    const preprocessor = b.addExecutable(.{
        .name = "preprocessor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/preprocessor.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(preprocessor);

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(bench);

    const server_step = b.step("server", "Build the server + lb");
    server_step.dependOn(&b.addInstallArtifact(server, .{}).step);
    server_step.dependOn(&b.addInstallArtifact(lb, .{}).step);

    const pre_step = b.step("preprocessor", "Build the preprocessor only");
    pre_step.dependOn(&b.addInstallArtifact(preprocessor, .{}).step);

    const bench_step = b.step("bench", "Build the bench tool only");
    bench_step.dependOn(&b.addInstallArtifact(bench, .{}).step);

    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/vec.zig", "src/index.zig", "src/knn.zig", "src/json.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = host_target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
