use std::{fs, path::Path};

use evm2::{
    SpecId, config::BaseEvmConfigSelector, config::EvmConfigSelector, interpreter::Message,
};

use crate::{BenchTypes, ENGINE, MAX_GAS, execute, nonzero, parse_spec, prepared_code};

const SMALL: &[&str] = &[
    "push_pop",
    "add",
    "mul",
    "div",
    "sdiv",
    "mod",
    "smod",
    "addmod",
    "mulmod",
    "exp",
    "comparison",
    "bitwise",
    "shift",
];
const EDGE: &[&str] = &[
    "add_wide",
    "mul_wide",
    "div_wide",
    "sdiv_wide",
    "mod_wide",
    "smod_wide",
    "addmod_wide",
    "mulmod_wide",
    "exp_wide",
];
const LARGE: &[&str] = &["pushdata_large", "jumpdest_dense"];
const BRANCH: &[&str] = &[
    "jump",
    "jumpi_taken",
    "jumpi_fallthrough",
    "jumpi_alternating",
];

pub fn run(mut args: impl Iterator<Item = String>) -> Result<(), String> {
    let mut iterations = 100_000;
    let mut repeats = 5;
    let mut warmups = 1;
    let mut spec = SpecId::AMSTERDAM;
    let mut fixtures_dir = "fixtures/kernel".to_owned();
    let mut no_header = false;
    let mut cases = Vec::new();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--help" | "-h" => {
                eprintln!(
                    "EVM2 opcode kernels: kernel [options]\n  --case <name> --tier <small|edge|large|branch|all> (repeatable; default small)\n  --iterations <n> --repeats <n> --warmups <n>\n  --spec <fork> --fixtures-dir <path> --no-header"
                );
                return Ok(());
            }
            "--no-header" => {
                no_header = true;
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
            "--case" => {
                let name = value.replace('-', "_");
                let case = SMALL
                    .iter()
                    .chain(EDGE)
                    .chain(LARGE)
                    .chain(BRANCH)
                    .find(|&&case| case == name)
                    .ok_or_else(|| format!("unknown case: {value}"))?;
                append_cases(&mut cases, &[*case]);
            }
            "--tier" => match value.as_str() {
                "small" => append_cases(&mut cases, SMALL),
                "edge" => append_cases(&mut cases, EDGE),
                "large" => append_cases(&mut cases, LARGE),
                "branch" => append_cases(&mut cases, BRANCH),
                "all" => {
                    for tier in [SMALL, EDGE, LARGE, BRANCH] {
                        append_cases(&mut cases, tier);
                    }
                }
                _ => return Err(format!("unknown tier: {value}")),
            },
            "--iterations" | "-n" => iterations = nonzero(&value)?,
            "--repeats" => repeats = nonzero(&value)?,
            "--warmups" => warmups = value.parse::<usize>().map_err(|e| e.to_string())?,
            "--spec" => spec = parse_spec(&value)?,
            "--fixtures-dir" => fixtures_dir = value,
            _ => return Err(format!("unknown argument: {flag}")),
        }
    }
    if cases.is_empty() {
        append_cases(&mut cases, SMALL);
    }
    if !no_header {
        println!(
            "suite,engine,case,repeat,iterations,bytecode_bytes,capture_bytes,bytes_per_iter,elapsed_ns,ns_per_iter,gas_used,host_calls"
        );
    }
    let config = BaseEvmConfigSelector::execution_config(spec);
    for case in cases {
        let code = bytecode(Path::new(&fixtures_dir), case, iterations)?;
        let bytecode_bytes = code.len();
        let message = Message::<BenchTypes> {
            code: prepared_code(code),
            gas_limit: MAX_GAS,
            ..Default::default()
        };
        for _ in 0..warmups {
            execute(&message, &config, false, "null")?;
        }
        for repeat in 1..=repeats {
            let measurement = execute(&message, &config, false, "null")?;
            let elapsed_ns = measurement.elapsed.as_nanos();
            println!(
                "kernel,{ENGINE},{case},{repeat},{iterations},{bytecode_bytes},0,0.000,{elapsed_ns},{:.3},{},{}",
                elapsed_ns as f64 / iterations as f64,
                measurement.gas_used,
                measurement.host_calls,
            );
        }
    }
    Ok(())
}

fn append_cases(cases: &mut Vec<&'static str>, additions: &[&'static str]) {
    for &case in additions {
        if !cases.contains(&case) {
            cases.push(case);
        }
    }
}

fn bytecode(dir: &Path, case: &str, iterations: usize) -> Result<Vec<u8>, String> {
    let path = dir.join(format!("{case}.hex"));
    let text = fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let patterns: Vec<Vec<u8>> = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|line| {
            alloy_primitives::hex::decode(line.strip_prefix("0X").unwrap_or(line))
                .map_err(|e| e.to_string())
        })
        .collect::<Result<_, _>>()?;
    if patterns.is_empty() {
        return Err(format!("empty fixture: {}", path.display()));
    }
    let len = 1
        + (0..iterations)
            .map(|i| patterns[i % patterns.len()].len())
            .sum::<usize>();
    let mut code = Vec::with_capacity(len);
    for i in 0..iterations {
        code.extend_from_slice(&patterns[i % patterns.len()]);
    }
    code.push(0x00);
    Ok(code)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_kernel_patterns_execute_without_host_callbacks() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../fixtures/kernel");
        for spec in [SpecId::SHANGHAI, SpecId::OSAKA, SpecId::AMSTERDAM] {
            let config = BaseEvmConfigSelector::execution_config(spec);
            for &case in SMALL.iter().chain(EDGE).chain(LARGE).chain(BRANCH) {
                let message = Message::<BenchTypes> {
                    code: prepared_code(bytecode(&dir, case, 7).unwrap()),
                    gas_limit: MAX_GAS,
                    ..Default::default()
                };
                let result = execute(&message, &config, false, "null")
                    .unwrap_or_else(|e| panic!("{spec:?}/{case}: {e}"));
                assert_eq!(result.host_calls, 0);
                assert!(result.gas_used > 0);
            }
        }
    }
}
