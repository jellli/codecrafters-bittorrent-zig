const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const stdout = std.io.getStdOut().writer();
const BencodeDecoder = @import("Bencode.zig").BencodeDecoder;

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
        var bencode = try BencodeDecoder.initFromEncoded(allocator, encodedStr);
        defer bencode.deinit();

        try bencode.printDecoded();
    }
    if (std.mem.eql(u8, command, "info")) {
        const path = args[2];
        var buffer: [1024]u8 = undefined;
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const byte_read = try file.readAll(&buffer);
        var bencode = try BencodeDecoder.initFromEncoded(allocator, buffer[0..byte_read]);
        defer bencode.deinit();

        try bencode.printInfo();
    }
}
