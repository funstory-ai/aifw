const std = @import("std");
const RegexRecognizer = @import("RegexRecognizer.zig");
const entity = @import("recog_entity.zig");

pub const PipelineKind = enum { mask, restore };

pub const Pipeline = struct {
    kind: PipelineKind,
    // optional regex recognizer plugged for mask pipeline
    recog: ?RegexRecognizer = null,

    pub fn run(self: *const Pipeline, input: []const u8, allocator: std.mem.Allocator) []u8 {
        _ = allocator; // placeholder
        switch (self.kind) {
            .mask => {
                std.log.info("[core-lib] mask pipeline invoked. input_len={d}", .{input.len});
                if (self.recog) |r| {
                    const ents = r.run(input) catch |e| {
                        std.log.warn("[core-lib] regex recognizer failed: {s}", .{@errorName(e)});
                        return @constCast(input);
                    };
                    defer r.allocator.free(ents);
                    std.log.info("[core-lib] regex matched {d} entities", .{ents.len});
                }
                return @constCast(input);
            },
            .restore => {
                std.log.info("[core-lib] restore pipeline invoked. input_len={d}", .{input.len});
                return @constCast(input);
            },
        }
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    mask_pipeline: Pipeline,
    restore_pipeline: Pipeline,

    pub fn init(allocator: std.mem.Allocator) !Session {
        std.log.info("[core-lib] session init", .{});
        // Build default recognizers by EntityType presets
        const validate_fn: ?*const fn ([]const u8) ?f32 = null;
        const recog = try RegexRecognizer.buildRecognizerFor(allocator, .EMAIL_ADDRESS, validate_fn);
        return Session{
            .allocator = allocator,
            .mask_pipeline = .{ .kind = .mask, .recog = recog },
            .restore_pipeline = .{ .kind = .restore },
        };
    }

    pub fn deinit(self: *Session) void {
        std.log.info("[core-lib] session deinit", .{});
        self.mask_pipeline.recog.?.deinit();
    }

    pub fn getPipeline(self: *Session, kind: PipelineKind) *Pipeline {
        return switch (kind) {
            .mask => &self.mask_pipeline,
            .restore => &self.restore_pipeline,
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}

// Minimal unit test
test "session and pipelines no-op" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.log.warn("[core-lib] allocator leak detected", .{});
    }
    const allocator = gpa.allocator();

    var session = try Session.init(allocator);
    defer session.deinit();

    const input = "Hello NER";
    const out_mask = session.getPipeline(.mask).run(input, allocator);
    try std.testing.expectEqualStrings(input, out_mask);

    const out_restore = session.getPipeline(.restore).run(input, allocator);
    try std.testing.expectEqualStrings(input, out_restore);
}
