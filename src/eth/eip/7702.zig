//! EIP-7702 parameters for set-code transactions and delegation indicators.

/// MAGIC byte used in the authorization signing message.
pub const magic: u8 = 0x05;

/// PER_AUTH_BASE_COST: cost to process one authorization tuple.
pub const per_auth_base_cost: u64 = 12_500;

/// PER_EMPTY_ACCOUNT_COST: worst-case authorization cost charged up front.
pub const per_empty_account_cost: u64 = 25_000;

/// Refund issued when an authorization touches an already-existing authority.
pub const existing_account_refund_gas: u64 = per_empty_account_cost - per_auth_base_cost;

/// EIP-7702 delegation indicator prefix: 0xef0100.
pub const delegation_designator = [_]u8{ 0xef, 0x01, 0x00 };

pub const delegation_address_len: usize = 20;
pub const delegation_code_len: usize = delegation_designator.len + delegation_address_len;

/// State bytes written by one delegation indicator, before EIP-8037 applies CPSB.
pub const delegation_indicator_state_bytes: u64 = @intCast(delegation_code_len);
