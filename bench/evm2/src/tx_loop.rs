//! Transaction-level lane: one complete transaction per call on a long-lived `Evm`.
//!
//! Mirrors `bench/src/tx_loop.zig`. The addresses, fees and setup transactions below must stay
//! identical in both files.

use std::{fs, path::Path, time::Instant};

use alloy_consensus::{TxLegacy, transaction::Recovered};
use alloy_primitives::{Address, Bytes, TxKind, U256, address, hex};
use evm2::{
    BaseEvmTypes, Evm, Precompiles, SpecId, TxResult,
    env::BlockEnvExt,
    ethereum::{RecoveredTxEnvelope, TxEnvelope, ethereum_tx_registry},
    evm::InMemoryDB,
};

use crate::{ENGINE, nonzero, parse_spec, spec_name};

const SENDER: Address = address!("0x1000000000000000000000000000000000000001");
const RECIPIENT: Address = address!("0x3000000000000000000000000000000000000003");
const COINBASE: Address = address!("0xc000000000000000000000000000000000000000");

const BASE_FEE: u64 = 7;
const GAS_PRICE: u128 = 10;
const BLOCK_GAS_LIMIT: u64 = 60_000_000;
/// Below the EIP-7825 transaction gas cap of 2^24.
const SETUP_GAS_LIMIT: u64 = 16_000_000;
/// Covers every workload on every fork, including forks that reprice the intrinsic cost.
const WORKLOAD_GAS_LIMIT: u64 = 100_000;

const SELECTOR_BENCHMARK: [u8; 4] = [0x30, 0x62, 0x7b, 0x7c];
const SELECTOR_BALANCE_OF: [u8; 4] = [0x70, 0xa0, 0x82, 0x31];
const SELECTOR_TRANSFER: [u8; 4] = [0xa9, 0x05, 0x9c, 0xbb];

#[derive(Clone, Copy, PartialEq, Eq)]
enum Case {
    EthTransfer,
    StopCall,
    Erc20Transfer,
}

impl Case {
    fn parse(s: &str) -> Result<Self, String> {
        match s {
            "eth-transfer" => Ok(Self::EthTransfer),
            "stop-call" => Ok(Self::StopCall),
            "erc20-transfer" => Ok(Self::Erc20Transfer),
            _ => Err(format!("unknown case: {s}")),
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::EthTransfer => "eth-transfer",
            Self::StopCall => "stop-call",
            Self::Erc20Transfer => "erc20-transfer",
        }
    }
}

struct Call {
    to: TxKind,
    value: u64,
    input: Bytes,
    gas_limit: u64,
}

struct Runner {
    evm: Evm<'static, BaseEvmTypes>,
    nonce: u64,
}

impl Runner {
    fn new(spec: SpecId) -> Self {
        let mut db = InMemoryDB::default();
        let mut sender = evm2::evm::AccountInfo::default();
        sender.balance = U256::from(1) << 100;
        db.insert_account_info(&SENDER, sender);
        let block = BlockEnvExt {
            number: U256::from(1),
            beneficiary: COINBASE,
            timestamp: U256::from(1),
            gas_limit: U256::from(BLOCK_GAS_LIMIT),
            basefee: U256::from(BASE_FEE),
            ..BlockEnvExt::default()
        };
        let evm = Evm::new(
            spec,
            block,
            ethereum_tx_registry(spec),
            db,
            Precompiles::base(spec),
        );
        Self { evm, nonce: 0 }
    }

    fn envelope(&self, call: &Call) -> RecoveredTxEnvelope {
        Recovered::new_unchecked(
            TxEnvelope::Legacy(TxLegacy {
                chain_id: None,
                nonce: self.nonce,
                gas_price: GAS_PRICE,
                gas_limit: call.gas_limit,
                to: call.to,
                value: U256::from(call.value),
                input: call.input.clone(),
            }),
            SENDER,
        )
    }

    /// Executes one transaction, requires success, and commits its state transition.
    fn send(&mut self, tx: &RecoveredTxEnvelope) -> Result<TxResult, String> {
        let executed = self
            .evm
            .transact(tx)
            .map_err(|e| format!("transaction rejected: {e:?}"))?;
        if !executed.result().status {
            return Err(format!("transaction failed: {:?}", executed.result().stop));
        }
        self.nonce += 1;
        Ok(executed.commit())
    }

    fn call(&mut self, call: &Call) -> Result<TxResult, String> {
        let tx = self.envelope(call);
        self.send(&tx)
    }

    fn deploy(&mut self, fixtures_dir: &str, name: &str) -> Result<Address, String> {
        let path = Path::new(fixtures_dir).join(name).join("init.hex");
        let text = fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        let init_code = hex::decode(text.trim()).map_err(|e| e.to_string())?;
        let result = self.call(&Call {
            to: TxKind::Create,
            value: 0,
            input: init_code.into(),
            gas_limit: SETUP_GAS_LIMIT,
        })?;
        result
            .created_address
            .ok_or_else(|| "missing created address".into())
    }

    fn token_balance(&mut self, token: Address, holder: Address) -> Result<U256, String> {
        let result = self.call(&Call {
            to: TxKind::Call(token),
            value: 0,
            input: abi_call(SELECTOR_BALANCE_OF, holder, None),
            gas_limit: WORKLOAD_GAS_LIMIT,
        })?;
        if result.output.len() < 32 {
            return Err("short return data".into());
        }
        Ok(U256::from_be_slice(&result.output[..32]))
    }

    /// Brings state to the steady point the timed loop repeats and measures its gas.
    fn prepare(
        &mut self,
        case: Case,
        fixtures_dir: &str,
        measured: u64,
    ) -> Result<Workload, String> {
        let call = match case {
            Case::EthTransfer => Call {
                to: TxKind::Call(RECIPIENT),
                value: 1,
                input: Bytes::new(),
                gas_limit: WORKLOAD_GAS_LIMIT,
            },
            Case::StopCall => Call {
                to: TxKind::Call(self.deploy(fixtures_dir, "stop-target")?),
                value: 0,
                input: Bytes::new(),
                gas_limit: WORKLOAD_GAS_LIMIT,
            },
            Case::Erc20Transfer => {
                let token = self.deploy(fixtures_dir, "erc20-transfer")?;
                // `Benchmark()` mints to the caller before its own transfer loop.
                let _ = self.call(&Call {
                    to: TxKind::Call(token),
                    value: 0,
                    input: Bytes::from_static(&SELECTOR_BENCHMARK),
                    gas_limit: SETUP_GAS_LIMIT,
                })?;
                // Two priming transfers follow, then the timed ones.
                if self.token_balance(token, SENDER)? < U256::from(measured + 2) {
                    return Err("insufficient token balance".into());
                }
                Call {
                    to: TxKind::Call(token),
                    value: 0,
                    input: abi_call(SELECTOR_TRANSFER, RECIPIENT, Some(1)),
                    gas_limit: WORKLOAD_GAS_LIMIT,
                }
            }
        };
        // The first call creates the recipient account or balance slot and the coinbase
        // account, which forks with state gas price far above the workload limit. The
        // second already runs in the steady state, so its gas is the reference.
        let _ = self.call(&Call {
            to: call.to,
            value: call.value,
            input: call.input.clone(),
            gas_limit: SETUP_GAS_LIMIT,
        })?;
        let gas_per_tx = self.call(&call)?.tx_gas_used();
        let target = *call.to.to().expect("workload is a call");
        let expected_before = self.recipient_balance(case, target)?;
        Ok(Workload {
            tx: self.envelope(&call),
            target,
            gas_per_tx,
            expected_before,
        })
    }

    fn recipient_balance(&mut self, case: Case, target: Address) -> Result<U256, String> {
        match case {
            Case::EthTransfer => Ok(self
                .evm
                .read_account_info(&RECIPIENT)
                .map_err(|e| e.to_string())?
                .map_or(U256::ZERO, |info| info.balance)),
            Case::StopCall => Ok(U256::ZERO),
            Case::Erc20Transfer => self.token_balance(target, RECIPIENT),
        }
    }

    /// Runs `txs` workload transactions and returns the elapsed nanoseconds.
    fn run_batch(&mut self, workload: &mut Workload, txs: usize) -> Result<u128, String> {
        let mut gas_used = 0;
        let start = Instant::now();
        for _ in 0..txs {
            let TxEnvelope::Legacy(tx) = workload.tx.inner_mut() else {
                unreachable!()
            };
            tx.nonce = self.nonce;
            gas_used += self.send(&workload.tx)?.tx_gas_used();
        }
        let elapsed = start.elapsed();
        if gas_used != workload.gas_per_tx * txs as u64 {
            return Err("unsteady gas".into());
        }
        Ok(elapsed.as_nanos())
    }
}

/// The transaction every timed call repeats. Only the nonce changes.
struct Workload {
    tx: RecoveredTxEnvelope,
    target: Address,
    /// Gas used by one steady-state transaction, measured by the last setup transaction.
    gas_per_tx: u64,
    /// Recipient balance the timed transactions must add to, checked after the run.
    expected_before: U256,
}

/// Encodes `selector(address)` or `selector(address,uint256)`.
fn abi_call(selector: [u8; 4], account: Address, amount: Option<u64>) -> Bytes {
    let mut data = vec![0; if amount.is_some() { 68 } else { 36 }];
    data[..4].copy_from_slice(&selector);
    data[16..36].copy_from_slice(account.as_slice());
    if let Some(amount) = amount {
        data[60..].copy_from_slice(&amount.to_be_bytes());
    }
    data.into()
}

pub fn run(mut args: impl Iterator<Item = String>) -> Result<(), String> {
    let mut case = Case::EthTransfer;
    let mut spec = SpecId::AMSTERDAM;
    let mut repeats = 5;
    let mut warmups = 1;
    let mut txs = 1000;
    let mut fixtures_dir = "fixtures/vm-loop".to_owned();
    let mut no_header = false;
    let mut summary = false;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--help" | "-h" => {
                eprintln!(
                    "EVM2 transaction loop: tx-loop [options]\n  --case <eth-transfer|stop-call|erc20-transfer>\n  --spec <fork> --repeats <n> --warmups <n> --txs <n>\n  --fixtures-dir <path> --no-header --summary"
                );
                return Ok(());
            }
            "--no-header" => {
                no_header = true;
                continue;
            }
            "--summary" => {
                summary = true;
                continue;
            }
            _ => {}
        }
        let (flag, value) = match arg.split_once('=') {
            Some((flag, value)) => (flag.to_owned(), value.to_owned()),
            None => (
                arg.clone(),
                args.next().ok_or_else(|| format!("missing {arg} value"))?,
            ),
        };
        match flag.as_str() {
            "--case" => case = Case::parse(&value)?,
            "--spec" => spec = parse_spec(&value)?,
            "--repeats" => repeats = nonzero(&value)?,
            "--warmups" => warmups = value.parse::<usize>().map_err(|e| e.to_string())?,
            "--txs" => txs = nonzero(&value)?,
            "--fixtures-dir" => fixtures_dir = value,
            _ => return Err(format!("unknown argument: {flag}")),
        }
    }

    let measured = ((warmups + repeats) * txs) as u64;
    let mut runner = Runner::new(spec);
    let mut workload = runner.prepare(case, &fixtures_dir, measured)?;

    for _ in 0..warmups {
        runner.run_batch(&mut workload, txs)?;
    }

    if !no_header {
        println!("suite,engine,case,spec,code_cache,repeat,txs,elapsed_ns,ns_per_tx,gas_per_tx");
    }
    for repeat in 0..repeats {
        let elapsed_ns = runner.run_batch(&mut workload, txs)?;
        // EVM2 keeps jump analysis inside the committed `Bytecode`, so the code cache is always on.
        println!(
            "tx-loop,{ENGINE},{},{},true,{repeat},{txs},{elapsed_ns},{:.3},{}",
            case.name(),
            spec_name(spec),
            elapsed_ns as f64 / txs as f64,
            workload.gas_per_tx,
        );
    }

    // Each timed transaction moves one unit to the recipient, so a lost state transition shows.
    if case != Case::StopCall {
        let balance = runner.recipient_balance(case, workload.target)?;
        if balance != workload.expected_before + U256::from(measured) {
            return Err("recipient balance mismatch".into());
        }
    }

    if summary {
        eprintln!(
            "engine={ENGINE} case={} spec={} code_cache=true warmups={warmups} repeats={repeats} txs={txs} gas_per_tx={}",
            case.name(),
            spec_name(spec),
            workload.gas_per_tx,
        );
    }
    Ok(())
}
