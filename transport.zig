//! A small C ABI around Zig's HTTP/1.1 client for the Python transport.
//! A client owns the connection pool. Each response is buffered before crossing the ABI.
const std = @import("std");

const gpa = std.heap.page_allocator;

pub const Slice = extern struct {
    ptr: [*]const u8,
    len: usize,

    fn bytes(self: Slice) []const u8 {
        return self.ptr[0..self.len];
    }
};

pub const Header = extern struct {
    name: Slice,
    value: Slice,
};

pub const Result = extern struct {
    status: u16,
    headers: Slice,
    body: Slice,
    error_name: ?[*:0]const u8,
};

const Client = struct {
    threaded: std.Io.Threaded,
    http: std.http.Client,
};

/// Create a client with a reusable connection pool.
export fn createClient() ?*Client {
    const client = gpa.create(Client) catch return null;
    client.threaded = .init_single_threaded;
    client.http = .{ .allocator = gpa, .io = client.threaded.io() };
    return client;
}

/// Close all pooled connections and release the client.
export fn freeClient(client: *Client) void {
    client.http.deinit();
    gpa.destroy(client);
}

/// Send one request and return owned response data. The caller must call freeResult.
export fn sendRequest(
    client: *Client,
    method: Slice,
    url: Slice,
    headers: [*]const Header,
    headers_len: usize,
    body: Slice,
) ?*Result {
    const result = gpa.create(Result) catch return null;
    result.* = .{
        .status = 0,
        .headers = .{ .ptr = "".ptr, .len = 0 },
        .body = .{ .ptr = "".ptr, .len = 0 },
        .error_name = null,
    };
    request(&client.http, result, method.bytes(), url.bytes(), headers[0..headers_len], body.bytes()) catch |err| {
        result.error_name = @errorName(err);
    };
    return result;
}

/// Release the response returned by sendRequest.
export fn freeResult(result: *Result) void {
    if (result.headers.len > 0) gpa.free(@constCast(result.headers.bytes()));
    if (result.body.len > 0) gpa.free(@constCast(result.body.bytes()));
    gpa.destroy(result);
}

fn request(
    client: *std.http.Client,
    result: *Result,
    method_bytes: []const u8,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
) !void {
    const method = std.meta.stringToEnum(std.http.Method, method_bytes) orelse return error.UnsupportedMethod;
    const uri = try std.Uri.parse(url);
    const extra_headers = try gpa.alloc(std.http.Header, headers.len);
    defer gpa.free(extra_headers);
    var header_count: usize = 0;
    for (headers) |header| {
        const name = header.name.bytes();
        if (std.ascii.eqlIgnoreCase(name, "content-length") or
            std.ascii.eqlIgnoreCase(name, "transfer-encoding")) continue;
        extra_headers[header_count] = .{ .name = name, .value = header.value.bytes() };
        header_count += 1;
    }

    var req = try client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .host = .omit,
            .user_agent = .omit,
            .connection = .omit,
            .accept_encoding = .omit,
            .content_type = .omit,
        },
        .extra_headers = extra_headers[0..header_count],
    });
    defer req.deinit();
    if (method.requestHasBody()) {
        try req.sendBodyComplete(@constCast(body));
    } else {
        if (body.len > 0) return error.UnsupportedBody;
        try req.sendBodiless();
    }

    var response = try req.receiveHead(&.{});
    result.status = @intFromEnum(response.head.status);
    var header_writer: std.Io.Writer.Allocating = .init(gpa);
    defer header_writer.deinit();
    var header_iterator = std.http.HeaderIterator.init(response.head.bytes);
    while (header_iterator.next()) |header| {
        try header_writer.writer.print("{s}: {s}\r\n", .{ header.name, header.value });
    }
    const header_bytes = try header_writer.toOwnedSlice();
    result.headers = .{ .ptr = header_bytes.ptr, .len = header_bytes.len };

    const body_capacity = if (response.head.transfer_encoding == .none) capacity: {
        const length = response.head.content_length orelse break :capacity 0;
        break :capacity if (length >= 4096 and length <= 1024 * 1024) @as(usize, @intCast(length)) else 0;
    } else 0;
    var transfer_buffer: [64]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    if (body_capacity > 0) {
        const body_bytes = try gpa.alloc(u8, body_capacity);
        errdefer gpa.free(body_bytes);
        reader.readSliceAll(body_bytes) catch return response.bodyErr() orelse error.ReadFailed;
        result.body = .{ .ptr = body_bytes.ptr, .len = body_bytes.len };
        return;
    }
    var body_writer: std.Io.Writer.Allocating = .init(gpa);
    defer body_writer.deinit();
    _ = reader.streamRemaining(&body_writer.writer) catch return response.bodyErr() orelse error.ReadFailed;
    const body_bytes = try body_writer.toOwnedSlice();
    result.body = .{ .ptr = body_bytes.ptr, .len = body_bytes.len };
}
