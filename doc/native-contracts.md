# Native contracts, precompiles, predeploys, and system calls

Most EVM engines call every address that runs host code a _precompile_. evmz splits
the word because the capabilities differ: a hash function should not get state
access just because the same chain also ships a stateful native contract.

## Three independent axes

| Question                         | Answers                                                 | Where evmz decides                                          |
| -------------------------------- | ------------------------------------------------------- | ----------------------------------------------------------- |
| What executes when it is called? | bytecode · precompile · native contract                 | `Spec.precompile`, `Spec.native_contract`, code resolution  |
| How did the code get there?      | user deployment · predeploy                             | genesis or a presigned deployment; the executor never knows |
| Who is calling, and when?        | a transaction or a CALL · a system call at a block hook | `BlockSpec` hooks returning `BlockSystemCall` lists         |

The answers are independent. The beacon-roots contract is bytecode, a predeploy,
and system-called. An L2 bridge might be a native contract that users call.

## Precompile

A pure native function: allocator, input and gas in; status, output and gas left
out. No Host, no state, no child calls.

evmz ships the Ethereum catalog as `precompile.Config`. A chain derives its own
config and can add a _custom leaf_ for addresses outside the catalog. The leaf is
consulted first.

```zig
const ReverseContract = struct {
    pub const Entry = enum { reverse };

    pub fn resolve(target: evmz.Address) ?Entry {
        return if (target.eql(evmz.addr(0x1234))) .reverse else null;
    }

    pub fn execute(entry: Entry, call: evmz.precompile.Call) evmz.precompile.Error!evmz.precompile.Result {
        _ = entry;
        const output = try call.allocator.dupe(u8, call.input_data);
        std.mem.reverse(u8, output);
        return .{ .status = .success, .output_data = output, .gas_left = call.gas - 100 };
    }
};

const my_spec = evmz.eth.cancun.extend(.{ .precompile = .{
    .config = my_config,
    .custom = ReverseContract,
} });
```

Full example: [`examples/custom_fork/precompiles.zig`](../examples/custom_fork/precompiles.zig).

## Native contract

Native code with the executor's `Host` and the full `Host.Message`. It can read
and write journaled storage, emit logs, credit and debit balances, and request
child calls into the EVM. Other stacks call this a stateful precompile.

The spec activates addresses at compile time. The embedding binds behavior when it
constructs the executor.

```zig
const Native = struct {
    pub fn active(candidate: evmz.Address) bool {
        return candidate.eql(evmz.addr(0x1800000000000000000000000000000000000003));
    }
};
const my_spec = evmz.eth.latest.extend(.{ .native_contract = Native });
const Vm = evmz.Vm(my_spec);
const target = evmz.addr(0x5678);

const Runtime = struct {
    fn service(self: *Runtime) evmz.execution.NativeContractRuntime {
        return .{ .ptr = self, .vtable = &.{ .execute = execute } };
    }

    fn execute(ptr: *anyopaque, call: evmz.execution.NativeContractCall) !evmz.execution.NativeContractStep {
        _ = ptr;
        // Second entry: the executor has run and settled the child requested below.
        if (call.child) |child| return .{ .done = .{
            .status = child.status(),
            .output_data = try call.allocator.dupe(u8, child.output_data),
        } };
        if (!call.ledger.trackGas(100)) return .{ .done = .{} };
        return .{ .call = .{
            .kind = .call,
            .recipient = target,
            .code_address = target,
            .sender = call.message.sender,
            .input_data = call.message.input_data,
            .gas = call.ledger.gas_left,
        } };
    }
};

var runtime = Runtime{};
var executor = Vm.Executor.init(allocator, .{ .native_contract_runtime = runtime.service() });
```

The executor borrows the runtime, so it must outlive the executor. An active
address with no runtime fails with `MissingNativeContractRuntime`. For embedding
state that rolls back with the EVM, see
[`examples/transaction_journal.zig`](../examples/transaction_journal.zig).

### Entries and child calls

Each entry returns a `NativeContractStep`:

- `.done` ends the call with a status and output.
- `.call` requests one CALL-family child. The executor runs it, then enters the
  native again with `call.child` set. The request's `continuation` pointer comes
  back as `call.continuation`, so a native making several calls knows where it is.

Entries never nest, so native recursion does not grow the Zig stack. Allocate
output and continuation state from `call.allocator`. It lives until the native
call ends, and so does the copied child output in `call.child`.

`Host.call` inside an entry fails with `NativeHostCallUnsupported`. CREATE cannot
be requested. To deploy, call a factory contract, which then becomes the deployer.

### Who owns what

The executor builds the child message the way the CALL opcode would. It sets depth
and staticness, forwards gas through `CallSpec.childGas`, and adds the value
stipend. It settles the child's gas into `call.ledger`. When the native call ends,
the executor applies bytecode's failure rules. Revert keeps output. Invalid and
out-of-gas drop output and remaining gas. Any failure drops refunds, unwinds state
gas and rolls back state, including state written by children that succeeded.

In a static call, storage, transient storage, log, self-destruct and balance
effects fail with `error.StaticModeViolation`, and so does a CALL request with
value. Catching the error does not help. The call still ends as `.invalid` with
`write_protection`.

The adapter owns everything the chain decides:

- Charge native work and CALL-like overhead such as account access and value
  transfer with `call.ledger.trackGas`, `trackStateGas` and `refillStateGas`. A
  false return is terminal, so return `.done` without further effects. Price
  SSTORE- or CALL-like work from `call.rules`, the executor's own compiled spec,
  never a builtin fork.
- Decide which senders a request may name. The executor does not restrict them.
- Add chain gas rules the EVM lacks. Arc burns the retained 1/64 after a child
  halts; `_ = call.ledger.trackGas(call.ledger.gas_left)` on the next entry does
  the same.
- Report chain-visible failures, such as bad input or an unauthorized caller, as
  `.done` with `.revert` or `.invalid`. A Zig error aborts the whole execution, so
  keep errors for infrastructure faults like allocation or database failures.

`Host.changeBalance` credits or debits a balance with an optional log, for
issuance. Balance and log apply together or not at all, and no transfer log is
emitted.

### Rules shared by both native kinds

- Both are always warm for access accounting.
- Dispatch follows the code address after resolution. An EIP-7702 account
  delegating to a native address runs bytecode.
- One address cannot be both.
- Neither can be the root of a system call. The entrypoint fails with
  `NativeSystemCallUnsupported`.

## Predeploy

Bytecode the protocol placed at a fixed address: EIP-7002 and EIP-7251 request
contracts, beacon roots, history storage, OP Stack's `0x4200…` contracts. evmz has
nothing to declare. Seed the bytecode into state the way your genesis does.
`evmz.eth.system` exports the Ethereum addresses.

## System call

A call the protocol makes from `system_address` with `system_call_gas` at a block
lifecycle point, outside any transaction. EIP-4788, EIP-2935, EIP-7002 and
EIP-7251 drive their predeploys this way.

A spec returns system calls from four `BlockSpec` hooks: `beforeBlock`,
`beforeTransaction`, `afterTransaction` and `finalizeBlock`. Each
`BlockSystemCall` names sender, recipient, input, gas, and whether the target must
have code. Finalize calls can tag their output as an EIP-7685 request.

In evmz, "system contract" only means the target of a system call. It implies no
privilege. Where an L2 uses the phrase for privileged code anyone may call, evmz
calls that a native contract or a predeploy with its own access control.

## If you come from another engine

| You say                                                       | evmz says                       | Notes                                          |
| ------------------------------------------------------------- | ------------------------------- | ---------------------------------------------- |
| precompile (geth, revm, evmone, Nethermind)                   | precompile                      | same terminal shape                            |
| stateful precompile (Avalanche, Cosmos EVM, Arbitrum)         | native contract                 | may also request child calls                   |
| `PrecompileProvider` with context (revm)                      | native contract                 | revm has one tier; evmz types two              |
| precompile with `PrecompileHandle::call` (Frontier, Moonbeam) | native contract                 | evmz returns the call instead of making it     |
| subcall precompile (Arc)                                      | native contract                 | same two-phase shape; routing is chain policy  |
| predeploy, preinstall (OP, EIP-7002)                          | predeploy                       | evmz does not track ownership                  |
| system call, system transaction (L1 clients, EELS)            | system call                     | same meaning                                   |
| system contract (L1 sense: 4788, 2935, 7002)                  | predeploy that is system-called | two axes, not one term                         |
| system contract (zkSync, BSC, Polygon sense)                  | native contract or predeploy    | privilege is chain policy                      |
| host handles precompiles (EVMC)                               | dispatch lives in the executor  | a C adapter forwards it                        |

## Choosing a kind

- Pure function of its input: precompile.
- Needs state, logs, balances or a child call: native contract. Do not smuggle
  state into a precompile through the runtime pointer.
- Protocol logic that fits in bytecode: predeploy, system-called if the protocol
  invokes it.
