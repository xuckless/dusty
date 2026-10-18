//! HTTP/2 engine tests: a dusty server with cleartext HTTP/2 (prior
//! knowledge) on loopback, driven by a minimal nghttp2 client.
const std = @import("std");
const dusty = @import("../root.zig");
const c = @import("nghttp2");
const build_options = @import("build_options");
const tls = @import("tls");

const loopback_addr: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };

/// A blocking HTTP/2 client over one connection, for tests: submit
/// requests, then `run` until every stream is closed.
const TestClient = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    read_buf: [16 * 1024 + 1024]u8 = undefined,
    write_buf: [16 * 1024 + 1024]u8 = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    /// The connection as the session sees it: the socket, or TLS over it.
    r: *std.Io.Reader = undefined,
    w: *std.Io.Writer = undefined,
    tls_conn: if (build_options.use_tls) ?tls.Connection else void = if (build_options.use_tls) null else {},
    tls_reader: if (build_options.use_tls) tls.Connection.Reader else void = undefined,
    tls_writer: if (build_options.use_tls) tls.Connection.Writer else void = undefined,
    plain_read: [4096]u8 = undefined,
    plain_write: [4096]u8 = undefined,
    session: ?*c.nghttp2_session = null,
    responses: std.AutoHashMapUnmanaged(i32, *Resp) = .empty,
    /// The last-stream-ID of each GOAWAY received, in order.
    goaways: [4]i32 = undefined,
    goaway_count: usize = 0,

    const Resp = struct {
        status: u16 = 0,
        content_length: ?[]u8 = null,
        has_date: bool = false,
        body: std.ArrayList(u8) = .empty,
        trailer: ?[]u8 = null,
        closed: bool = false,
        error_code: u32 = 0,
        /// The request body to send, if any.
        send: []const u8 = "",
        sent: usize = 0,
    };

    fn init(self: *TestClient, gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress) !void {
        self.* = .{ .gpa = gpa, .io = io, .stream = try addr.connect(io, .{ .mode = .stream }) };
        self.reader = self.stream.reader(io, &self.read_buf);
        self.writer = self.stream.writer(io, &self.write_buf);
        self.r = &self.reader.interface;
        self.w = &self.writer.interface;
        try self.initSession();
    }

    /// Over TLS, offering only "h2" through ALPN.
    fn initTls(self: *TestClient, gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress, ca: *std.crypto.Certificate.Bundle) !void {
        self.* = .{ .gpa = gpa, .io = io, .stream = try addr.connect(io, .{ .mode = .stream }) };
        self.reader = self.stream.reader(io, &self.read_buf);
        self.writer = self.stream.writer(io, &self.write_buf);
        var rng: std.Random.IoSource = .{ .io = io };
        self.tls_conn = try tls.client(&self.reader.interface, &self.writer.interface, .{
            .host = "localhost",
            .root_ca = ca.*,
            .now = std.Io.Clock.real.now(io),
            .rng = rng.interface(),
            .alpn_protocols = &.{"h2"},
        });
        if (!std.mem.eql(u8, self.tls_conn.?.alpn_protocol orelse "", "h2")) return error.NoH2;
        self.tls_reader = self.tls_conn.?.reader(&self.plain_read);
        self.tls_writer = self.tls_conn.?.writer(&self.plain_write);
        self.r = &self.tls_reader.interface;
        self.w = &self.tls_writer.interface;
        try self.initSession();
    }

    fn initSession(self: *TestClient) !void {
        var callbacks: ?*c.nghttp2_session_callbacks = null;
        _ = c.nghttp2_session_callbacks_new(&callbacks);
        defer c.nghttp2_session_callbacks_del(callbacks);
        c.nghttp2_session_callbacks_set_on_header_callback(callbacks, onHeader);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onData);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onClose);
        c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrame);
        if (c.nghttp2_session_client_new(&self.session, callbacks, self) != 0) return error.Http2Init;
        if (c.nghttp2_submit_settings(self.session, c.NGHTTP2_FLAG_NONE, null, 0) != 0) return error.Http2Init;
    }

    fn deinit(self: *TestClient) void {
        var it = self.responses.valueIterator();
        while (it.next()) |r| {
            r.*.body.deinit(self.gpa);
            if (r.*.content_length) |v| self.gpa.free(v);
            if (r.*.trailer) |v| self.gpa.free(v);
            self.gpa.destroy(r.*);
        }
        self.responses.deinit(self.gpa);
        c.nghttp2_session_del(self.session);
        self.stream.close(self.io);
    }

    fn request(self: *TestClient, method: []const u8, path: []const u8, body: ?[]const u8) !i32 {
        const nva = [_]c.nghttp2_nv{
            nv(":method", method),
            nv(":path", path),
            nv(":scheme", "http"),
            nv(":authority", "localhost"),
        };
        const resp = try self.gpa.create(Resp);
        resp.* = .{ .send = body orelse "" };
        var provider: c.nghttp2_data_provider2 = .{ .source = .{ .ptr = resp }, .read_callback = provide };
        const id = c.nghttp2_submit_request2(self.session, null, &nva, nva.len, if (body != null) &provider else null, resp);
        if (id < 0) return error.Http2Submit;
        try self.responses.put(self.gpa, id, resp);
        return id;
    }

    fn get(self: *TestClient, id: i32) *Resp {
        return self.responses.get(id).?;
    }

    /// Sends and receives until every submitted stream is closed.
    fn run(self: *TestClient) !void {
        while (true) {
            while (true) {
                var data: [*c]const u8 = undefined;
                const n = c.nghttp2_session_mem_send2(self.session, &data);
                if (n < 0) return error.Http2Send;
                if (n == 0) break;
                try self.w.writeAll(data[0..@intCast(n)]);
            }
            try self.w.flush();

            var all_closed = true;
            var it = self.responses.valueIterator();
            while (it.next()) |r| if (!r.*.closed) {
                all_closed = false;
            };
            if (all_closed) return;

            const bytes = try self.r.peekGreedy(1);
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Http2Recv;
            self.r.toss(@intCast(rv));
        }
    }

    fn nv(name: []const u8, value: []const u8) c.nghttp2_nv {
        return .{ .name = @constCast(name.ptr), .namelen = name.len, .value = @constCast(value.ptr), .valuelen = value.len, .flags = c.NGHTTP2_NV_FLAG_NONE };
    }

    fn respFor(session: ?*c.nghttp2_session, id: i32) ?*Resp {
        const ptr = c.nghttp2_session_get_stream_user_data(session, id) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn onHeader(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, name: [*c]const u8, namelen: usize, value: [*c]const u8, valuelen: usize, _: u8, user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *TestClient = @ptrCast(@alignCast(user_data.?));
        const resp = respFor(session, frame.*.hd.stream_id) orelse return 0;
        const n = name[0..namelen];
        const v = value[0..valuelen];
        if (frame.*.headers.cat == c.NGHTTP2_HCAT_HEADERS) {
            // Trailers: the second header block.
            if (std.mem.eql(u8, n, "x-done")) resp.trailer = self.gpa.dupe(u8, v) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            return 0;
        }
        if (std.mem.eql(u8, n, ":status")) resp.status = std.fmt.parseInt(u16, v, 10) catch 0;
        if (std.mem.eql(u8, n, "content-length")) resp.content_length = self.gpa.dupe(u8, v) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        if (std.mem.eql(u8, n, "date")) resp.has_date = true;
        return 0;
    }

    fn onData(session: ?*c.nghttp2_session, _: u8, id: i32, data: [*c]const u8, len: usize, user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *TestClient = @ptrCast(@alignCast(user_data.?));
        const resp = respFor(session, id) orelse return 0;
        resp.body.appendSlice(self.gpa, data[0..len]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn onFrame(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *TestClient = @ptrCast(@alignCast(user_data.?));
        if (frame.*.hd.type == c.NGHTTP2_GOAWAY and self.goaway_count < self.goaways.len) {
            self.goaways[self.goaway_count] = frame.*.goaway.last_stream_id;
            self.goaway_count += 1;
        }
        return 0;
    }

    /// Keeps the connection going (answering PINGs and SETTINGS) until the
    /// server closes it.
    fn runUntilClosed(self: *TestClient) !void {
        while (true) {
            while (true) {
                var data: [*c]const u8 = undefined;
                const n = c.nghttp2_session_mem_send2(self.session, &data);
                if (n < 0) return error.Http2Send;
                if (n == 0) break;
                try self.w.writeAll(data[0..@intCast(n)]);
            }
            try self.w.flush();
            const bytes = self.r.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return,
                else => |e| return e,
            };
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Http2Recv;
            self.r.toss(@intCast(rv));
        }
    }

    fn onClose(session: ?*c.nghttp2_session, id: i32, error_code: u32, _: ?*anyopaque) callconv(.c) c_int {
        const resp = respFor(session, id) orelse return 0;
        resp.closed = true;
        resp.error_code = error_code;
        return 0;
    }

    fn provide(_: ?*c.nghttp2_session, _: i32, buf: [*c]u8, length: usize, flags: [*c]u32, source: [*c]c.nghttp2_data_source, _: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
        const resp: *Resp = @ptrCast(@alignCast(source.*.ptr.?));
        const rest = resp.send[resp.sent..];
        const n = @min(rest.len, length);
        @memcpy(buf[0..n], rest[0..n]);
        resp.sent += n;
        if (resp.sent == resp.send.len) flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
        return @intCast(n);
    }
};

const Handlers = struct {
    fn hello(_: *dusty.Request, res: *dusty.Response) !void {
        try res.print(.text, "hello", .{});
    }
    fn user(req: *dusty.Request, res: *dusty.Response) !void {
        try std.testing.expectEqual(@as(u8, 2), req.version_major);
        try res.print(.text, "user {s}", .{req.params.get("id").?});
    }
    fn echo(req: *dusty.Request, res: *dusty.Response) !void {
        var in_buf: [4096]u8 = undefined;
        var body = try req.reader(&in_buf);
        var out_buf: [4096]u8 = undefined;
        var out = try res.stream(&out_buf);
        _ = body.interface.streamRemaining(&out.interface) catch |err| switch (err) {
            error.ReadFailed => return body.err orelse error.Unexpected,
            error.WriteFailed => return out.err orelse error.Unexpected,
        };
        try out.end();
    }
    fn trailers(_: *dusty.Request, res: *dusty.Response) !void {
        res.body = "with trailers";
        try res.trailer("x-done", "yes");
    }
    fn ignoreBody(_: *dusty.Request, res: *dusty.Response) !void {
        res.body = "not reading that";
    }
    fn slow(req: *dusty.Request, res: *dusty.Response) !void {
        try req.io.sleep(.fromMilliseconds(300), .awake);
        res.body = "slow but whole";
    }
};

const Fixture = struct {
    server: dusty.Server(void),
    future: std.Io.Future(anyerror!void) = undefined,

    fn start(self: *Fixture, io: std.Io) !void {
        self.server = dusty.Server(void).init(std.testing.allocator, io, .{
            .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
        }, {});
        self.server.router.get("/hello", Handlers.hello);
        self.server.router.get("/users/:id", Handlers.user);
        self.server.router.post("/echo", Handlers.echo);
        self.server.router.get("/trailers", Handlers.trailers);
        self.server.router.post("/ignore", Handlers.ignoreBody);
        self.server.router.get("/slow", Handlers.slow);
        self.future = try io.concurrent(run, .{&self.server});
        try self.server.ready.wait(io);
    }

    fn run(s: *dusty.Server(void)) anyerror!void {
        try s.run();
    }

    fn stop(self: *Fixture, io: std.Io) void {
        self.future.cancel(io) catch {};
        self.server.deinit();
    }
};

test "HTTP/2: GET over prior-knowledge h2c reaches the router" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const ok = try client.request("GET", "/hello", null);
    const head = try client.request("HEAD", "/hello", null);
    const missing = try client.request("GET", "/nope", null);
    try client.run();

    try std.testing.expectEqual(@as(u16, 200), client.get(ok).status);
    try std.testing.expectEqualStrings("hello", client.get(ok).body.items);
    try std.testing.expect(client.get(ok).has_date);
    try std.testing.expectEqual(@as(u16, 200), client.get(head).status);
    try std.testing.expectEqualStrings("5", client.get(head).content_length.?);
    try std.testing.expectEqualStrings("", client.get(head).body.items);
    try std.testing.expectEqual(@as(u16, 404), client.get(missing).status);
}

test "HTTP/2: many streams multiplexed on one connection" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    var ids: [32]i32 = undefined;
    var paths: [32][16]u8 = undefined;
    for (&ids, 0..) |*id, i| {
        const path = try std.fmt.bufPrint(&paths[i], "/users/{d}", .{i});
        id.* = try client.request("GET", path, null);
    }
    try client.run();
    for (ids, 0..) |id, i| {
        var expect: [16]u8 = undefined;
        try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "user {d}", .{i}), client.get(id).body.items);
    }
}

test "HTTP/2: a request body larger than the windows is echoed back whole" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    const body = try std.testing.allocator.alloc(u8, 1024 * 1024 + 123);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 11));

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("POST", "/echo", body);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
    try std.testing.expectEqual(body.len, client.get(id).body.items.len);
    try std.testing.expect(std.mem.eql(u8, body, client.get(id).body.items));
}

test "HTTP/2: trailers follow the body" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("GET", "/trailers", null);
    try client.run();
    try std.testing.expectEqualStrings("with trailers", client.get(id).body.items);
    try std.testing.expectEqualStrings("yes", client.get(id).trailer.?);
}

test "HTTP/2: a small unread request body is read and dropped, and the stream ends cleanly" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    const body = try std.testing.allocator.alloc(u8, 20 * 1024);
    defer std.testing.allocator.free(body);
    @memset(body, 'y');

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("POST", "/ignore", body);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
    try std.testing.expectEqualStrings("not reading that", client.get(id).body.items);
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_NO_ERROR), client.get(id).error_code);
}

test "HTTP/2: an unread request body gets the whole response, then RST_STREAM(NO_ERROR)" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    const body = try std.testing.allocator.alloc(u8, 300 * 1024);
    defer std.testing.allocator.free(body);
    @memset(body, 'x');

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("POST", "/ignore", body);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
    try std.testing.expectEqualStrings("not reading that", client.get(id).body.items);
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_NO_ERROR), client.get(id).error_code);
}

test "HTTP/2: HTTP/1.1 still works on a prior-knowledge listener" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client = dusty.Client.init(std.testing.allocator, io, .{});
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/hello", .{fx.server.address.ip.getPort()});
    var response = try client.fetch(url, .{});
    defer response.deinit();
    try std.testing.expectEqual(.ok, response.status());
    try std.testing.expectEqualStrings("hello", (try response.body()).?);
}

test "HTTP/2: over TLS, chosen through ALPN" {
    if (!build_options.use_tls) return error.SkipZigTest;
    const io = std.testing.io;
    // The self-signed test certificate from examples/certs, as in client_test.zig.
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback_addr, .tls = .{
            .cert_path = "examples/certs/cert.pem",
            .key_path = "examples/certs/key.pem",
            .alpn_protocols = &.{ "h2", "http/1.1" },
        } }},
    }, {});
    defer server.deinit();
    server.router.get("/hello", Handlers.hello);
    server.router.post("/echo", Handlers.echo);
    var future = try io.concurrent(Fixture.run, .{&server});
    defer future.cancel(io) catch {};
    try server.ready.wait(io);

    const ca: dusty.TlsCa = .{ .file = .{ .path = "examples/certs/cert.pem" } };
    var bundle = try ca.load(std.testing.allocator, io);
    defer bundle.deinit(std.testing.allocator);

    const body = try std.testing.allocator.alloc(u8, 200 * 1024);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 7);

    var client: TestClient = undefined;
    try client.initTls(std.testing.allocator, io, server.address.ip, &bundle);
    defer client.deinit();
    const hello = try client.request("GET", "/hello", null);
    const echoed = try client.request("POST", "/echo", body);
    try client.run();
    try std.testing.expectEqualStrings("hello", client.get(hello).body.items);
    try std.testing.expect(std.mem.eql(u8, body, client.get(echoed).body.items));
}

/// Counts allocations through it, for the hot-path test below.
const CountingAllocator = struct {
    inner: std.mem.Allocator,
    count: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .monotonic);
        return self.inner.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .monotonic);
        return self.inner.rawRemap(memory, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ra);
    }
};

test "HTTP/2: a warm connection serves requests without allocating" {
    const io = std.testing.io;
    var counting: CountingAllocator = .{ .inner = std.testing.allocator };
    var server = dusty.Server(void).init(counting.allocator(), io, .{
        .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
    }, {});
    defer server.deinit();
    server.router.get("/users/:id", Handlers.user);
    var future = try io.concurrent(Fixture.run, .{&server});
    defer future.cancel(io) catch {};
    try server.ready.wait(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, server.address.ip);
    defer client.deinit();
    // Warm up: the stream pool, arenas and maps grow to what a request needs.
    for (0..5) |_| {
        _ = try client.request("GET", "/users/1", null);
        try client.run();
    }
    const before = counting.count.load(.monotonic);
    for (0..20) |_| {
        const id = try client.request("GET", "/users/2", null);
        try client.run();
        try std.testing.expectEqualStrings("user 2", client.get(id).body.items);
    }
    try std.testing.expectEqual(before, counting.count.load(.monotonic));
}

fn stopFixture(f: *Fixture, io: std.Io) void {
    f.future.cancel(io) catch {};
}

test "HTTP/2: a drain closes an idle connection with GOAWAY at once" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.server.deinit();

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);

    const started: std.Io.Clock.Timestamp = .now(io, .awake);
    var stopper = try io.concurrent(stopFixture, .{ &fx, io });
    defer stopper.await(io);

    // An nghttp2 client with nothing open takes the GOAWAY notice as the
    // end and closes; the server's side ends with it, well before the
    // notice's one-second fallback.
    try client.runUntilClosed();
    try std.testing.expect(client.goaway_count >= 1);
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), client.goaways[0]);
    try std.testing.expect(started.durationTo(.now(io, .awake)).raw.toMilliseconds() < 900);
}

test "HTTP/2: a drain with a stream in flight sends a two-phase GOAWAY and finishes the stream" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.server.deinit();

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const warm = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(warm).status);

    // Start the slow request, then shut down while it runs.
    const id = try client.request("GET", "/slow", null);
    while (true) {
        var data: [*c]const u8 = undefined;
        const n = c.nghttp2_session_mem_send2(client.session, &data);
        if (n <= 0) break;
        try client.w.writeAll(data[0..@intCast(n)]);
    }
    try client.w.flush();
    try io.sleep(.fromMilliseconds(100), .awake);
    var stopper = try io.concurrent(stopFixture, .{ &fx, io });
    defer stopper.await(io);

    try client.runUntilClosed();
    // The notice (the largest stream ID), answered with the PING ack,
    // then the final GOAWAY naming the slow stream as the last one taken.
    try std.testing.expectEqual(@as(usize, 2), client.goaway_count);
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), client.goaways[0]);
    try std.testing.expectEqual(id, client.goaways[1]);
    const resp = client.get(id);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("slow but whole", resp.body.items);
}
