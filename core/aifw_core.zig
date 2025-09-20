const std = @import("std");
const builtin = @import("builtin");
pub const RegexRecognizer = @import("RegexRecognizer.zig");
pub const NerRecognizer = @import("NerRecognizer.zig");
pub const NerRecogType = NerRecognizer.NerRecogType;
const entity = @import("recog_entity.zig");

const is_freestanding = builtin.target.os.tag == .freestanding;

// When targeting wasm32-freestanding, route std.log to an extern JS-provided logger.
// Otherwise, use Zig's default logger.
pub const std_options = std.Options{
    .log_level = .info,
    .logFn = logFn,
};

extern fn js_log(level: u8, ptr: [*]const u8, len: usize) void;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (is_freestanding) {
        var buf: [512]u8 = undefined;
        const prefix = switch (level) {
            .err => "[ERR] ",
            .warn => "[WRN] ",
            .info => "[INF] ",
            .debug => "[DBG] ",
        };
        var w = std.io.fixedBufferStream(&buf);
        const writer = w.writer();
        // best-effort formatting; ignore errors
        _ = writer.writeAll(prefix) catch {};
        _ = std.fmt.format(writer, format, args) catch {};
        const msg = w.getWritten();
        js_log(@intFromEnum(level), msg.ptr, msg.len);
        return;
    } else {
        // Hosted targets: use default logger
        std.log.defaultLog(level, scope, format, args);
    }
}

test {
    std.testing.refAllDecls(@This());
}

pub const PipelineKind = enum { mask, restore };

pub const RecogEntity = entity.RecogEntity;
pub const EntityType = entity.EntityType;
pub const NerRecogEntity = NerRecognizer.NerRecogEntity;

pub const PlaceholderMatchedPair = struct {
    // The entity_id and entity_type is placeholder's information
    entity_id: u32,
    entity_type: EntityType,

    // The matched_text is the text that matches the placeholder,
    // which is just a substring of the original text, no copy is made.
    matched_text: []const u8,
};

pub const MaskMetaData = struct {
    // The placeholder_dict is a dictionary of placeholder and matched text,
    // the key is the placeholder, the value is the matched text.
    placeholder_dict: []PlaceholderMatchedPair,

    pub fn deinit(self: *const MaskMetaData, allocator: std.mem.Allocator) void {
        allocator.free(self.placeholder_dict);
    }
};

pub const MaskInitArgs = struct {
    regex_list: []const RegexRecognizer,
    ner_recognizer: *const NerRecognizer,
};

pub const RestoreInitArgs = struct {
    // no args
};

pub const PipelineInitArgs = union(PipelineKind) {
    mask: MaskInitArgs,
    restore: RestoreInitArgs,
};

pub const MaskArgs = struct {
    original_text: [*:0]const u8,
    ner_data: NerRecognizer.NerRecogData, // external NER recognition results
};

pub const RestoreArgs = struct {
    masked_text: [*:0]const u8,
    mask_meta_data: MaskMetaData,
};

pub const PipelineArgs = union(PipelineKind) {
    mask: MaskArgs,
    restore: RestoreArgs,
};

pub const MaskResult = struct {
    masked_text: [*:0]u8,
    mask_meta_data: MaskMetaData,

    pub fn deinit(self: *const MaskResult, allocator: std.mem.Allocator) void {
        allocator.free(std.mem.span(self.masked_text));
        self.mask_meta_data.deinit(allocator);
    }
};

pub const RestoreResult = struct {
    restored_text: [*:0]u8,

    pub fn deinit(self: *const RestoreResult, allocator: std.mem.Allocator) void {
        allocator.free(std.mem.span(self.restored_text));
    }
};

pub const PipelineResult = union(PipelineKind) {
    mask: MaskResult,
    restore: RestoreResult,

    pub fn deinit(self: *const PipelineResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .mask => self.mask.deinit(allocator),
            .restore => self.restore.deinit(allocator),
        }
    }
};

pub const Pipeline = union(PipelineKind) {
    mask: MaskPipeline,
    restore: RestorePipeline,

    pub fn init(allocator: std.mem.Allocator, init_args: PipelineInitArgs) Pipeline {
        return switch (init_args) {
            .mask => .{ .mask = MaskPipeline.init(allocator, init_args.mask) },
            .restore => .{ .restore = RestorePipeline.init(allocator, init_args.restore) },
        };
    }

    pub fn deinit(self: *const Pipeline) void {
        switch (self.*) {
            .mask => self.mask.deinit(),
            .restore => self.restore.deinit(),
        }
    }

    pub fn run(self: *const Pipeline, args: PipelineArgs) !PipelineResult {
        switch (self.*) {
            .mask => return self.mask.run(args.mask),
            .restore => return self.restore.run(args.restore),
        }
    }
};

pub const MaskPipeline = struct {
    allocator: std.mem.Allocator,
    // components
    regex_list: []const RegexRecognizer,
    ner_recognizer: *const NerRecognizer,

    pub fn init(allocator: std.mem.Allocator, init_args: MaskInitArgs) MaskPipeline {
        return .{
            .allocator = allocator,
            .regex_list = init_args.regex_list,
            .ner_recognizer = init_args.ner_recognizer,
        };
    }

    pub fn deinit(self: *const MaskPipeline) void {
        for (self.regex_list) |r| r.deinit();
        self.ner_recognizer.deinit();
        self.allocator.free(self.regex_list);
    }

    pub fn run(self: *const MaskPipeline, args: MaskArgs) !PipelineResult {
        const original_text = std.mem.span(args.original_text);
        // 1) Tokenizer (optional) - skipped
        // 2) Regex recognizers
        var merged = try std.ArrayList(RecogEntity).initCapacity(self.allocator, 4);
        defer merged.deinit(self.allocator);
        // from regex
        for (self.regex_list) |r| {
            const regex_ents = try r.run(original_text);
            // append
            try merged.appendSlice(self.allocator, regex_ents);
            self.allocator.free(regex_ents);
        }
        // 3) NER results from args
        const ner_ents = try self.ner_recognizer.run(args.ner_data);
        try merged.appendSlice(self.allocator, ner_ents);
        self.allocator.free(ner_ents);

        // 4) SpanMerger: sort, dedup by range, filter by score >= 0.5
        const spans = try merged.toOwnedSlice(self.allocator);
        defer self.allocator.free(spans);
        std.sort.block(RecogEntity, spans, {}, struct {
            fn lessThan(_: void, a: RecogEntity, b: RecogEntity) bool {
                return if (a.start == b.start) a.end < b.end else a.start < b.start;
            }
        }.lessThan);

        var filtered = try std.ArrayList(RecogEntity).initCapacity(self.allocator, spans.len);
        defer filtered.deinit(self.allocator);
        var i: usize = 0;
        while (i < spans.len) : (i += 1) {
            const cur = spans[i];
            if (cur.score < 0.5) continue;
            if (filtered.items.len == 0) {
                try filtered.append(self.allocator, cur);
            } else {
                const last = filtered.items[filtered.items.len - 1];
                if (cur.start == last.start and cur.end == last.end) {
                    if (cur.score > last.score) filtered.items[filtered.items.len - 1] = cur;
                } else {
                    try filtered.append(self.allocator, cur);
                }
            }
        }
        const final_spans = try filtered.toOwnedSlice(self.allocator);
        defer self.allocator.free(final_spans);

        // 5) Anonymizer: build masked text with placeholders
        var out_buf = try std.ArrayList(u8).initCapacity(self.allocator, original_text.len);
        errdefer out_buf.deinit(self.allocator);
        var placeholder_dict = try std.ArrayList(PlaceholderMatchedPair).initCapacity(self.allocator, final_spans.len);
        errdefer placeholder_dict.deinit(self.allocator);

        var pos: usize = 0;
        var idx: u32 = 0;
        while (idx < final_spans.len) : (idx += 1) {
            const span_start = final_spans[idx].start;
            const span_end = final_spans[idx].end;
            if (span_start > pos) try out_buf.appendSlice(self.allocator, original_text[pos..span_start]);
            var ph_buf: [PLACEHOLDER_MAX_LEN]u8 = undefined;
            const ph_text = try writePlaceholder(ph_buf[0..], final_spans[idx].entity_type, idx);
            try out_buf.appendSlice(self.allocator, ph_text);
            try placeholder_dict.append(self.allocator, .{
                .entity_id = idx,
                .entity_type = final_spans[idx].entity_type,
                .matched_text = original_text[span_start..span_end],
            });
            pos = span_end;
        }
        if (pos < original_text.len) try out_buf.appendSlice(self.allocator, original_text[pos..]);

        // add sentinel for masked text
        try out_buf.append(self.allocator, 0);
        const masked_text = try out_buf.toOwnedSlice(self.allocator);
        return .{
            .mask = .{
                .masked_text = @as([*:0]u8, @ptrCast(masked_text.ptr)),
                .mask_meta_data = .{
                    .placeholder_dict = try placeholder_dict.toOwnedSlice(self.allocator),
                },
            },
        };
    }
};

pub const RestorePipeline = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, init_args: RestoreInitArgs) RestorePipeline {
        _ = init_args;
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *const RestorePipeline) void {
        _ = self;
    }

    pub fn run(self: *const RestorePipeline, args: RestoreArgs) !PipelineResult {
        // naive restore: sequentially replace placeholders with originals in order
        const masked_text = std.mem.span(args.masked_text);
        var out = try std.ArrayList(u8).initCapacity(self.allocator, masked_text.len);
        defer out.deinit(self.allocator);
        var pos: usize = 0;
        for (args.mask_meta_data.placeholder_dict) |item| {
            if (pos < masked_text.len) {
                // find placeholder occurrence from current pos
                var ph_buf: [PLACEHOLDER_MAX_LEN]u8 = undefined;
                const ph_text = try writePlaceholder(ph_buf[0..], item.entity_type, item.entity_id);
                const found = std.mem.indexOfPos(u8, masked_text, pos, ph_text);
                if (found) |ph_pos| {
                    if (ph_pos > pos) try out.appendSlice(self.allocator, masked_text[pos..ph_pos]);
                    try out.appendSlice(self.allocator, item.matched_text);
                    pos = ph_pos + ph_text.len;
                }
            }
        }
        if (pos < masked_text.len) try out.appendSlice(self.allocator, masked_text[pos..]);

        // add sentinel for restored text
        try out.append(self.allocator, 0);
        const restored_text = try out.toOwnedSlice(self.allocator);
        return .{ .restore = .{ .restored_text = @as([*:0]u8, @ptrCast(restored_text.ptr)) } };
    }
};

fn maxPlaceholderLen() comptime_int {
    const fields = std.meta.fields(EntityType);
    comptime var max_name_len: usize = 0;
    inline for (fields) |f| {
        if (f.name.len > max_name_len) max_name_len = f.name.len;
    }
    // "__PII_" + name + "_" + 8 hex + "__"
    return 6 + max_name_len + 1 + 8 + 2;
}

const PLACEHOLDER_MAX_LEN: usize = maxPlaceholderLen();

fn writePlaceholder(buf: []u8, t: EntityType, serial: u32) ![]u8 {
    return std.fmt.bufPrint(buf, "__PII_{s}_{X:0>8}__", .{ @tagName(t), serial });
}

pub const SessionInitArgs = extern struct {
    ner_recog_type: NerRecogType,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    mask_meta_data: ?MaskMetaData = null,
    mask_pipeline: Pipeline,
    restore_pipeline: Pipeline,

    pub fn init(allocator: std.mem.Allocator, init_args: SessionInitArgs) !Session {
        std.log.info("[core-lib] session init", .{});
        // Build recognizers set (email/url/phone/bank)
        const types = [_]EntityType{ .EMAIL_ADDRESS, .URL_ADDRESS, .PHONE_NUMBER, .BANK_NUMBER };
        var list = try std.ArrayList(RegexRecognizer).initCapacity(allocator, types.len);
        errdefer {
            for (list.items) |r| r.deinit();
            list.deinit(allocator);
        }
        for (types) |t| {
            const r = try RegexRecognizer.buildRecognizerFor(allocator, t, null);
            list.appendAssumeCapacity(r);
        }
        const regex_list = try list.toOwnedSlice(allocator);
        const ner_recognizer = NerRecognizer.init(allocator, init_args.ner_recog_type);
        const mask_pipeline = Pipeline.init(allocator, .{
            .mask = .{
                .regex_list = regex_list,
                .ner_recognizer = &ner_recognizer,
            },
        });
        const restore_pipeline = Pipeline.init(allocator, .{
            .restore = .{},
        });
        return .{ .allocator = allocator, .mask_pipeline = mask_pipeline, .restore_pipeline = restore_pipeline };
    }

    pub fn deinit(self: *Session) void {
        self.mask_pipeline.deinit();
        self.restore_pipeline.deinit();
        if (self.mask_meta_data) |meta_data| meta_data.deinit(self.allocator);
    }

    pub fn getPipeline(self: *Session, kind: PipelineKind) *Pipeline {
        return switch (kind) {
            .mask => &self.mask_pipeline,
            .restore => &self.restore_pipeline,
        };
    }

    pub fn mask(self: *Session, text: [*:0]const u8, ner_entities: []const NerRecogEntity) ![*:0]u8 {
        const mask_result = (try self.getPipeline(.mask).run(.{ .mask = .{
            .original_text = text,
            .ner_data = .{
                .text = text,
                .ner_entities = ner_entities.ptr,
                .ner_entity_count = ner_entities.len,
            },
        } })).mask;
        self.mask_meta_data = mask_result.mask_meta_data;
        return mask_result.masked_text;
    }

    pub fn restore(self: *Session, text: [*:0]const u8) ![*:0]u8 {
        defer {
            self.mask_meta_data.?.deinit(self.allocator);
            self.mask_meta_data = null;
        }
        return (try self.getPipeline(.restore).run(.{ .restore = .{
            .masked_text = text,
            .mask_meta_data = self.mask_meta_data.?,
        } })).restore.restored_text;
    }
};

test "session mask/restore" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.log.warn("[core-lib] allocator leak detected", .{});
    }
    const allocator = gpa.allocator();
    var session = try Session.init(allocator, .{ .ner_recog_type = .token_classification });
    defer session.deinit();

    const input = "Contact me: a.b+1@test.io and visit https://ziglang.org";
    const masked_text = try session.mask(input, &[_]NerRecogEntity{});
    std.debug.print("masked={s}\n", .{masked_text});
    defer allocator.free(std.mem.span(masked_text));

    const restored_text = try session.restore(masked_text);
    std.debug.print("restored={s}\n", .{restored_text});
    defer allocator.free(std.mem.span(restored_text));
    try std.testing.expect(std.mem.eql(u8, std.mem.span(restored_text), input));
}

/// Global allocator selection
/// - Debug (hosted): GeneralPurposeAllocator
/// - Freestanding: FixedBufferAllocator
/// - Release hosted: page_allocator
const is_debug = builtin.mode == .Debug;

const HEAP_SIZE: usize = if (is_freestanding) 8 * 1024 * 1024 else 0; // 8 MiB for freestanding
var fb_mem: [HEAP_SIZE]u8 align(16) = undefined;

var gpa_inst = if (is_freestanding)
    std.heap.FixedBufferAllocator.init(&fb_mem)
else if (is_debug)
    std.heap.GeneralPurposeAllocator(.{}){}
else
    std.heap.SmpAllocator{};

fn globalAllocator() std.mem.Allocator {
    return gpa_inst.allocator();
}

fn globalAllocatorDeinit() void {
    if (!is_freestanding and is_debug) {
        _ = gpa_inst.deinit();
    }
}

/// ----- C API -----
pub export fn getErrorString(err_no: u16) [*:0]const u8 {
    const err = @errorFromInt(err_no);
    return @errorName(err);
}

/// C wrapper for Session
pub export fn aifw_session_create(init_args: *const SessionInitArgs) *allowzero anyopaque {
    const allocator = globalAllocator();
    const session = allocator.create(Session) catch return @ptrFromInt(0);
    session.* = Session.init(allocator, init_args.*) catch {
        allocator.destroy(session);
        return @ptrFromInt(0);
    };
    return session;
}

pub export fn aifw_session_destroy(session_ptr: *allowzero anyopaque) void {
    if (@intFromPtr(session_ptr) == 0) return;

    const session: *Session = @as(*Session, @ptrCast(@alignCast(session_ptr)));
    session.deinit();
    globalAllocator().destroy(session);
    globalAllocatorDeinit();
}

pub export fn aifw_session_mask(
    session_ptr: *allowzero anyopaque,
    c_text: [*:0]const u8,
    ner_entities: [*c]const NerRecogEntity,
    ner_entity_count: c_ulonglong,
    out_masked_text: *[*:0]u8,
) u16 {
    if (@intFromPtr(session_ptr) == 0) return @intFromError(error.InvalidSessionPtr);

    const session: *Session = @as(*Session, @ptrCast(@alignCast(session_ptr)));
    const ner_entities_slice = ner_entities[0..@intCast(ner_entity_count)];
    const masked_text = session.mask(c_text, ner_entities_slice) catch |err| {
        return @intFromError(err);
    };
    out_masked_text.* = masked_text;
    return 0;
}

pub export fn aifw_session_restore(
    session_ptr: *allowzero anyopaque,
    c_text: [*:0]const u8,
    out_restored_text: *[*:0]u8,
) u16 {
    if (@intFromPtr(session_ptr) == 0) return @intFromError(error.InvalidSessionPtr);

    const session: *Session = @as(*Session, @ptrCast(@alignCast(session_ptr)));
    const restored_text = session.restore(c_text) catch |err| {
        return @intFromError(err);
    };
    out_restored_text.* = restored_text;
    return 0;
}

/// Free a NUL-terminated string allocated by the core (masked/restored text)
pub export fn aifw_string_free(str: [*:0]u8) void {
    globalAllocator().free(std.mem.span(str));
}
