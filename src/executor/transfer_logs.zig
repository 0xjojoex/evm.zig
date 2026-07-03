const std = @import("std");
const evmz = @import("../evm.zig");
const Executor = @import("../executor.zig");

const Address = evmz.Address;
const Host = evmz.Host;

pub const transfer_topic = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

pub fn emit(executor: *Executor, from: Address, to: Address, amount: u256) !void {
    if (!executor.spec.isImpl(.amsterdam)) return;
    if (amount == 0) return;
    if (std.mem.eql(u8, &from, &to)) return;

    const topics = [_]u256{
        transfer_topic,
        evmz.address.toU256(from),
        evmz.address.toU256(to),
    };
    var data: [32]u8 = undefined;
    std.mem.writeInt(u256, &data, amount, .big);

    try executor.state.emitLog(Host.Log{
        .address = Executor.system_contracts.system_address,
        .topics = &topics,
        .data = &data,
    });
}
