//! Compact semantic inputs for call-capture regression and differential runs.
//!
//! These are programs and client-independent expectations, not captured output.

pub const sender = "0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b";
pub const sender_secret_key = "0x45a915e4d060149eb4365960e6a7a45f334393093061116b197e3240065ff2d8";

pub const Status = enum {
    success,
    revert,
    out_of_gas,
    insufficient_balance,
    nonce_overflow,
    invalid_opcode,
    contract_address_collision,
    max_code_size_exceeded,
    invalid_code,
    code_store_out_of_gas,
    code_store_out_of_gas_committed,
};

pub const ExpectedRow = struct {
    status: Status,
    checkpoint_reverted: bool = false,
    attempted_to: ?[]const u8 = null,
    created_address: ?[]const u8 = null,
};

pub const Account = struct {
    address: []const u8,
    balance: []const u8 = "0x0",
    nonce: u64 = 0,
    code: []const u8 = "0x",
};

pub const Case = struct {
    id: []const u8,
    fork: []const u8 = "cancun",
    gas: u64 = 300_000,
    sender_balance: []const u8 = "0x3b9aca00",
    recipient: []const u8 = "0x0000000000000000000000000000000000001000",
    value: []const u8 = "0x0",
    accounts: []const Account,
    expected_rows: []const ExpectedRow,

    /// False when a transaction runner rejects before Geth emits a call frame.
    external: bool = true,
};

pub const all = [_]Case{
    .{
        .id = "call-variants-sibling-order",
        .accounts = &.{.{
            .address = "0x0000000000000000000000000000000000001000",
            .code = "0x5f5f5f5f5f6111015af1505f5f5f5f5f6111025af2505f5f5f5f6111035af4505f5f5f5f6111045afa5000",
        }},
        .expected_rows = &.{
            .{ .status = .success },
            .{ .status = .success },
            .{ .status = .success },
            .{ .status = .success },
            .{ .status = .success },
        },
    },
    .{
        .id = "precompile-and-empty-call",
        .accounts = &.{.{
            .address = "0x0000000000000000000000000000000000001000",
            .code = "0x60ab5f5360015f60015f5f6100045af1505f5f5f5f5f6112005af15000",
        }},
        .expected_rows = &.{
            .{ .status = .success },
            .{ .status = .success },
            .{ .status = .success },
        },
    },
    .{
        .id = "revert-and-invalid-siblings",
        .accounts = &.{
            .{
                .address = "0x0000000000000000000000000000000000001000",
                .code = "0x5f5f5f5f5f6113015af1505f5f5f5f5f6113025af15000",
            },
            .{
                .address = "0x0000000000000000000000000000000000001301",
                .code = "0x5f5ffd",
            },
            .{
                .address = "0x0000000000000000000000000000000000001302",
                .code = "0x0c",
            },
        },
        .expected_rows = &.{
            .{ .status = .success },
            .{ .status = .revert, .checkpoint_reverted = true },
            .{ .status = .invalid_opcode, .checkpoint_reverted = true },
        },
    },
    .{
        .id = "create-and-create2-empty-init",
        .accounts = &.{.{
            .address = "0x0000000000000000000000000000000000001000",
            .nonce = 1,
            .code = "0x5f5f5ff0505f5f5f5ff55000",
        }},
        .expected_rows = &.{
            .{ .status = .success },
            .{ .status = .success, .created_address = "0x5bafcc0c93ecd8022925d7fd89da1c6250850e19" },
            .{ .status = .success, .created_address = "0x8a557efc20cc785695bb17fb9a31b711b8b23c8c" },
        },
    },
    .{
        .id = "create-collision",
        .accounts = &.{
            .{
                .address = "0x0000000000000000000000000000000000001000",
                .nonce = 7,
                .code = "0x5f5f5ff05000",
            },
            .{
                .address = "0x46c851443beeee0748d553eb34777b777dbca99c",
                .nonce = 1,
            },
        },
        .expected_rows = &.{
            .{ .status = .success },
            .{
                .status = .contract_address_collision,
                .attempted_to = "0x46c851443beeee0748d553eb34777b777dbca99c",
            },
        },
    },
    .{
        .id = "insufficient-balance",
        .accounts = &.{.{
            .address = "0x0000000000000000000000000000000000001000",
            .code = "0x5f5f5f5f60016114015af15000",
        }},
        .expected_rows = &.{
            .{ .status = .success },
            .{ .status = .insufficient_balance },
        },
    },
    .{
        .id = "selfdestruct",
        .accounts = &.{
            .{
                .address = "0x0000000000000000000000000000000000001000",
                .code = "0x5f5f5f5f5f6115015af15000",
            },
            .{
                .address = "0x0000000000000000000000000000000000001501",
                .balance = "0x9",
                .nonce = 1,
                .code = "0x61beefff",
            },
        },
        .expected_rows = &.{
            .{ .status = .success },
            .{ .status = .success },
            .{ .status = .success },
        },
    },
    .{
        .id = "nested-out-of-gas",
        .accounts = &.{
            .{
                .address = "0x0000000000000000000000000000000000001000",
                .code = "0x5f5f5f5f5f6116015af15000",
            },
            .{
                .address = "0x0000000000000000000000000000000000001601",
                .code = "0x5b600056",
            },
        },
        .expected_rows = &.{
            .{ .status = .success },
            .{ .status = .out_of_gas, .checkpoint_reverted = true },
        },
    },
    .{
        .id = "create-nonce-overflow",
        .accounts = &.{.{
            .address = "0x0000000000000000000000000000000000001000",
            .nonce = 0xffffffffffffffff,
            .code = "0x6000600d5f3960005f5ff05000",
        }},
        .expected_rows = &.{
            .{ .status = .success },
            .{
                .status = .nonce_overflow,
                .attempted_to = "0x0a08972e9e79eda1d04efd585218b00654a4f15d",
            },
        },
    },
    .{
        .id = "create-max-code-size-exceeded",
        .accounts = &.{.{
            .address = "0x0000000000000000000000000000000000001000",
            .nonce = 1,
            .code = "0x6006600d5f3960065f5ff050006160016000f3",
        }},
        .expected_rows = &.{
            .{ .status = .success },
            .{
                .status = .max_code_size_exceeded,
                .checkpoint_reverted = true,
                .attempted_to = "0x5bafcc0c93ecd8022925d7fd89da1c6250850e19",
            },
        },
    },
    .{
        .id = "create-invalid-code",
        .accounts = &.{.{
            .address = "0x0000000000000000000000000000000000001000",
            .nonce = 1,
            .code = "0x600a600d5f39600a5f5ff0500060ef60005360016000f3",
        }},
        .expected_rows = &.{
            .{ .status = .success },
            .{
                .status = .invalid_code,
                .checkpoint_reverted = true,
                .attempted_to = "0x5bafcc0c93ecd8022925d7fd89da1c6250850e19",
            },
        },
    },
    .{
        .id = "create-code-store-out-of-gas",
        .accounts = &.{.{
            .address = "0x0000000000000000000000000000000000001000",
            .nonce = 1,
            .code = "0x6006600d5f3960065f5ff050006107d06000f3",
        }},
        .expected_rows = &.{
            .{ .status = .success },
            .{
                .status = .code_store_out_of_gas,
                .checkpoint_reverted = true,
                .attempted_to = "0x5bafcc0c93ecd8022925d7fd89da1c6250850e19",
            },
        },
    },
    .{
        .id = "frontier-create-code-store-out-of-gas-committed",
        .fork = "frontier",
        .accounts = &.{.{
            .address = "0x0000000000000000000000000000000000001000",
            .nonce = 1,
            .code = "0x60066010600039600660006000f050006107d06000f3",
        }},
        .expected_rows = &.{
            .{ .status = .success },
            .{
                .status = .code_store_out_of_gas_committed,
                .created_address = "0x5bafcc0c93ecd8022925d7fd89da1c6250850e19",
            },
        },
    },
    .{
        .id = "root-insufficient-balance",
        .sender_balance = "0x0",
        .value = "0x1",
        .accounts = &.{.{
            .address = "0x0000000000000000000000000000000000001000",
            .code = "0x00",
        }},
        .expected_rows = &.{.{ .status = .insufficient_balance }},
        .external = false,
    },
};
