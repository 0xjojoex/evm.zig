const std = @import("std");
const bal = @import("../../evm.zig").eth.bal;

pub fn apply(
    io: std.Io,
    allocator: std.mem.Allocator,
    input: bal.BlockInput,
    strategy: bal.ParallelStrategy,
    resources: bal.ParallelResources,
) !bal.Result {
    var executor = bal.Executor.init(io, allocator, input, strategy, resources);
    defer executor.deinit();
    return executor.run();
}

pub fn applyAssumeDecoded(
    io: std.Io,
    allocator: std.mem.Allocator,
    input: bal.AssumeDecodedBlockInput,
    strategy: bal.ParallelStrategy,
    resources: bal.ParallelResources,
) !bal.Result {
    var executor = bal.Executor.initAssumeDecoded(io, allocator, input, strategy, resources);
    defer executor.deinit();
    return executor.run();
}
