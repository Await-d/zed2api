const std = @import("std");

pub const Account = struct {
    name: []const u8,
    user_id: []const u8,
    credential_json: []const u8,
    jwt_token: ?[]const u8 = null,
    jwt_exp: i64 = 0,
    plan: ?[]const u8 = null,
    expires_at: ?[]const u8 = null,
};

pub const AccountManager = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayListUnmanaged(Account) = .empty,
    current: usize = 0,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) AccountManager {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *AccountManager) void {
        self.list.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn getCurrent(self: *AccountManager) ?*Account {
        if (self.list.items.len == 0) return null;
        return &self.list.items[self.current];
    }

    pub fn switchTo(self: *AccountManager, name: []const u8) bool {
        for (self.list.items, 0..) |acc, i| {
            if (std.mem.eql(u8, acc.name, name)) {
                self.current = i;
                return true;
            }
        }
        return false;
    }

    pub fn loadFromFile(self: *AccountManager) !void {
        const alloc = self.arena.allocator();
        const file = std.fs.cwd().openFile("accounts.json", .{}) catch return;
        defer file.close();

        const content = try file.readToEndAlloc(alloc, 4 * 1024 * 1024);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
        const root = parsed.value;

        const accs_val = root.object.get("accounts") orelse return;
        var it = accs_val.object.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (val != .object) continue;

            const obj = val.object;
            const uid = blk: {
                const v = obj.get("user_id") orelse continue;
                break :blk switch (v) {
                    .string => |s| s,
                    .integer => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
                    else => continue,
                };
            };

            const cred_val = obj.get("credential") orelse continue;
            const cred_json = std.json.Stringify.valueAlloc(alloc, cred_val, .{}) catch continue;

            const plan = if (obj.get("plan")) |v| switch (v) { .string => |s| s, else => null } else null;
            const expires = if (obj.get("expires_at")) |v| switch (v) { .string => |s| s, else => null } else null;

            self.list.append(self.allocator, .{
                .name = name,
                .user_id = uid,
                .credential_json = cred_json,
                .plan = plan,
                .expires_at = expires,
            }) catch continue;
        }
    }
};

pub fn addAccount(allocator: std.mem.Allocator, name: []const u8, user_id: []const u8, access_token_json: []const u8) !void {
    var buf: [4 * 1024 * 1024]u8 = undefined;
    var existing_content: ?[]const u8 = null;

    if (std.fs.cwd().openFile("accounts.json", .{})) |file| {
        defer file.close();
        const n = try file.readAll(&buf);
        existing_content = buf[0..n];
    } else |_| {}

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    try w.writeAll("{\n  \"accounts\": {\n");

    var wrote_any = false;
    if (existing_content) |content| {
        if (content.len > 0) {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (p.value == .object) {
                    if (p.value.object.get("accounts")) |accs| {
                        if (accs == .object) {
                            var it = accs.object.iterator();
                            while (it.next()) |entry| {
                                const existing_name = entry.key_ptr.*;
                                if (std.mem.eql(u8, existing_name, name)) continue;
                                if (wrote_any) try w.writeAll(",\n");
                                try w.writeAll("    ");
                                const existing_name_json = try std.json.Stringify.valueAlloc(allocator, existing_name, .{});
                                defer allocator.free(existing_name_json);
                                try w.writeAll(existing_name_json);
                                try w.writeAll(": ");
                                const val_str = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
                                defer allocator.free(val_str);
                                try w.writeAll(val_str);
                                wrote_any = true;
                            }
                        }
                    }
                }
            }
        }
    }

    if (wrote_any) try w.writeAll(",\n");
    try w.writeAll("    ");
    const name_json = try std.json.Stringify.valueAlloc(allocator, name, .{});
    defer allocator.free(name_json);
    try w.writeAll(name_json);
    try w.writeAll(": {\"user_id\":");
    const user_id_json = try std.json.Stringify.valueAlloc(allocator, user_id, .{});
    defer allocator.free(user_id_json);
    try w.writeAll(user_id_json);
    try w.writeAll(",\"credential\":");

    const parsed_credential = std.json.parseFromSlice(std.json.Value, allocator, access_token_json, .{}) catch null;
    if (parsed_credential) |p| {
        defer p.deinit();
        try w.writeAll(access_token_json);
    } else {
        const credential_str_json = try std.json.Stringify.valueAlloc(allocator, access_token_json, .{});
        defer allocator.free(credential_str_json);
        try w.writeAll(credential_str_json);
    }

    try w.writeAll("}\n  }\n}");

    const file = try std.fs.cwd().createFile("accounts.json", .{});
    defer file.close();
    try file.writeAll(output.items);
}

/// Remove one or more accounts from accounts.json by name.
/// Returns the number of accounts actually removed.
pub fn removeAccounts(allocator: std.mem.Allocator, names: []const []const u8) !usize {
    var buf: [4 * 1024 * 1024]u8 = undefined;
    var existing_content: ?[]const u8 = null;

    if (std.fs.cwd().openFile("accounts.json", .{})) |file| {
        defer file.close();
        const n = try file.readAll(&buf);
        existing_content = buf[0..n];
    } else |_| {}

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    try w.writeAll("{\n  \"accounts\": {\n");

    var wrote_any = false;
    var removed: usize = 0;

    if (existing_content) |content| {
        if (content.len > 0) {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (p.value == .object) {
                    if (p.value.object.get("accounts")) |accs| {
                        if (accs == .object) {
                            var it = accs.object.iterator();
                            while (it.next()) |entry| {
                                const existing_name = entry.key_ptr.*;
                                // Check if this name is in the remove list
                                var should_remove = false;
                                for (names) |n_to_remove| {
                                    if (std.mem.eql(u8, existing_name, n_to_remove)) {
                                        should_remove = true;
                                        removed += 1;
                                        break;
                                    }
                                }
                                if (should_remove) continue;
                                if (wrote_any) try w.writeAll(",\n");
                                try w.writeAll("    ");
                                const existing_name_json = try std.json.Stringify.valueAlloc(allocator, existing_name, .{});
                                defer allocator.free(existing_name_json);
                                try w.writeAll(existing_name_json);
                                try w.writeAll(": ");
                                const val_str = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
                                defer allocator.free(val_str);
                                try w.writeAll(val_str);
                                wrote_any = true;
                            }
                        }
                    }
                }
            }
        }
    }

    if (wrote_any) try w.writeAll("\n");
    try w.writeAll("  }\n}");

    const file = try std.fs.cwd().createFile("accounts.json", .{});
    defer file.close();
    try file.writeAll(output.items);
    return removed;
}

/// Rename an account in accounts.json.
/// Returns error.NotFound if the account does not exist.
pub fn renameAccount(allocator: std.mem.Allocator, old_name: []const u8, new_name: []const u8) !void {
    var buf: [4 * 1024 * 1024]u8 = undefined;
    var existing_content: ?[]const u8 = null;

    if (std.fs.cwd().openFile("accounts.json", .{})) |file| {
        defer file.close();
        const n = try file.readAll(&buf);
        existing_content = buf[0..n];
    } else |_| {}

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    try w.writeAll("{\n  \"accounts\": {\n");

    var wrote_any = false;
    var found = false;

    if (existing_content) |content| {
        if (content.len > 0) {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (p.value == .object) {
                    if (p.value.object.get("accounts")) |accs| {
                        if (accs == .object) {
                            var it = accs.object.iterator();
                            while (it.next()) |entry| {
                                const existing_name = entry.key_ptr.*;
                                const is_target = std.mem.eql(u8, existing_name, old_name);
                                if (is_target) found = true;
                                const emit_name = if (is_target) new_name else existing_name;
                                if (wrote_any) try w.writeAll(",\n");
                                try w.writeAll("    ");
                                const emit_name_json = try std.json.Stringify.valueAlloc(allocator, emit_name, .{});
                                defer allocator.free(emit_name_json);
                                try w.writeAll(emit_name_json);
                                try w.writeAll(": ");
                                const val_str = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
                                defer allocator.free(val_str);
                                try w.writeAll(val_str);
                                wrote_any = true;
                            }
                        }
                    }
                }
            }
        }
    }

    if (!found) return error.NotFound;

    if (wrote_any) try w.writeAll("\n");
    try w.writeAll("  }\n}");

    const file = try std.fs.cwd().createFile("accounts.json", .{});
    defer file.close();
    try file.writeAll(output.items);
}

/// Update plan and expires_at for a named account in accounts.json.
/// Other accounts and all existing fields are preserved verbatim.
pub fn saveBillingInfo(allocator: std.mem.Allocator, name: []const u8, plan: []const u8, expires_at: []const u8) !void {
    var buf: [4 * 1024 * 1024]u8 = undefined;
    var existing_content: ?[]const u8 = null;

    if (std.fs.cwd().openFile("accounts.json", .{})) |file| {
        defer file.close();
        const n = try file.readAll(&buf);
        existing_content = buf[0..n];
    } else |_| {}

    const content = existing_content orelse return error.FileNotFound;
    if (content.len == 0) return error.EmptyFile;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidFormat;
    const accs = parsed.value.object.get("accounts") orelse return error.InvalidFormat;
    if (accs != .object) return error.InvalidFormat;

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    try w.writeAll("{\n  \"accounts\": {\n");

    var wrote_any = false;
    var it = accs.object.iterator();
    while (it.next()) |entry| {
        const ename = entry.key_ptr.*;
        if (wrote_any) try w.writeAll(",\n");
        try w.writeAll("    ");
        const key_json = try std.json.Stringify.valueAlloc(allocator, ename, .{});
        defer allocator.free(key_json);
        try w.writeAll(key_json);
        try w.writeAll(": ");

        if (std.mem.eql(u8, ename, name) and entry.value_ptr.* == .object) {
            // Rebuild entry: copy all fields except plan/expires_at, then add fresh ones.
            const obj = entry.value_ptr.*.object;
            try w.writeAll("{");
            var field_first = true;
            var fit = obj.iterator();
            while (fit.next()) |field| {
                if (std.mem.eql(u8, field.key_ptr.*, "plan")) continue;
                if (std.mem.eql(u8, field.key_ptr.*, "expires_at")) continue;
                if (!field_first) try w.writeAll(", ");
                field_first = false;
                const fk = try std.json.Stringify.valueAlloc(allocator, field.key_ptr.*, .{});
                defer allocator.free(fk);
                const fv = try std.json.Stringify.valueAlloc(allocator, field.value_ptr.*, .{});
                defer allocator.free(fv);
                try w.writeAll(fk);
                try w.writeAll(": ");
                try w.writeAll(fv);
            }
            if (!field_first) try w.writeAll(", ");
            const plan_json = try std.json.Stringify.valueAlloc(allocator, plan, .{});
            defer allocator.free(plan_json);
            const expires_json = try std.json.Stringify.valueAlloc(allocator, expires_at, .{});
            defer allocator.free(expires_json);
            try w.writeAll("\"plan\": ");
            try w.writeAll(plan_json);
            try w.writeAll(", \"expires_at\": ");
            try w.writeAll(expires_json);
            try w.writeAll("}");
        } else {
            const val_str = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
            defer allocator.free(val_str);
            try w.writeAll(val_str);
        }
        wrote_any = true;
    }

    if (wrote_any) try w.writeAll("\n");
    try w.writeAll("  }\n}");

    const file = try std.fs.cwd().createFile("accounts.json", .{});
    defer file.close();
    try file.writeAll(output.items);
}
