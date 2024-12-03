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

  struct evmc_host_interface *host = evmz_create_mock_host(&tx_context);
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

  // struct evmc_result result =
  //     vm->execute(vm, host, NULL, EVMC_HOMESTEAD, &msg, code, code_size);

  vm->destroy(vm);

  return 0;
}
