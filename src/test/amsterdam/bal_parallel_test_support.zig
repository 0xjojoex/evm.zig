const std = @import("std");
const eth = @import("../../evm.zig").eth;
const bal = eth.bal;
const block_stf = eth.block_stf;

pub fn apply(
    io: std.Io,
    allocator: std.mem.Allocator,
    input: block_stf.BlockInput,
    strategy: bal.ParallelStrategy,
    resources: bal.ParallelResources,
) !block_stf.Result {
    var executor = bal.Executor(.amsterdam).init(io, allocator, input, strategy, resources);
    defer executor.deinit();
    return executor.run();
}

pub fn applyAssumeDecoded(
    io: std.Io,
    allocator: std.mem.Allocator,
    input: block_stf.AssumeDecodedBlockInput,
    strategy: bal.ParallelStrategy,
    resources: bal.ParallelResources,
) !block_stf.Result {
    var executor = bal.Executor(.amsterdam).initAssumeDecoded(io, allocator, input, strategy, resources);
    defer executor.deinit();
    return executor.run();
}
