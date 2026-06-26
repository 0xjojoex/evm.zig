use std::cell::Cell;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::Path;
use std::time::Instant;

use revm::context::{BlockEnv, CfgEnv, TxEnv};
use revm::context_interface::cfg::GasParams;
use revm::context_interface::context::{SStoreResult, SelfDestructResult, StateLoad};
use revm::context_interface::host::{Host, LoadError};
use revm::context_interface::journaled_state::AccountInfoLoad;
use revm::database::InMemoryDB;
use revm::interpreter::instructions::{gas_table_spec, instruction_table};
use revm::interpreter::interpreter::{EthInterpreter, ExtBytecode};
use revm::interpreter::{CallInput, InputsImpl, Interpreter, InterpreterAction, SharedMemory};
use revm::primitives::hardfork::SpecId;
use revm::primitives::{Address, Bytes, Log, StorageKey, StorageValue, TxKind, B256, U256};
use revm::state::{AccountInfo, Bytecode};
use revm::{Context, ExecuteEvm, MainBuilder, MainContext};

const DEFAULT_ITERATIONS: usize = 100_000;
const DEFAULT_REPEATS: usize = 5;
const DEFAULT_WARMUPS: usize = 1;
const DEFAULT_FIXTURES_DIR: &str = "fixtures/kernel";
const TX_BASE_GAS: u64 = 21_000;
const MAX_GAS: u64 = 1_000_000_000_000;

#[derive(Clone, Copy, PartialEq, Eq)]
enum KernelCase {
    PushPop,
    Add,
    Mul,
    Div,
    Sdiv,
    Mod,
    Smod,
    Addmod,
    Mulmod,
    Exp,
    Comparison,
    Bitwise,
    Shift,
    AddWide,
    MulWide,
    DivWide,
    SdivWide,
    ModWide,
    SmodWide,
    AddmodWide,
    MulmodWide,
    ExpWide,
    PushdataLarge,
    JumpdestDense,
    Jump,
    JumpiTaken,
    JumpiFallthrough,
    JumpiAlternating,
}

enum KernelTier {
    Small,
    Edge,
    Large,
    Branch,
    All,
}

struct Options {
    iterations: usize,
    repeats: usize,
    warmups: usize,
    spec: SpecId,
    fixtures_dir: String,
    no_header: bool,
}

struct Measurement {
    elapsed_ns: u128,
    bytecode_bytes: usize,
    gas_used: u64,
}

fn main() -> Result<(), String> {
    let mut args: Vec<String> = env::args().skip(1).collect();
    if matches!(
        args.first().map(String::as_str),
        Some("vm-loop") | Some("--vm-loop")
    ) {
        args.remove(0);
        return run_vm_loop(args.into_iter());
    }
    run_kernel(args.into_iter())
}

fn run_kernel<I>(mut args: I) -> Result<(), String>
where
    I: Iterator<Item = String>,
{
    let mut options = Options {
        iterations: DEFAULT_ITERATIONS,
        repeats: DEFAULT_REPEATS,
        warmups: DEFAULT_WARMUPS,
        spec: SpecId::OSAKA,
        fixtures_dir: DEFAULT_FIXTURES_DIR.to_string(),
        no_header: false,
    };
    let mut selected_cases = Vec::new();
    let mut selected_tiers = Vec::new();

    while let Some(arg) = args.next() {
        if arg == "--help" || arg == "-h" {
            print_usage();
            return Ok(());
        } else if arg == "--case" {
            let value = args.next().ok_or("missing --case value")?;
            selected_cases.push(parse_case(&value).ok_or("invalid --case value")?);
        } else if let Some(value) = arg.strip_prefix("--case=") {
            selected_cases.push(parse_case(value).ok_or("invalid --case value")?);
        } else if arg == "--tier" {
            let value = args.next().ok_or("missing --tier value")?;
            selected_tiers.push(parse_tier(&value).ok_or("invalid --tier value")?);
        } else if let Some(value) = arg.strip_prefix("--tier=") {
            selected_tiers.push(parse_tier(value).ok_or("invalid --tier value")?);
        } else if arg == "--iterations" || arg == "-n" {
            let value = args.next().ok_or("missing --iterations value")?;
            options.iterations = parse_nonzero_usize(&value)?;
        } else if let Some(value) = arg.strip_prefix("--iterations=") {
            options.iterations = parse_nonzero_usize(value)?;
        } else if arg == "--repeats" {
            let value = args.next().ok_or("missing --repeats value")?;
            options.repeats = parse_nonzero_usize(&value)?;
        } else if let Some(value) = arg.strip_prefix("--repeats=") {
            options.repeats = parse_nonzero_usize(value)?;
        } else if arg == "--warmups" {
            let value = args.next().ok_or("missing --warmups value")?;
            options.warmups = parse_usize(&value)?;
        } else if let Some(value) = arg.strip_prefix("--warmups=") {
            options.warmups = parse_usize(value)?;
        } else if arg == "--spec" {
            let value = args.next().ok_or("missing --spec value")?;
            options.spec = parse_spec(&value).ok_or("invalid --spec value")?;
        } else if let Some(value) = arg.strip_prefix("--spec=") {
            options.spec = parse_spec(value).ok_or("invalid --spec value")?;
        } else if arg == "--fixtures-dir" {
            options.fixtures_dir = args.next().ok_or("missing --fixtures-dir value")?;
        } else if let Some(value) = arg.strip_prefix("--fixtures-dir=") {
            options.fixtures_dir = value.to_string();
        } else if arg == "--no-header" {
            options.no_header = true;
        } else {
            return Err(format!("unknown argument: {arg}"));
        }
    }

    if selected_cases.is_empty() && selected_tiers.is_empty() {
        append_tier_cases(&mut selected_cases, KernelTier::Small);
    } else {
        for tier in selected_tiers {
            append_tier_cases(&mut selected_cases, tier);
        }
    }

    if !options.no_header {
        println!(
            "suite,engine,case,repeat,iterations,bytecode_bytes,elapsed_ns,ns_per_iter,gas_used,host_calls"
        );
    }

    for case in selected_cases {
        for _ in 0..options.warmups {
            let _ = measure(
                case,
                options.iterations,
                options.spec,
                &options.fixtures_dir,
            )?;
        }
        for repeat in 1..=options.repeats {
            let measurement = measure(
                case,
                options.iterations,
                options.spec,
                &options.fixtures_dir,
            )?;
            let ns_per_iter = measurement.elapsed_ns as f64 / options.iterations as f64;
            println!(
                "kernel,revm,{},{},{},{},{},{:.3},{},0",
                case_name(case),
                repeat,
                options.iterations,
                measurement.bytecode_bytes,
                measurement.elapsed_ns,
                ns_per_iter,
                measurement.gas_used,
            );
        }
    }

    Ok(())
}

struct VmLoopOptions {
    fixture_dir: Option<String>,
    contract_code_path: Option<String>,
    call_data_hex: Option<String>,
    num_runs: Option<usize>,
    spec: SpecId,
    host_profile: Option<HostProfile>,
    summary: bool,
}

struct ResolvedVmLoopOptions {
    fixture_dir: Option<String>,
    contract_code_path: String,
    call_data_hex: String,
    num_runs: usize,
    spec: SpecId,
    host_profile: HostProfile,
    summary: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum HostProfile {
    Null,
    Mock,
}

impl HostProfile {
    fn name(self) -> &'static str {
        match self {
            HostProfile::Null => "null",
            HostProfile::Mock => "mock",
        }
    }
}

fn run_vm_loop<I>(mut args: I) -> Result<(), String>
where
    I: Iterator<Item = String>,
{
    let mut options = VmLoopOptions {
        fixture_dir: None,
        contract_code_path: None,
        call_data_hex: None,
        num_runs: None,
        spec: SpecId::OSAKA,
        host_profile: None,
        summary: false,
    };

    while let Some(arg) = args.next() {
        if arg == "--help" || arg == "-h" {
            print_vm_loop_usage();
            return Ok(());
        } else if arg == "--fixture" {
            options.fixture_dir = Some(args.next().ok_or("missing --fixture value")?);
        } else if let Some(value) = arg.strip_prefix("--fixture=") {
            options.fixture_dir = Some(value.to_string());
        } else if arg == "--contract-code-path" {
            options.contract_code_path =
                Some(args.next().ok_or("missing --contract-code-path value")?);
        } else if let Some(value) = arg.strip_prefix("--contract-code-path=") {
            options.contract_code_path = Some(value.to_string());
        } else if arg == "--call-data" {
            options.call_data_hex = Some(args.next().ok_or("missing --call-data value")?);
        } else if let Some(value) = arg.strip_prefix("--call-data=") {
            options.call_data_hex = Some(value.to_string());
        } else if arg == "--num-runs" || arg == "-n" {
            options.num_runs = Some(parse_nonzero_usize(
                &args.next().ok_or("missing --num-runs value")?,
            )?);
        } else if let Some(value) = arg.strip_prefix("--num-runs=") {
            options.num_runs = Some(parse_nonzero_usize(value)?);
        } else if arg == "--spec" {
            options.spec = parse_spec(&args.next().ok_or("missing --spec value")?)
                .ok_or("invalid --spec value")?;
        } else if let Some(value) = arg.strip_prefix("--spec=") {
            options.spec = parse_spec(value).ok_or("invalid --spec value")?;
        } else if arg == "--host-profile" {
            options.host_profile = Some(parse_host_profile(
                &args.next().ok_or("missing --host-profile value")?,
            )?);
        } else if let Some(value) = arg.strip_prefix("--host-profile=") {
            options.host_profile = Some(parse_host_profile(value)?);
        } else if arg == "--summary" {
            options.summary = true;
        } else {
            return Err(format!("unknown argument: {arg}"));
        }
    }

    let resolved = resolve_vm_loop_options(options)?;
    let contract_code_hex = fs::read_to_string(&resolved.contract_code_path)
        .map_err(|err| format!("failed to read '{}': {err}", resolved.contract_code_path))?;
    let contract_code = decode_hex(contract_code_hex.trim())?;
    let call_data = decode_hex(resolved.call_data_hex.trim())?;
    let deploy = deploy_runtime_revm(&contract_code, resolved.spec, resolved.host_profile)?;
    let runtime_code = deploy.runtime_code;
    let runtime_bytecode = Bytecode::new_raw(Bytes::from(runtime_code.clone()));

    let mut timed_host_calls = 0usize;
    let mut total_logs = 0usize;
    for _ in 0..resolved.num_runs {
        let measurement = time_runtime_call_revm(
            runtime_bytecode.clone(),
            &call_data,
            resolved.spec,
            resolved.host_profile,
        )?;
        timed_host_calls += measurement.host_calls;
        total_logs += measurement.logs;
        println!("{:.6}", measurement.elapsed_ns as f64 / 1_000_000.0);
    }

    if resolved.summary {
        eprintln!(
            "fixture={} engine=revm-interpreter host_profile={} spec={} runtime_bytes={} deploy_host_calls={} timed_host_calls={} logs={}",
            resolved.fixture_dir.as_deref().unwrap_or(""),
            resolved.host_profile.name(),
            spec_name(resolved.spec),
            runtime_code.len(),
            deploy.host_calls,
            timed_host_calls,
            total_logs,
        );
    }

    Ok(())
}

fn print_vm_loop_usage() {
    eprintln!(
        "\
Usage:
  cargo run --release -- vm-loop --fixture <dir>
  cargo run --release -- vm-loop --contract-code-path <hex-file> --call-data <hex> --num-runs <n>

Options:
  --fixture <dir>              fixture dir containing init.hex plus optional metadata
  --contract-code-path <path>  init-code hex file to deploy once
  --call-data <hex>            calldata hex for each runtime call
  --num-runs, -n <n>           number of timed calls
  --spec <name>                osaka, prague, cancun, shanghai, latest; default osaka
  --host-profile <null|mock>   fixture host profile label, default null
  --summary                    print fixture metadata to stderr
"
    );
}

fn resolve_vm_loop_options(options: VmLoopOptions) -> Result<ResolvedVmLoopOptions, String> {
    let mut contract_code_path = options.contract_code_path;
    let mut call_data_hex = options.call_data_hex;
    let mut num_runs = options.num_runs;
    let mut host_profile = options.host_profile;

    if let Some(fixture_dir) = &options.fixture_dir {
        if contract_code_path.is_none() {
            contract_code_path = Some(fixture_path(fixture_dir, "init.hex"));
        }
        if call_data_hex.is_none() {
            call_data_hex =
                read_optional_fixture_text(fixture_dir, "calldata.hex")?.or(Some(String::new()));
        }
        if num_runs.is_none() {
            if let Some(text) = read_optional_fixture_text(fixture_dir, "num-runs.txt")? {
                num_runs = Some(parse_nonzero_usize(text.trim())?);
            }
        }
        if host_profile.is_none() {
            if let Some(text) = read_optional_fixture_text(fixture_dir, "host-profile.txt")? {
                host_profile = Some(parse_host_profile(text.trim())?);
            }
        }
    }

    Ok(ResolvedVmLoopOptions {
        fixture_dir: options.fixture_dir,
        contract_code_path: contract_code_path.ok_or("missing contract code path")?,
        call_data_hex: call_data_hex.unwrap_or_default(),
        num_runs: num_runs.unwrap_or(1),
        spec: options.spec,
        host_profile: host_profile.unwrap_or(HostProfile::Null),
        summary: options.summary,
    })
}

fn fixture_path(fixture_dir: &str, name: &str) -> String {
    Path::new(fixture_dir)
        .join(name)
        .to_string_lossy()
        .into_owned()
}

fn read_optional_fixture_text(fixture_dir: &str, name: &str) -> Result<Option<String>, String> {
    let path = fixture_path(fixture_dir, name);
    match fs::read_to_string(&path) {
        Ok(text) => Ok(Some(text)),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(format!("failed to read '{path}': {err}")),
    }
}

fn parse_host_profile(value: &str) -> Result<HostProfile, String> {
    match value {
        "null" => Ok(HostProfile::Null),
        "mock" => Ok(HostProfile::Mock),
        _ => Err(format!("invalid host profile '{value}'")),
    }
}

struct VmLoopDeploy {
    runtime_code: Vec<u8>,
    host_calls: usize,
}

struct VmLoopMeasurement {
    elapsed_ns: u128,
    host_calls: usize,
    logs: usize,
}

fn deploy_runtime_revm(
    contract_code: &[u8],
    spec: SpecId,
    host_profile: HostProfile,
) -> Result<VmLoopDeploy, String> {
    let bytecode = Bytecode::new_raw(Bytes::from(contract_code.to_vec()));
    let output = execute_raw_interpreter(bytecode, &[], spec, false)?;
    reject_null_host_touches(host_profile, output.counters)?;
    Ok(VmLoopDeploy {
        runtime_code: output.output,
        host_calls: output.counters.total,
    })
}

fn time_runtime_call_revm(
    runtime_bytecode: Bytecode,
    call_data: &[u8],
    spec: SpecId,
    host_profile: HostProfile,
) -> Result<VmLoopMeasurement, String> {
    let output = execute_raw_interpreter(runtime_bytecode, call_data, spec, true)?;
    reject_null_host_touches(host_profile, output.counters)?;
    Ok(VmLoopMeasurement {
        elapsed_ns: output.elapsed_ns,
        host_calls: output.counters.total,
        logs: output.counters.logs,
    })
}

struct RawInterpreterOutput {
    output: Vec<u8>,
    elapsed_ns: u128,
    counters: HostCounters,
}

fn execute_raw_interpreter(
    bytecode: Bytecode,
    call_data: &[u8],
    spec: SpecId,
    timed: bool,
) -> Result<RawInterpreterOutput, String> {
    let instruction_table = instruction_table::<EthInterpreter, BenchHost>();
    let gas_table = gas_table_spec(spec);
    let inputs = InputsImpl {
        target_address: contract_address(),
        bytecode_address: Some(contract_address()),
        caller_address: caller_address(),
        input: CallInput::Bytes(Bytes::from(call_data.to_vec())),
        call_value: U256::ZERO,
    };
    let mut host = BenchHost::new(spec);
    let mut interpreter = Interpreter::new(
        SharedMemory::new(),
        ExtBytecode::new(bytecode),
        inputs,
        false,
        spec,
        MAX_GAS,
    );

    let start = timed.then(Instant::now);
    let action = interpreter.run_plain(&instruction_table, &gas_table, &mut host);
    let elapsed_ns = start.map(|value| value.elapsed().as_nanos()).unwrap_or(0);

    match action {
        InterpreterAction::Return(result) if result.is_ok() => Ok(RawInterpreterOutput {
            output: result.output.to_vec(),
            elapsed_ns,
            counters: host.counters(),
        }),
        InterpreterAction::Return(result) => {
            Err(format!("raw interpreter failed: {:?}", result.result))
        }
        InterpreterAction::NewFrame(_) => {
            Err("raw interpreter returned nested frame; VM-loop revm runner does not execute CALL/CREATE frames".to_string())
        }
    }
}

#[derive(Clone, Copy, Default)]
struct HostCounters {
    total: usize,
    logs: usize,
}

fn reject_null_host_touches(profile: HostProfile, counters: HostCounters) -> Result<(), String> {
    if profile == HostProfile::Null && counters.total != 0 {
        return Err(format!(
            "null host fixture touched {} revm host callbacks",
            counters.total
        ));
    }
    Ok(())
}

struct BenchHost {
    gas_params: GasParams,
    storage: HashMap<(Address, StorageKey), StorageValue>,
    original_storage: HashMap<(Address, StorageKey), StorageValue>,
    transient_storage: HashMap<(Address, StorageKey), StorageValue>,
    empty_account: AccountInfo,
    counters: Cell<HostCounters>,
}

impl BenchHost {
    fn new(spec: SpecId) -> Self {
        Self {
            gas_params: GasParams::new_spec(spec),
            storage: HashMap::new(),
            original_storage: HashMap::new(),
            transient_storage: HashMap::new(),
            empty_account: AccountInfo::default(),
            counters: Cell::new(HostCounters::default()),
        }
    }

    fn counters(&self) -> HostCounters {
        self.counters.get()
    }

    fn record_host_call(&self) {
        let mut counters = self.counters.get();
        counters.total += 1;
        self.counters.set(counters);
    }

    fn record_log(&self) {
        let mut counters = self.counters.get();
        counters.total += 1;
        counters.logs += 1;
        self.counters.set(counters);
    }
}

impl Host for BenchHost {
    fn basefee(&self) -> U256 {
        U256::ZERO
    }

    fn blob_gasprice(&self) -> U256 {
        U256::ZERO
    }

    fn gas_limit(&self) -> U256 {
        U256::from(MAX_GAS)
    }

    fn difficulty(&self) -> U256 {
        U256::ZERO
    }

    fn prevrandao(&self) -> Option<U256> {
        None
    }

    fn block_number(&self) -> U256 {
        U256::ZERO
    }

    fn timestamp(&self) -> U256 {
        U256::ZERO
    }

    fn beneficiary(&self) -> Address {
        Address::ZERO
    }

    fn slot_num(&self) -> U256 {
        U256::ZERO
    }

    fn chain_id(&self) -> U256 {
        U256::ZERO
    }

    fn effective_gas_price(&self) -> U256 {
        U256::ZERO
    }

    fn caller(&self) -> Address {
        caller_address()
    }

    fn blob_hash(&self, _number: usize) -> Option<U256> {
        None
    }

    fn max_initcode_size(&self) -> usize {
        usize::MAX
    }

    fn gas_params(&self) -> &GasParams {
        &self.gas_params
    }

    fn is_amsterdam_eip8037_enabled(&self) -> bool {
        false
    }

    fn block_hash(&mut self, _number: u64) -> Option<B256> {
        self.record_host_call();
        None
    }

    fn selfdestruct(
        &mut self,
        _address: Address,
        _target: Address,
        _skip_cold_load: bool,
    ) -> Result<StateLoad<SelfDestructResult>, LoadError> {
        self.record_host_call();
        Ok(StateLoad::new(SelfDestructResult::default(), false))
    }

    fn log(&mut self, _log: Log) {
        self.record_log();
    }

    fn sstore_skip_cold_load(
        &mut self,
        address: Address,
        key: StorageKey,
        value: StorageValue,
        _skip_cold_load: bool,
    ) -> Result<StateLoad<SStoreResult>, LoadError> {
        self.record_host_call();
        let storage_key = (address, key);
        let present_value = *self
            .storage
            .get(&storage_key)
            .unwrap_or(&StorageValue::ZERO);
        let original_value = *self
            .original_storage
            .entry(storage_key)
            .or_insert(present_value);
        self.storage.insert(storage_key, value);
        Ok(StateLoad::new(
            SStoreResult {
                original_value,
                present_value,
                new_value: value,
            },
            false,
        ))
    }

    fn sload_skip_cold_load(
        &mut self,
        address: Address,
        key: StorageKey,
        _skip_cold_load: bool,
    ) -> Result<StateLoad<StorageValue>, LoadError> {
        self.record_host_call();
        Ok(StateLoad::new(
            *self
                .storage
                .get(&(address, key))
                .unwrap_or(&StorageValue::ZERO),
            false,
        ))
    }

    fn tstore(&mut self, address: Address, key: StorageKey, value: StorageValue) {
        self.record_host_call();
        self.transient_storage.insert((address, key), value);
    }

    fn tload(&mut self, address: Address, key: StorageKey) -> StorageValue {
        self.record_host_call();
        *self
            .transient_storage
            .get(&(address, key))
            .unwrap_or(&StorageValue::ZERO)
    }

    fn load_account_info_skip_cold_load(
        &mut self,
        _address: Address,
        _load_code: bool,
        _skip_cold_load: bool,
    ) -> Result<AccountInfoLoad<'_>, LoadError> {
        self.record_host_call();
        Ok(AccountInfoLoad::new(&self.empty_account, false, true))
    }
}

fn caller_address() -> Address {
    Address::from([
        0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01,
    ])
}

fn contract_address() -> Address {
    Address::from([
        0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02,
    ])
}

fn spec_name(spec: SpecId) -> &'static str {
    match spec {
        SpecId::OSAKA => "osaka",
        SpecId::PRAGUE => "prague",
        SpecId::CANCUN => "cancun",
        SpecId::SHANGHAI => "shanghai",
        _ => "unknown",
    }
}

fn print_usage() {
    eprintln!(
        "\
Usage:
  cargo run --release -- [options]
  cargo run --release -- vm-loop [options]

Options:
  --case <name>           case filter; repeatable, default all cases
  --tier <name>           small, edge, large, branch, all; repeatable
  --iterations, -n <n>    repeated opcode pattern count, default 100000
  --repeats <n>           printed samples per case, default 5
  --warmups <n>           unprinted samples before repeats, default 1
  --spec <name>           osaka, prague, cancun, shanghai, default osaka
  --fixtures-dir <path>   kernel fixture directory, default fixtures/kernel
  --no-header             omit CSV header
"
    );
}

fn measure(
    case: KernelCase,
    iterations: usize,
    spec: SpecId,
    fixtures_dir: &str,
) -> Result<Measurement, String> {
    let code = kernel_bytecode(case, iterations, fixtures_dir)?;
    let bytecode_bytes = code.len();
    let bytecode = Bytecode::new_raw(Bytes::from(code));
    let mut db = InMemoryDB::default();
    let contract = Address::repeat_byte(0x20);
    db.insert_account_info(contract, AccountInfo::from_bytecode(bytecode));

    let mut block = BlockEnv::default();
    block.gas_limit = MAX_GAS;
    let mut cfg = CfgEnv::new_with_spec(spec);
    cfg.tx_gas_limit_cap = Some(MAX_GAS);

    let tx = TxEnv {
        caller: Address::repeat_byte(0x10),
        kind: TxKind::Call(contract),
        gas_limit: MAX_GAS,
        gas_price: 0,
        value: U256::ZERO,
        data: Bytes::new(),
        ..Default::default()
    };

    let mut evm = Context::mainnet()
        .with_db(db)
        .with_block(block)
        .with_cfg(cfg)
        .build_mainnet();

    let start = Instant::now();
    let output = evm.transact(tx).map_err(|err| format!("{err:?}"))?;
    let elapsed_ns = start.elapsed().as_nanos();
    let total_gas = output.result.gas().total_gas_spent();
    let gas_used = total_gas.saturating_sub(TX_BASE_GAS);

    Ok(Measurement {
        elapsed_ns,
        bytecode_bytes,
        gas_used,
    })
}

fn kernel_bytecode(
    case: KernelCase,
    iterations: usize,
    fixtures_dir: &str,
) -> Result<Vec<u8>, String> {
    let patterns = load_fixture_patterns(fixtures_dir, case)?;
    let bytecode_bytes = 1
        + (0..iterations)
            .map(|iteration| patterns[iteration % patterns.len()].len())
            .sum::<usize>();
    let mut code = Vec::with_capacity(bytecode_bytes);
    for iteration in 0..iterations {
        code.extend_from_slice(&patterns[iteration % patterns.len()]);
    }
    code.push(0x00);
    Ok(code)
}

fn load_fixture_patterns(fixtures_dir: &str, case: KernelCase) -> Result<Vec<Vec<u8>>, String> {
    let path = Path::new(fixtures_dir).join(format!("{}.hex", case_name(case)));
    let text = fs::read_to_string(&path)
        .map_err(|err| format!("failed to read fixture '{}': {err}", path.display()))?;
    let mut patterns = Vec::new();
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        patterns.push(decode_hex(line)?);
    }
    if patterns.is_empty() {
        return Err(format!("empty fixture '{}'", path.display()));
    }
    Ok(patterns)
}

fn decode_hex(source: &str) -> Result<Vec<u8>, String> {
    let hex = source
        .strip_prefix("0x")
        .or_else(|| source.strip_prefix("0X"))
        .unwrap_or(source);
    if hex.len() % 2 != 0 {
        return Err(format!("invalid hex length in fixture line '{source}'"));
    }
    let mut bytes = Vec::with_capacity(hex.len() / 2);
    let mut offset = 0;
    while offset < hex.len() {
        let byte = u8::from_str_radix(&hex[offset..offset + 2], 16)
            .map_err(|err| format!("invalid hex byte in fixture line '{source}': {err}"))?;
        bytes.push(byte);
        offset += 2;
    }
    Ok(bytes)
}

fn append_tier_cases(cases: &mut Vec<KernelCase>, tier: KernelTier) {
    let small = [
        KernelCase::PushPop,
        KernelCase::Add,
        KernelCase::Mul,
        KernelCase::Div,
        KernelCase::Sdiv,
        KernelCase::Mod,
        KernelCase::Smod,
        KernelCase::Addmod,
        KernelCase::Mulmod,
        KernelCase::Exp,
        KernelCase::Comparison,
        KernelCase::Bitwise,
        KernelCase::Shift,
    ];
    let edge = [
        KernelCase::AddWide,
        KernelCase::MulWide,
        KernelCase::DivWide,
        KernelCase::SdivWide,
        KernelCase::ModWide,
        KernelCase::SmodWide,
        KernelCase::AddmodWide,
        KernelCase::MulmodWide,
        KernelCase::ExpWide,
    ];
    let large = [KernelCase::PushdataLarge, KernelCase::JumpdestDense];
    let branch = [
        KernelCase::Jump,
        KernelCase::JumpiTaken,
        KernelCase::JumpiFallthrough,
        KernelCase::JumpiAlternating,
    ];
    match tier {
        KernelTier::Small => append_unique_cases(cases, &small),
        KernelTier::Edge => append_unique_cases(cases, &edge),
        KernelTier::Large => append_unique_cases(cases, &large),
        KernelTier::Branch => append_unique_cases(cases, &branch),
        KernelTier::All => {
            append_unique_cases(cases, &small);
            append_unique_cases(cases, &edge);
            append_unique_cases(cases, &large);
            append_unique_cases(cases, &branch);
        }
    }
}

fn append_unique_cases(cases: &mut Vec<KernelCase>, additions: &[KernelCase]) {
    for case in additions {
        if !cases.contains(case) {
            cases.push(*case);
        }
    }
}

fn parse_case(value: &str) -> Option<KernelCase> {
    Some(match value {
        "push-pop" | "push_pop" => KernelCase::PushPop,
        "add" => KernelCase::Add,
        "mul" => KernelCase::Mul,
        "div" => KernelCase::Div,
        "sdiv" => KernelCase::Sdiv,
        "mod" => KernelCase::Mod,
        "smod" => KernelCase::Smod,
        "addmod" => KernelCase::Addmod,
        "mulmod" => KernelCase::Mulmod,
        "exp" => KernelCase::Exp,
        "comparison" => KernelCase::Comparison,
        "bitwise" => KernelCase::Bitwise,
        "shift" => KernelCase::Shift,
        "add-wide" | "add_wide" => KernelCase::AddWide,
        "mul-wide" | "mul_wide" => KernelCase::MulWide,
        "div-wide" | "div_wide" => KernelCase::DivWide,
        "sdiv-wide" | "sdiv_wide" => KernelCase::SdivWide,
        "mod-wide" | "mod_wide" => KernelCase::ModWide,
        "smod-wide" | "smod_wide" => KernelCase::SmodWide,
        "addmod-wide" | "addmod_wide" => KernelCase::AddmodWide,
        "mulmod-wide" | "mulmod_wide" => KernelCase::MulmodWide,
        "exp-wide" | "exp_wide" => KernelCase::ExpWide,
        "pushdata-large" | "pushdata_large" => KernelCase::PushdataLarge,
        "jumpdest-dense" | "jumpdest_dense" => KernelCase::JumpdestDense,
        "jump" => KernelCase::Jump,
        "jumpi-taken" | "jumpi_taken" => KernelCase::JumpiTaken,
        "jumpi-fallthrough" | "jumpi_fallthrough" => KernelCase::JumpiFallthrough,
        "jumpi-alternating" | "jumpi_alternating" => KernelCase::JumpiAlternating,
        _ => return None,
    })
}

fn case_name(case: KernelCase) -> &'static str {
    match case {
        KernelCase::PushPop => "push_pop",
        KernelCase::Add => "add",
        KernelCase::Mul => "mul",
        KernelCase::Div => "div",
        KernelCase::Sdiv => "sdiv",
        KernelCase::Mod => "mod",
        KernelCase::Smod => "smod",
        KernelCase::Addmod => "addmod",
        KernelCase::Mulmod => "mulmod",
        KernelCase::Exp => "exp",
        KernelCase::Comparison => "comparison",
        KernelCase::Bitwise => "bitwise",
        KernelCase::Shift => "shift",
        KernelCase::AddWide => "add_wide",
        KernelCase::MulWide => "mul_wide",
        KernelCase::DivWide => "div_wide",
        KernelCase::SdivWide => "sdiv_wide",
        KernelCase::ModWide => "mod_wide",
        KernelCase::SmodWide => "smod_wide",
        KernelCase::AddmodWide => "addmod_wide",
        KernelCase::MulmodWide => "mulmod_wide",
        KernelCase::ExpWide => "exp_wide",
        KernelCase::PushdataLarge => "pushdata_large",
        KernelCase::JumpdestDense => "jumpdest_dense",
        KernelCase::Jump => "jump",
        KernelCase::JumpiTaken => "jumpi_taken",
        KernelCase::JumpiFallthrough => "jumpi_fallthrough",
        KernelCase::JumpiAlternating => "jumpi_alternating",
    }
}

fn parse_tier(value: &str) -> Option<KernelTier> {
    Some(match value {
        "small" => KernelTier::Small,
        "edge" => KernelTier::Edge,
        "large" => KernelTier::Large,
        "branch" => KernelTier::Branch,
        "all" => KernelTier::All,
        _ => return None,
    })
}

fn parse_spec(value: &str) -> Option<SpecId> {
    Some(match value {
        "latest" | "osaka" => SpecId::OSAKA,
        "prague" => SpecId::PRAGUE,
        "cancun" => SpecId::CANCUN,
        "shanghai" => SpecId::SHANGHAI,
        _ => return None,
    })
}

fn parse_nonzero_usize(value: &str) -> Result<usize, String> {
    let parsed = parse_usize(value)?;
    if parsed == 0 {
        return Err("expected non-zero number".to_string());
    }
    Ok(parsed)
}

fn parse_usize(value: &str) -> Result<usize, String> {
    value
        .parse::<usize>()
        .map_err(|err| format!("invalid number '{value}': {err}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sstore_keeps_original_value_from_start_of_call() {
        let mut host = BenchHost::new(SpecId::OSAKA);
        let address = contract_address();
        let key = StorageKey::ZERO;

        let first = host
            .sstore_skip_cold_load(address, key, StorageValue::from(1), false)
            .expect("first sstore succeeds");
        let second = host
            .sstore_skip_cold_load(address, key, StorageValue::from(2), false)
            .expect("second sstore succeeds");

        assert_eq!(StorageValue::ZERO, first.data.original_value);
        assert_eq!(StorageValue::ZERO, second.data.original_value);
        assert_eq!(StorageValue::from(1), second.data.present_value);
        assert_eq!(2, host.counters().total);
    }
}
