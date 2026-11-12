use std::borrow::Cow;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

mod kernel;
mod tx_loop;

use alloy_primitives::{Address, B256, Bytes, U256, hex, keccak256};
use evm2::bytecode::Bytecode;
use evm2::config::{BaseEvmConfigSelector, EvmConfigSelector};
use evm2::env::{BlockEnv, TxEnv};
use evm2::evm::{AccountLoad, SLoad, SStore, SelfDestructResult};
use evm2::interpreter::{Host, Interpreter, Message, MessageKind, MessageResult, Word};
use evm2::{
    DatabaseError, EvmTypesHost, ExecutionConfig, ExecutionError, HostError, LoadError, SpecId,
};

const ENGINE: &str = env!("EVM2_BENCH_ENGINE");
const DISPATCH: &str = env!("EVM2_BENCH_DISPATCH");
const RUSTC: &str = env!("EVM2_BENCH_RUSTC");

const MAX_GAS: u64 = 1_000_000_000_000;
const REVISION: &str = "66687c18b34d3bdbb899f5eb7605070615c03475";
const CALLER: Address = Address::new([
    0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
]);
const CONTRACT: Address = Address::new([
    0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2,
]);

fn main() -> Result<(), String> {
    let mut args = env::args().skip(1).peekable();
    if args.peek().is_some_and(|arg| arg == "kernel") {
        args.next();
        return kernel::run(args);
    }
    if args.peek().is_some_and(|arg| arg == "tx-loop") {
        args.next();
        return tx_loop::run(args);
    }
    let mut fixture = None;
    let mut code_path = None;
    let mut call_data = None;
    let mut num_runs = None;
    let mut host_profile = None;
    let mut warmup_ms = 100;
    let mut spec = SpecId::OSAKA;
    let mut summary = false;
    while let Some(arg) = args.next() {
        if arg == "--summary" {
            summary = true;
            continue;
        }
        if arg == "--help" || arg == "-h" {
            eprintln!(
                "EVM2 VM-loop runner: --fixture <dir> | --contract-code-path <hex-file>\n  --call-data <hex> --num-runs <n> --warmup-ms <n> --spec <fork>\n  --host-profile <null|mock> --summary"
            );
            return Ok(());
        }
        let (flag, value) = match arg.split_once('=') {
            Some((flag, value)) => (flag.to_owned(), value.to_owned()),
            None => (
                arg.clone(),
                args.next().ok_or_else(|| format!("missing {arg} value"))?,
            ),
        };
        match flag.as_str() {
            "--fixture" => fixture = Some(value),
            "--contract-code-path" => code_path = Some(value),
            "--call-data" => call_data = Some(value),
            "--num-runs" | "-n" => num_runs = Some(nonzero(&value)?),
            "--warmup-ms" => warmup_ms = value.parse::<u64>().map_err(|e| e.to_string())?,
            "--spec" => spec = parse_spec(&value)?,
            "--host-profile" => host_profile = Some(value),
            _ => return Err(format!("unknown argument: {flag}")),
        }
    }
    if let Some(dir) = &fixture {
        code_path.get_or_insert_with(|| {
            Path::new(dir)
                .join("init.hex")
                .to_string_lossy()
                .into_owned()
        });
        if call_data.is_none() {
            call_data = optional_text(dir, "calldata.hex")?;
        }
        if num_runs.is_none() {
            num_runs = optional_text(dir, "num-runs.txt")?
                .map(|s| nonzero(s.trim()))
                .transpose()?;
        }
        if host_profile.is_none() {
            host_profile = optional_text(dir, "host-profile.txt")?;
        }
    }
    let host_profile = host_profile.unwrap_or_else(|| "null".into());
    let host_profile = host_profile.trim();
    if !matches!(host_profile, "null" | "mock") {
        return Err("invalid host profile".into());
    }
    let num_runs = num_runs.unwrap_or(1);
    let code_path = code_path.ok_or("missing contract code path")?;
    let init = fs::read_to_string(&code_path).map_err(|e| format!("{code_path}: {e}"))?;
    let config = BaseEvmConfigSelector::execution_config(spec);
    let mut message = Message::<BenchTypes> {
        kind: MessageKind::Create,
        caller: CALLER,
        destination: CONTRACT,
        call_target: CONTRACT,
        code_address: CONTRACT,
        gas_limit: MAX_GAS,
        code: prepared_code(hex::decode(init.trim()).map_err(|e| e.to_string())?),
        ..Default::default()
    };
    let deploy = execute(&message, &config, true, host_profile)?;
    message.kind = MessageKind::Call;
    message.code = prepared_code(deploy.output.to_vec());
    message.input =
        Bytes::from(hex::decode(call_data.unwrap_or_default().trim()).map_err(|e| e.to_string())?)
            .into();
    let reference = execute(&message, &config, true, host_profile)?;
    let warmup_start = Instant::now();
    let mut warmup_calls = 0;
    while warmup_start.elapsed() < Duration::from_millis(warmup_ms) {
        execute(&message, &config, false, host_profile)?;
        warmup_calls += 1;
    }
    let warmup_elapsed = warmup_start.elapsed();
    let mut host_calls = 0;
    let mut logs = 0;
    for _ in 0..num_runs {
        let result = execute(&message, &config, false, host_profile)?;
        if result.gas_used != reference.gas_used
            || result.host_calls != reference.host_calls
            || result.logs != reference.logs
        {
            return Err("execution changed between fresh-state calls".into());
        }
        host_calls += result.host_calls;
        logs += result.logs;
        println!("{:.6}", result.elapsed.as_secs_f64() * 1_000.0);
    }
    if summary {
        eprintln!(
            "fixture={} engine={ENGINE} scope=raw-interpreter dispatch={DISPATCH} revision={REVISION} rustc={} host_profile={host_profile} spec={} runtime_bytes={} runtime_hash={} gas_used={} output_hash={} deploy_host_calls={} timed_host_calls={host_calls} logs={logs} warmup_ms={warmup_ms} warmup_calls={warmup_calls} warmup_elapsed_ms={:.3}",
            fixture.as_deref().unwrap_or(""),
            RUSTC.split_whitespace().nth(1).unwrap_or("unknown"),
            spec_name(spec),
            message.code.len(),
            keccak256(message.code.original_byte_slice()),
            reference.gas_used,
            keccak256(&reference.output),
            deploy.host_calls,
            warmup_elapsed.as_secs_f64() * 1_000.0
        );
        eprintln!("compiler={RUSTC}");
    }
    Ok(())
}

fn prepared_code(bytes: Vec<u8>) -> Bytecode {
    let code = Bytecode::new_legacy(bytes.into());
    // EVM2 defers jump analysis; the scoreboard prepares it even with warmup disabled.
    let _ = code.legacy_jump_table();
    code
}

struct Measurement {
    elapsed: Duration,
    output: Bytes,
    gas_used: u64,
    host_calls: usize,
    logs: usize,
}

fn execute(
    message: &Message<BenchTypes>,
    config: &ExecutionConfig<BenchTypes>,
    capture: bool,
    profile: &str,
) -> Result<Measurement, String> {
    let mut host = BenchHost::new(config.clone());
    let mut interpreter = Interpreter::<BenchTypes>::new(message);
    let start = Instant::now();
    let stop = interpreter.run(&mut host);
    let elapsed = start.elapsed();
    let stop = stop.map_err(|e| e.to_string())?;
    if !stop.is_success() {
        return Err(format!("interpreter failed: {stop:?}"));
    }
    if profile == "null" && host.host_calls != 0 {
        return Err("null host touched".into());
    }
    Ok(Measurement {
        elapsed,
        output: if capture {
            Bytes::copy_from_slice(interpreter.output())
        } else {
            Bytes::new()
        },
        gas_used: message.gas_limit - interpreter.gas().remaining(),
        host_calls: host.host_calls,
        logs: host.logs,
    })
}

struct BenchTypes;
impl EvmTypesHost for BenchTypes {
    type ConfigSelector = BaseEvmConfigSelector;
    type SpecId = SpecId;
    type Tx = ();
    type EvmExt = ();
    type MessageExt = ();
    type MessageResultExt = ();
    type TxEnvExt = ();
    type TxResultExt = ();
    type BlockEnvExt = ();
    type Host<'a> = BenchHost;
}

#[derive(Default)]
struct StorageSlot {
    value: Word,
    warm: bool,
}

struct BenchHost {
    config: ExecutionConfig<BenchTypes>,
    block: BlockEnv<BenchTypes>,
    tx: TxEnv<BenchTypes>,
    storage: HashMap<(Address, Word), StorageSlot>,
    original_storage: HashMap<(Address, Word), Word>,
    transient_storage: HashMap<(Address, Word), Word>,
    host_calls: usize,
    logs: usize,
}

impl BenchHost {
    fn new(config: ExecutionConfig<BenchTypes>) -> Self {
        Self {
            config,
            block: BlockEnv::<BenchTypes> {
                gas_limit: U256::from(MAX_GAS),
                ..Default::default()
            },
            tx: TxEnv::<BenchTypes> {
                origin: CALLER,
                chain_id: U256::ZERO,
                ..Default::default()
            },
            storage: HashMap::new(),
            original_storage: HashMap::new(),
            transient_storage: HashMap::new(),
            host_calls: 0,
            logs: 0,
        }
    }
}

impl Host<BenchTypes> for BenchHost {
    fn spec_id(&self) -> SpecId {
        self.config.base_spec_id()
    }
    fn execution_config(&self) -> &ExecutionConfig<BenchTypes> {
        &self.config
    }
    fn block_env(&mut self) -> &BlockEnv<BenchTypes> {
        &self.block
    }
    fn tx_env(&mut self) -> &TxEnv<BenchTypes> {
        &self.tx
    }
    fn initial_call_depth(&self) -> u16 {
        0
    }
    fn load_account(&mut self, _: &Address, _: bool, _: bool) -> Result<AccountLoad, HostError> {
        self.host_calls += 1;
        Ok(AccountLoad {
            is_empty: true,
            ..Default::default()
        })
    }
    fn block_hash(&mut self, _: &Word) -> Result<B256, DatabaseError> {
        self.host_calls += 1;
        Ok(B256::ZERO)
    }
    fn sload(
        &mut self,
        address: &Address,
        key: &Word,
        skip_cold_load: bool,
    ) -> Result<SLoad, HostError> {
        self.host_calls += 1;
        let k = (*address, *key);
        if skip_cold_load && !self.storage.get(&k).is_some_and(|s| s.warm) {
            return Err(LoadError::ColdLoadSkipped.into());
        }
        let slot = self.storage.entry(k).or_default();
        let is_cold = !slot.warm;
        slot.warm = true;
        Ok(SLoad {
            value: slot.value,
            is_cold,
            ..Default::default()
        })
    }
    fn sstore(
        &mut self,
        address: &Address,
        key: &Word,
        value: &Word,
        skip_cold_load: bool,
    ) -> Result<SStore, HostError> {
        self.host_calls += 1;
        let k = (*address, *key);
        if skip_cold_load && !self.storage.get(&k).is_some_and(|s| s.warm) {
            return Err(LoadError::ColdLoadSkipped.into());
        }
        let slot = self.storage.entry(k).or_default();
        let is_cold = !slot.warm;
        slot.warm = true;
        let present_value = slot.value;
        slot.value = *value;
        let original_value = *self.original_storage.entry(k).or_insert(present_value);
        Ok(SStore {
            original_value,
            present_value,
            new_value: *value,
            is_cold,
            ..Default::default()
        })
    }
    fn tload(&mut self, address: &Address, key: &Word) -> Word {
        self.host_calls += 1;
        *self
            .transient_storage
            .get(&(*address, *key))
            .unwrap_or(&Word::ZERO)
    }
    fn tstore(&mut self, address: &Address, key: &Word, value: &Word) {
        self.host_calls += 1;
        self.transient_storage.insert((*address, *key), *value);
    }
    fn log(&mut self, _: &Address, _: Cow<'_, [B256]>, _: Cow<'_, [u8]>) {
        self.host_calls += 1;
        self.logs += 1;
    }
    fn execute_message(
        &mut self,
        _: &mut Message<BenchTypes>,
    ) -> Result<MessageResult<BenchTypes>, ExecutionError> {
        Err(ExecutionError::Fatal(
            "VM-core runner does not execute nested CALL/CREATE frames".into(),
        ))
    }
    fn selfdestruct(
        &mut self,
        _: &Address,
        _: &Address,
        _: bool,
    ) -> Result<SelfDestructResult, HostError> {
        Err(ExecutionError::Fatal("VM-core runner does not execute SELFDESTRUCT".into()).into())
    }
}

fn optional_text(dir: &str, name: &str) -> Result<Option<String>, String> {
    match fs::read_to_string(Path::new(dir).join(name)) {
        Ok(s) => Ok(Some(s)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

fn nonzero(s: &str) -> Result<usize, String> {
    let n = s
        .parse()
        .map_err(|e: std::num::ParseIntError| e.to_string())?;
    if n == 0 {
        return Err("run count must be positive".into());
    }
    Ok(n)
}

fn parse_spec(s: &str) -> Result<SpecId, String> {
    match s {
        "latest" | "amsterdam" => Ok(SpecId::AMSTERDAM),
        "osaka" => Ok(SpecId::OSAKA),
        "prague" => Ok(SpecId::PRAGUE),
        "cancun" => Ok(SpecId::CANCUN),
        "shanghai" => Ok(SpecId::SHANGHAI),
        _ => Err(format!("unsupported spec: {s}")),
    }
}

fn spec_name(spec: SpecId) -> &'static str {
    match spec {
        SpecId::AMSTERDAM => "amsterdam",
        SpecId::OSAKA => "osaka",
        SpecId::PRAGUE => "prague",
        SpecId::CANCUN => "cancun",
        SpecId::SHANGHAI => "shanghai",
        _ => unreachable!(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host() -> BenchHost {
        BenchHost::new(BaseEvmConfigSelector::execution_config(SpecId::OSAKA))
    }

    #[test]
    fn zero_slots_warm_independently_of_value_and_keep_original_value() {
        let mut host = host();
        let key = Word::ZERO;
        let first = host.sload(&CONTRACT, &key, false).unwrap();
        assert!(first.is_cold);
        assert_eq!(first.value, Word::ZERO);
        assert!(!host.sload(&CONTRACT, &key, false).unwrap().is_cold);
        let first = host.sstore(&CONTRACT, &key, &Word::from(7), false).unwrap();
        assert!(!first.is_cold);
        assert_eq!(first.original_value, Word::ZERO);
        let second = host.sstore(&CONTRACT, &key, &Word::from(9), false).unwrap();
        assert_eq!(second.original_value, Word::ZERO);
        assert_eq!(second.present_value, Word::from(7));
    }

    #[test]
    fn skipped_cold_load_does_not_create_or_warm_slot() {
        let mut host = host();
        let key = Word::ZERO;
        assert!(host.sload(&CONTRACT, &key, true).is_err());
        assert!(host.sstore(&CONTRACT, &key, &Word::from(7), true).is_err());
        assert!(host.storage.is_empty());
        assert!(host.original_storage.is_empty());
        assert!(host.sload(&CONTRACT, &key, false).unwrap().is_cold);
    }

    #[test]
    fn each_interpreter_call_gets_fresh_storage_and_null_host_rejects_access() {
        let config = BaseEvmConfigSelector::execution_config(SpecId::OSAKA);
        let message = Message::<BenchTypes> {
            code: prepared_code(hex::decode("60005460010160005560005460005260206000f3").unwrap()),
            gas_limit: MAX_GAS,
            destination: CONTRACT,
            ..Default::default()
        };
        let first = execute(&message, &config, true, "mock").unwrap();
        let second = execute(&message, &config, true, "mock").unwrap();
        assert_eq!(U256::from_be_slice(&first.output), U256::ONE);
        assert_eq!(first.output, second.output);
        assert_eq!(first.gas_used, second.gas_used);
        assert_eq!(first.host_calls, 3);
        assert!(execute(&message, &config, false, "null").is_err());
    }

    #[test]
    fn nested_calls_fail_instead_of_timing_stubbed_execution() {
        let config = BaseEvmConfigSelector::execution_config(SpecId::OSAKA);
        let message = Message::<BenchTypes> {
            code: prepared_code(hex::decode("5f5f5f5f5f60015af100").unwrap()),
            gas_limit: MAX_GAS,
            ..Default::default()
        };
        assert!(
            execute(&message, &config, true, "mock")
                .err()
                .unwrap()
                .contains("nested CALL/CREATE")
        );
    }
}
