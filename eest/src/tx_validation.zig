const std = @import("std");
const evmz = @import("evmz");

const transaction = evmz.transaction;
const transaction_envelope = evmz.transaction.envelope;

pub fn eestExceptionName(error_value: transaction.ValidationError) []const u8 {
    return switch (error_value) {
        .intrinsic_gas_too_low => "TransactionException.INTRINSIC_GAS_TOO_LOW",
        .intrinsic_gas_below_floor_gas_cost => "TransactionException.INTRINSIC_GAS_BELOW_FLOOR_GAS_COST",
        .insufficient_account_funds => "TransactionException.INSUFFICIENT_ACCOUNT_FUNDS",
        .insufficient_max_fee_per_gas => "TransactionException.INSUFFICIENT_MAX_FEE_PER_GAS",
        .priority_greater_than_max_fee_per_gas => "TransactionException.PRIORITY_GREATER_THAN_MAX_FEE_PER_GAS",
        .insufficient_max_fee_per_blob_gas => "TransactionException.INSUFFICIENT_MAX_FEE_PER_BLOB_GAS",
        .gas_allowance_exceeded => "TransactionException.GAS_ALLOWANCE_EXCEEDED",
        .nonce_is_max => "TransactionException.NONCE_IS_MAX",
        .nonce_mismatch => "TransactionException.NONCE_MISMATCH",
        .type_1_tx_pre_fork => "TransactionException.TYPE_1_TX_PRE_FORK",
        .type_2_tx_pre_fork => "TransactionException.TYPE_2_TX_PRE_FORK",
        .type_3_tx_pre_fork => "TransactionException.TYPE_3_TX_PRE_FORK",
        .type_4_tx_pre_fork => "TransactionException.TYPE_4_TX_PRE_FORK",
        .type_3_tx_contract_creation => "TransactionException.TYPE_3_TX_CONTRACT_CREATION",
        .type_3_tx_zero_blobs => "TransactionException.TYPE_3_TX_ZERO_BLOBS",
        .type_3_tx_blob_count_exceeded => "TransactionException.TYPE_3_TX_BLOB_COUNT_EXCEEDED",
        .type_3_tx_max_blob_gas_allowance_exceeded => "TransactionException.TYPE_3_TX_MAX_BLOB_GAS_ALLOWANCE_EXCEEDED",
        .type_3_tx_invalid_blob_versioned_hash => "TransactionException.TYPE_3_TX_INVALID_BLOB_VERSIONED_HASH",
        .initcode_size_exceeded => "TransactionException.INITCODE_SIZE_EXCEEDED",
        .sender_not_eoa => "TransactionException.SENDER_NOT_EOA",
        .type_4_empty_authorization_list => "TransactionException.TYPE_4_EMPTY_AUTHORIZATION_LIST",
        .type_4_tx_contract_creation => "TransactionException.TYPE_4_TX_CONTRACT_CREATION",
    };
}

pub fn validationErrorMatchesEest(error_value: transaction.ValidationError, expected: []const u8) bool {
    const name = eestExceptionName(error_value);
    if (error_value == .intrinsic_gas_below_floor_gas_cost and exceptionNameMatches("TransactionException.INTRINSIC_GAS_TOO_LOW", expected)) return true;
    if (error_value == .gas_allowance_exceeded and exceptionNameMatches("TransactionException.GAS_LIMIT_EXCEEDS_MAXIMUM", expected)) return true;
    return exceptionNameMatches(name, expected);
}

pub fn rawEestExceptionName(error_value: transaction_envelope.RawValidationError) []const u8 {
    return switch (error_value) {
        .unsupported_transaction_type => "TransactionException.UNSUPPORTED_TRANSACTION_TYPE",
        .type_4_tx_pre_fork => "TransactionException.TYPE_4_TX_PRE_FORK",
        .type_4_empty_authorization_list => "TransactionException.TYPE_4_EMPTY_AUTHORIZATION_LIST",
        .type_4_invalid_authorization_format => "TransactionException.TYPE_4_INVALID_AUTHORIZATION_FORMAT",
        .type_4_invalid_authority_signature => "TransactionException.TYPE_4_INVALID_AUTHORITY_SIGNATURE",
        .type_4_invalid_authority_signature_s_too_high => "TransactionException.TYPE_4_INVALID_AUTHORITY_SIGNATURE_S_TOO_HIGH",
    };
}

pub fn rawValidationErrorMatchesEest(error_value: transaction_envelope.RawValidationError, expected: []const u8) bool {
    return exceptionNameMatches(rawEestExceptionName(error_value), expected);
}

fn exceptionNameMatches(name: []const u8, expected: []const u8) bool {
    var it = std.mem.splitScalar(u8, expected, '|');
    while (it.next()) |part| {
        if (std.mem.eql(u8, std.mem.trim(u8, part, " \t\r\n"), name)) return true;
    }
    return false;
}

test "EEST tx validation matches pipe-separated expected exceptions" {
    try std.testing.expect(validationErrorMatchesEest(
        .type_3_tx_zero_blobs,
        "TransactionException.INSUFFICIENT_ACCOUNT_FUNDS | TransactionException.TYPE_3_TX_ZERO_BLOBS",
    ));
    try std.testing.expect(!validationErrorMatchesEest(
        .type_3_tx_zero_blobs,
        "TransactionException.INSUFFICIENT_ACCOUNT_FUNDS",
    ));
    try std.testing.expect(rawValidationErrorMatchesEest(
        .type_4_invalid_authority_signature,
        "TransactionException.TYPE_4_INVALID_AUTHORITY_SIGNATURE|TransactionException.TYPE_4_INVALID_AUTHORITY_SIGNATURE_S_TOO_HIGH",
    ));
    try std.testing.expect(validationErrorMatchesEest(
        .intrinsic_gas_below_floor_gas_cost,
        "TransactionException.INTRINSIC_GAS_TOO_LOW",
    ));
    try std.testing.expect(validationErrorMatchesEest(
        .gas_allowance_exceeded,
        "TransactionException.GAS_LIMIT_EXCEEDS_MAXIMUM",
    ));
}
