//! Ethereum catalog view of the engine-owned EIP-7702 mechanism.

const delegation = @import("../../code/eip7702.zig");
const authorization = @import("../../transaction/authorization.zig");

pub const magic = authorization.signing_magic;
pub const per_auth_base_cost = authorization.base_cost;
pub const per_empty_account_cost = authorization.empty_account_cost;
pub const existing_account_refund_gas = authorization.existing_account_refund_gas;
pub const delegation_designator = delegation.delegation_designator;
pub const delegation_address_len = delegation.delegation_address_len;
pub const delegation_code_len = delegation.delegation_code_len;
pub const delegation_indicator_state_bytes = delegation.delegation_indicator_state_bytes;
