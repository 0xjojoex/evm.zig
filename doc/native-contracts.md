# Native contracts, precompiles, predeploys, and system calls

Most EVM engines use one word, _precompile_, for every address that runs host
code instead of bytecode. evmz splits that word because the capabilities behind it
differ, and a chain should not hand state access to a hash function just because
it also ships a stateful native contract. This page defines the vocabulary, maps it
to the terms you already know from geth, revm and the L2 stacks, and shows how each
kind is declared.

## Three independent axes

Every address answers three questions. The answers do not constrain each other.

| Question                         | Answers                                                 | Where evmz decides                                          |
| -------------------------------- | ------------------------------------------------------- | ----------------------------------------------------------- |
| What executes when it is called? | bytecode · precompile · native contract                 | `Spec.precompile`, `Spec.native_contract`, code resolution  |
| How did the code get there?      | user deployment · predeploy                             | genesis or a presigned deployment; the executor never knows |
| Who is calling, and when?        | a transaction or a CALL · a system call at a block hook | `BlockSpec` hooks returning `BlockSystemCall` lists         |

The beacon-roots contract is bytecode, a predeploy, and system-called. An L2's
native bridge might be a native contract, not a predeploy, and user-called. Keep the
axes apart and most naming confusion disappears.

## Axis one: what executes

### Precompile

A terminal native function. It receives an allocator, input bytes and a gas budget,
and returns status, output and gas left. It has no Host, no message, no state, and
cannot call anything. This is geth's `PrecompiledContract`, revm's `revm-precompile`
function type, and EELS's precompile table.

evmz ships the Ethereum catalog as `precompile.Config`: per-contract activation, gas
schedule, modexp pricing, input caps. A chain derives its own configuration and may
add a _custom leaf_ for addresses outside the catalog:

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

The custom leaf is consulted first, then the catalog. Full example:
[`examples/custom_fork/precompiles.zig`](../examples/custom_fork/precompiles.zig).

### Native contract

A host-capable native implementation. It receives the executor's `Host` and the
full `Host.Message`, so it can read and write journaled storage, emit logs, read
balances and code, and call back into the EVM through `Host.call`. A child call runs
to completion inside the native invocation and returns a `Host.Result`; the native
code can inspect it and call again.

This is the tier other stacks call a _stateful precompile_ (Avalanche subnet-evm,
Cosmos EVM, Arbitrum's ArbOS precompiles, revm's `PrecompileProvider`), plus the
callback ability that only Frontier's `PrecompileHandle::call` and Arc's subcall
registry provide. Callback is permitted, not required. A native contract that only
touches storage is still this kind.

Declaring one takes two steps with two different owners. The spec activates
addresses at compile time; the embedding binds behavior at executor construction.

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

    fn execute(ptr: *anyopaque, call: evmz.execution.NativeContractCall) !evmz.execution.NativeContractResult {
        _ = ptr;
        var result = evmz.execution.NativeContractResult.init(call.message);
        const child = try call.host.call(.{
            .depth = call.message.depth + 1,
            .kind = .call,
            .gas = call.message.gas,
            .gas_reservoir = call.message.gas_reservoir,
            .recipient = target,
            .sender = call.message.sender,
            .input_data = call.message.input_data,
            .value = 0,
            .is_static = call.message.is_static,
            .code_address = target,
        });
        // Child output is borrowed until the next Host call; copy what you keep.
        const output = try call.allocator.dupe(u8, child.output_data);
        result.output_data = output;
        if (!result.settleChild(call.message.gas, 0, child)) return result;
        result.status = child.status();
        return result;
    }
};

var runtime = Runtime{};
var executor = Vm.Executor.init(allocator, .{ .native_contract_runtime = runtime.service() });
```

An active address with no bound runtime fails with
`MissingNativeContractRuntime`. The runtime is borrowed and must outlive the
executor. Full example with journaled embedding state:
[`examples/transaction_journal.zig`](../examples/transaction_journal.zig).

What the executor does for you: it opens a checkpoint around the invocation, commits
it on success and restores it on revert or halt, so a successful child's storage and
logs are undone if your completion step fails afterwards. It copies your output into
retained storage before releasing invocation scratch. It maps your status into the
caller's frame exactly as a bytecode child's would be.
It hands you its own pricing rules as `call.rules`, borrowed `StorageSpec` and
`CallSpec` pointers from the spec it was compiled with, so an SSTORE-like or
CALL-like effect is priced exactly as bytecode would price it, including any
`Spec.extend` overrides. Never pick a builtin fork inside a native contract.

The executor enforces static protection for native Host effects, including calls
that try to drop inherited staticness. A caught violation still fails that native
invocation. Direct child depth must equal the native parent's depth plus one.
Invalid/OOG discard output and regular gas; all failures discard refunds and unwind
state gas. Successful child state remains reversible until its ancestors complete.

You still own gas pricing, child identity, forwarding and exactly-once settlement.
Initialize `NativeContractResult` from the message, use `trackGas`, `trackStateGas`,
`refillStateGas` and `settleChild`, then return the native ledger before terminal
finalization. Price EVM-like effects through `call.rules`, never a fork you chose.
Zero reservoir is an available balance, not a state-gas activation flag.

`Host.changeBalance` supplies explicit credit/debit for issuance, with an optional
adapter-defined log. Balance and log share a checkpoint; overflow, insufficient
balance or logging failure leaves neither partially applied. A zero amount changes
no balance but emits a supplied log. This privileged operation has no ordinary
transfer semantics or implicit transfer log.

The Host port does not carry instruction metering. Reversible state outside the
EVM goes through
`CompileOptions.transaction_journal`, whose scopes pair with EVM checkpoints.

Native recursion uses the thread stack. The depth-1024 regression uses a 16 MiB
thread stack and checks native-only and alternating bytecode/native execution.
Debug native-only execution exceeds 8 MiB on the measured Darwin arm64 build.
Embeddings must provision stack space for their adapter's own work as well; this
test does not establish a stack bound for arbitrary callbacks.

### Rules shared by both native kinds

- Both are always _warm_ for access accounting, matching the Ethereum precompile
  rule and revm's `warm_addresses()`.
- Both are dispatched by _code address after resolution_. An EIP-7702 account
  delegating to a native address runs the bytecode path; it is not treated as native
  by recipient.
- One address cannot be both. Overlap is an authoring error asserted at dispatch.
- Neither can be the root of a system call today; see below.

## Axis two: predeploy

A predeploy is bytecode the protocol placed at a fixed address, whether at genesis or
through a presigned deployment. Ethereum's EIP-7002 and EIP-7251 request contracts,
the beacon-roots and history-storage contracts, and OP Stack's `0x4200…` contracts
are predeploys. OP additionally distinguishes _preinstalls_, third-party canonical
contracts such as Multicall3 shipped in genesis but not protocol-owned.

There is nothing to declare in evmz. A predeploy is ordinary bytecode in state, and
the interpreter executes it like any other account. Seed it into the world state the
way your chain's genesis does. `evmz.eth.system` exports the Ethereum addresses.

## Axis three: system call

A system call is an invocation the protocol makes from `system_address`
(`0xff…fe`) with `system_call_gas`, at a block lifecycle point and outside any
transaction. It is how EIP-4788, EIP-2935, EIP-7002 and EIP-7251 drive their
predeploys. Every L1 client models it this way: reth's `SystemCaller`, revm's
`transact_system_call`, evmone's `state::system_call`, Besu's
`SystemCallProcessor`, EELS's `process_system_transaction`.

A spec returns its system calls from four `BlockSpec` hooks: `beforeBlock`,
`beforeTransaction`, `afterTransaction` and `finalizeBlock`. Each `BlockSystemCall`
names sender, recipient, input, gas and whether the target must have code
(`require_code`, EELS's _checked_ system transaction). Finalize calls can tag their
output as an EIP-7685 request.

In evmz, "system contract" means only "the target of a system call". It says
nothing about privilege and it is not an execution kind. Today the target must be
bytecode; the system-call entrypoint does not dispatch native addresses. Some L2s
use the same phrase for privileged kernel-space code that anyone may call. That is
a different concept and, in evmz vocabulary, usually a native contract or a
predeploy with its own access control.

## If you come from another engine

| You say                                                       | evmz says                       | Notes                                       |
| ------------------------------------------------------------- | ------------------------------- | ------------------------------------------- |
| precompile (geth, revm, evmone, Nethermind)                   | precompile                      | same terminal shape                         |
| stateful precompile (Avalanche, Cosmos EVM, Arbitrum)         | native contract                 | evmz also lets it call back                 |
| `PrecompileProvider` with context (revm)                      | native contract                 | revm has one tier; evmz types the two       |
| precompile with `PrecompileHandle::call` (Frontier, Moonbeam) | native contract                 | closest existing analog                     |
| subcall precompile (Arc)                                      | native contract                 | routing policy belongs in the chain adapter |
| predeploy (OP, EIP-7002)                                      | predeploy                       | same meaning                                |
| preinstall (OP)                                               | predeploy                       | evmz does not distinguish ownership         |
| system call, system transaction (L1 clients, EELS)            | system call                     | same meaning                                |
| system contract (L1 sense: 4788, 2935, 7002)                  | predeploy that is system-called | two axes, not one term                      |
| system contract (zkSync, BSC, Polygon sense)                  | native contract or predeploy    | privilege is chain policy                   |
| host handles precompiles (EVMC)                               | dispatch lives in the executor  | a C adapter forwards it                     |

## Choosing a kind

- Pure function of its input: precompile. Custom leaf if the address is outside the
  Ethereum catalog.
- Needs state, logs, balances or a child call: native contract. Do not reach for a
  precompile and smuggle state in through the runtime pointer.
- Protocol-owned logic that can be expressed in bytecode: predeploy, driven by a
  system call if the protocol invokes it, by users otherwise.
