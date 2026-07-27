const std = @import("std");
const evmz = @import("evmz");
const fixture = @import("fixture.zig");

const block_stf = evmz.eth.BlockSTF;
const wire = evmz.stateless.wire;
const wire_v1 = wire.v1;

pub const Mutation = enum {
    missing_state_node,
    altered_state_node,
    missing_code,
    altered_code,
    missing_header,
    altered_header,
    altered_header_history,
    altered_pre_state_root,
    altered_public_key,
    altered_transaction_body,
    state_root_claim,
    receipts_root_claim,
    logs_bloom_claim,
    block_gas_claim,
    block_hash_claim,
    block_access_list_claim,
    withdrawal_body,
    deposit_request,
    withdrawal_request,
    consolidation_request,
    builder_deposit_request,
    builder_exit_request,
};

/// Bounds how many node/code/header/transaction positions one input explores.
const max_variants = 128;

const Case = struct {
    mutation: Mutation,
    expected: block_stf.Status,
};

const cases = [_]Case{
    .{ .mutation = .missing_state_node, .expected = .invalid_witness },
    .{ .mutation = .altered_state_node, .expected = .invalid_witness },
    .{ .mutation = .missing_code, .expected = .invalid_witness },
    .{ .mutation = .altered_code, .expected = .invalid_witness },
    .{ .mutation = .missing_header, .expected = .invalid_witness },
    .{ .mutation = .altered_header, .expected = .invalid_witness },
    .{ .mutation = .altered_header_history, .expected = .invalid_witness },
    .{ .mutation = .altered_pre_state_root, .expected = .invalid_witness },
    .{ .mutation = .altered_public_key, .expected = .invalid_witness },
    // Public-key authentication binds the body before any root claim is compared.
    .{ .mutation = .altered_transaction_body, .expected = .invalid_witness },
    .{ .mutation = .state_root_claim, .expected = .state_root_mismatch },
    .{ .mutation = .receipts_root_claim, .expected = .receipts_root_mismatch },
    .{ .mutation = .logs_bloom_claim, .expected = .logs_bloom_mismatch },
    .{ .mutation = .block_gas_claim, .expected = .block_gas_used_mismatch },
    .{ .mutation = .block_hash_claim, .expected = .block_hash_mismatch },
    .{ .mutation = .block_access_list_claim, .expected = .block_access_list_mismatch },
    .{ .mutation = .withdrawal_body, .expected = .block_hash_mismatch },
    .{ .mutation = .deposit_request, .expected = .requests_hash_mismatch },
    .{ .mutation = .withdrawal_request, .expected = .requests_hash_mismatch },
    .{ .mutation = .consolidation_request, .expected = .requests_hash_mismatch },
    .{ .mutation = .builder_deposit_request, .expected = .requests_hash_mismatch },
    .{ .mutation = .builder_exit_request, .expected = .requests_hash_mismatch },
};

pub const Summary = struct {
    canonical_inputs: usize = 0,
    resolved: [cases.len]bool = [_]bool{false} ** cases.len,
    /// First status a still-unresolved mutation did reach, so a failing gate
    /// names the wrong verdict instead of only the missing one.
    observed: [cases.len]?block_stf.Status = [_]?block_stf.Status{null} ** cases.len,

    pub fn resolvedCount(self: Summary) usize {
        var count: usize = 0;
        for (self.resolved) |resolved| count += @intFromBool(resolved);
        return count;
    }

    pub fn complete(self: Summary) bool {
        return self.resolvedCount() == cases.len;
    }

    pub fn printMissing(self: Summary) void {
        for (cases, self.resolved, self.observed) |case, resolved, observed| {
            if (resolved) continue;
            std.debug.print("missing mutation={s} expected={s} observed={s}\n", .{
                @tagName(case.mutation),
                @tagName(case.expected),
                if (observed) |status| @tagName(status) else "none",
            });
        }
    }
};

pub fn runManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    fixture_root: []const u8,
    manifest_path: []const u8,
) !Summary {
    const manifest = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(64 * 1024));
    defer allocator.free(manifest);

    var summary = Summary{};
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const path = try std.fs.path.join(allocator, &.{ fixture_root, line });
        defer allocator.free(path);
        try runFile(io, allocator, path, &summary);
        if (summary.complete()) break;
    }
    return summary;
}

fn runFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    summary: *Summary,
) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(fixture.JsonValue, allocator, bytes, .{ .parse_numbers = false });
    defer parsed.deinit();

    var root = fixture.asObject(parsed.value) orelse return error.ExpectedObject;
    var tests = root.iterator();
    while (tests.next()) |entry| {
        const test_object = fixture.asObject(entry.value_ptr.*) orelse return error.ExpectedObject;
        const blocks = fixture.asArray(test_object.get("blocks") orelse return error.MissingBlocks) orelse
            return error.ExpectedArray;
        for (blocks.items, 0..) |block_value, block_index| {
            const block = fixture.asObject(block_value) orelse return error.ExpectedObject;
            if (block.get("expectException") != null) continue;
            const encoded_value = block.get("statelessInputBytes") orelse continue;
            const input_bytes = try fixture.parseBytesFromValue(allocator, encoded_value);
            defer allocator.free(input_bytes);

            const canonical = try wire.validateStatelessResultBytes(allocator, input_bytes);
            if (canonical.status != .valid) continue;
            summary.canonical_inputs += 1;

            for (cases, 0..) |case, case_index| {
                if (summary.resolved[case_index]) continue;
                const outcome = try runCase(allocator, input_bytes, case);
                if (!outcome.matched) {
                    if (summary.observed[case_index] == null)
                        summary.observed[case_index] = outcome.observed;
                    continue;
                }
                summary.resolved[case_index] = true;
                std.debug.print(
                    "mutation={s} status={s} source={s} test={s} block={}\n",
                    .{ @tagName(case.mutation), @tagName(case.expected), path, entry.key_ptr.*, block_index },
                );
            }
            if (summary.complete()) return;
        }
    }
}

const Outcome = struct {
    matched: bool = false,
    observed: ?block_stf.Status = null,
};

/// Stops at the first variant reaching `case.expected`: this witnesses that the
/// rejection path is live, not that every variant of the mutation is caught.
fn runCase(allocator: std.mem.Allocator, input_bytes: []const u8, case: Case) !Outcome {
    var shape_arena = std.heap.ArenaAllocator.init(allocator);
    defer shape_arena.deinit();
    const shape = try wire.StatelessInput.decodeSchemaPrefixed(shape_arena.allocator(), input_bytes);
    const variant_count = mutationVariantCount(shape, case.mutation);

    var outcome = Outcome{};
    for (0..variant_count) |variant| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var input = try wire.StatelessInput.decodeSchemaPrefixed(scratch, input_bytes);
        if (!try mutate(scratch, &input, case.mutation, variant)) continue;
        const encoded = try input.encodeSchemaPrefixed(scratch);
        _ = try wire.StatelessInput.decodeSchemaPrefixed(scratch, encoded);
        const result = try wire.validateStatelessResultBytes(scratch, encoded);
        if (result.status == case.expected) return .{ .matched = true, .observed = result.status };
        if (outcome.observed == null) outcome.observed = result.status;
    }
    return outcome;
}

fn mutationVariantCount(input: wire.StatelessInput, mutation: Mutation) usize {
    return switch (mutation) {
        .missing_state_node, .altered_state_node => @min(input.witness.state.len, max_variants),
        .missing_code, .altered_code => @min(input.witness.codes.len, max_variants),
        .missing_header, .altered_header => @min(input.witness.headers.len, max_variants),
        .altered_header_history => @min(input.witness.headers.len -| 1, max_variants),
        .altered_transaction_body => if (amsterdamRequest(&input)) |request|
            @min(request.execution_payload.v3.v2.v1.transactions.len, max_variants)
        else
            0,
        else => 1,
    };
}

fn mutate(
    allocator: std.mem.Allocator,
    input: *wire.StatelessInput,
    mutation: Mutation,
    variant: usize,
) !bool {
    switch (mutation) {
        .missing_state_node => {
            if (variant >= input.witness.state.len) return false;
            input.witness.state = try omit([]const u8, allocator, input.witness.state, variant);
        },
        .altered_state_node => {
            if (!try alterBlob(allocator, &input.witness.state, variant)) return false;
        },
        .missing_code => {
            if (variant >= input.witness.codes.len) return false;
            input.witness.codes = try omit([]const u8, allocator, input.witness.codes, variant);
        },
        .altered_code => {
            if (!try alterBlob(allocator, &input.witness.codes, variant)) return false;
        },
        .missing_header => {
            if (variant >= input.witness.headers.len) return false;
            input.witness.headers = try omit([]const u8, allocator, input.witness.headers, variant);
        },
        .altered_header => {
            if (!try alterHeaderStateRoot(allocator, input, variant, false)) return false;
        },
        .altered_header_history => {
            if (input.witness.headers.len <= 1 or variant >= input.witness.headers.len - 1) return false;
            if (!try alterHeaderStateRoot(allocator, input, variant, false)) return false;
        },
        .altered_pre_state_root => {
            if (input.witness.headers.len == 0) return false;
            if (!try alterHeaderStateRoot(allocator, input, input.witness.headers.len - 1, true)) return false;
        },
        .altered_public_key => {
            if (input.public_keys.len == 0) return false;
            const keys = try allocator.dupe([65]u8, input.public_keys);
            keys[0][0] ^= 1;
            input.public_keys = keys;
        },
        else => {
            var request = amsterdamRequest(input) orelse return false;
            if (!try mutatePayload(allocator, &request, mutation, variant)) return false;
            input.new_payload_request = .{ .amsterdam = request };
        },
    }
    return true;
}

/// Payload-scoped mutations. The caller unwraps the Amsterdam request and
/// writes it back, so each arm only names the field it corrupts.
fn mutatePayload(
    allocator: std.mem.Allocator,
    request: *wire_v1.NewPayloadRequestAmsterdam,
    mutation: Mutation,
    variant: usize,
) !bool {
    const payload = &request.execution_payload.v3.v2.v1;
    switch (mutation) {
        .state_root_claim => payload.state_root[0] ^= 1,
        .receipts_root_claim => payload.receipts_root[0] ^= 1,
        .logs_bloom_claim => payload.logs_bloom[0] ^= 1,
        .block_gas_claim => payload.gas_used ^= 1,
        .block_hash_claim => payload.block_hash[0] ^= 1,
        .withdrawal_body => return flipFirst("index", allocator, &request.execution_payload.v3.v2.withdrawals),
        .deposit_request => return flipFirst("amount", allocator, &request.execution_requests.deposits),
        .withdrawal_request => return flipFirst("amount", allocator, &request.execution_requests.withdrawals),
        .consolidation_request => return flipFirst("target_pubkey", allocator, &request.execution_requests.consolidations),
        .builder_deposit_request => return flipFirst("amount", allocator, &request.execution_requests.builder_deposits),
        .builder_exit_request => return flipFirst("pubkey", allocator, &request.execution_requests.builder_exits),
        .altered_transaction_body => {
            const transactions = payload.transactions;
            if (variant >= transactions.len or transactions[variant].len == 0) return false;
            const outer = try allocator.dupe([]const u8, transactions);
            const altered = try allocator.dupe(u8, outer[variant]);
            altered[altered.len - 1] ^= 1;
            outer[variant] = altered;
            payload.transactions = outer;
        },
        .block_access_list_claim => {
            const decoded = evmz.eth.bal.decode(allocator, request.execution_payload.block_access_list) catch return false;
            if (!try alterBlockAccessList(allocator, decoded.accounts)) return false;
            request.execution_payload.block_access_list = try evmz.eth.bal.encodeAlloc(allocator, decoded.accounts);
        },
        else => unreachable,
    }
    return true;
}

/// Duplicates `list` and flips one bit of `field` in its first element, so a
/// scalar and a fixed-array field corrupt the same way.
fn flipFirst(comptime field: []const u8, allocator: std.mem.Allocator, list: anytype) !bool {
    const Element = @typeInfo(@TypeOf(list.*)).pointer.child;
    if (list.len == 0) return false;
    const altered = try allocator.dupe(Element, list.*);
    const target = &@field(altered[0], field);
    switch (@typeInfo(@TypeOf(target.*))) {
        .array => target.*[0] ^= 1,
        else => target.* ^= 1,
    }
    list.* = altered;
    return true;
}

fn amsterdamRequest(input: *const wire.StatelessInput) ?wire_v1.NewPayloadRequestAmsterdam {
    return switch (input.new_payload_request) {
        .amsterdam => |request| request,
        else => null,
    };
}

fn omit(
    comptime T: type,
    allocator: std.mem.Allocator,
    items: []const T,
    index: usize,
) ![]const T {
    const out = try allocator.alloc(T, items.len - 1);
    @memcpy(out[0..index], items[0..index]);
    @memcpy(out[index..], items[index + 1 ..]);
    return out;
}

fn alterBlob(
    allocator: std.mem.Allocator,
    blobs: *[]const []const u8,
    index: usize,
) !bool {
    if (index >= blobs.len or blobs.*[index].len == 0) return false;
    const outer = try allocator.dupe([]const u8, blobs.*);
    const bytes = try allocator.dupe(u8, outer[index]);
    bytes[bytes.len - 1] ^= 1;
    outer[index] = bytes;
    blobs.* = outer;
    return true;
}

fn alterHeaderStateRoot(
    allocator: std.mem.Allocator,
    input: *wire.StatelessInput,
    index: usize,
    authenticate_mutation: bool,
) !bool {
    if (index >= input.witness.headers.len) return false;
    const outer = try allocator.dupe([]const u8, input.witness.headers);
    const header = try allocator.dupe(u8, outer[index]);
    var cursor = evmz.rlp.Cursor.init(header);
    var fields = cursor.nextList() catch return false;
    cursor.expectDone() catch return false;
    _ = fields.nextBytesExact(32) catch return false;
    _ = fields.nextBytesExact(32) catch return false;
    _ = fields.nextBytesExact(20) catch return false;
    const state_root = fields.nextBytesExact(32) catch return false;
    @constCast(state_root)[0] ^= 1;
    outer[index] = header;
    input.witness.headers = outer;

    if (authenticate_mutation) {
        var request = amsterdamRequest(input) orelse return false;
        request.execution_payload.v3.v2.v1.parent_hash = evmz.crypto.keccak256(header);
        input.new_payload_request = .{ .amsterdam = request };
    }
    return true;
}

fn alterBlockAccessList(
    allocator: std.mem.Allocator,
    accounts: []evmz.eth.bal.AccountChanges,
) !bool {
    for (accounts) |*account| {
        for (account.storage_changes) |slot| {
            if (slot.changes.len == 0) continue;
            @constCast(slot.changes)[0].new_value ^= 1;
            return true;
        }
        if (account.balance_changes.len > 0) {
            @constCast(account.balance_changes)[0].post_balance ^= 1;
            return true;
        }
        if (account.nonce_changes.len > 0) {
            @constCast(account.nonce_changes)[0].new_nonce ^= 1;
            return true;
        }
        if (account.code_changes.len > 0) {
            const changes = @constCast(account.code_changes);
            const replacement = try allocator.dupe(u8, changes[0].new_code);
            if (replacement.len == 0) return false;
            replacement[0] ^= 1;
            changes[0].new_code = replacement;
            return true;
        }
    }
    if (accounts.len != 1) return false;
    accounts[0].address[0] ^= 1;
    return true;
}

test "structured claim mutation re-encodes valid SSZ and reaches typed status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const input = try wire.smokeInputBytes(scratch);
    try std.testing.expect((try runCase(scratch, input, .{
        .mutation = .state_root_claim,
        .expected = .state_root_mismatch,
    })).matched);
}
