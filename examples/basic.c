#include "../include/evmz.h"
#include <stdio.h>

int main(void) {
  struct evmc_vm *vm = evmc_create_evmz();

  printf("EVMC ABI version: %d\n", vm->abi_version);
  printf("EVMC name: %s\n", vm->name);

  enum evmc_capabilities capabilities = vm->get_capabilities(vm);
  printf("EVMC capabilities: %d\n", capabilities);

  const uint8_t code[] = "\x43\x60\x00\x55\x43\x60\x00\x52\x59\x60\x00\xf3";
  const size_t code_size = sizeof(code) - 1;
  const uint8_t input[] = "Hello World!";
  const evmc_uint256be value = {{1, 0}};
  const evmc_address addr = {{0, 1, 2}};
  const int64_t gas = 200000;
  struct evmc_tx_context tx_context = {
      .block_number = 42,
      .block_timestamp = 66,
      .block_gas_limit = gas * 2,
  };

  struct evmc_host_context *ctx = evmz_create_mock_host_context(&tx_context);
  const struct evmc_host_interface host = evmz_mock_host_interace();
  struct evmc_message msg = {
      .kind = EVMC_CALL,
      .sender = addr,
      .recipient = addr,
      .value = value,
      .input_data = input,
      .input_size = sizeof(input),
      .gas = gas,
      .depth = 0,
  };

  printf("Executing EVM bytecode...\n");

  struct evmc_result result =
      vm->execute(vm, &host, ctx, EVMC_HOMESTEAD, &msg, code, code_size);

  printf("Executed EVM bytecode...\n");

  printf("Status code: %d\n", result.status_code);
  printf("Gas used: %lld\n", result.gas_left);
  printf("Output size: %ld\n", result.output_size);
  printf("Output: ");
  for (size_t i = 0; i < result.output_size; i++) {
    printf("%02x", result.output_data[i]);
  }
  printf("\n");

  vm->destroy(vm);
  evmz_destroy_mock_host_context(ctx);

  return 0;
}
