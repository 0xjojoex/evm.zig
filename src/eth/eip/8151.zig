//! EIP-8151 account-code-restricted ecRecover.
//!
//! A successful recovery pays an account access and a code read for the
//! recovered address, priced as bogota-devnet-2's EELS prices them: EIP-8038's
//! cold account access or a warm access, plus a warm access for the code read.

const precompile = @import("../../precompile.zig");
const eip2929 = @import("2929.zig");
const eip8038 = @import("8038.zig");

pub const account_check: precompile.EcrecoverAccountCheck = .{
    .cold_access_gas = eip8038.cold_account_access_cost,
    .warm_access_gas = eip2929.warm_storage_read_cost,
    .code_read_gas = eip2929.warm_storage_read_cost,
};
