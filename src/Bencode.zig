const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const stdout = std.io.getStdOut().writer();

const BencodeValue = union(enum) {
    String: []const u8,
    Int: i64,
    Array: []BencodeValue,
};
pub const BencodeDecoder = struct {
    allocator: Allocator,
    decoded: []BencodeValue,

    pub fn initFromEncoded(allocator: Allocator, encoded: []const u8) !BencodeDecoder {
        const decoded = try decodeBencode(allocator, encoded);
        defer allocator.free(decoded.values);

        return .{ .allocator = allocator, .decoded = try allocator.dupe(BencodeValue, decoded.values) };
    }

    pub fn printDecoded(self: *BencodeDecoder) !void {
        const fmt = try formatBencodeValues(self.allocator, self.decoded);
        defer self.allocator.free(fmt);
        try stdout.print("{s}\n", .{fmt});
    }

    pub fn deinit(self: *BencodeDecoder) void {
        freeBencodeValues(self.allocator, self.decoded);
        self.allocator.free(self.decoded);
    }
};

const BencodeParseResult = struct {
    values: []BencodeValue,
    bytes_consumed: usize,
};
fn decodeBencode(allocator: Allocator, input: []const u8) !BencodeParseResult {
    var i: usize = 0;
    var result = std.ArrayList(BencodeValue).init(allocator);
    defer result.deinit();
    while (i < input.len) {
        const undecoded_slice = input[i..];
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
                defer allocator.free(decoded.values);
                try result.append(.{ .Array = try allocator.dupe(BencodeValue, decoded.values) });
                i += decoded.bytes_consumed + 1;
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
        .values = try allocator.dupe(BencodeValue, result.items),
        .bytes_consumed = i,
    };
}

fn freeBencodeValues(allocator: Allocator, list: []BencodeValue) void {
    for (list) |item| switch (item) {
        .Array => {
            freeBencodeValues(allocator, item.Array);
            allocator.free(item.Array);
        },
        else => {},
    };
}

fn formatBencodeValues(allocator: Allocator, items: []BencodeValue) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    const writer = result.writer();
    for (items) |item| switch (item) {
        .String => |stringValue| {
            var string = std.ArrayList(u8).init(allocator);
            try std.json.stringify(stringValue, .{}, string.writer());
            const jsonStr = try string.toOwnedSlice();
            defer allocator.free(jsonStr);
            _ = try writer.write(jsonStr);
        },
        .Int => |intValue| {
            const fmt = try std.fmt.allocPrint(allocator, "{d}", .{intValue});
            defer allocator.free(fmt);
            _ = try writer.write(fmt);
        },
        .Array => |inner_items| {
            _ = try writer.write("[");
            var i: usize = 0;
            while (i < inner_items.len) : (i += 1) {
                const fmt = try formatBencodeValues(allocator, inner_items[i .. i + 1]);
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

test "should decode string" {
    const allocator = testing.allocator;
    const str_1 = "5:mango";
    const str_2 = "9:blueberryi29e";
    var decoded_1 = try BencodeDecoder.initFromEncoded(allocator, str_1);
    var decoded_2 = try BencodeDecoder.initFromEncoded(allocator, str_2);
    defer decoded_1.deinit();
    defer decoded_2.deinit();
    try testing.expectEqualStrings("mango", decoded_1.decoded[0].String);
    try testing.expectEqualStrings("blueberry", decoded_2.decoded[0].String);
}

test "should decode int" {
    const allocator = testing.allocator;
    const str_1 = "i4294967300e";
    const str_2 = "i1024e6:banana";
    var decoded_1 = try BencodeDecoder.initFromEncoded(allocator, str_1);
    var decoded_2 = try BencodeDecoder.initFromEncoded(allocator, str_2);
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
    var decoded_1 = try BencodeDecoder.initFromEncoded(allocator, str_1);
    var decoded_2 = try BencodeDecoder.initFromEncoded(allocator, str_2);
    var decoded_3 = try BencodeDecoder.initFromEncoded(allocator, str_3);
    defer decoded_1.deinit();
    defer decoded_2.deinit();
    defer decoded_3.deinit();

    const fmt_1 = try formatBencodeValues(allocator, decoded_1.decoded);
    const fmt_2 = try formatBencodeValues(allocator, decoded_2.decoded);
    const fmt_3 = try formatBencodeValues(allocator, decoded_3.decoded);
    defer allocator.free(fmt_1);
    defer allocator.free(fmt_2);
    defer allocator.free(fmt_3);
    try testing.expectEqualStrings("[]", fmt_1);
    try testing.expectEqualStrings("[\"grape\",935]", fmt_2);
    try testing.expectEqualStrings("[[972,\"blueberry\"]]", fmt_3);
}
