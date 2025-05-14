const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const stdout = std.io.getStdOut().writer();

pub const Bencode = struct {
    allocator: Allocator,
    decoded: []DecodedBencode,

    pub fn initFromEncoded(allocator: Allocator, encoded: []const u8) !Bencode {
        const decoded = try decodeBencode(allocator, encoded);
        defer allocator.free(decoded.list);

        return .{ .allocator = allocator, .decoded = try allocator.dupe(DecodedBencode, decoded.list) };
    }

    pub fn printDecoded(self: *Bencode) !void {
        const fmt = try formatDecoded(self.allocator, self.decoded);
        defer self.allocator.free(fmt);
        try stdout.print("{s}\n", .{fmt});
    }

    pub fn deinit(self: *Bencode) void {
        freeArray(self.allocator, self.decoded);
        self.allocator.free(self.decoded);
    }
};

const DecodedBencode = union(enum) {
    String: []const u8,
    Int: i64,
    Array: []DecodedBencode,
};

fn freeArray(allocator: Allocator, list: []DecodedBencode) void {
    for (list) |item| switch (item) {
        .Array => {
            freeArray(allocator, item.Array);
            allocator.free(item.Array);
        },
        else => {},
    };
}

fn formatDecoded(allocator: Allocator, items: []DecodedBencode) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    const writer = result.writer();
    for (items) |item| switch (item) {
        .String => |decodedStr| {
            var string = std.ArrayList(u8).init(allocator);
            try std.json.stringify(decodedStr, .{}, string.writer());
            const jsonStr = try string.toOwnedSlice();
            defer allocator.free(jsonStr);
            _ = try writer.write(jsonStr);
        },
        .Int => |decodedInt| {
            const fmt = try std.fmt.allocPrint(allocator, "{d}", .{decodedInt});
            defer allocator.free(fmt);
            _ = try writer.write(fmt);
        },
        .Array => |inner_items| {
            _ = try writer.write("[");
            var i: usize = 0;
            while (i < inner_items.len) : (i += 1) {
                const fmt = try formatDecoded(allocator, inner_items[i .. i + 1]);
                defer allocator.free(fmt);
                _ = try writer.write(fmt);
                if (i != inner_items.len - 1) {
                    _ = try writer.write(",");
                }
            }
            _ = try writer.write("]");
        },
    };
    return try allocator.dupe(u8, result.items);
}

fn findMatchingTerminator(target_str: []const u8) !usize {
    var level: usize = 1;
    var i: usize = 0;
    while (i < target_str.len) : (i += 1) {
        switch (target_str[i]) {
            'i', 'l' => level += 1,
            'e' => {
                level -= 1;
                if (level == 0) {
                    break;
                }
            },
            else => {},
        }
    }
    if (level > 0) {
        return error.NoMatchingTerminator;
    }
    return i;
}

const Decoded = struct {
    list: []DecodedBencode,
    end_pos: usize,
};

fn decodeBencode(allocator: Allocator, encodedValue: []const u8) !Decoded {
    var i: usize = 0;
    var result = std.ArrayList(DecodedBencode).init(allocator);
    defer result.deinit();
    while (i < encodedValue.len) {
        const undecoded_slice = encodedValue[i..];
        switch (undecoded_slice[0]) {
            '0'...'9' => {
                const first_colon = std.mem.indexOf(u8, undecoded_slice, ":") orelse return error.InvalidArgument;
                // skip colon
                const rest_slice = undecoded_slice[first_colon + 1 ..];
                const str_len = try std.fmt.parseInt(usize, undecoded_slice[0..first_colon], 10);
                try result.append(.{ .String = rest_slice[0..str_len] });
                i += first_colon + 1 + str_len;
            },
            'i' => {
                const end_pos = std.mem.indexOfScalar(u8, undecoded_slice, 'e') orelse return error.InvalidArgument;
                const int = std.fmt.parseInt(i64, undecoded_slice[1..end_pos], 10) catch return error.InvalidArgument;
                try result.append(.{ .Int = int });
                i += end_pos + 1;
            },
            'l' => {
                const str = undecoded_slice[1..];
                const decoded = try decodeBencode(allocator, str);
                defer allocator.free(decoded.list);
                try result.append(.{ .Array = try allocator.dupe(DecodedBencode, decoded.list) });
                i += decoded.end_pos + 1;
            },
            'e' => {
                i += 1;
                break;
            },
            else => {
                try stdout.print("Not Supported data type.\n", .{});
                std.process.exit(1);
            },
        }
    }
    return .{
        .list = try allocator.dupe(DecodedBencode, result.items),
        .end_pos = i,
    };
}

test "should match right terminator" {
    const str_1 = "i10230e";
    const str_2 = "l5:mongoi-52ee";
    const str_3 = "li-52e";
    try testing.expect(try findMatchingTerminator(str_1[1..]) == 5);
    try testing.expect(try findMatchingTerminator(str_2[1..]) == 12);
    try testing.expect(try findMatchingTerminator(str_2[9..]) == 3);
    try testing.expectError(error.NoMatchingTerminator, findMatchingTerminator(str_3[1..]));
}

test "should decode string" {
    const allocator = testing.allocator;
    const str_1 = "5:mango";
    const str_2 = "9:blueberryi29e";
    var decoded_1 = try Bencode.initFromEncoded(allocator, str_1);
    var decoded_2 = try Bencode.initFromEncoded(allocator, str_2);
    defer decoded_1.deinit();
    defer decoded_2.deinit();
    try testing.expectEqualStrings("mango", decoded_1.decoded[0].String);
    try testing.expectEqualStrings("blueberry", decoded_2.decoded[0].String);
}

test "should decode int" {
    const allocator = testing.allocator;
    const str_1 = "i4294967300e";
    const str_2 = "i1024e6:banana";
    var decoded_1 = try Bencode.initFromEncoded(allocator, str_1);
    var decoded_2 = try Bencode.initFromEncoded(allocator, str_2);
    defer decoded_1.deinit();
    defer decoded_2.deinit();
    try testing.expectEqual(4294967300, decoded_1.decoded[0].Int);
    try testing.expectEqual(1024, decoded_2.decoded[0].Int);
}

test "should decode array" {
    const allocator = testing.allocator;
    const str_1 = "le";
    const str_2 = "l5:grapei935ee";
    const str_3 = "lli972e9:blueberryee";
    var decoded_1 = try Bencode.initFromEncoded(allocator, str_1);
    var decoded_2 = try Bencode.initFromEncoded(allocator, str_2);
    var decoded_3 = try Bencode.initFromEncoded(allocator, str_3);
    defer decoded_1.deinit();
    defer decoded_2.deinit();
    defer decoded_3.deinit();

    const fmt_1 = try formatDecoded(allocator, decoded_1.decoded);
    const fmt_2 = try formatDecoded(allocator, decoded_2.decoded);
    const fmt_3 = try formatDecoded(allocator, decoded_3.decoded);
    defer allocator.free(fmt_1);
    defer allocator.free(fmt_2);
    defer allocator.free(fmt_3);
    try testing.expectEqualStrings("[]", fmt_1);
    try testing.expectEqualStrings("[\"grape\",935]", fmt_2);
    try testing.expectEqualStrings("[[972,\"blueberry\"]]", fmt_3);
}
