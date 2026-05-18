//! zig-h3-csv — a downstream consumer demo.
//!
//! Reads a CSV of (lat, lng) from stdin or a file, encodes each point to
//! an H3 cell at a given resolution, writes (lat, lng, cell_hex) to stdout.
//!
//! This is the kind of tool a real downstream user would build with zig-h3.
//! Closes BAKEOFF axis 12 (ecosystem integration) toward 🟡 — we now have
//! a runnable, useful, non-trivial application of the library beyond tests.
//!
//! Usage:
//!     zig-h3-csv [--res N] [--threads N] [--input PATH] [--output PATH]
//!
//! Examples:
//!     echo "40.6892,-74.0445" | zig-h3-csv --res 9
//!     zig-h3-csv --res 7 --input cities.csv --output cells.csv
//!     # 1 million points, 8-thread parallel:
//!     zig-h3-csv --res 9 --threads 8 --input big.csv --output big_cells.csv

const std = @import("std");
const h3 = @import("h3");

const Args = struct {
    res: i32 = 9,
    threads: usize = 1,
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    show_help: bool = false,
};

fn parseArgs(argv: []const []const u8) !Args {
    var args = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            args.show_help = true;
        } else if (std.mem.eql(u8, a, "--res")) {
            i += 1;
            args.res = try std.fmt.parseInt(i32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--threads")) {
            i += 1;
            args.threads = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--input")) {
            i += 1;
            args.input_path = argv[i];
        } else if (std.mem.eql(u8, a, "--output")) {
            i += 1;
            args.output_path = argv[i];
        } else {
            return error.UnknownArg;
        }
    }
    return args;
}

const help_text =
    \\zig-h3-csv — encode CSV (lat, lng) to H3 cells
    \\
    \\Usage:
    \\    zig-h3-csv [--res N] [--threads N] [--input PATH] [--output PATH]
    \\
    \\Options:
    \\    --res N         H3 resolution 0..15 (default: 9)
    \\    --threads N     Parallel workers (default: 1; use 8 on a 4C/8T box)
    \\    --input PATH    Read CSV from PATH (default: stdin)
    \\    --output PATH   Write CSV to PATH (default: stdout)
    \\    --help, -h      Show this help
    \\
    \\Input format: each line is "lat,lng" (degrees). Header line OK if first
    \\token isn't a number. Blank lines ignored.
    \\
    \\Output format: "lat,lng,cell_hex" — one line per input.
    \\
;

fn readAllInput(io: std.Io, allocator: std.mem.Allocator, args: Args) ![]u8 {
    if (args.input_path) |path| {
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    }
    // Stdin path: read all from fd=0 via libc.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &buf, buf.len);
        if (n <= 0) break;
        try list.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return try list.toOwnedSlice(allocator);
}

fn parseLine(line: []const u8) ?h3.LatLng {
    var it = std.mem.tokenizeAny(u8, line, ", \t");
    const lat_str = it.next() orelse return null;
    const lng_str = it.next() orelse return null;
    const lat = std.fmt.parseFloat(f64, lat_str) catch return null;
    const lng = std.fmt.parseFloat(f64, lng_str) catch return null;
    return h3.LatLng.fromDegrees(lat, lng);
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args_buf: [64][]const u8 = undefined;
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    var argc: usize = 0;
    while (args_iter.next()) |a| : (argc += 1) {
        if (argc >= args_buf.len) break;
        args_buf[argc] = try allocator.dupe(u8, a);
    }
    const argv = args_buf[0..argc];

    const args = parseArgs(argv) catch {
        std.debug.print("error parsing arguments\n\n", .{});
        std.debug.print("{s}\n", .{help_text});
        std.process.exit(2);
    };
    if (args.show_help) {
        std.debug.print("{s}\n", .{help_text});
        return;
    }

    // Read input
    const input = try readAllInput(init.io, allocator, args);

    // Parse to LatLng[]
    var points: std.ArrayList(h3.LatLng) = .empty;
    defer points.deinit(allocator);
    var line_iter = std.mem.tokenizeAny(u8, input, "\n\r");
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        const point = parseLine(trimmed) orelse continue;
        try points.append(allocator, point);
    }

    if (points.items.len == 0) {
        std.debug.print("no valid lat,lng lines found in input\n", .{});
        std.process.exit(3);
    }

    // Encode in batch
    const cells = try allocator.alloc(h3.H3Index, points.items.len);
    if (args.threads > 1) {
        _ = try h3.latLngToCellBatchParallel(allocator, points.items, args.res, cells, args.threads);
    } else {
        _ = h3.latLngToCellBatch(points.items, args.res, cells);
    }

    // Write output: lat,lng,cell_hex
    var output_buf: std.ArrayList(u8) = .empty;
    defer output_buf.deinit(allocator);
    var hex_buf: [17]u8 = undefined;
    var line_buf: [128]u8 = undefined;
    for (points.items, cells) |p, cell| {
        const hex = try h3.h3ToString(cell, &hex_buf);
        const lat_deg = p.lat * 180.0 / std.math.pi;
        const lng_deg = p.lng * 180.0 / std.math.pi;
        const line = try std.fmt.bufPrint(&line_buf, "{d},{d},{s}\n", .{ lat_deg, lng_deg, hex });
        try output_buf.appendSlice(allocator, line);
    }

    if (args.output_path) |path| {
        try std.Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = path,
            .data = output_buf.items,
        });
    } else {
        // stdout via libc fd=1
        const written = std.c.write(1, output_buf.items.ptr, output_buf.items.len);
        if (written < 0) return error.WriteError;
    }
}
