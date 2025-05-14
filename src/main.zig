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
        const encodedStr = try allocator.dupe(u8, args[2]);
        defer allocator.free(encodedStr);
        var bencode = try BencodeDecoder.initFromEncoded(allocator, encodedStr);
        defer bencode.deinit();

        try bencode.printDecoded();
    }
}

// test "123" {
//     const str_1 = "5:mangoi10230e";
//     const decoded = try decodeBencode(testing.allocator, str_1);
//     defer decoded.deinit();
//
//     std.debug.print("{any}", .{decoded.items});
// }

// test "should match right terminator" {
//     const str_1 = "i10230e";
//     const str_2 = "l5:mongoi-52ee";
//     const str_3 = "li-52e";
//     try testing.expect(try findMatchingTerminator(str_1[1..]) == 5);
//     try testing.expect(try findMatchingTerminator(str_2[1..]) == 12);
//     try testing.expect(try findMatchingTerminator(str_2[9..]) == 3);
//     try testing.expectError(error.NoMatchingTerminator, findMatchingTerminator(str_3[1..]));
// }
//
// test "should decode string" {
//     const allocator = testing.allocator;
//     const str_1: []u8 = try allocator.dupe(u8, "5:mango");
//     const str_2: []u8 = try allocator.dupe(u8, "9:blueberryi29e");
//     defer allocator.free(str_1);
//     defer allocator.free(str_2);
//     const expected_1 = DecodedBencode{ .String = "mango" };
//     const actual_1 = try decodeBencode(str_1);
//     const expected_2 = DecodedBencode{ .String = "blueberry" };
//     const actual_2 = try decodeBencode(str_2);
//     try testing.expectEqualStrings(expected_1.String, actual_1.String);
//     try testing.expectEqualStrings(expected_2.String, actual_2.String);
// }
