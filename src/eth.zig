//! Exact Ethereum specifications and supporting domain modules.
//!
//! Each named fork is one complete `Spec`; callers bind it with `Vm(spec)`.
//! Runtime fork selection stays outside the generated VM.
//!
//! Layer note: most declarations here are exact spec data and pure semantics.
//! `eth.block_stf` is the concrete Ethereum block-transition layer above
//! the bound `Vm.BlockExecution`; raw message execution still lives under
//! `executor/` and opcode behavior under `instruction/`.

pub const revision = @import("eth/revision.zig");
pub const spec = @import("eth/spec.zig");
pub const bal = @import("eth/bal.zig");
pub const bal_diff = @import("eth/bal/diff.zig");
pub const bal_view = @import("eth/bal/ClaimView.zig");
pub const bal_recorder = @import("eth/bal/recorder.zig");
pub const instruction = @import("eth/instruction.zig");
pub const transaction = @import("eth/transaction.zig");
pub const transaction_prepare = @import("transaction/prepare.zig");
pub const transaction_validation = @import("transaction/validation.zig");
pub const precompile = @import("eth/precompile.zig");
pub const system = @import("eth/system.zig");
pub const header = @import("eth/header.zig");
pub const trie = @import("eth/trie.zig");
pub const block_stf = @import("eth/block_stf.zig");
pub const eip6110 = @import("eth/eip/6110.zig");
pub const eip7002 = @import("eth/eip/7002.zig");
pub const eip7702 = @import("eth/eip/7702.zig");
pub const eip7251 = @import("eth/eip/7251.zig");
pub const eip7685 = @import("eth/eip/7685.zig");
pub const eip8282 = @import("eth/eip/8282.zig");
pub const eip8037 = @import("eth/eip/8037.zig");

pub const Revision = revision.Revision;
pub const Spec = spec.Spec;
pub const frontier = spec.frontier;
pub const frontier_thawing = spec.frontier_thawing;
pub const homestead = spec.homestead;
pub const dao_fork = spec.dao_fork;
pub const tangerine_whistle = spec.tangerine_whistle;
pub const spurious_dragon = spec.spurious_dragon;
pub const byzantium = spec.byzantium;
pub const constantinople = spec.constantinople;
pub const petersburg = spec.petersburg;
pub const istanbul = spec.istanbul;
pub const muir_glacier = spec.muir_glacier;
pub const berlin = spec.berlin;
pub const london = spec.london;
pub const arrow_glacier = spec.arrow_glacier;
pub const gray_glacier = spec.gray_glacier;
pub const merge = spec.merge_fork;
pub const shanghai = spec.shanghai;
pub const cancun = spec.cancun;
pub const prague = spec.prague;
pub const osaka = spec.osaka;
pub const amsterdam = spec.amsterdam;
pub const latest = spec.latest;
pub const specAt = spec.specAt;

pub const ExecutionHeader = header.ExecutionHeader;
pub const Withdrawal = @import("eth/Withdrawal.zig");
pub const BlockSTF = block_stf;

pub const system_address = system.system_address;
pub const beacon_roots_address = system.beacon_roots_address;
pub const history_storage_address = system.history_storage_address;
pub const deposit_contract_address = system.deposit_contract_address;
pub const withdrawal_request_predeploy_address = system.withdrawal_request_predeploy_address;
pub const consolidation_request_predeploy_address = system.consolidation_request_predeploy_address;
pub const builder_deposit_request_predeploy_address = system.builder_deposit_request_predeploy_address;
pub const builder_exit_request_predeploy_address = system.builder_exit_request_predeploy_address;
pub const deposit_event_signature_hash = system.deposit_event_signature_hash;
pub const deposit_request_type = system.deposit_request_type;
pub const withdrawal_request_type = system.withdrawal_request_type;
pub const consolidation_request_type = system.consolidation_request_type;
pub const builder_deposit_request_type = system.builder_deposit_request_type;
pub const builder_exit_request_type = system.builder_exit_request_type;
pub const value_transfer_log_topic = system.value_transfer_log_topic;
pub const system_call_gas = system.system_call_gas;
pub const system_call_state_gas = system.system_call_state_gas;
