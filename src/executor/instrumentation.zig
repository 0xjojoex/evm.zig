const CaptureContext = @import("capture_context.zig").Context;

/// Non-consensus execution instrumentation selected for one borrowed scope.
pub const Mode = union(enum) {
    normal,
    observed,
    captured: *CaptureContext,

    pub fn observesState(self: Mode) bool {
        return self != .normal;
    }

    pub fn captureContext(self: Mode) ?*CaptureContext {
        return switch (self) {
            .normal, .observed => null,
            .captured => |context| context,
        };
    }
};
