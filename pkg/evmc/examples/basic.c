#include <evmz/evmc.h>
#include <stdio.h>

int main(void) {
  struct evmc_vm *vm = evmc_create_evmz();
  if (vm == NULL)
    return 1;

  printf("EVMC ABI version: %d\n", vm->abi_version);
  printf("EVMC name: %s\n", vm->name);

  const uint8_t code[] = "\x60\x2a\x60\x00\x52\x60\x20\x60\x00\xf3";
  const size_t code_size = sizeof(code) - 1;
  const int64_t gas = 200000;
  struct evmc_message msg = {
      .kind = EVMC_CALL,
      .gas = gas,
      .depth = 0,
  };

  printf("Executing EVM bytecode...\n");

  struct evmc_result result =
      vm->execute(vm, NULL, NULL, EVMC_OSAKA, &msg, code, code_size);

  printf("Executed EVM bytecode...\n");

  printf("Status code: %d\n", result.status_code);
  printf("Gas left: %lld\n", result.gas_left);
  printf("Output size: %zu\n", result.output_size);
  printf("Output: ");
  for (size_t i = 0; i < result.output_size; i++) {
    printf("%02x", result.output_data[i]);
  }
  printf("\n");

  if (result.release != NULL)
    result.release(&result);

  vm->destroy(vm);

  return 0;
}
