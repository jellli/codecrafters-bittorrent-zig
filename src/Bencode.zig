const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const stdout = std.io.getStdOut().writer();

const DictMap = struct {
    key: []const u8,
    value: *BencodeValue,
};
const Dict = struct {
    list: []DictMap,
    decoded: BencodeParseResult,

    pub fn get(self: *const Dict, key: []const u8) ?BencodeValue {
        return for (self.list) |item| {
            if (std.mem.eql(u8, key, item.key)) {
                return item.value.*;
            }
        } else null;
    }
};
const BencodeValue = union(enum) { String: []const u8, Int: i64, Array: []BencodeValue, Dict: Dict };
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

    pub fn printInfo(self: *BencodeDecoder) !void {
        for (self.decoded) |value| {
            if (value == .Dict) {
                const announce = value.Dict.get("announce").?.String;
                const info = value.Dict.get("info").?;
                const length = info.Dict.get("length").?.Int;

                const encoded = try encodeBencode(self.allocator, info);
                defer self.allocator.free(encoded);

                var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
                std.crypto.hash.Sha1.hash(encoded, &hash, .{});

                try stdout.print("Tracker URL: {s}\nLength: {d}\nInfo Hash: {s}", .{ announce, length, std.fmt.fmtSliceHexLower(&hash) });
                break;
            }
        }
    }

    pub fn deinit(self: *BencodeDecoder) void {
        for (self.decoded) |item| {
            freeBencodeValue(self.allocator, item);
        }
        self.allocator.free(self.decoded);
    }
};

fn encodeBencode(allocator: Allocator, target: BencodeValue) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    switch (target) {
        .String => |v| try writer.print("{d}:{s}", .{ v.len, v }),
        .Int => |v| try writer.print("i{d}e", .{v}),
        .Array => |array| {
            try writer.writeByte('l');
            for (array) |item| {
                const encoded = try encodeBencode(allocator, item);
                defer allocator.free(encoded);
                try writer.print("{s}", .{encoded});
            }
            try writer.writeByte('e');
        },
        .Dict => |dict| {
            std.mem.sort(DictMap, dict.list, {}, (struct {
                pub fn lessThan(_: void, a: DictMap, b: DictMap) bool {
                    return std.mem.lessThan(u8, a.key, b.key);
                }
            }).lessThan);

            try writer.writeByte('d');
            for (dict.list) |item| {
                try writer.print("{d}:{s}", .{ item.key.len, item.key });
                const encoded = try encodeBencode(allocator, item.value.*);
                defer allocator.free(encoded);
                try writer.print("{s}", .{encoded});
            }
            try writer.writeByte('e');
        },
    }
    return try buffer.toOwnedSlice();
}

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
                var dict_buffer = std.ArrayList(DictMap).init(allocator);
                defer dict_buffer.deinit();
                var j: usize = 0;
                while (j < decoded.values.len) : (j += 2) {
                    try dict_buffer.append(.{
                        .key = decoded.values[j].String,
                        .value = &decoded.values[j + 1],
                    });
                }
                try buffer.append(.{ .Dict = .{ .list = try allocator.dupe(DictMap, dict_buffer.items), .decoded = decoded } });
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
        .values = try buffer.toOwnedSlice(),
        .bytes_consumed = i,
    };
}

fn freeBencodeValue(allocator: Allocator, value: BencodeValue) void {
    switch (value) {
        .Array => |list| {
            for (list) |item| {
                freeBencodeValue(allocator, item);
            }
            allocator.free(list);
        },
        .Dict => |dict| {
            for (dict.list) |pair| {
                freeBencodeValue(allocator, pair.value.*);
            }
            allocator.free(dict.list);
            allocator.free(dict.decoded.values);
        },
        else => {},
    }
}

fn formatValue(allocator: Allocator, value: BencodeValue) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    switch (value) {
        .String => |s| try writer.print("\"{s}\"", .{s}),
        .Int => |v| try writer.print("{d}", .{v}),
        .Array => |inner_items| {
            const fmt = try formatBencodeValues(allocator, inner_items);
            defer allocator.free(fmt);
            try writer.print("[{s}]", .{fmt});
        },
        .Dict => |dict_list| {
            try writer.writeByte('{');
            for (dict_list.list, 0..) |dict, i| {
                const fmt = try formatValue(allocator, dict.value.*);
                defer allocator.free(fmt);
                try writer.print("\"{s}\":{s}", .{ dict.key, fmt });
                if (i != dict_list.list.len - 1) {
                    try writer.writeByte(',');
                }
            }
            try writer.writeByte('}');
        },
    }
    return buffer.toOwnedSlice();
}

fn formatBencodeValues(allocator: Allocator, list: []BencodeValue) error{OutOfMemory}![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    for (list, 0..) |item, index| {
        const fmt = try formatValue(allocator, item);
        defer allocator.free(fmt);
        try writer.print("{s}", .{fmt});
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
    const str_3 = "d10:inner_dictd4:key16:value14:key2i42e8:list_keyl5:item15:item2i3eeee";
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
    try testing.expectEqualStrings("{}", fmt_1);
    try testing.expectEqualStrings("{\"grape\":935}", fmt_2);
    try testing.expectEqualStrings("{\"inner_dict\":{\"key1\":\"value1\",\"key2\":42,\"list_key\":[\"item1\",\"item2\",3]}}", fmt_3);
}
