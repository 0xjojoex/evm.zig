const std = @import("std");
const evmz = @import("evmz");

const evmc = @cImport({
    @cInclude("evmc/evmc.h");
});

fn getCapabilities(vm: [*c]evmc.struct_evmc_vm) callconv(.C) evmc.evmc_capabilities {
    _ = vm;
    return evmc.EVMC_CAPABILITY_EVM1;
}

pub fn main() !void {
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    // const Evm = evmz.Evm;

    // const evm = Evm.init();

    std.debug.print("EVMC ABI version: {d}\n", .{evmc.EVMC_ABI_VERSION});

    const vm = evmc.evmc_vm{
        .name = "evmz",
        .abi_version = evmc.EVMC_ABI_VERSION,
        .version = "0.1.0",
        .get_capabilities = getCapabilities,
    };

    std.debug.print("{any}\n", .{vm});
}
