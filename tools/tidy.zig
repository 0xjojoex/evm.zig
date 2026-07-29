//! `zig build tidy` — a conservative, repo-owned housecleaning check.
//! Inspired by tigerbeetle
//!
//! Compilation proves that reachable declarations type-check; it says nothing
//! about container-level declarations that nothing references. This tool
//! reports three classes of review candidate and never edits source:
//!
//! - `unused-private`: a private container-level `const`/`fn` whose name
//!   appears exactly once in its file — the definition. Fails the step.
//! - `unreferenced-pub`: a `pub` container-level declaration whose name is
//!   spelled nowhere else in the repository. Advisory.
//! - `test-only`: a private declaration referenced only from `test` blocks.
//!   Advisory.
//! - `orphan-file`: a `.zig` file unreachable from any `build.zig` root. A
//!   standalone entry point can opt out with a `// tidy:root` comment.
//!   Advisory.
//!
//! Every heuristic errs toward silence. Counting is scope-blind, so shadowed
//! names and same-named struct fields inflate counts and suppress findings;
//! that is the intended direction of error. Files that reach declarations
//! reflectively are skipped outright, because no identifier count can be
//! trusted there.
//!
//! `unreferenced-pub` is advisory for a reason evmz cannot escape: it is a
//! library, so an unreferenced export may be deliberate API rather than rot.
//! What makes the class worth reading anyway is that the repository contains
//! its own consumers — `examples/`, `bench/`, `eest/`, `guest/` — so a `pub`
//! declaration none of them name is surface nothing exercises. That is a
//! prompt to decide whether the export earns its keep, never a proof that it
//! does not.
//!
//! Findings are review candidates, not proofs.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

/// Directory names that never hold first-party Zig source. Dot-directories are
/// pruned separately.
const pruned_dirs = [_][]const u8{
    "zig-out",
    "zig-cache",
    "zig-pkg",
    "node_modules",
    "fixtures",
    "patches",
    "target",
    "output",
};

/// Trees that only ever compile into test binaries. Declarations there reach
/// their entry point through `test` blocks by design, so `test-only` carries
/// no information.
const test_driven_prefixes = [_][]const u8{"bench/"};

/// Names the toolchain or `std` dispatches by convention rather than through a
/// reference any file spells out. Being unreferenced is their normal state.
const convention_names = [_][]const u8{
    "main",
    "build",
    "panic",
    "std_options",
    "format",
    "jsonStringify",
    "jsonParse",
    "jsonParseFromValue",
};

/// Opt-in marker for a standalone entry point that lives outside the build
/// graph — a `zig run` generator, say. Declaring the intent in the source beats
/// re-deriving it from docs every time the orphan report is read.
const root_marker = "// tidy:root";

/// Constructs that can name a declaration without ever spelling it as an
/// identifier. One occurrence disqualifies the whole file from decl findings.
const reflective_markers = [_][]const u8{
    "refAllDecls",
    "@hasDecl",
    "@field(",
    ".decls",
    "usingnamespace",
};

const max_source_bytes: std.Io.Limit = .limited(8 * 1024 * 1024);

const Class = enum {
    unused_private,
    unreferenced_pub,
    test_only,
    orphan_file,

    fn label(class: Class) []const u8 {
        return switch (class) {
            .unused_private => "unused-private",
            .unreferenced_pub => "unreferenced-pub",
            .test_only => "test-only",
            .orphan_file => "orphan-file",
        };
    }
};

const Finding = struct {
    class: Class,
    path: []const u8,
    /// 1-based; zero for whole-file findings.
    line: usize = 0,
    /// Rendered as `const name` / `fn name`; empty for whole-file findings.
    keyword: []const u8 = "",
    name: []const u8 = "",
};

const Source = struct {
    /// Repository-relative, always `/`-separated.
    path: []const u8,
    text: [:0]const u8,
};

/// The file set under analysis.
const Tree = struct {
    files: []const Source,
    by_path: std.StringHashMapUnmanaged(usize),

    fn init(arena: Allocator, files: []const Source) !Tree {
        var by_path: std.StringHashMapUnmanaged(usize) = .empty;
        for (files, 0..) |file, index| try by_path.put(arena, file.path, index);
        return .{ .files = files, .by_path = by_path };
    }

    fn text(tree: Tree, path: []const u8) ?[:0]const u8 {
        const index = tree.by_path.get(path) orelse return null;
        return tree.files[index].text;
    }
};

const Options = struct {
    root: []const u8 = ".",
    /// Fail on advisory classes too. Off until their noise floor is known.
    strict: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const options = try parseOptions(init, arena);

    var root = try std.Io.Dir.cwd().openDir(io, options.root, .{ .iterate = true });
    defer root.close(io);

    const tree = try readTree(arena, io, root);
    const findings = try analyze(arena, tree);

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const failed = try report(&stdout.interface, tree.files.len, findings, options.strict);
    try stdout.interface.flush();
    if (failed) std.process.exit(1);
}

fn parseOptions(init: std.process.Init, arena: Allocator) !Options {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer args.deinit();
    _ = args.next();

    var options: Options = .{};
    var saw_root = false;
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--strict")) {
            options.strict = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("usage: tidy [repo-root] [--strict]\n", .{});
            return error.UnknownArgument;
        } else if (!saw_root) {
            options.root = arg;
            saw_root = true;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return options;
}

fn analyze(arena: Allocator, tree: Tree) ![]const Finding {
    const reachable = try reachableFiles(arena, tree);
    const repo_uses = try repoIdentifierCounts(arena, tree);
    var findings: std.ArrayList(Finding) = .empty;
    for (tree.files) |file| {
        if (!reachable.contains(file.path)) {
            try findings.append(arena, .{ .class = .orphan_file, .path = file.path });
        }
        try scanDeclarations(arena, file, repo_uses, &findings);
    }
    return findings.items;
}

/// How often each name is spelled anywhere in the repository.
///
/// Identifier-shaped string literals count, because `@hasDecl(T, "Name")` and
/// `@field(v, "name")` are real references the tokenizer would otherwise miss.
/// Comments do not: prose reuses ordinary words and would silence everything.
fn repoIdentifierCounts(arena: Allocator, tree: Tree) !std.StringHashMapUnmanaged(u32) {
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    for (tree.files) |file| {
        var tokenizer: std.zig.Tokenizer = .init(file.text);
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            const raw = file.text[token.loc.start..token.loc.end];
            const name = switch (token.tag) {
                .identifier => raw,
                .string_literal => inner: {
                    const inner = if (raw.len >= 2) raw[1 .. raw.len - 1] else continue;
                    if (!isIdentifier(inner)) continue;
                    break :inner inner;
                },
                else => continue,
            };
            const entry = try counts.getOrPutValue(arena, name, 0);
            entry.value_ptr.* += 1;
        }
    }
    return counts;
}

fn isIdentifier(text: []const u8) bool {
    if (text.len == 0 or std.ascii.isDigit(text[0])) return false;
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// Reads every `.zig` file outside pruned directories.
fn readTree(arena: Allocator, io: std.Io, root: std.Io.Dir) !Tree {
    var walker = try root.walkSelectively(arena);
    defer walker.deinit();

    var files: std.ArrayList(Source) = .empty;
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => if (!isPruned(entry.basename)) try walker.enter(io, entry),
        .file => if (std.mem.endsWith(u8, entry.basename, ".zig")) {
            const path = try arena.dupe(u8, entry.path);
            const text = try root.readFileAllocOptions(io, path, arena, max_source_bytes, .of(u8), 0);
            try files.append(arena, .{ .path = path, .text = text });
        },
        else => {},
    };
    return Tree.init(arena, files.items);
}

fn isPruned(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, ".")) return true;
    for (pruned_dirs) |pruned| {
        if (std.mem.eql(u8, name, pruned)) return true;
    }
    return false;
}

/// Paths reachable from the build graph.
///
/// Build scripts are the only place module roots are named, so every `.zig`
/// path literal in a `build.zig` seeds the search. That over-seeds — a literal
/// that is not really a root still counts — but an extra root can only
/// suppress an orphan finding, never invent one.
fn reachableFiles(arena: Allocator, tree: Tree) !std.StringHashMapUnmanaged(void) {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;

    for (tree.files) |file| {
        if (std.mem.indexOf(u8, file.text, root_marker) != null) {
            try discover(arena, &seen, &queue, file.path);
        }
        if (!std.mem.eql(u8, std.fs.path.basenamePosix(file.path), "build.zig")) continue;
        try discover(arena, &seen, &queue, file.path);
        for (try pathLiterals(arena, file.text, .all)) |literal| {
            if (try resolveFrom(arena, file.path, literal)) |resolved| {
                try discover(arena, &seen, &queue, resolved);
            }
        }
    }

    while (queue.pop()) |path| {
        const text = tree.text(path) orelse continue;
        for (try pathLiterals(arena, text, .imports)) |literal| {
            if (try resolveFrom(arena, path, literal)) |resolved| {
                try discover(arena, &seen, &queue, resolved);
            }
        }
    }
    return seen;
}

fn discover(
    arena: Allocator,
    seen: *std.StringHashMapUnmanaged(void),
    queue: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    if (try seen.fetchPut(arena, path, {}) != null) return;
    try queue.append(arena, path);
}

const LiteralScan = enum {
    /// Every `.zig` string literal, wherever it appears.
    all,
    /// Only the argument of an `@import(...)` call.
    imports,
};

/// The `.zig` paths named by string literals in `text`.
fn pathLiterals(arena: Allocator, text: [:0]const u8, scan: LiteralScan) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    var tokenizer: std.zig.Tokenizer = .init(text);
    var in_import = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .builtin => in_import = std.mem.eql(u8, text[token.loc.start..token.loc.end], "@import"),
            .l_paren => {},
            .string_literal => {
                const raw = text[token.loc.start..token.loc.end];
                // Path literals never contain escapes; anything else is not a path.
                if (raw.len >= 2 and std.mem.indexOfScalar(u8, raw, '\\') == null) {
                    const literal = raw[1 .. raw.len - 1];
                    if (std.mem.endsWith(u8, literal, ".zig") and (scan == .all or in_import)) {
                        try found.append(arena, literal);
                    }
                }
                in_import = false;
            },
            else => in_import = false,
        }
    }
    return found.items;
}

/// Joins `rel` onto the directory holding `from`, collapsing `.` and `..`.
/// Returns null when the result escapes the repository root.
fn resolveFrom(arena: Allocator, from: []const u8, rel: []const u8) !?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(arena);

    var dir = std.mem.tokenizeScalar(u8, std.fs.path.dirnamePosix(from) orelse "", '/');
    while (dir.next()) |part| try parts.append(arena, part);

    var tail = std.mem.tokenizeScalar(u8, rel, '/');
    while (tail.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.pop() == null) return null;
            continue;
        }
        try parts.append(arena, part);
    }
    return try std.mem.join(arena, "/", parts.items);
}

const Decl = struct {
    keyword: []const u8,
    name: []const u8,
    token: Ast.TokenIndex,
    /// `pub`, so file-local counting says nothing about it.
    public: bool,
};

/// Inclusive token span of one `test { ... }` block.
const TokenSpan = struct { first: Ast.TokenIndex, last: Ast.TokenIndex };

const Uses = struct { total: u32 = 0, in_test: u32 = 0 };

fn scanDeclarations(
    arena: Allocator,
    file: Source,
    repo_uses: std.StringHashMapUnmanaged(u32),
    findings: *std.ArrayList(Finding),
) !void {
    for (reflective_markers) |marker| {
        if (std.mem.indexOf(u8, file.text, marker) != null) return;
    }

    var tree = try Ast.parse(arena, file.text, .zig);
    defer tree.deinit(arena);
    // Syntax errors are the compiler's business, and the AST is unusable here.
    if (tree.errors.len != 0) return;

    var decls: std.ArrayList(Decl) = .empty;
    var tests: std.ArrayList(TokenSpan) = .empty;
    try collectMembers(arena, tree, tree.rootDecls(), &decls, &tests);

    var uses: std.StringHashMapUnmanaged(Uses) = .empty;
    for (0..tree.tokens.len) |index| {
        const token: Ast.TokenIndex = @intCast(index);
        if (tree.tokenTag(token) != .identifier) continue;
        const entry = try uses.getOrPutValue(arena, tree.tokenSlice(token), .{});
        entry.value_ptr.total += 1;
        if (inAnySpan(tests.items, token)) entry.value_ptr.in_test += 1;
    }

    const test_driven = isTestDriven(file.path);
    for (decls.items) |decl| {
        const class = classify(decl, uses, repo_uses, test_driven) orelse continue;
        try findings.append(arena, .{
            .class = class,
            .path = file.path,
            .line = tree.tokenLocation(0, decl.token).line + 1,
            .keyword = decl.keyword,
            .name = decl.name,
        });
    }
}

/// A `pub` declaration is reachable from any file, so only a repository-wide
/// count means anything; a private one is file-visible, so its own file is the
/// whole world.
fn classify(
    decl: Decl,
    uses: std.StringHashMapUnmanaged(Uses),
    repo_uses: std.StringHashMapUnmanaged(u32),
    test_driven: bool,
) ?Class {
    if (decl.public) {
        if (isConventionName(decl.name)) return null;
        return if ((repo_uses.get(decl.name) orelse 0) <= 1) .unreferenced_pub else null;
    }
    const count = uses.get(decl.name) orelse return null;
    if (count.total <= 1) return .unused_private;
    const test_only = !test_driven and
        !isTestHelperName(decl.name) and
        count.total - count.in_test <= 1;
    return if (test_only) .test_only else null;
}

/// Records private declarations and `test` spans, descending through nested
/// containers. Declarations inside function bodies are left alone: the
/// compiler already rejects unused locals.
fn collectMembers(
    arena: Allocator,
    tree: Ast,
    members: []const Ast.Node.Index,
    decls: *std.ArrayList(Decl),
    tests: *std.ArrayList(TokenSpan),
) error{OutOfMemory}!void {
    for (members) |member| {
        if (tree.nodeTag(member) == .test_decl) {
            try tests.append(arena, .{
                .first = tree.firstToken(member),
                .last = tree.lastToken(member),
            });
            continue;
        }

        var proto_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&proto_buffer, member)) |proto| {
            const name = proto.name_token orelse continue;
            if (isLinkageToken(tree, proto.extern_export_inline_token)) continue;
            try decls.append(arena, .{
                .keyword = "fn",
                .name = tree.tokenSlice(name),
                .token = name,
                .public = proto.visib_token != null,
            });
            continue;
        }

        const var_decl = tree.fullVarDecl(member) orelse continue;
        const eligible = var_decl.comptime_token == null and
            !isLinkageToken(tree, var_decl.extern_export_token);
        const name = var_decl.ast.mut_token + 1;
        if (eligible and !std.mem.eql(u8, tree.tokenSlice(name), "_")) {
            try decls.append(arena, .{
                .keyword = tree.tokenSlice(var_decl.ast.mut_token),
                .name = tree.tokenSlice(name),
                .token = name,
                .public = var_decl.visib_token != null,
            });
        }

        // A `pub` container still hides private members, so recurse regardless.
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        var container_buffer: [2]Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&container_buffer, init_node) orelse continue;
        try collectMembers(arena, tree, container.ast.members, decls, tests);
    }
}

/// `inline` leaves a declaration private; `extern` and `export` do not.
fn isLinkageToken(tree: Ast, token: ?Ast.TokenIndex) bool {
    const index = token orelse return false;
    return switch (tree.tokenTag(index)) {
        .keyword_extern, .keyword_export => true,
        else => false,
    };
}

fn inAnySpan(spans: []const TokenSpan, token: Ast.TokenIndex) bool {
    for (spans) |span| {
        if (token >= span.first and token <= span.last) return true;
    }
    return false;
}

/// True for files that only ever compile into a test binary: test and fuzz
/// roots, plus the benchmark tree. `test-only` is not a finding there.
fn isTestDriven(path: []const u8) bool {
    const basename = std.fs.path.basenamePosix(path);
    if (std.mem.eql(u8, basename, "test.zig") or std.mem.eql(u8, basename, "fuzz.zig")) return true;
    if (std.mem.endsWith(u8, basename, "_test.zig") or std.mem.endsWith(u8, basename, "_fuzz.zig")) return true;
    if (std.mem.indexOf(u8, path, "test/") != null) return true;
    for (test_driven_prefixes) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

/// A helper that names itself as test support inside a production file is
/// doing its job, not rotting. Suppressing these keeps `test-only` pointed at
/// the interesting case: a production-named declaration only tests still
/// reach.
fn isConventionName(name: []const u8) bool {
    for (convention_names) |convention| {
        if (std.mem.eql(u8, name, convention)) return true;
    }
    return false;
}

fn isTestHelperName(name: []const u8) bool {
    return std.mem.eql(u8, name, "t") or
        std.mem.eql(u8, name, "testing") or
        std.mem.startsWith(u8, name, "expect") or
        std.mem.indexOf(u8, name, "test") != null or
        std.mem.indexOf(u8, name, "Test") != null;
}

/// Prints findings grouped by class. Returns true when the step should fail.
fn report(
    out: *std.Io.Writer,
    file_count: usize,
    findings: []const Finding,
    strict: bool,
) !bool {
    var failed = false;
    for ([_]Class{ .unused_private, .unreferenced_pub, .test_only, .orphan_file }) |class| {
        const fails = class == .unused_private or strict;
        var printed: usize = 0;
        for (findings) |finding| {
            if (finding.class != class) continue;
            if (printed == 0) {
                try out.print("\n{s} ({s})\n", .{
                    class.label(),
                    if (fails) "must fix" else "advisory",
                });
            }
            printed += 1;
            if (finding.line == 0) {
                try out.print("  {s}\n", .{finding.path});
            } else {
                try out.print("  {s}:{d}  {s} {s}\n", .{
                    finding.path,
                    finding.line,
                    finding.keyword,
                    finding.name,
                });
            }
        }
        if (printed != 0 and fails) failed = true;
    }
    try out.print("\ntidy: {d} files scanned, {d} findings\n", .{ file_count, findings.len });
    return failed;
}
