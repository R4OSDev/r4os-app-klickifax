const std = @import("std");
const r4os = @import("r4os");

pub const Error = error{
    SourceTooLarge,
    DepthLimit,
    InvalidNode,
};

pub const Serializer = struct {
    buffer: []u8,
    len: usize = 0,

    pub fn serialize(self: *Serializer, document: *const r4os.html.Document, node: u16) Error![]const u8 {
        self.len = 0;
        try self.appendElement(document, node, 0);
        return self.buffer[0..self.len];
    }

    fn appendElement(self: *Serializer, document: *const r4os.html.Document, node: u16, depth: usize) Error!void {
        if (depth >= 64) return error.DepthLimit;
        if (node >= document.node_count or document.nodes[node].kind != .element) return error.InvalidNode;
        const name = document.nodeName(node);
        if (name.len == 0) return error.InvalidNode;
        try self.append("<");
        try self.append(name);
        if (std.ascii.eqlIgnoreCase(name, "a")) {
            try self.append(" data-r4-node=\"");
            try self.appendUnsigned(node);
            try self.append("\"");
        }
        var attribute = document.nodes[node].first_attribute;
        var visited: usize = 0;
        while (attribute != r4os.html.none and visited < document.attribute_count) : (visited += 1) {
            if (attribute >= document.attribute_count) return error.InvalidNode;
            const item = document.attributes[attribute];
            const attribute_name = item.name.bytes(document.strings[0..document.string_len]);
            const attribute_value = item.value.bytes(document.strings[0..document.string_len]);
            try self.append(" ");
            try self.append(attribute_name);
            try self.append("=\"");
            try self.appendAttributeValue(attribute_value);
            try self.append("\"");
            attribute = item.next;
        }
        if (attribute != r4os.html.none) return error.InvalidNode;
        try self.append(">");
        var child = document.nodes[node].first_child;
        while (child != r4os.html.none) {
            if (child >= document.node_count) return error.InvalidNode;
            switch (document.nodes[child].kind) {
                .element => try self.appendElement(document, child, depth + 1),
                .text => try self.appendCdata(document.nodeValue(child)),
                else => {},
            }
            child = document.nodes[child].next_sibling;
        }
        try self.append("</");
        try self.append(name);
        try self.append(">");
    }

    fn appendAttributeValue(self: *Serializer, value: []const u8) Error!void {
        for (value) |byte| switch (byte) {
            '&' => try self.append("&amp;"),
            '"' => try self.append("&quot;"),
            '<' => try self.append("&lt;"),
            '>' => try self.append("&gt;"),
            else => try self.appendByte(byte),
        };
    }

    fn appendCdata(self: *Serializer, value: []const u8) Error!void {
        try self.append("<![CDATA[");
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, value, cursor, "]]>")) |end| {
            try self.append(value[cursor .. end + 2]);
            try self.append("]]><![CDATA[>");
            cursor = end + 3;
        }
        try self.append(value[cursor..]);
        try self.append("]]>");
    }

    fn append(self: *Serializer, value: []const u8) Error!void {
        if (value.len > self.buffer.len -| self.len) return error.SourceTooLarge;
        if (value.len > 0) @memcpy(self.buffer[self.len .. self.len + value.len], value);
        self.len += value.len;
    }

    fn appendByte(self: *Serializer, value: u8) Error!void {
        if (self.len >= self.buffer.len) return error.SourceTooLarge;
        self.buffer[self.len] = value;
        self.len += 1;
    }

    fn appendUnsigned(self: *Serializer, value: u16) Error!void {
        var digits: [5]u8 = undefined;
        var cursor = digits.len;
        var remaining = value;
        while (true) {
            cursor -= 1;
            digits[cursor] = '0' + @as(u8, @intCast(remaining % 10));
            remaining /= 10;
            if (remaining == 0) break;
        }
        try self.append(digits[cursor..]);
    }
};

pub fn isRoot(document: *const r4os.html.Document, node: u16) bool {
    if (node >= document.node_count or document.nodes[node].kind != .element or
        !std.ascii.eqlIgnoreCase(document.nodeName(node), "svg")) return false;
    var parent = document.nodes[node].parent;
    var visited: usize = 0;
    var connected = false;
    while (parent != r4os.html.none and visited < r4os.html.max_depth) : (visited += 1) {
        if (parent >= document.node_count) return false;
        if (document.nodes[parent].kind == .document) connected = true;
        if (document.nodes[parent].kind == .element and std.ascii.eqlIgnoreCase(document.nodeName(parent), "svg")) return false;
        parent = document.nodes[parent].parent;
    }
    return parent == r4os.html.none and connected;
}

test "inline SVG serializer emits a bounded standalone source" {
    var document: r4os.html.Document = undefined;
    _ = try document.parse(
        "<body><svg width='32' height='16' viewBox='0 0 32 16'><a href='/next'><rect width='32' height='16' fill='#2468ac'/></a><image href='https://fixture.invalid/optional.png' width='4' height='4'/><text>A &amp; B</text></svg></body>",
        .{ .content_type = "text/html" },
    );
    const root = document.findFirstElement("svg").?;
    try std.testing.expect(isRoot(&document, root));
    var source_buffer: [4096]u8 = undefined;
    var serializer = Serializer{ .buffer = source_buffer[0..] };
    const source = try serializer.serialize(&document, root);
    try std.testing.expect(std.mem.indexOf(u8, source, "<![CDATA[A & B]]>") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "data-r4-node=") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "<image") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "width=\"32\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "fill=\"#2468ac\"") != null);
}

test "inline SVG roots and serializer limits stay bounded" {
    var document: r4os.html.Document = undefined;
    _ = try document.parse(
        "<svg width='8' height='8'><g><svg width='4' height='4'><rect width='4' height='4'/></svg></g></svg>",
        .{ .content_type = "text/html" },
    );
    const outer = document.findFirstElement("svg").?;
    const group = document.nodes[outer].first_child;
    const inner = document.nodes[group].first_child;
    try std.testing.expect(isRoot(&document, outer));
    try std.testing.expect(!isRoot(&document, inner));
    var tiny: [8]u8 = undefined;
    var serializer = Serializer{ .buffer = tiny[0..] };
    try std.testing.expectError(error.SourceTooLarge, serializer.serialize(&document, outer));
    try document.detach(outer);
    try std.testing.expect(!isRoot(&document, outer));
}
