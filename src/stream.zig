const std = @import("std");
const accounts = @import("accounts.zig");
const zed = @import("zed.zig");
const proxy = @import("proxy.zig");
const providers = @import("providers.zig");
const socket = @import("socket.zig");

/// Handle streaming proxy with account failover
pub fn handleStreamProxy(
    client_stream: std.net.Stream,
    body: []const u8,
    is_anthropic: bool,
    account_mgr: *accounts.AccountManager,
    allocator: std.mem.Allocator,
) void {
    if (account_mgr.list.items.len == 0) {
        socket.writeResponse(client_stream, 400, "{\"error\":\"no account configured\"}");
        return;
    }

    const total = account_mgr.list.items.len;
    var try_order: [64]usize = undefined;
    const count = @min(total, 64);
    try_order[0] = account_mgr.current;
    var idx: usize = 1;
    for (0..total) |i| {
        if (i != account_mgr.current and idx < count) {
            try_order[idx] = i;
            idx += 1;
        }
    }

    for (try_order[0..count]) |acc_idx| {
        const acc = &account_mgr.list.items[acc_idx];
        if (doStreamProxy(client_stream, acc, body, is_anthropic, allocator)) {
            if (acc_idx != account_mgr.current) {
                std.debug.print("[zed2api] stream failover: switched to '{s}'\n", .{acc.name});
                account_mgr.current = acc_idx;
            }
            return;
        } else {
            std.debug.print("[zed2api] stream: account '{s}' failed, trying next...\n", .{acc.name});
        }
    }

    socket.writeResponse(client_stream, 502, "{\"error\":{\"message\":\"All accounts failed\",\"type\":\"upstream_error\"}}");
}

fn doStreamProxy(client_stream: std.net.Stream, acc: *accounts.Account, body: []const u8, is_anthropic: bool, allocator: std.mem.Allocator) bool {
    const payload = providers.buildZedPayload(allocator, body, is_anthropic) catch |err| {
        std.debug.print("[stream] buildZedPayload failed: {}\n", .{err});
        return false;
    };
    defer allocator.free(payload);
    std.debug.print("[stream] zed payload: {d} bytes (client input: {d} bytes)\n", .{ payload.len, body.len });

    const jwt = zed.getToken(allocator, acc) catch |err| {
        std.debug.print("[stream] getToken failed: {}\n", .{err});
        return false;
    };
    const bearer = std.fmt.allocPrint(allocator, "Bearer {s}", .{jwt}) catch return false;
    defer allocator.free(bearer);

    const auth_header = std.fmt.allocPrint(allocator, "authorization: {s}", .{bearer}) catch return false;
    defer allocator.free(auth_header);

    proxy.init(allocator);

    // Write payload to temp file
    var tmp_name_buf: [64]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_name_buf, "zed2api_stream_{d}.json", .{std.time.milliTimestamp()}) catch "zed2api_stream_req.json";
    {
        const f = std.fs.cwd().createFile(tmp_path, .{}) catch return false;
        defer f.close();
        f.writeAll(payload) catch return false;
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const at_path = std.fmt.allocPrint(allocator, "@{s}", .{tmp_path}) catch return false;
    defer allocator.free(at_path);

    const proxy_url = if (proxy.getHost()) |host|
        (std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, proxy.getPort() }) catch return false)
    else
        null;
    defer if (proxy_url) |p| allocator.free(p);

    var argv_buf: [20][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "curl"; argc += 1;
    argv_buf[argc] = "-siN"; argc += 1;
    if (proxy_url) |p| { argv_buf[argc] = "-x"; argc += 1; argv_buf[argc] = p; argc += 1; }
    argv_buf[argc] = "-X"; argc += 1;
    argv_buf[argc] = "POST"; argc += 1;
    argv_buf[argc] = "https://cloud.zed.dev/completions"; argc += 1;
    argv_buf[argc] = "-H"; argc += 1;
    argv_buf[argc] = auth_header; argc += 1;
    argv_buf[argc] = "-H"; argc += 1;
    argv_buf[argc] = "content-type: application/json"; argc += 1;
    argv_buf[argc] = "-H"; argc += 1;
    argv_buf[argc] = "x-zed-version: 0.222.4+stable.147.b385025df963c9e8c3f74cc4dadb1c4b29b3c6f0"; argc += 1;
    argv_buf[argc] = "--data-binary"; argc += 1;
    argv_buf[argc] = at_path; argc += 1;
    argv_buf[argc] = "--max-time"; argc += 1;
    argv_buf[argc] = "300"; argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return false;

    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return false;
    };

    var line_buf: [65536]u8 = undefined;
    var line_len: usize = 0;
    var block_index: usize = 0;
    var got_any_data = false;
    var headers_sent = false;
    var has_tool_use = false;
    var http_headers_done = false;
    var http_status: u16 = 0;

    const model = providers.extractModelFromBody(allocator, body) catch "claude-sonnet-4-5";

    // Generate a stable ID for OpenAI format based on current time
    var openai_id_buf: [32]u8 = undefined;
    const openai_id = std.fmt.bufPrint(&openai_id_buf, "chatcmpl-{x}", .{@as(u64, @bitCast(std.time.milliTimestamp()))}) catch "chatcmpl-zed";

    while (true) {
        var one: [1]u8 = undefined;
        const n = stdout.read(&one) catch break;
        if (n == 0) break;

        if (one[0] == '\n') {
            if (!http_headers_done) {
                // Parse HTTP response headers from curl -i
                const line = line_buf[0..line_len];
                // Trim trailing \r
                const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
                if (trimmed.len == 0) {
                    // Empty line = end of HTTP headers
                    http_headers_done = true;
                    if (http_status != 0 and http_status != 200) {
                        std.debug.print("[stream] upstream HTTP {d}\n", .{http_status});
                        // Drain remaining body and log it for debugging
                        var body_buf: [8192]u8 = undefined;
                        var body_len: usize = 0;
                        while (body_len < body_buf.len) {
                            const nb = stdout.read(body_buf[body_len .. body_buf.len]) catch break;
                            if (nb == 0) break;
                            body_len += nb;
                        }
                        if (body_len > 0) {
                            std.debug.print("[stream] upstream error body ({d} bytes): {s}\n", .{ body_len, body_buf[0..@min(body_len, 2000)] });
                        } else {
                            std.debug.print("[stream] upstream error body: (empty)\n", .{});
                        }
                        line_len = 0;
                        break;
                    }
                } else if (std.mem.startsWith(u8, trimmed, "HTTP/")) {
                    // Parse status code from "HTTP/1.1 200 OK" or "HTTP/2 200"
                    var parts = std.mem.splitScalar(u8, trimmed, ' ');
                    _ = parts.next(); // skip HTTP/x.x
                    if (parts.next()) |code_str| {
                        http_status = std.fmt.parseInt(u16, code_str, 10) catch 0;
                    }
                }
                line_len = 0;
                continue;
            }

            if (line_len > 0) {
                const line = line_buf[0..line_len];
                if (line[0] == '{') {
                    // Check if this is an error response (non-200 status)
                    if (http_status != 0 and http_status != 200) {
                        std.debug.print("[stream] upstream error HTTP {d}: {s}\n", .{ http_status, line[0..@min(line.len, 500)] });
                        line_len = 0;
                        continue;
                    }
                    if (!headers_sent) {
                        headers_sent = true;
                        const sse_header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\n\r\n";
                        socket.send(client_stream, sse_header) catch {
                            _ = child.wait() catch {};
                            return false;
                        };
                        if (is_anthropic) {
                            var msg_start_buf: [512]u8 = undefined;
                            const msg_start = std.fmt.bufPrint(&msg_start_buf, "event: message_start\ndata: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_zed\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"{s}\",\"content\":[],\"stop_reason\":null,\"usage\":{{\"input_tokens\":0,\"output_tokens\":0}}}}}}\n\n", .{model}) catch "";
                            socket.send(client_stream, msg_start) catch {};
                        }
                    }
                    got_any_data = true;
                    convertAndSendSSE(client_stream, line, &block_index, &has_tool_use, is_anthropic, openai_id, model, allocator) catch break;
                } else {
                    std.debug.print("[stream] non-JSON from upstream ({d} bytes): {s}\n", .{ line.len, line[0..@min(line.len, 500)] });
                }
            }
            line_len = 0;
        } else {
            if (line_len < line_buf.len) {
                line_buf[line_len] = one[0];
                line_len += 1;
            }
        }
    }

    if (headers_sent) {
        if (is_anthropic) {
            const stop_reason = if (has_tool_use) "tool_use" else "end_turn";
            var stop_buf: [256]u8 = undefined;
            const stop_msg = std.fmt.bufPrint(&stop_buf, "event: message_delta\ndata: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n", .{stop_reason}) catch "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n";
            socket.send(client_stream, stop_msg) catch {};
            socket.send(client_stream, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n") catch {};
        } else {
            // OpenAI format: finish_reason reflects response type (tool_calls or stop)
            var finish_buf: [512]u8 = undefined;
            const finish_reason = if (has_tool_use) "tool_calls" else "stop";
            const finish_chunk = std.fmt.bufPrint(&finish_buf, "data: {{\"id\":\"{s}\",\"object\":\"chat.completion.chunk\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"{s}\"}}]}}\n\ndata: [DONE]\n\n", .{ openai_id, finish_reason }) catch "data: [DONE]\n\n";
            socket.send(client_stream, finish_chunk) catch {};
        }
    }

    const stderr_pipe = child.stderr;
    var stderr_buf: [2048]u8 = undefined;
    var stderr_len: usize = 0;
    if (stderr_pipe) |sp| {
        stderr_len = sp.read(&stderr_buf) catch 0;
    }
    const term = child.wait() catch {
        std.debug.print("[stream] done, {d} blocks, headers_sent={}, wait failed\n", .{ block_index, headers_sent });
        return got_any_data;
    };
    const exit_code: u32 = switch (term) {
        .Exited => |c| c,
        else => 999,
    };
    if (!got_any_data or exit_code != 0) {
        std.debug.print("[stream] done, {d} blocks, headers_sent={}, curl exit={d}, http={d}, stderr={s}\n", .{ block_index, headers_sent, exit_code, http_status, stderr_buf[0..stderr_len] });
        // If we got no data, print any remaining buffered content for debugging
        if (!got_any_data and line_len > 0) {
            std.debug.print("[stream] remaining buffer ({d} bytes): {s}\n", .{ line_len, line_buf[0..@min(line_len, 500)] });
        }
    } else {
        std.debug.print("[stream] done, {d} blocks\n", .{block_index});
    }
    return got_any_data;
}

/// Convert a single Zed streaming JSON line to SSE events.
/// Emits Anthropic SSE when is_anthropic=true, OpenAI SSE chunks when is_anthropic=false.
fn convertAndSendSSE(client_stream: std.net.Stream, line: []const u8, block_index: *usize, has_tool_use: *bool, is_anthropic: bool, openai_id: []const u8, model: []const u8, allocator: std.mem.Allocator) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return;
    defer parsed.deinit();

    const obj = if (parsed.value.object.get("event")) |event|
        (if (event == .object) event else parsed.value)
    else
        parsed.value;

    if (obj.object.get("type")) |et_val| {
        if (et_val == .string) {
            const event_type = et_val.string;

            if (std.mem.eql(u8, event_type, "message_start")) {
                if (obj.object.get("message")) |msg| {
                    if (msg == .object) {
                        if (msg.object.get("model")) |m| {
                            if (m == .string) std.debug.print("[stream] zed returned model: {s}\n", .{m.string});
                        }
                    }
                }
                return;
            }

            if (std.mem.eql(u8, event_type, "content_block_start")) {
                if (!is_anthropic) return; // OpenAI clients don't use content_block events
                const cb = obj.object.get("content_block") orelse return;
                if (cb != .object) return;
                const cb_type = switch (cb.object.get("type") orelse return) { .string => |s| s, else => return };
                var buf: std.io.Writer.Allocating = .init(allocator);
                defer buf.deinit();
                const w = &buf.writer;
                if (std.mem.eql(u8, cb_type, "tool_use")) {
                    has_tool_use.* = true;
                    // Pass through tool_use content_block_start with id and name
                    try w.print("event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\"", .{block_index.*});
                    if (cb.object.get("id")) |id| {
                        try w.writeAll(",\"id\":"); try std.json.Stringify.value(id, .{}, w);
                    }
                    if (cb.object.get("name")) |name| {
                        try w.writeAll(",\"name\":"); try std.json.Stringify.value(name, .{}, w);
                    }
                    try w.writeAll(",\"input\":{}}}\n\n");
                } else {
                    try w.print("event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"{s}\"", .{ block_index.*, cb_type });
                    if (std.mem.eql(u8, cb_type, "thinking")) try w.writeAll(",\"thinking\":\"\"") else try w.writeAll(",\"text\":\"\"");
                    try w.writeAll("}}\n\n");
                }
                try socket.send(client_stream, buf.written());
                return;
            }

            if (std.mem.eql(u8, event_type, "content_block_delta")) {
                const delta = obj.object.get("delta") orelse return;
                if (delta != .object) return;
                if (!is_anthropic) {
                    // For OpenAI clients: extract text from text_delta and emit as OpenAI chunk
                    const delta_type = switch (delta.object.get("type") orelse return) { .string => |s| s, else => return };
                    if (std.mem.eql(u8, delta_type, "text_delta")) {
                        if (delta.object.get("text")) |t| {
                            if (t == .string and t.string.len > 0) {
                                try emitOpenAIChunk(client_stream, t.string, openai_id, model, allocator);
                            }
                        }
                    }
                    // input_json_delta and thinking_delta are skipped for OpenAI clients
                    return;
                }
                var buf: std.io.Writer.Allocating = .init(allocator);
                defer buf.deinit();
                const w = &buf.writer;
                try w.print("event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":", .{block_index.*});
                try std.json.Stringify.value(delta, .{}, w);
                try w.writeAll("}\n\n");
                try socket.send(client_stream, buf.written());
                return;
            }

            if (std.mem.eql(u8, event_type, "content_block_stop")) {
                if (!is_anthropic) return; // OpenAI clients don't use content_block events
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "event: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{block_index.*}) catch return;
                try socket.send(client_stream, msg);
                block_index.* += 1;
                return;
            }

            if (std.mem.eql(u8, event_type, "ping")) {
                if (is_anthropic) {
                    try socket.send(client_stream, "event: ping\ndata: {\"type\":\"ping\"}\n\n");
                }
                return;
            }

            if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
                if (obj.object.get("delta")) |d| {
                    if (d == .string and d.string.len > 0) {
                        try emitTextDelta(client_stream, d.string, block_index, is_anthropic, openai_id, model, allocator);
                    }
                }
                return;
            }
        }
    }

    // xAI (Grok)
    if (obj.object.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const choice = choices.array.items[0];
            if (choice == .object) {
                if (choice.object.get("delta")) |delta| {
                    if (delta == .object) {
                        if (delta.object.get("content")) |c| {
                            if (c == .string and c.string.len > 0) {
                                try emitTextDelta(client_stream, c.string, block_index, is_anthropic, openai_id, model, allocator);
                            }
                        }
                    }
                }
            }
        }
        return;
    }

    // Google (Gemini) — raw Gemini API format returned by Zed
    if (obj.object.get("candidates")) |candidates| {
        if (candidates == .array and candidates.array.items.len > 0) {
            const cand = candidates.array.items[0];
            if (cand == .object) {
                if (cand.object.get("content")) |content| {
                    if (content == .object) {
                        if (content.object.get("parts")) |parts| {
                            if (parts == .array) {
                                var call_idx: usize = 0;
                                for (parts.array.items) |part| {
                                    if (part != .object) continue;
                                    // Text response
                                    if (part.object.get("text")) |t| {
                                        if (t == .string and t.string.len > 0) {
                                            try emitTextDelta(client_stream, t.string, block_index, is_anthropic, openai_id, model, allocator);
                                        }
                                    }
                                    // Tool call (functionCall) — convert to OpenAI/Anthropic format
                                    if (part.object.get("functionCall")) |fc| {
                                        if (fc == .object) {
                                            has_tool_use.* = true;
                                            try emitGeminiFunctionCall(client_stream, fc, is_anthropic, openai_id, model, block_index, call_idx, allocator);
                                            call_idx += 1;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return;
    }
}

/// Convert a Gemini functionCall to OpenAI tool_calls or Anthropic tool_use SSE format.
fn emitGeminiFunctionCall(
    client_stream: std.net.Stream,
    fc: std.json.Value,
    is_anthropic: bool,
    openai_id: []const u8,
    model: []const u8,
    block_index: *usize,
    call_idx: usize,
    allocator: std.mem.Allocator,
) !void {
    const name = if (fc.object.get("name")) |n| (if (n == .string) n.string else return) else return;
    const args = fc.object.get("args") orelse std.json.Value{ .null = {} };

    // Serialize args to JSON string
    var args_buf: std.io.Writer.Allocating = .init(allocator);
    defer args_buf.deinit();
    try std.json.Stringify.value(args, .{}, &args_buf.writer);
    const args_json = if (args_buf.written().len > 0 and !std.mem.eql(u8, args_buf.written(), "null"))
        args_buf.written()
    else
        "{}";

    if (!is_anthropic) {
        // ── OpenAI streaming tool_calls format ──
        // Chunk 1: establish tool call (role, id, name, empty arguments)
        var id_buf: [32]u8 = undefined;
        const call_id = std.fmt.bufPrint(&id_buf, "call_{x}{d}", .{ @as(u64, @bitCast(std.time.milliTimestamp())), call_idx }) catch "call_zed";

        var buf1: std.io.Writer.Allocating = .init(allocator);
        defer buf1.deinit();
        const w1 = &buf1.writer;
        try w1.print(
            "data: {{\"id\":\"{s}\",\"object\":\"chat.completion.chunk\",\"model\":\"{s}\"," ++
                "\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":null," ++
                "\"tool_calls\":[{{\"id\":\"{s}\",\"type\":\"function\",\"index\":{d}," ++
                "\"function\":{{\"name\":",
            .{ openai_id, model, call_id, call_idx },
        );
        try std.json.Stringify.encodeJsonString(name, .{}, w1);
        try w1.writeAll(",\"arguments\":\"\"}}]},\"finish_reason\":null}]}\n\n");
        try socket.send(client_stream, buf1.written());

        // Chunk 2: arguments
        var buf2: std.io.Writer.Allocating = .init(allocator);
        defer buf2.deinit();
        const w2 = &buf2.writer;
        try w2.print(
            "data: {{\"id\":\"{s}\",\"object\":\"chat.completion.chunk\",\"model\":\"{s}\"," ++
                "\"choices\":[{{\"index\":0,\"delta\":{{\"tool_calls\":[{{\"index\":{d}," ++
                "\"function\":{{\"arguments\":",
            .{ openai_id, model, call_idx },
        );
        try std.json.Stringify.encodeJsonString(args_json, .{}, w2);
        try w2.writeAll("}}]},\"finish_reason\":null}]}\n\n");
        try socket.send(client_stream, buf2.written());
    } else {
        // ── Anthropic tool_use SSE format ──
        // content_block_start → content_block_delta (input_json_delta) → content_block_stop
        const idx = block_index.*;
        var id_buf: [36]u8 = undefined;
        const tool_id = providers.fakeUuid(&id_buf);

        // content_block_start
        var buf1: std.io.Writer.Allocating = .init(allocator);
        defer buf1.deinit();
        const w1 = &buf1.writer;
        try w1.print(
            "event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d}," ++
                "\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":",
            .{ idx, tool_id },
        );
        try std.json.Stringify.encodeJsonString(name, .{}, w1);
        try w1.writeAll(",\"input\":{}}}\n\n");
        try socket.send(client_stream, buf1.written());

        // content_block_delta: full arguments as input_json_delta
        var buf2: std.io.Writer.Allocating = .init(allocator);
        defer buf2.deinit();
        const w2 = &buf2.writer;
        try w2.print(
            "event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":{d}," ++
                "\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":",
            .{idx},
        );
        try std.json.Stringify.encodeJsonString(args_json, .{}, w2);
        try w2.writeAll("}}\n\n");
        try socket.send(client_stream, buf2.written());

        // content_block_stop
        var stop_buf: [128]u8 = undefined;
        const stop_msg = std.fmt.bufPrint(&stop_buf, "event: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{idx}) catch return;
        try socket.send(client_stream, stop_msg);
        block_index.* += 1;
    }
}

/// Emit a text delta in the appropriate SSE format.
fn emitTextDelta(client_stream: std.net.Stream, text: []const u8, block_index: *usize, is_anthropic: bool, openai_id: []const u8, model: []const u8, allocator: std.mem.Allocator) !void {
    if (!is_anthropic) {
        try emitOpenAIChunk(client_stream, text, openai_id, model, allocator);
        return;
    }
    // Anthropic format
    if (block_index.* == 0) {
        try socket.send(client_stream, "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n");
        block_index.* = 1;
    }
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try w.writeAll("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":");
    try std.json.Stringify.encodeJsonString(text, .{}, w);
    try w.writeAll("}}\n\n");
    try socket.send(client_stream, buf.written());
}

/// Emit a single OpenAI-format SSE chunk with text content.
fn emitOpenAIChunk(client_stream: std.net.Stream, text: []const u8, openai_id: []const u8, model: []const u8, allocator: std.mem.Allocator) !void {
    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try w.print("data: {{\"id\":\"{s}\",\"object\":\"chat.completion.chunk\",\"model\":\"{s}\",\"choices\":[{{\"index\":0,\"delta\":{{\"content\":", .{ openai_id, model });
    try std.json.Stringify.encodeJsonString(text, .{}, w);
    try w.writeAll("},\"finish_reason\":null}]}}\n\n");
    try socket.send(client_stream, buf.written());
}
