# evmz EVMC compatibility package

This package adapts the public `evmz` engine module to the EVMC ABI. It owns
the compatibility source, headers, C example, and static/shared
`libevmz-evmc` artifacts; the engine implementation remains in the `evmz`
package.

```sh
zig build ci -Doptimize=ReleaseFast
```

Installed headers are `evmz/evmc.h`, the compatibility include `evmz.h`, and
the pinned `evmc/evmc.h` used to build the adapter. The Zig module is named
`evmz_evmc`. The `ci` step builds both libraries, runs the adapter tests, and
runs the C example against both the static and shared artifacts.

Test and diagnostic tools can use the reverse host bridge through
`evmz_evmc.testing.host2c`; it is not part of the installed C ABI.

The repository manifest uses a local `../..` dependency for development. A
published archive must replace it with the URL and hash of the matching `evmz`
release; both packages are versioned in lockstep.

## License

Licensed under either the [Apache License, Version 2.0](LICENSE-APACHE) or the
[MIT license](LICENSE-MIT), at your option.
