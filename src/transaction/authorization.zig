const std = @import("std");

/// State observed while applying one successful authorization tuple.
pub const signing_magic: u8 = 0x05;
pub const base_cost: u64 = 12_500;
pub const empty_account_cost: u64 = 25_000;
pub const existing_account_refund_gas: u64 = empty_account_cost - base_cost;

pub const SuccessInput = struct {
    account_exists: bool,
    account_already_written: bool,
    clears_delegation: bool,
    delegated_before_transaction: bool,
    delegation_set_before: bool,
};

pub const GasAdjustment = struct {
    account_state_charge: u64 = 0,
    account_write_charge: u64 = 0,
    delegation_state_charge: u64 = 0,
    regular_refund: u64 = 0,

    pub fn add(self: *GasAdjustment, other: GasAdjustment) void {
        self.account_state_charge = std.math.add(u64, self.account_state_charge, other.account_state_charge) catch std.math.maxInt(u64);
        self.account_write_charge = std.math.add(u64, self.account_write_charge, other.account_write_charge) catch std.math.maxInt(u64);
        self.delegation_state_charge = std.math.add(u64, self.delegation_state_charge, other.delegation_state_charge) catch std.math.maxInt(u64);
        self.regular_refund = std.math.add(u64, self.regular_refund, other.regular_refund) catch std.math.maxInt(u64);
    }
};
