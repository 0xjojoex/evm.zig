const std = @import("std");
const evmz = @import("../evm.zig");

const Address = evmz.Address;
const Host = evmz.Host;

pub fn emit(executor: anytype, from: Address, to: Address, amount: u256) !void {
    const Protocol = @TypeOf(executor.*).Protocol;
    const transfer_log = Protocol.block.valueTransferLog(executor.revision(), from, to, amount) orelse return;

    const topics = [_]u256{
        transfer_log.topic,
        evmz.address.toU256(from),
        evmz.address.toU256(to),
    };
    var data: [32]u8 = undefined;
    std.mem.writeInt(u256, &data, amount, .big);

    try executor.state.emitLog(Host.Log{
        .address = transfer_log.address,
        .topics = &topics,
        .data = &data,
    });
}

test "value transfer log metadata comes from comptime protocol" {
    const CustomProtocol = struct {
        pub const Revision = evmz.eth.Revision;

        pub const block = struct {
            pub fn valueTransferLog(
                revision: Revision,
                from: Address,
                to: Address,
                amount: u256,
            ) ?evmz.protocol.interface.ValueTransferLog {
                _ = revision;
                _ = from;
                _ = to;
                _ = amount;
                return .{
                    .address = evmz.addr(0x77),
                    .topic = 0x1234,
                };
            }
        };
    };
    const FakeState = struct {
        allocator: std.mem.Allocator,
        logs: std.ArrayList(Host.Log) = .empty,

        fn deinit(self: *@This()) void {
            for (self.logs.items) |event_log| {
                self.allocator.free(event_log.topics);
                self.allocator.free(event_log.data);
            }
            self.logs.deinit(self.allocator);
        }

        fn emitLog(self: *@This(), event_log: Host.Log) !void {
            const topics = try self.allocator.dupe(u256, event_log.topics);
            errdefer self.allocator.free(topics);
            const data = try self.allocator.dupe(u8, event_log.data);
            errdefer self.allocator.free(data);
            try self.logs.append(self.allocator, .{
                .address = event_log.address,
                .topics = topics,
                .data = data,
            });
        }
    };
    const FakeExecutor = struct {
        pub const Protocol = CustomProtocol;

        state: FakeState,

        fn revision(self: *const @This()) CustomProtocol.Revision {
            _ = self;
            return .frontier;
        }
    };

    var executor = FakeExecutor{ .state = .{ .allocator = std.testing.allocator } };
    defer executor.state.deinit();

    try emit(&executor, evmz.addr(1), evmz.addr(2), 3);

    try std.testing.expectEqual(@as(usize, 1), executor.state.logs.items.len);
    const event_log = executor.state.logs.items[0];
    try std.testing.expectEqualSlices(u8, &evmz.addr(0x77), &event_log.address);
    try std.testing.expectEqual(@as(usize, 3), event_log.topics.len);
    try std.testing.expectEqual(@as(u256, 0x1234), event_log.topics[0]);
    try std.testing.expectEqual(evmz.address.toU256(evmz.addr(1)), event_log.topics[1]);
    try std.testing.expectEqual(evmz.address.toU256(evmz.addr(2)), event_log.topics[2]);
    var expected_data: [32]u8 = undefined;
    std.mem.writeInt(u256, &expected_data, 3, .big);
    try std.testing.expectEqualSlices(u8, &expected_data, event_log.data);
}
