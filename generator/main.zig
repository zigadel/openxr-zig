const std = @import("std");
const Io = std.Io;
const generator = @import("openxr/generator.zig");

const Allocator = std.mem.Allocator;

const usage =
    "Usage: {s} [-h|--help] <spec xml path> <output zig source>\n";

/// Minimal in-memory writer that matches what the OpenXR generator expects.
/// It gathers all output into a growable buffer, which we later flush to disk.
const BufferWriter = struct {
    buf: std.ArrayList(u8),
    allocator: Allocator,

    pub const Error = error{OutOfMemory};

    pub fn init(allocator: Allocator) BufferWriter {
        return .{
            .buf = std.ArrayList(u8){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BufferWriter) void {
        self.buf.deinit(self.allocator);
    }

    pub fn writeAll(self: *BufferWriter, bytes: []const u8) Error!void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: *BufferWriter, byte: u8) Error!void {
        try self.buf.append(self.allocator, byte);
    }

    pub fn print(self: *BufferWriter, comptime fmt: []const u8, args: anytype) Error!void {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(s);
        try self.writeAll(s);
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    const prog_name = args.next() orelse return error.ExecutableNameMissing;

    var maybe_xml_path: ?[]const u8 = null;
    var maybe_out_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            @setEvalBranchQuota(2000);
            std.debug.print(
                \\Utility to generate a Zig binding from the OpenXR XML API registry.
                \\
                \\The most recent OpenXR XML API registry can be obtained from
                \\https://github.com/KhronosGroup/OpenXR-Docs/blob/master/xml/xr.xml,
                \\and the most recent LunarG OpenXR SDK version can be found at
                \\$OPENXR_SDK/x86_64/share/openxr/registry/xr.xml.
                \\
                \\
            ++ usage,
                .{prog_name},
            );
            return;
        } else if (maybe_xml_path == null) {
            maybe_xml_path = arg;
        } else if (maybe_out_path == null) {
            maybe_out_path = arg;
        } else {
            std.debug.print("Error: Superfluous argument '{s}'\n", .{arg});
            return;
        }
    }

    const xml_path = maybe_xml_path orelse {
        std.debug.print(
            "Error: Missing required argument <spec xml path>\n" ++ usage,
            .{prog_name},
        );
        return;
    };

    const out_path = maybe_out_path orelse {
        std.debug.print(
            "Error: Missing required argument <output zig source>\n" ++ usage,
            .{prog_name},
        );
        return;
    };

    const cwd = std.fs.cwd();

    // --- Read xr.xml fully into memory using Dir.readFileAlloc ---
    const limit: Io.Limit = @enumFromInt(std.math.maxInt(usize));
    const xml_src = cwd.readFileAlloc(xml_path, gpa, limit) catch |err| {
        std.debug.print(
            "Error: Failed to read input file '{s}' ({s})\n",
            .{ xml_path, @errorName(err) },
        );
        return;
    };
    defer gpa.free(xml_src);

    // --- Drive the generator into an in-memory buffer ---
    var writer = BufferWriter.init(gpa);
    defer writer.deinit();

    // generator.generate(allocator, spec_xml, writer: anytype)
    try generator.generate(gpa, xml_src, writer);

    const generated = writer.buf.items;

    // --- Ensure output directory exists ---
    if (std.fs.path.dirname(out_path)) |dir| {
        cwd.makePath(dir) catch |err| {
            std.debug.print(
                "Error: Failed to create output directory '{s}' ({s})\n",
                .{ dir, @errorName(err) },
            );
            return;
        };
    }

    // --- Write the generated Zig to disk in one shot ---
    cwd.writeFile(.{
        .sub_path = out_path,
        .data = generated,
    }) catch |err| {
        std.debug.print(
            "Error: Failed to write output file '{s}' ({s})\n",
            .{ out_path, @errorName(err) },
        );
        return;
    };
}
