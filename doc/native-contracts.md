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

Native code with journaled state and the full `Host.Message`. It can read and
write storage, emit logs, mint and burn balances, and request child calls into
the EVM. Other stacks call this a stateful precompile.

The spec names one native type. Its `active` is the compile-time address set and
its `execute` is the code. The embedding binds an instance when it constructs the
executor, so the type's fields carry embedding state.

```zig
const Native = struct {
    const target = evmz.addr(0x5678);

    calls: u64 = 0,

    pub fn active(candidate: evmz.Address) bool {
        return candidate.eql(evmz.addr(0x1800000000000000000000000000000000000003));
    }

    pub fn execute(
        self: *Native,
        ctx: anytype,
        call: evmz.execution.NativeContractCall,
    ) !evmz.execution.NativeContractStep {
        // Second entry: the executor has run and settled the child requested below.
        if (call.child) |child| return .{ .done = .{
            .status = child.status(),
            .output_data = try call.allocator.dupe(u8, child.output_data),
        } };
        self.calls += 1;
        _ = try ctx.setStorage(call.message.recipient, 0, self.calls);
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
const my_spec = evmz.eth.latest.extend(.{ .native_contract = Native });
const Vm = evmz.Vm(my_spec);

var native: Native = .{};
var executor = Vm.Executor.init(allocator, .{ .native_contract = &native });
```

The executor borrows the instance, so it must outlive the executor. An active
address with no instance fails with `MissingNativeContract`. To run different
code under one spec, as tests do, make the native type a tagged union that
dispatches `execute`. For embedding state that rolls back with the EVM, see
[`examples/transaction_journal.zig`](../examples/transaction_journal.zig).

### The context

`ctx` is the executor's `NativeContext`, valid for one entry only:

- Reads: accounts, code, balances, storage, transient storage, block hashes, and
  access status for pricing.
- Effects: storage, transient storage, logs, self-destruct, and `addBalance` and
  `subtractBalance` for issuance. They take the same journaled paths bytecode
  does, so they roll back with the native call.
- `@TypeOf(ctx).spec`: the executor's own compiled spec.

`ctx` has no call. Children are requested through the returned step. State the
instance mutates directly is outside the EVM journal unless the embedding
journals it, as the transaction-journal example does.

### Entries and child calls

Each entry returns a `NativeContractStep`:

- `.done` ends the call with a status and output.
- `.call` requests one CALL-family child. The executor runs it, then enters the
  native again with `call.child` set. The request's `continuation` pointer comes
  back as `call.continuation`, so a native making several calls knows where it is.

Entries never nest, so native recursion does not grow the Zig stack. Allocate
output and continuation state from `call.allocator`. It lives until the native
call ends, and so does the copied child output in `call.child`.

CREATE cannot be requested. To deploy, call a factory contract, which then
becomes the deployer.

### Who owns what

The executor builds the child message the way the CALL opcode would. It sets depth
and staticness, forwards gas through `CallSpec.childGas`, and adds the value
stipend. It settles the child's gas into `call.ledger`. When the native call ends,
the executor applies bytecode's failure rules. Revert keeps output. Invalid and
out-of-gas drop output and remaining gas. Any failure drops refunds, unwinds state
gas and rolls back state, including state written by children that succeeded.

In a static call, every `ctx` effect fails with `error.StaticModeViolation`, and
so does a CALL request with value. Catching the error does not help. The call
still ends as `.invalid` with `write_protection`.

The adapter owns everything the chain decides:

- Charge native work and CALL-like overhead such as account access and value
  transfer with `call.ledger.trackGas`, `trackStateGas` and `refillStateGas`. A
  false return is terminal, so return `.done` without further effects. Price
  SSTORE- or CALL-like work from `@TypeOf(ctx).spec`, never a builtin fork.
- Decide which senders a request may name. The executor does not restrict them.
- Add chain gas rules the EVM lacks. Arc burns the retained 1/64 after a child
  halts; `_ = call.ledger.trackGas(call.ledger.gas_left)` on the next entry does
  the same.
- Report chain-visible failures, such as bad input or an unauthorized caller, as
  `.done` with `.revert` or `.invalid`. A Zig error aborts the whole execution, so
  keep errors for infrastructure faults like allocation or database failures.
- Define issuance. `addBalance` fails with `error.BalanceOverflow` and
  `subtractBalance` returns false when the balance is short, both changing
  nothing. Neither emits a transfer log, so emit the chain's own issuance log
  after the balance moves.

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
  state into a precompile through globals.
- Protocol logic that fits in bytecode: predeploy, system-called if the protocol
  invokes it.
