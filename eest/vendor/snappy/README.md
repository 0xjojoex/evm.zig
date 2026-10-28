# Snappy

Vendored from [blockblaz/zig-snappy](https://github.com/blockblaz/zig-snappy)
at commit `050f529bc5fa11242140312ecf550c186f05af1e` (v0.0.5), under the MIT license.

Local change: replace the four removed array repetition expressions with
`@splat` for Zig 0.17. Keep the codec and its upstream tests together.
