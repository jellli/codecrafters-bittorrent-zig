const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const stdout = std.io.getStdOut().writer();

const Dict = struct {
    key: []const u8,
    value: []BencodeValue,
};
const BencodeValue = union(enum) { String: []const u8, Int: i64, Array: []BencodeValue, Dict: []Dict };
pub const BencodeDecoder = struct {
    allocator: Allocator,
    decoded: []BencodeValue,

    pub fn initFromEncoded(allocator: Allocator, encoded: []const u8) !BencodeDecoder {
        const decoded = try decodeBencode(allocator, encoded);
        return .{ .allocator = allocator, .decoded = decoded.values };
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
    var buffer = std.ArrayList(BencodeValue).init(allocator);
    defer buffer.deinit();
    while (i < input.len) {
        const undecoded_slice = input[i..];
        switch (undecoded_slice[0]) {
            '0'...'9' => {
                const first_colon = std.mem.indexOf(u8, undecoded_slice, ":") orelse return error.InvalidArgument;
                const str_len = std.fmt.parseInt(usize, undecoded_slice[0..first_colon], 10) catch return error.InvalidArgument;
                try buffer.append(.{ .String = undecoded_slice[first_colon + 1 .. first_colon + 1 + str_len] });
                i += first_colon + 1 + str_len;
            },
            'i' => {
                const end_pos = std.mem.indexOfScalar(u8, undecoded_slice, 'e') orelse return error.InvalidArgument;
                const int = std.fmt.parseInt(i64, undecoded_slice[1..end_pos], 10) catch return error.InvalidArgument;
                try buffer.append(.{ .Int = int });
                i += end_pos + 1;
            },
            'l' => {
                const str = undecoded_slice[1..];
                const decoded = try decodeBencode(allocator, str);
                try buffer.append(.{ .Array = decoded.values });
                i += decoded.bytes_consumed + 1;
            },
            'd' => {
                const str = undecoded_slice[1..];
                const decoded = try decodeBencode(allocator, str);
                defer allocator.free(decoded.values);
                var dict_buffer = std.ArrayList(Dict).init(allocator);
                defer dict_buffer.deinit();
                var j: usize = 0;
                while (j < decoded.values.len) : (j += 2) {
                    try dict_buffer.append(.{
                        .key = decoded.values[j].String,
                        .value = try allocator.dupe(BencodeValue, decoded.values[j + 1 .. j + 2]),
                    });
                }
                try buffer.append(.{ .Dict = try allocator.dupe(Dict, dict_buffer.items) });
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
        .values = try allocator.dupe(BencodeValue, buffer.items),
        .bytes_consumed = i,
    };
}

fn freeBencodeValues(allocator: Allocator, list: []BencodeValue) void {
    for (list) |item| switch (item) {
        .Array => {
            freeBencodeValues(allocator, item.Array);
            allocator.free(item.Array);
        },
        .Dict => {
            for (item.Dict) |dict| {
                freeBencodeValues(allocator, dict.value);
                allocator.free(dict.value);
            }
            allocator.free(item.Dict);
        },
        else => {},
    };
}

fn formatBencodeValues(allocator: Allocator, list: []BencodeValue) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    for (list, 0..) |item, index| {
        switch (item) {
            .String => |s| try writer.print("\"{s}\"", .{s}),
            .Int => |v| try writer.print("{d}", .{v}),
            .Array => |inner_items| {
                const fmt = try formatBencodeValues(allocator, inner_items);
                defer allocator.free(fmt);
                try writer.print("[{s}]", .{fmt});
            },
            .Dict => |dict_list| {
                try writer.writeByte('{');
                for (dict_list, 0..) |dict, i| {
                    const fmt = try formatBencodeValues(allocator, dict.value);
                    defer allocator.free(fmt);
                    try writer.print("\"{s}\":{s}", .{ dict.key, fmt });
                    if (i != dict_list.len - 1) {
                        try writer.writeByte(',');
                    }
                }
                try writer.writeByte('}');
            },
        }
        if (index != list.len - 1) {
            try writer.writeByte(',');
        }
    }
    return buffer.toOwnedSlice();
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

test "should decode dict" {
    const allocator = testing.allocator;
    const str_1 = "de";
    const str_2 = "d5:grapei935ee";
    // const str_3 = "dryee";
    var decoded_1 = try BencodeDecoder.initFromEncoded(allocator, str_1);
    var decoded_2 = try BencodeDecoder.initFromEncoded(allocator, str_2);
    // var decoded_3 = try BencodeDecoder.initFromEncoded(allocator, str_3);
    defer decoded_1.deinit();
    defer decoded_2.deinit();
    // defer decoded_3.deinit();

    const fmt_1 = try formatBencodeValues(allocator, decoded_1.decoded);
    const fmt_2 = try formatBencodeValues(allocator, decoded_2.decoded);
    // const fmt_3 = try formatBencodeValues(allocator, decoded_3.decoded);
    defer allocator.free(fmt_1);
    defer allocator.free(fmt_2);
    // defer allocator.free(fmt_3);
    try testing.expectEqualStrings("{}", fmt_1);
    try testing.expectEqualStrings("{\"grape\":935}", fmt_2);
    // try testing.expectEqualStrings("[[972,\"blueberry\"]]", fmt_3);
}
