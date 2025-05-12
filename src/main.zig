const std = @import("std");
const stdout = std.io.getStdOut().writer();

const DecodedBencode = union(enum) {
    String: []const u8,
    Int: i64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try stdout.print("Usage: your_program.sh <command> <args>\n", .{});
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "decode")) {
        std.debug.print("Logs from your program will appear here\n", .{});
        const encodedStr = args[2];
        const decoded = try decodeBencode(encodedStr);
        switch (decoded) {
            .String => |decodedStr| {
                var string = std.ArrayList(u8).init(allocator);
                try std.json.stringify(decodedStr, .{}, string.writer());
                const jsonStr = try string.toOwnedSlice();
                defer allocator.free(jsonStr);
                try stdout.print("{s}\n", .{jsonStr});
            },
            .Int => |decodedInt| {
                try stdout.print("{d}\n", .{decodedInt});
            },
        }
    }
}

fn decodeBencode(encodedValue: []const u8) !DecodedBencode {
    if (encodedValue[0] >= '0' and encodedValue[0] <= '9') {
        const firstColon = std.mem.indexOf(u8, encodedValue, ":");
        if (firstColon == null) {
            return error.InvalidArgument;
        }
        return .{ .String = encodedValue[firstColon.? + 1 ..] };
    } else if (encodedValue[0] == 'i') {
        return .{ .Int = try std.fmt.parseInt(i64, encodedValue[1 .. encodedValue.len - 1], 10) };
    } else {
        try stdout.print("Not Supported data type.\n", .{});
        std.process.exit(1);
    }
}
