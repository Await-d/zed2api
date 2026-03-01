const std = @import("std");
const accounts = @import("accounts.zig");
const auth = @import("auth.zig");
const zed = @import("zed.zig");
const proxy = @import("proxy.zig");
const providers = @import("providers.zig");
const stream = @import("stream.zig");
const socket = @import("socket.zig");
const web_ui = @embedFile("web_index_html");

var account_mgr: accounts.AccountManager = undefined;
var global_allocator: std.mem.Allocator = undefined;
var account_mutex: std.Thread.Mutex = .{};
var server_port: u16 = 0;

// Dynamic models cache
var cached_models_openai: ?[]const u8 = null;
var cached_models_time: i64 = 0;
const MODELS_CACHE_TTL: i64 = 3600; // 1 hour

pub fn run(allocator: std.mem.Allocator, port: u16) !void {
    global_allocator = allocator;
    server_port = port;
    account_mgr = accounts.AccountManager.init(allocator);
    defer account_mgr.deinit();
    account_mgr.loadFromFile() catch {};

    std.debug.print("[zed2api] http://127.0.0.1:{d}\n[zed2api] {d} account(s) loaded\n", .{ port, account_mgr.list.items.len });

    proxy.init(allocator);
    if (proxy.getHost()) |host| {
        std.debug.print("[zed2api] proxy: {s}:{d}\n", .{ host, proxy.getPort() });
    } else {
        std.debug.print("[zed2api] proxy: none (set HTTPS_PROXY to use)\n", .{});
    }

    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    var tcp_server = try addr.listen(.{ .reuse_address = true });
    defer tcp_server.deinit();

    while (true) {
        const conn = tcp_server.accept() catch continue;
        const thread = std.Thread.spawn(.{}, handleConnection, .{conn.stream}) catch {
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(conn_stream: std.net.Stream) void {
    defer conn_stream.close();

    var hdr_buf: [8192]u8 = undefined;
    var hdr_total: usize = 0;

    while (hdr_total < hdr_buf.len) {
        const n = socket.recv(conn_stream, hdr_buf[hdr_total..]) catch return;
        if (n == 0) return;
        hdr_total += n;
        if (std.mem.indexOf(u8, hdr_buf[0..hdr_total], "\r\n\r\n") != null) break;
    }

    const header_end = std.mem.indexOf(u8, hdr_buf[0..hdr_total], "\r\n\r\n") orelse return;
    const headers = hdr_buf[0..header_end];
    const body_in_hdr = hdr_buf[header_end + 4 .. hdr_total];

    const first_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return;
    const first_line = headers[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.next() orelse return;
    const full_path = parts.next() orelse return;
    const path = if (std.mem.indexOf(u8, full_path, "?")) |i| full_path[0..i] else full_path;

    const is_login_callback = std.mem.eql(u8, method, "GET") and
        std.mem.eql(u8, path, "/") and
        login_status == .waiting and
        std.mem.indexOf(u8, full_path, "user_id=") != null and
        std.mem.indexOf(u8, full_path, "access_token=") != null;
    if (is_login_callback) {
        handleLoginCallback(conn_stream, full_path);
        return;
    }

    var content_length: usize = 0;
    var header_lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (header_lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trim(u8, line["content-length:".len..], " ");
            content_length = std.fmt.parseInt(usize, val, 10) catch 0;
        }
    }

    // Read body (up to 16MB)
    const max_body = 16 * 1024 * 1024;
    const actual_len = @min(content_length, max_body);
    var body: []const u8 = "";
    var body_alloc: ?[]u8 = null;
    defer if (body_alloc) |b| global_allocator.free(b);

    if (actual_len > 0) {
        const body_buf = global_allocator.alloc(u8, actual_len) catch {
            socket.writeResponse(conn_stream, 500, "{\"error\":\"body too large\"}");
            return;
        };
        body_alloc = body_buf;
        const already = @min(body_in_hdr.len, actual_len);
        @memcpy(body_buf[0..already], body_in_hdr[0..already]);
        var filled: usize = already;
        while (filled < actual_len) {
            const n = socket.recv(conn_stream, body_buf[filled..actual_len]) catch break;
            if (n == 0) break;
            filled += n;
        }
        body = body_buf[0..filled];
    }

    // Streaming proxy check
    const is_messages = std.mem.eql(u8, path, "/v1/messages") and std.mem.eql(u8, method, "POST");
    const is_completions = std.mem.eql(u8, path, "/v1/chat/completions") and std.mem.eql(u8, method, "POST");
    const wants_stream = (is_messages or is_completions) and
        (std.mem.indexOf(u8, body, "\"stream\":true") != null or
        std.mem.indexOf(u8, body, "\"stream\": true") != null);

    if (wants_stream) {
        const req_model = providers.extractModelFromBody(global_allocator, body) catch "unknown";
        const has_thinking = std.mem.indexOf(u8, body, "\"thinking\"") != null;
        std.debug.print("[req] {s} {s} model={s} thinking={} body={d}bytes (stream)\n", .{ method, path, req_model, has_thinking, body.len });
        stream.handleStreamProxy(conn_stream, body, is_messages, &account_mgr, global_allocator);
        return;
    }

    // Non-streaming route
    const response = route(method, path, body) catch |err| {
        std.debug.print("[zed2api] route error: {} for {s} {s}\n", .{ err, method, path });
        socket.writeResponse(conn_stream, 500, "{\"error\":\"internal error\"}");
        return;
    };
    defer if (response.allocated) global_allocator.free(response.body);
    socket.writeResponseWithType(conn_stream, response.status, response.body, response.content_type);
}

const Response = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8 = "application/json",
    allocated: bool = false,
};

fn route(method: []const u8, path: []const u8, body: []const u8) !Response {
    std.debug.print("[req] {s} {s} body={d}bytes\n", .{ method, path, body.len });

    if (std.mem.eql(u8, path, "/")) return .{ .status = 200, .body = web_ui, .content_type = "text/html; charset=utf-8" };
    if (std.mem.eql(u8, path, "/v1/models") and std.mem.eql(u8, method, "GET"))
        return try handleModels();
    if (std.mem.eql(u8, path, "/api/event_logging/batch"))
        return .{ .status = 200, .body = "{\"status\":\"ok\"}" };
    if (std.mem.startsWith(u8, path, "/v1/messages/count_tokens"))
        return .{ .status = 200, .body = "{\"input_tokens\":0}" };
    if (std.mem.eql(u8, path, "/zed/accounts") and std.mem.eql(u8, method, "GET"))
        return try handleListAccounts();
    if (std.mem.eql(u8, path, "/zed/accounts/switch") and std.mem.eql(u8, method, "POST"))
        return handleSwitchAccount(body);
    if (std.mem.eql(u8, path, "/zed/accounts/delete") and std.mem.eql(u8, method, "POST"))
        return try handleDeleteAccounts(body);
    if (std.mem.eql(u8, path, "/zed/accounts/rename") and std.mem.eql(u8, method, "POST"))
        return try handleRenameAccount(body);
    if (std.mem.eql(u8, path, "/zed/accounts/sync-billing") and std.mem.eql(u8, method, "POST"))
        return try handleSyncBilling(body);
    if (std.mem.eql(u8, path, "/zed/usage") and std.mem.eql(u8, method, "GET"))
        return try handleUsage();
    if (std.mem.eql(u8, path, "/zed/billing") and std.mem.eql(u8, method, "GET"))
        return try handleBilling();
    if (std.mem.eql(u8, path, "/v1/chat/completions") and std.mem.eql(u8, method, "POST"))
        return try handleProxy(body, false);
    if (std.mem.eql(u8, path, "/v1/messages") and std.mem.eql(u8, method, "POST"))
        return try handleProxy(body, true);
    if (std.mem.eql(u8, path, "/zed/login") and std.mem.eql(u8, method, "POST"))
        return try handleLogin(body);
    if (std.mem.eql(u8, path, "/zed/login/status") and std.mem.eql(u8, method, "GET"))
        return handleLoginStatus();
    if (std.mem.eql(u8, method, "OPTIONS"))
        return .{ .status = 200, .body = "" };
    return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
}

// ── Non-streaming proxy with failover ──

fn handleProxy(body: []const u8, is_anthropic: bool) !Response {
    account_mutex.lock(); defer account_mutex.unlock();
    if (account_mgr.list.items.len == 0) return .{ .status = 400, .body = "{\"error\":\"no account configured\"}" };

    const total = account_mgr.list.items.len;
    var try_order: [64]usize = undefined;
    const count = @min(total, 64);
    try_order[0] = account_mgr.current;
    var order_idx: usize = 1;
    for (0..total) |i| {
        if (i != account_mgr.current and order_idx < count) {
            try_order[order_idx] = i;
            order_idx += 1;
        }
    }

    var last_err: anyerror = error.UpstreamError;
    for (try_order[0..count]) |acc_idx| {
        const acc = &account_mgr.list.items[acc_idx];
        const result = if (is_anthropic)
            zed.proxyMessages(global_allocator, acc, body)
        else
            zed.proxyChatCompletions(global_allocator, acc, body);

        if (result) |data| {
            if (acc_idx != account_mgr.current) {
                std.debug.print("[zed2api] failover success: switched to '{s}'\n", .{acc.name});
                account_mgr.current = acc_idx;
            }
            return .{ .status = 200, .body = data, .allocated = true };
        } else |err| {
            last_err = err;
            std.debug.print("[zed2api] account '{s}' failed: {}\n", .{ acc.name, err });
            const should_failover = (err == error.TokenRefreshFailed or err == error.TokenExpired or err == error.UpstreamError);
            if (!should_failover) break;
        }
    }

    const status: u16 = switch (last_err) {
        error.TokenRefreshFailed => 401,
        error.TokenExpired => 401,
        error.UpstreamError => 502,
        else => 500,
    };
    const msg = switch (last_err) {
        error.TokenRefreshFailed => "{\"error\":{\"message\":\"All accounts failed: token refresh failed\",\"type\":\"auth_error\"}}",
        error.TokenExpired => "{\"error\":{\"message\":\"All accounts failed: token expired\",\"type\":\"auth_error\"}}",
        error.UpstreamError => "{\"error\":{\"message\":\"All accounts failed: upstream error\",\"type\":\"upstream_error\"}}",
        else => "{\"error\":{\"message\":\"All accounts failed: internal error\",\"type\":\"server_error\"}}",
    };
    return .{ .status = status, .body = msg };
}

// ── Account handlers ──

fn handleListAccounts() !Response {
    account_mutex.lock(); defer account_mutex.unlock();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(global_allocator);
    try w.writeAll("{\"accounts\":[");
    for (account_mgr.list.items, 0..) |acc, i| {
        if (i > 0) try w.writeAll(",");

        // Extract plan: prefer live JWT claims, fall back to persisted acc.plan.
        var plan_buf: [256]u8 = undefined;
        var plan_len: usize = 0;
        plan_blk: {
            if (acc.jwt_token) |jwt| {
                const claims = zed.parseJwtClaims(global_allocator, jwt) catch break :plan_blk;
                defer global_allocator.free(claims);
                const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, claims, .{}) catch break :plan_blk;
                defer parsed.deinit();
                if (parsed.value == .object) {
                    if (parsed.value.object.get("plan")) |pv| {
                        if (pv == .string) {
                            const len = @min(pv.string.len, plan_buf.len - 1);
                            @memcpy(plan_buf[0..len], pv.string[0..len]);
                            plan_len = len;
                        }
                    }
                }
            } else if (acc.plan) |p| {
                // JWT not cached yet — use value persisted by saveBillingInfo.
                const len = @min(p.len, plan_buf.len - 1);
                @memcpy(plan_buf[0..len], p[0..len]);
                plan_len = len;
            }
        }

        const expires = acc.expires_at orelse "";
        try w.print(
            "{{\"name\":\"{s}\",\"user_id\":\"{s}\",\"current\":{s},\"plan\":\"{s}\",\"expires_at\":\"{s}\"}}",
            .{
                acc.name, acc.user_id,
                if (i == account_mgr.current) "true" else "false",
                plan_buf[0..plan_len],
                expires,
            },
        );
    }
    try w.print("],\"current\":\"{s}\"}}", .{
        if (account_mgr.getCurrent()) |c| c.name else "",
    });
    return .{ .status = 200, .body = try buf.toOwnedSlice(global_allocator), .allocated = true };
}

fn handleSwitchAccount(body: []const u8) Response {
    account_mutex.lock(); defer account_mutex.unlock();
    const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch
        return .{ .status = 400, .body = "{\"error\":\"invalid json\"}" };
    defer parsed.deinit();
    const name = switch (parsed.value.object.get("account") orelse return .{ .status = 400, .body = "{\"error\":\"missing account\"}" }) {
        .string => |s| s,
        else => return .{ .status = 400, .body = "{\"error\":\"bad type\"}" },
    };
    if (account_mgr.switchTo(name))
        return .{ .status = 200, .body = "{\"success\":true}" }
    else
        return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
}
fn handleDeleteAccounts(body: []const u8) !Response {
    account_mutex.lock(); defer account_mutex.unlock();
    const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch
        return .{ .status = 400, .body = "{\"error\":\"invalid json\"}" };
    defer parsed.deinit();

    // Accept either {"names":[...]} or {"name":"..."}
    var names_list = std.ArrayListUnmanaged([]const u8).empty;
    defer names_list.deinit(global_allocator);

    if (parsed.value.object.get("names")) |v| {
        if (v == .array) {
            for (v.array.items) |item| {
                if (item == .string) {
                    try names_list.append(global_allocator, item.string);
                }
            }
        }
    } else if (parsed.value.object.get("name")) |v| {
        if (v == .string) {
            try names_list.append(global_allocator, v.string);
        }
    }

    if (names_list.items.len == 0)
        return .{ .status = 400, .body = "{\"error\":\"no names provided\"}" };

    const removed = accounts.removeAccounts(global_allocator, names_list.items) catch
        return .{ .status = 500, .body = "{\"error\":\"failed to update accounts file\"}" };

    // Reload account manager
    account_mgr.deinit();
    account_mgr = accounts.AccountManager.init(global_allocator);
    account_mgr.loadFromFile() catch {};

    var resp_buf: [128]u8 = undefined;
    const resp = try std.fmt.bufPrint(&resp_buf, "{{\"removed\":{d}}}", .{removed});
    return .{ .status = 200, .body = try global_allocator.dupe(u8, resp), .allocated = true };
}

fn handleRenameAccount(body: []const u8) !Response {
    account_mutex.lock(); defer account_mutex.unlock();
    const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch
        return .{ .status = 400, .body = "{\"error\":\"invalid json\"}" };
    defer parsed.deinit();

    const old_name = switch (parsed.value.object.get("old_name") orelse
        return .{ .status = 400, .body = "{\"error\":\"missing old_name\"}" }) {
        .string => |s| s,
        else => return .{ .status = 400, .body = "{\"error\":\"bad type\"}" },
    };
    const new_name = switch (parsed.value.object.get("new_name") orelse
        return .{ .status = 400, .body = "{\"error\":\"missing new_name\"}" }) {
        .string => |s| s,
        else => return .{ .status = 400, .body = "{\"error\":\"bad type\"}" },
    };

    if (new_name.len == 0)
        return .{ .status = 400, .body = "{\"error\":\"new_name cannot be empty\"}" };

    accounts.renameAccount(global_allocator, old_name, new_name) catch |err| {
        if (err == error.NotFound)
            return .{ .status = 404, .body = "{\"error\":\"account not found\"}" };
        return .{ .status = 500, .body = "{\"error\":\"failed to update accounts file\"}" };
    };

    // Reload account manager
    account_mgr.deinit();
    account_mgr = accounts.AccountManager.init(global_allocator);
    account_mgr.loadFromFile() catch {};

    return .{ .status = 200, .body = "{\"success\":true}" };
}


fn handleSyncBilling(body: []const u8) !Response {
    account_mutex.lock(); defer account_mutex.unlock();

    // Parse optional target account name from body
    var req_name: ?[]const u8 = null;
    var body_p: ?std.json.Parsed(std.json.Value) = null;
    if (body.len > 0) {
        if (std.json.parseFromSlice(std.json.Value, global_allocator, body, .{})) |p| {
            body_p = p;
            if (p.value == .object) {
                if (p.value.object.get("name")) |v| {
                    if (v == .string) req_name = v.string;
                }
            }
        } else |_| {}
    }
    defer if (body_p) |p| p.deinit();

    // Find the account pointer
    const acc = blk: {
        if (req_name) |n| {
            for (account_mgr.list.items) |*a| {
                if (std.mem.eql(u8, a.name, n)) break :blk a;
            }
            return .{ .status = 404, .body = "{\"error\":\"account not found\"}" };
        }
        break :blk account_mgr.getCurrent() orelse
            return .{ .status = 400, .body = "{\"error\":\"no account\"}" };
    };

    // Refresh token and extract plan name from JWT claims
    var plan_buf: [256]u8 = undefined;
    var plan_len: usize = 0;
    if (zed.getToken(global_allocator, acc)) |jwt| {
        if (zed.parseJwtClaims(global_allocator, jwt)) |claims_raw| {
            defer global_allocator.free(claims_raw);
            if (std.json.parseFromSlice(std.json.Value, global_allocator, claims_raw, .{})) |c| {
                defer c.deinit();
                if (c.value == .object) {
                    if (c.value.object.get("plan")) |pv| {
                        if (pv == .string) {
                            const l = @min(pv.string.len, plan_buf.len - 1);
                            @memcpy(plan_buf[0..l], pv.string[0..l]);
                            plan_len = l;
                        }
                    }
                }
            } else |_| {}
        } else |_| {}
    } else |_| {}

    // Copy fields we need before account_mgr reload
    const name_dup = try global_allocator.dupe(u8, acc.name);
    defer global_allocator.free(name_dup);
    const uid_dup = try global_allocator.dupe(u8, acc.user_id);
    defer global_allocator.free(uid_dup);
    const cred_dup = try global_allocator.dupe(u8, acc.credential_json);
    defer global_allocator.free(cred_dup);
    const plan_dup = try global_allocator.dupe(u8, plan_buf[0..plan_len]);
    defer global_allocator.free(plan_dup);

    // Fetch billing (users/me) for expires_at
    var expires_buf: [64]u8 = undefined;
    var expires_len: usize = 0;
    if (zed.fetchBillingUsageRaw(global_allocator, uid_dup, cred_dup)) |billing_raw| {
        defer global_allocator.free(billing_raw);
        if (std.json.parseFromSlice(std.json.Value, global_allocator, billing_raw, .{})) |b| {
            defer b.deinit();
            if (b.value == .object) {
                if (b.value.object.get("plan")) |plan_val| {
                    if (plan_val == .object) {
                        if (plan_val.object.get("subscription_period")) |sp| {
                            if (sp == .object) {
                                if (sp.object.get("ended_at")) |ea| {
                                    if (ea == .string) {
                                        const l = @min(ea.string.len, expires_buf.len - 1);
                                        @memcpy(expires_buf[0..l], ea.string[0..l]);
                                        expires_len = l;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else |_| {}
    } else |_| {}

    // Persist plan + expires_at
    accounts.saveBillingInfo(global_allocator, name_dup, plan_dup, expires_buf[0..expires_len]) catch |err| {
        std.debug.print("[billing] saveBillingInfo failed: {}\n", .{err});
        return .{ .status = 500, .body = "{\"error\":\"save failed\"}" };
    };

    // Reload account manager so in-memory data matches disk
    account_mgr.deinit();
    account_mgr = accounts.AccountManager.init(global_allocator);
    account_mgr.loadFromFile() catch {};

    return .{ .status = 200, .body = "{\"success\":true}" };
}
fn handleUsage() !Response {
    account_mutex.lock(); defer account_mutex.unlock();
    const acc = account_mgr.getCurrent() orelse return .{ .status = 400, .body = "{\"error\":\"no account\"}" };
    const jwt = try zed.getToken(global_allocator, acc);
    const claims = try zed.parseJwtClaims(global_allocator, jwt);
    return .{ .status = 200, .body = claims, .allocated = true };
}

fn handleBilling() !Response {
    account_mutex.lock(); defer account_mutex.unlock();
    const acc = account_mgr.getCurrent() orelse return .{ .status = 400, .body = "{\"error\":\"no account\"}" };
    const user_info = zed.fetchBillingUsage(global_allocator, acc) catch {
        return .{ .status = 502, .body = "{\"error\":\"failed to fetch user info\"}" };
    };
    return .{ .status = 200, .body = user_info, .allocated = true };
}

fn handleModels() !Response {
    account_mutex.lock(); defer account_mutex.unlock();
    const now = std.time.timestamp();
    if (cached_models_openai) |cached| {
        if (now - cached_models_time < MODELS_CACHE_TTL) {
            return .{ .status = 200, .body = cached };
        }
    }

    // Fetch from Zed
    const acc = account_mgr.getCurrent() orelse {
        // Fallback to static
        return .{ .status = 200, .body = @embedFile("models.json") };
    };

    const raw = zed.fetchModels(global_allocator, acc) catch {
        // Fallback to cache or static
        if (cached_models_openai) |cached| return .{ .status = 200, .body = cached };
        return .{ .status = 200, .body = @embedFile("models.json") };
    };
    defer global_allocator.free(raw);

    // Convert Zed format to OpenAI format
    const openai = convertZedModelsToOpenAI(global_allocator, raw) catch {
        if (cached_models_openai) |cached| return .{ .status = 200, .body = cached };
        return .{ .status = 200, .body = @embedFile("models.json") };
    };

    // Update cache
    if (cached_models_openai) |old| global_allocator.free(old);
    cached_models_openai = openai;
    cached_models_time = now;

    std.debug.print("[zed2api] models refreshed ({d} bytes)\n", .{openai.len});
    return .{ .status = 200, .body = openai };
}

fn convertZedModelsToOpenAI(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const models = switch (parsed.value.object.get("models") orelse return error.InvalidFormat) {
        .array => |a| a,
        else => return error.InvalidFormat,
    };

    var buf: std.io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("{\"object\":\"list\",\"data\":[");
    var first = true;
    for (models.items) |model| {
        if (model != .object) continue;
        const id = switch (model.object.get("id") orelse continue) { .string => |s| s, else => continue };
        const provider = switch (model.object.get("provider") orelse continue) { .string => |s| s, else => continue };

        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"id\":\"{s}\",\"object\":\"model\",\"owned_by\":\"{s}\"}}", .{ id, provider });
    }
    try w.writeAll("]}");
    return try buf.toOwnedSlice();
}

// ── Login ──
const LoginSession = struct {
    keypair: *auth.RsaKeyPair,
    account_name: []const u8,
};

var login_status: enum { idle, waiting, success, failed } = .idle;
var login_error_msg: []const u8 = "";
var login_result_name: []const u8 = "";
var login_session: ?LoginSession = null;

fn parseEnvPort(name: []const u8) ?u16 {
    const raw = std.process.getEnvVarOwned(global_allocator, name) catch return null;
    defer global_allocator.free(raw);
    return std.fmt.parseInt(u16, raw, 10) catch null;
}

fn clearLoginSession() void {
    const session = login_session orelse return;
    session.keypair.deinit();
    global_allocator.destroy(session.keypair);
    if (session.account_name.len > 0) global_allocator.free(session.account_name);
    login_session = null;
}

fn writeLoginSuccessRedirect(conn_stream: std.net.Stream) void {
    const redirect = "HTTP/1.1 302 Found\r\nLocation: https://zed.dev/native_app_signin_succeeded\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    socket.send(conn_stream, redirect) catch {};
}

fn handleLoginCallback(conn_stream: std.net.Stream, full_path: []const u8) void {
    const session = login_session orelse {
        socket.writeResponse(conn_stream, 409, "{\"error\":\"login session missing\"}");
        return;
    };

    const creds = auth.completeLoginFromPath(global_allocator, session.keypair, full_path) catch |err| {
        login_status = .failed;
        login_error_msg = @errorName(err);
        clearLoginSession();
        socket.writeResponse(conn_stream, 400, "{\"error\":\"bad callback\"}");
        return;
    };
    defer global_allocator.free(creds.user_id);
    defer global_allocator.free(creds.access_token);

    const name = if (session.account_name.len > 0) session.account_name else creds.user_id;
    accounts.addAccount(global_allocator, name, creds.user_id, creds.access_token) catch |err| {
        login_status = .failed;
        login_error_msg = @errorName(err);
        clearLoginSession();
        socket.writeResponse(conn_stream, 500, "{\"error\":\"failed to save account\"}");
        return;
    };

    account_mutex.lock(); defer account_mutex.unlock();
    account_mgr.deinit();
    account_mgr = accounts.AccountManager.init(global_allocator);
    account_mgr.loadFromFile() catch {};

    if (login_result_name.len > 0) global_allocator.free(login_result_name);
    login_result_name = global_allocator.dupe(u8, name) catch "";
    login_error_msg = "";
    login_status = .success;

    std.debug.print("[login] success: {s}\n", .{name});
    clearLoginSession();
    writeLoginSuccessRedirect(conn_stream);
}

fn handleLogin(body: []const u8) !Response {
    if (login_status == .waiting) return .{ .status = 409, .body = "{\"error\":\"login already in progress\"}" };

    var account_name: []const u8 = "";
    var requested_public_port: ?u16 = null;
    var requested_public_host: ?[]const u8 = null;
    if (body.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value.object.get("name")) |n| {
                if (n == .string) account_name = global_allocator.dupe(u8, n.string) catch "";
            }
            if (p.value.object.get("public_port")) |pp| {
                switch (pp) {
                    .integer => |v| {
                        if (v > 0 and v <= std.math.maxInt(u16)) {
                            requested_public_port = @intCast(v);
                        }
                    },
                    .string => |s| {
                        requested_public_port = std.fmt.parseInt(u16, s, 10) catch null;
                    },
                    else => {},
                }
            }
            if (p.value.object.get("public_host")) |ph| {
                if (ph == .string and ph.string.len > 0) {
                    requested_public_host = global_allocator.dupe(u8, ph.string) catch null;
                }
            }
        }
    }

    const keypair = try global_allocator.create(auth.RsaKeyPair);
    errdefer global_allocator.destroy(keypair);
    keypair.* = try auth.RsaKeyPair.generate(global_allocator);
    errdefer keypair.deinit();
    if (account_name.len > 0) {
        errdefer global_allocator.free(account_name);
    }

    const pub_key = try keypair.exportPublicKeyB64(global_allocator);
    defer global_allocator.free(pub_key);

    const public_port = requested_public_port orelse parseEnvPort("ZED2API_LOGIN_PUBLIC_PORT") orelse server_port;
    const is_remote_host = requested_public_host != null and
        !std.mem.eql(u8, requested_public_host.?, "localhost") and
        !std.mem.eql(u8, requested_public_host.?, "127.0.0.1");
    const url = if (is_remote_host)
        try std.fmt.allocPrint(global_allocator, "https://zed.dev/native_app_signin?native_app_host={s}&native_app_port={d}&native_app_public_key={s}", .{ requested_public_host.?, public_port, pub_key })
    else
        try std.fmt.allocPrint(global_allocator, "https://zed.dev/native_app_signin?native_app_port={d}&native_app_public_key={s}", .{ public_port, pub_key });
    defer global_allocator.free(url);

    clearLoginSession();
    login_session = .{
        .keypair = keypair,
        .account_name = account_name,
    };

    login_status = .waiting;
    login_error_msg = "";

    var resp_buf: [4096]u8 = undefined;
    const resp = try std.fmt.bufPrint(&resp_buf, "{{\"login_url\":\"{s}\",\"port\":{d}}}", .{ url, public_port });
    const result = try global_allocator.dupe(u8, resp);
    return .{ .status = 200, .body = result, .allocated = true };
}

fn handleLoginStatus() Response {
    return switch (login_status) {
        .idle => .{ .status = 200, .body = "{\"status\":\"idle\"}" },
        .waiting => .{ .status = 200, .body = "{\"status\":\"waiting\"}" },
        .success => blk: { login_status = .idle; break :blk .{ .status = 200, .body = "{\"status\":\"success\"}" }; },
        .failed => blk: { login_status = .idle; break :blk .{ .status = 200, .body = "{\"status\":\"failed\"}" }; },
    };
}
