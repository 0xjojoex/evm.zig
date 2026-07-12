const std = @import("std");

pub const Resolution = enum {
    never,
    always,
    runtime,
};

pub const OpcodeTier = enum {
    cold,
    hot,
};

pub const StaticGas = union(enum) {
    constant: i64,
    revision_bands: StaticGasBands,
};

pub const RevisionId = u16;

pub const max_static_gas_bands = 32;

pub const StaticGasBand = struct {
    since: RevisionId,
    gas: i64,
};

pub const StaticGasBands = struct {
    len: u8 = 0,
    items: [max_static_gas_bands]StaticGasBand = [_]StaticGasBand{.{ .since = 0, .gas = 0 }} ** max_static_gas_bands,

    pub fn from(comptime bands: anytype) StaticGasBands {
        var result = StaticGasBands{};
        inline for (bands) |band| {
            result.appendRevision(band.since, band.gas);
        }
        return result;
    }

    pub fn appendRevision(self: *StaticGasBands, revision_value: anytype, gas: i64) void {
        self.appendId(revisionId(revision_value), gas);
    }

    pub fn appendId(self: *StaticGasBands, since: RevisionId, gas: i64) void {
        if (self.len >= max_static_gas_bands) @panic("too many static gas revision bands");
        const index: usize = @intCast(self.len);
        self.items[index] = .{ .since = since, .gas = gas };
        self.len += 1;
    }
};

pub fn revisionId(revision_value: anytype) RevisionId {
    return @intCast(@intFromEnum(revision_value));
}

pub fn decodeRevision(comptime Revision: type, revision_id: RevisionId) Revision {
    const Tag = std.meta.Tag(Revision);
    const tag_value = std.math.cast(Tag, revision_id) orelse @panic("revision id does not fit definition revision tag");
    return std.enums.fromInt(Revision, tag_value) orelse @panic("revision id is not defined by definition revision enum");
}

pub fn revisionSupported(comptime Protocol: type, revision: Protocol.Revision) bool {
    if (!@hasDecl(Protocol, "support")) return true;
    return Protocol.support.contains(revision);
}

pub fn assertRevisionSupported(comptime Protocol: type, revision: Protocol.Revision) void {
    if (!@hasDecl(Protocol, "support")) return;
    if (!Protocol.support.contains(revision)) {
        std.debug.panic(
            "revision {s} is outside definition support window {s}..{s}",
            .{ @tagName(revision), @tagName(Protocol.support.min), @tagName(Protocol.support.max) },
        );
    }
}

pub fn revisionIdForProtocol(comptime Protocol: type, revision: Protocol.Revision) RevisionId {
    assertRevisionSupported(Protocol, revision);
    return revisionId(revision);
}

pub fn decodeRevisionForProtocol(comptime Protocol: type, revision_id: RevisionId) Protocol.Revision {
    const revision = decodeRevision(Protocol.Revision, revision_id);
    assertRevisionSupported(Protocol, revision);
    return revision;
}

pub fn ModelConfig(comptime Revision: type) type {
    return struct {
        revisions: ?[]const Revision = null,
        latest: ?Revision = null,
        stable: ?Revision = null,
        order: *const fn (Revision, Revision) std.math.Order = enumTagOrder(Revision),
        semantics: type = IdentitySemantics(Revision),
    };
}

pub fn Model(comptime Revision: type) type {
    return ModelWithConfig(Revision, .{});
}

pub fn ModelWithConfig(comptime Revision: type, comptime cfg: ModelConfig(Revision)) type {
    const default_revisions: []const Revision = std.enums.values(Revision);
    const configured_revisions = cfg.revisions orelse default_revisions;
    const configured_set = std.enums.EnumSet(Revision).initMany(configured_revisions);
    const Semantics = cfg.semantics;
    if (configured_revisions.len == 0) {
        @compileError("Revision.revisions must not be empty");
    }
    assertRevisionOrder(Revision, configured_revisions, cfg.order);
    assertSemantics(Revision, Semantics);
    const latest_revision = cfg.latest orelse configured_revisions[configured_revisions.len - 1];
    const stable_revision = cfg.stable orelse latest_revision;
    if (!configured_set.contains(latest_revision)) {
        @compileError("Revision.latest is not present in Revision.revisions: " ++ @tagName(latest_revision));
    }
    if (!configured_set.contains(stable_revision)) {
        @compileError("Revision.stable is not present in Revision.revisions: " ++ @tagName(stable_revision));
    }

    return struct {
        pub const revisions = configured_revisions;
        pub const latest = latest_revision;
        pub const stable = stable_revision;
        pub const RevisionSemantics = Semantics;
        pub const BaseRevision = Semantics.BaseRevision;

        pub fn order(a: Revision, b: Revision) std.math.Order {
            return cfg.order(a, b);
        }

        pub fn isImpl(current: Revision, required: Revision) bool {
            return includes(cfg.order, current, required);
        }

        pub fn baseRevision(revision: Revision) BaseRevision {
            return Semantics.baseRevision(revision);
        }

        pub fn isConfigured(revision: Revision) bool {
            return configured_set.contains(revision);
        }

        pub const Availability = union(enum) {
            never,
            always,
            since: Revision,
            gate: *const fn (Revision) bool,
        };

        pub const Support = struct {
            min: Revision = revisions[0],
            max: Revision = revisions[revisions.len - 1],

            pub const all: Support = .{};

            pub fn since(comptime min: Revision) Support {
                return .{ .min = min };
            }

            pub fn through(comptime max: Revision) Support {
                return .{ .max = max };
            }

            pub fn range(comptime min: Revision, comptime max: Revision) Support {
                return .{ .min = min, .max = max };
            }

            pub fn at(comptime revision: Revision) Support {
                return .{ .min = revision, .max = revision };
            }

            pub fn assertValid(comptime self: Support) void {
                if (comptime !isConfigured(self.min)) {
                    @compileError("definition support minimum is not configured: " ++ @tagName(self.min));
                }
                if (comptime !isConfigured(self.max)) {
                    @compileError("definition support maximum is not configured: " ++ @tagName(self.max));
                }
                if (comptime !includes(cfg.order, self.max, self.min)) {
                    @compileError("definition support window has max before min: " ++ @tagName(self.min) ++ ".." ++ @tagName(self.max));
                }
            }

            pub fn isValid(self: Support) bool {
                return isConfigured(self.min) and
                    isConfigured(self.max) and
                    includes(cfg.order, self.max, self.min);
            }

            pub fn contains(self: Support, revision: Revision) bool {
                return isConfigured(revision) and
                    includes(cfg.order, revision, self.min) and
                    includes(cfg.order, self.max, revision);
            }
        };

        pub fn resolveAvailability(comptime availability: Availability, comptime support: Support) Resolution {
            support.assertValid();
            return switch (availability) {
                .never => .never,
                .always => .always,
                .since => |activation| {
                    if (comptime includes(cfg.order, support.min, activation)) return .always;
                    if (comptime !includes(cfg.order, support.max, activation)) return .never;
                    return .runtime;
                },
                .gate => |active| {
                    var any_active = false;
                    var any_inactive = false;
                    inline for (revisions) |revision| {
                        if (comptime support.contains(revision)) {
                            if (comptime active(revision)) {
                                any_active = true;
                            } else {
                                any_inactive = true;
                            }
                        }
                    }
                    if (any_active and any_inactive) return .runtime;
                    if (any_active) return .always;
                    return .never;
                },
            };
        }
    };
}

pub fn IdentitySemantics(comptime Revision: type) type {
    return struct {
        pub const BaseRevision = Revision;

        pub fn baseRevision(revision: Revision) BaseRevision {
            return revision;
        }
    };
}

fn assertSemantics(comptime Revision: type, comptime Semantics: type) void {
    if (!@hasDecl(Semantics, "BaseRevision")) {
        @compileError("Revision semantics missing BaseRevision");
    }
    switch (@typeInfo(Semantics.BaseRevision)) {
        .@"enum" => {},
        else => @compileError("Revision semantics BaseRevision must be an enum"),
    }
    if (!std.meta.hasFn(Semantics, "baseRevision")) {
        @compileError("Revision semantics missing baseRevision");
    }

    const base_revision: *const fn (Revision) Semantics.BaseRevision = Semantics.baseRevision;
    _ = base_revision;
}

fn enumTagOrder(comptime Revision: type) *const fn (Revision, Revision) std.math.Order {
    return struct {
        fn f(a: Revision, b: Revision) std.math.Order {
            return std.math.order(@intFromEnum(a), @intFromEnum(b));
        }
    }.f;
}

fn includes(comptime orderFn: anytype, current: anytype, required: @TypeOf(current)) bool {
    return orderFn(current, required) != .lt;
}

fn assertRevisionOrder(
    comptime Revision: type,
    comptime revisions: []const Revision,
    comptime orderFn: *const fn (Revision, Revision) std.math.Order,
) void {
    @setEvalBranchQuota(100_000);
    inline for (revisions, 0..) |revision, index| {
        if (orderFn(revision, revision) != .eq) {
            @compileError("revision order must compare " ++ @tagName(revision) ++ " equal to itself");
        }
        inline for (revisions[index + 1 ..]) |later| {
            if (orderFn(revision, later) != .lt or orderFn(later, revision) != .gt) {
                @compileError("revision order disagrees with revisions sequence: " ++ @tagName(revision) ++ " before " ++ @tagName(later));
            }
        }
    }
}

test "support window resolves availability gates" {
    const Revision = @import("../eth/revision.zig").Revision;
    const revision = Model(Revision);
    const Support = revision.Support;
    const resolveAvailability = revision.resolveAvailability;

    try std.testing.expectEqual(Resolution.always, resolveAvailability(.{ .since = .cancun }, Support.since(.cancun)));
    try std.testing.expectEqual(Resolution.always, resolveAvailability(.{ .since = .shanghai }, Support.since(.cancun)));
    try std.testing.expectEqual(Resolution.runtime, resolveAvailability(.{ .since = .prague }, Support.since(.cancun)));
    try std.testing.expectEqual(Resolution.never, resolveAvailability(.{ .since = .prague }, Support.at(.cancun)));
    try std.testing.expectEqual(Resolution.runtime, resolveAvailability(.{ .since = .cancun }, Support.all));
    try std.testing.expectEqual(Resolution.always, resolveAvailability(.always, Support.at(.frontier)));
    try std.testing.expectEqual(Resolution.never, resolveAvailability(.never, Support.since(.amsterdam)));
}

test "support window contains specs inclusively" {
    const Revision = @import("../eth/revision.zig").Revision;
    const revision = Model(Revision);
    const Support = revision.Support;

    const cancun_plus = Support.since(.cancun);
    try std.testing.expect(cancun_plus.contains(.cancun));
    try std.testing.expect(cancun_plus.contains(.amsterdam));
    try std.testing.expect(!cancun_plus.contains(.shanghai));

    const exact_prague = Support.at(.prague);
    try std.testing.expect(exact_prague.contains(.prague));
    try std.testing.expect(!exact_prague.contains(.cancun));
    try std.testing.expect(!exact_prague.contains(.osaka));
}

test "support windows reject enum values omitted from the configured sequence" {
    const R = enum { alpha, beta, gamma };
    const revision = ModelWithConfig(R, .{
        .revisions = &.{ .alpha, .gamma },
    });
    const Support = revision.Support;
    const Protocol = struct {
        pub const Revision = R;
        pub const support = Support.all;
    };

    try std.testing.expect(revision.isConfigured(.alpha));
    try std.testing.expect(!revision.isConfigured(.beta));
    try std.testing.expect(revision.isConfigured(.gamma));
    try std.testing.expect(!Support.at(.beta).isValid());
    try std.testing.expect(!Support.all.contains(.beta));
    try std.testing.expect(!revisionSupported(Protocol, .beta));
}

test "protocol support check is conditional on support declaration" {
    const SpecRevision = @import("../eth/revision.zig").Revision;
    const revision = Model(SpecRevision);

    const CancunProtocol = struct {
        pub const Revision = SpecRevision;
        pub const support = revision.Support.at(.cancun);
    };
    try std.testing.expect(revisionSupported(CancunProtocol, .cancun));
    try std.testing.expect(!revisionSupported(CancunProtocol, .prague));

    const MinimalProtocol = struct {
        pub const Revision = SpecRevision;
    };
    try std.testing.expect(revisionSupported(MinimalProtocol, .prague));
}
