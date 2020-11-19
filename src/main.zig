const std = @import("std");
const clap = @import("clap");
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const process = std.process;

const doctest = @import("./doctest.zig");

const max_doc_file_size = 10 * 1024 * 1024; // TODO: this should be overridable by the user
const CommandLineCommand = enum {
    syntax,
    build,
    run,
    @"test",
};

// TODO: test (and maybe run?) should differentiate between panics and other error conditions.
// TODO: integrate with hugo & check that output is correct

// TODO: tests?
// TODO: run should accept arguments for the executable
// TODO: I believe the original code had also a syntax + semantic analisys mode.
// TODO: refactor duplicated code
// TODO: json output mode?

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    var args_it = try clap.args.OsIterator.init(allocator);
    defer args_it.deinit();

    const command_name = (try args_it.next()) orelse @panic("expected command arg");

    @setEvalBranchQuota(10000);
    const command = std.meta.stringToEnum(CommandLineCommand, command_name) orelse @panic("unknown command");
    switch (command) {
        .syntax => {
            const summary = "Tests that the syntax is valid, without running the code.";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help             Display this help message") catch unreachable,
                clap.parseParam("-i, --in_file <PATH>   path to the input file, defaults to stdin") catch unreachable,
                clap.parseParam("-o, --out_file <PATH>  path to the output file, defaults to stdout") catch unreachable,
            };

            var diag: clap.Diagnostic = undefined;
            var args = clap.ComptimeClap(
                clap.Help,
                clap.args.OsIterator,
                &params,
            ).parse(allocator, &args_it, &diag) catch |err| {
                // Report any useful error and exit
                diag.report(std.io.getStdErr().outStream(), err) catch {};
                return err;
            };
            check_help(summary, &params, args);

            const input_file_bytes = try read_input(allocator, args.option("--in_file"));
            var buffered_out_stream = try open_output(args.option("--out_file"));

            try doctest.highlightZigCode(input_file_bytes, buffered_out_stream.writer());
            try buffered_out_stream.flush();
        },
        .build => {
            // TODO: it seems a good idea to have a "check output" flag, rather than
            // tying output checking just to failure cases.
            const summary = "Builds a code snippet, checking for the build to succeed or fail as expected.";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help                     Display this help message") catch unreachable,
                clap.parseParam("-r, --format  <OUTPUT_FORMAT>  Output format, possible values: `exe`, `obj`, `lib`, defaults to `exe`") catch unreachable,
                clap.parseParam("-f, --fail <MATCH>             Expect the build command to encounter a compile error containing some text that is expected to be present in stderr") catch unreachable,
                clap.parseParam("-i, --in_file <PATH>           Path to the input file, defaults to stdin") catch unreachable,
                clap.parseParam("-o, --out_file <PATH>          Path to the output file, defaults to stdout") catch unreachable,
                clap.parseParam("-z, --zig_exe <PATH>           Path to the zig compiler, defaults to `zig` (i.e. assumes zig present in PATH)") catch unreachable,
                clap.parseParam("-t, --target <TARGET>          Compilation target, expected as a arch-os-abi tripled (e.g. `x86_64-linux-gnu`) defaults to `native`") catch unreachable,
                clap.parseParam("-k, --keep                     Don't delete the temp folder, useful for debugging the resulting executable.") catch unreachable,
            };

            var diag: clap.Diagnostic = undefined;
            var args = clap.ComptimeClap(
                clap.Help,
                clap.args.OsIterator,
                &params,
            ).parse(allocator, &args_it, &diag) catch |err| {
                // Report any useful error and exit
                diag.report(std.io.getStdErr().outStream(), err) catch {};
                return err;
            };
            check_help(summary, &params, args);

            const input_file_bytes = try read_input(allocator, args.option("--in_file"));
            var buffered_out_stream = try open_output(args.option("--out_file"));

            // Produce the syntax highlighting
            try doctest.highlightZigCode(input_file_bytes, buffered_out_stream.writer());

            // Grab env map and set max output size
            var env_map = try process.getEnvMap(allocator);
            try env_map.set("ZIG_DEBUG_COLOR", "1");

            // Create a temp folder
            const tmp_dir_name: []const u8 = while (true) {
                const tmp_dir_name = try randomized_path_name(allocator, "doctest-");
                fs.cwd().makePath(tmp_dir_name) catch |err| switch (err) {
                    error.PathAlreadyExists => continue,
                    else => |e| return e,
                };

                break tmp_dir_name;
            } else unreachable;
            defer if (!args.flag("--keep")) {
                fs.cwd().deleteTree(tmp_dir_name) catch {
                    @panic("Error while deleting the temp directory!");
                };
            };

            // Build the code and write the resulting output
            const output_format = if (args.option("--format")) |format|
                std.meta.stringToEnum(doctest.BuildCommand.Format, format) orelse {
                    std.debug.print("Invalid value for --format!\n", .{});
                    return error.InvalidFormat;
                }
            else
                .exe;

            _ = try doctest.runBuild(
                allocator,
                input_file_bytes,
                buffered_out_stream.writer(),
                &env_map,
                args.option("--zig_exe") orelse "zig",
                doctest.BuildCommand{
                    .format = output_format,
                    .tmp_dir_name = tmp_dir_name,
                    .expected_outcome = if (args.option("--fail")) |f| .{ .Failure = f } else .Success,
                    .target_str = args.option("--target"),
                },
            );

            try buffered_out_stream.flush();
        },

        .run => {
            // TODO: it seems a good idea to have a "check output" flag, rather than
            // tying output checking just to failure cases.
            const summary = "Compiles and runs a code snippet, checking for the execution to succeed or fail as expected.";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help                     Display this help message") catch unreachable,
                clap.parseParam("-f, --fail <MATCH>             Expect the execution to encounter a runtime error, optionally provide some text that is expected to be present in stderr") catch unreachable,
                clap.parseParam("-i, --in_file <PATH>           Path to the input file, defaults to stdin") catch unreachable,
                clap.parseParam("-o, --out_file <PATH>          Path to the output file, defaults to stdout") catch unreachable,
                clap.parseParam("-z, --zig_exe <PATH>           Path to the zig compiler, defaults to `zig` (i.e. assumes zig present in PATH)") catch unreachable,
            };

            var diag: clap.Diagnostic = undefined;
            var args = clap.ComptimeClap(
                clap.Help,
                clap.args.OsIterator,
                &params,
            ).parse(allocator, &args_it, &diag) catch |err| {
                // Report any useful error and exit
                diag.report(std.io.getStdErr().outStream(), err) catch {};
                return err;
            };
            check_help(summary, &params, args);

            const input_file_bytes = try read_input(allocator, args.option("--in_file"));
            var buffered_out_stream = try open_output(args.option("--out_file"));

            // Produce the syntax highlighting
            try doctest.highlightZigCode(input_file_bytes, buffered_out_stream.writer());

            // Grab env map and set max output size
            var env_map = try process.getEnvMap(allocator);
            try env_map.set("ZIG_DEBUG_COLOR", "1");

            // Create a temp folder
            const tmp_dir_name = while (true) {
                const tmp_dir_name = try randomized_path_name(allocator, "doctest-");
                fs.cwd().makePath(tmp_dir_name) catch |err| switch (err) {
                    error.PathAlreadyExists => continue,
                    else => |e| return e,
                };

                break tmp_dir_name;
            } else unreachable;
            defer fs.cwd().deleteTree(tmp_dir_name) catch {
                @panic("Error while deleting the temp directory!");
            };

            // Build the code and write the resulting output
            const executable_path = try doctest.runBuild(
                allocator,
                input_file_bytes,
                buffered_out_stream.writer(),
                &env_map,
                args.option("--zig_exe") orelse "zig",
                doctest.BuildCommand{
                    .format = .exe,
                    .tmp_dir_name = tmp_dir_name,
                    .expected_outcome = .SilentSuccess,
                    .target_str = null,
                },
            );

            // Missing executable path means that the build failed.
            if (executable_path) |exe_path| {
                const run_outcome = try doctest.runExe(
                    allocator,
                    exe_path,
                    buffered_out_stream.writer(),
                    &env_map,
                    doctest.RunCommand{
                        .expected_outcome = if (args.option("--fail")) |f| .{ .Failure = f } else .Success,
                    },
                );
            }

            try buffered_out_stream.flush();
        },

        .@"test" => {
            const summary = "Tests a code snippet, checking for the test to succeed or fail as expected.";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help                     Display this help message") catch unreachable,
                clap.parseParam("-f, --fail <MATCH>             Expect the test to fail, optionally provide some text that is expected to be present in stderr") catch unreachable,
                clap.parseParam("-i, --in_file <PATH>           Path to the input file, defaults to stdin") catch unreachable,
                clap.parseParam("-o, --out_file <PATH>          Path to the output file, defaults to stdout") catch unreachable,
                clap.parseParam("-z, --zig_exe <PATH>           Path to the zig compiler, defaults to `zig` (i.e. assumes zig present in PATH)") catch unreachable,
            };

            var diag: clap.Diagnostic = undefined;
            var args = clap.ComptimeClap(
                clap.Help,
                clap.args.OsIterator,
                &params,
            ).parse(allocator, &args_it, &diag) catch |err| {
                // Report any useful error and exit
                diag.report(std.io.getStdErr().outStream(), err) catch {};
                return err;
            };
            check_help(summary, &params, args);

            const input_file_bytes = try read_input(allocator, args.option("--in_file"));
            var buffered_out_stream = try open_output(args.option("--out_file"));

            // Produce the syntax highlighting
            try doctest.highlightZigCode(input_file_bytes, buffered_out_stream.writer());

            // Grab env map and set max output size
            var env_map = try process.getEnvMap(allocator);
            try env_map.set("ZIG_DEBUG_COLOR", "1");

            // Create a temp folder
            const tmp_dir_name = while (true) {
                const tmp_dir_name = try randomized_path_name(allocator, "doctest-");
                fs.cwd().makePath(tmp_dir_name) catch |err| switch (err) {
                    error.PathAlreadyExists => continue,
                    else => |e| return e,
                };

                break tmp_dir_name;
            } else unreachable;
            defer fs.cwd().deleteTree(tmp_dir_name) catch {
                @panic("Error while deleting the temp directory!");
            };

            const test_outcome = try doctest.runTest(
                allocator,
                input_file_bytes,
                buffered_out_stream.writer(),
                &env_map,
                args.option("--zig_exe") orelse "zig",
                doctest.TestCommand{
                    .expected_outcome = if (args.option("--fail")) |f| .{ .Failure = f } else .Success,
                    .tmp_dir_name = tmp_dir_name,
                },
            );

            try buffered_out_stream.flush();
        },
    }
}

fn check_help(comptime summary: []const u8, comptime params: anytype, args: anytype) void {
    if (args.flag("--help")) {
        std.debug.print("{}\n\n", .{summary});
        clap.help(io.getStdErr().writer(), params) catch {};
        std.debug.print("\n", .{});
        std.os.exit(0);
    }
}

// Nothing to see here, just a normal elegant generic type.
const BufferedFileType = @TypeOf(io.bufferedWriter((std.fs.File{ .handle = 0 }).writer()));
fn open_output(output: ?[]const u8) !BufferedFileType {
    const out_file = if (output) |out_file_name|
        try fs.cwd().createFile(out_file_name, .{})
    else
        io.getStdOut();

    return io.bufferedWriter(out_file.writer());
}

fn read_input(allocator: *mem.Allocator, input: ?[]const u8) ![]const u8 {
    const in_file = if (input) |in_file_name|
        try fs.cwd().openFile(in_file_name, .{ .read = true })
    else
        io.getStdIn();
    defer in_file.close();

    return try in_file.reader().readAllAlloc(allocator, max_doc_file_size);
}

fn randomized_path_name(allocator: *mem.Allocator, prefix: []const u8) ![]const u8 {
    const seed = @bitCast(u64, @truncate(i64, std.time.nanoTimestamp()));
    var xoro = std.rand.Xoroshiro128.init(seed);

    var buf: [4]u8 = undefined;
    xoro.random.bytes(&buf);

    var name = try allocator.alloc(u8, prefix.len + 8);
    errdefer allocator.free(name);

    return try std.fmt.bufPrint(name, "{}{x}", .{ prefix, buf });
}
