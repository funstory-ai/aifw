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
        // const prefix = switch (level) {
        //     .err => "[ERR] ",
        //     .warn => "[WRN] ",
        //     .info => "[INF] ",
        //     .debug => "[DBG] ",
        // };
        var w = std.io.fixedBufferStream(&buf);
        const writer = w.writer();
        // best-effort formatting; ignore errors
        // _ = writer.writeAll(prefix) catch {};
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

pub const MatchedPIISpan = extern struct {
    /// The entity_id is the id of the PII entity, it's unique within the placeholder_dict.
    entity_id: u32,
    /// The entity_type is the type of the PII entity.
    entity_type: EntityType,

    /// The matched_start and matched_end is the range of the matched text in the original text.
    /// The matched text is the substring of the original text[matched_start..matched_end].
    matched_start: u32,
    matched_end: u32,
};

pub const PlaceholderMatchedPair = struct {
    // The entity_id and entity_type is placeholder's information
    entity_id: u32,
    entity_type: EntityType,

    /// The matched text is substring of original text, it is pointer to serialed data
    matched_text: []const u8,
};

pub const MaskMetaData = struct {
    /// The referenced_text is referenced by PII span in matched_pii_spans, the
    /// matched_start and matched_end are index in referenced_text. It's used to
    /// restore the masked_text.
    /// The referenced_text maybe a original text input by the user, or maybe a
    /// serialized PlaceholderMatchedPairs.
    referenced_text: []const u8,

    /// The PII spans slice, every PII span is recognized by RegexRecognizer or NerRecognizer.
    /// The matched_start and matched_end is a index in original_text
    matched_pii_spans: []const MatchedPIISpan,

    /// The matched_pii_spans is owned by the MaskMetaData, if is_owned_pii_spans is true,
    /// then it must to free the matched_pii_spans in deinit function.
    is_owned_pii_spans: bool,

    pub fn deinit(self: *const MaskMetaData, allocator: std.mem.Allocator) void {
        if (self.is_owned_pii_spans) {
            allocator.free(self.matched_pii_spans);
        }
    }
};

fn serialize_mask_meta_data(allocator: std.mem.Allocator, mask_meta_data: MaskMetaData) ![]u8 {
    // serialized MaskMetaData layout:
    // [u32 total_len][u32 text_len][text bytes][padding][spans]
    // - text bytes are concatenation of matched slices
    // - spans aligned to @alignOf(MatchedPIISpan) from offset 4 + 4 + text_len

    // Calculate the serialized MaskMetaData length and allocate the buffer
    const span_align = @alignOf(MatchedPIISpan);
    const spans_count = mask_meta_data.matched_pii_spans.len;
    const spans_bytes: usize = @sizeOf(MatchedPIISpan) * spans_count;

    var total_span_text_len: usize = 0;
    for (mask_meta_data.matched_pii_spans) |span| {
        const span_text_len = span.matched_end - span.matched_start;
        total_span_text_len += span_text_len;
    }
    const concated_text_len: usize = total_span_text_len;

    const buf_len = @sizeOf(u32) + @sizeOf(u32) + concated_text_len + span_align + spans_bytes;
    var serialized_mask_meta_data = try allocator.alloc(u8, buf_len);
    errdefer allocator.free(serialized_mask_meta_data);

    // write buf_len and text_len
    const buf_len_slize = serialized_mask_meta_data[0..@sizeOf(u32)];
    const buf_len_fixed: *[@sizeOf(u32)]u8 = @ptrCast(buf_len_slize.ptr);
    std.mem.writeInt(u32, buf_len_fixed, @intCast(buf_len), .little);

    const text_len_slize = serialized_mask_meta_data[@sizeOf(u32) .. @sizeOf(u32) + @sizeOf(u32)];
    const text_len_fixed: *[@sizeOf(u32)]u8 = @ptrCast(text_len_slize.ptr);
    std.mem.writeInt(u32, text_len_fixed, @intCast(concated_text_len), .little);

    // Compute sizes for layout
    const header_len: usize = @sizeOf(u32) + @sizeOf(u32); // u32 buf_len and u32 text_len
    const concated_text = serialized_mask_meta_data[header_len .. header_len + concated_text_len];
    const spans_start: usize = std.mem.alignForward(usize, header_len + concated_text_len, span_align);
    const spans_byte_ptr: [*]u8 = serialized_mask_meta_data.ptr + spans_start;
    const spans_ptr: [*]MatchedPIISpan = @ptrCast(@alignCast(spans_byte_ptr));
    const remapped_spans: []MatchedPIISpan = spans_ptr[0..spans_count];
    const total_len = spans_start + spans_bytes;
    std.debug.assert(total_len <= buf_len);

    // Remap spans to the concatenated text
    var cursor: usize = 0;
    for (mask_meta_data.matched_pii_spans, 0..) |span, i| {
        const s: usize = span.matched_start;
        const e: usize = span.matched_end;
        const span_text_len = e - s;
        if (e > s and e <= mask_meta_data.referenced_text.len) {
            const slice = mask_meta_data.referenced_text[s..e];
            @memcpy(concated_text[cursor .. cursor + slice.len], slice);
        }
        remapped_spans[i] = .{
            .entity_id = span.entity_id,
            .entity_type = span.entity_type,
            .matched_start = @intCast(cursor),
            .matched_end = @intCast(cursor + span_text_len),
        };
        cursor += span_text_len;
    }

    return serialized_mask_meta_data;
}

fn deserialize_mask_meta_data(serialized_mask_meta_data: []const u8) MaskMetaData {
    // serialized MaskMetaData layout:
    // [u32 total_len][u32 text_len][text bytes][padding][spans]
    // - text bytes are concatenation of matched slices
    // - spans aligned to @alignOf(MatchedPIISpan) from offset 4 + 4 + text_len

    if (serialized_mask_meta_data.len < 4) {
        return MaskMetaData{
            .referenced_text = &[_]u8{},
            .matched_pii_spans = &[_]MatchedPIISpan{},
            .is_owned_pii_spans = false,
        };
    }

    const buf_len = std.mem.readInt(u32, serialized_mask_meta_data[0..@sizeOf(u32)], .little);
    const total_len: usize = serialized_mask_meta_data.len;
    std.debug.assert(buf_len == total_len);

    const text_len: usize = std.mem.readInt(u32, serialized_mask_meta_data[@sizeOf(u32) .. @sizeOf(u32) + @sizeOf(u32)], .little);
    const text_start: usize = @sizeOf(u32) + @sizeOf(u32);
    const text_end: usize = text_start + text_len;
    std.debug.assert(text_end < total_len);
    if (text_end >= total_len) {
        std.log.warn("[deserialize_mask_meta_data] text_end > total_len: text_end={d} total_len={d}", .{ text_end, total_len });
        return MaskMetaData{
            .referenced_text = &[_]u8{},
            .matched_pii_spans = &[_]MatchedPIISpan{},
            .is_owned_pii_spans = false,
        };
    }

    const span_align = @alignOf(MatchedPIISpan);
    const spans_start: usize = std.mem.alignForward(usize, text_end, span_align);
    std.debug.assert(spans_start < total_len);
    if ((spans_start >= total_len) or (spans_start + @sizeOf(MatchedPIISpan) > total_len)) {
        std.log.warn("[deserialize_mask_meta_data] spans_start >= total_len or not enough space for span: spans_start={d} total_len={d}", .{ spans_start, total_len });
        return MaskMetaData{
            .referenced_text = &[_]u8{},
            .matched_pii_spans = &[_]MatchedPIISpan{},
            .is_owned_pii_spans = false,
        };
    }

    const span_size: usize = @sizeOf(MatchedPIISpan);
    const available: usize = total_len - spans_start;
    std.debug.assert(available >= span_size);

    const referenced_text = serialized_mask_meta_data[text_start..text_end];
    const spans_count: usize = if (span_size == 0) 0 else available / span_size;
    const base_ptr: [*]const u8 = serialized_mask_meta_data.ptr;
    const spans_byte_ptr: [*]const u8 = base_ptr + spans_start;
    const spans_ptr: [*]const MatchedPIISpan = @ptrCast(@alignCast(spans_byte_ptr));
    const spans: []const MatchedPIISpan = spans_ptr[0..spans_count];

    return MaskMetaData{
        .referenced_text = referenced_text,
        .matched_pii_spans = spans,
        .is_owned_pii_spans = false,
    };
}

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
        // ner_recognizer is owned by Session; do not deinit here
        self.allocator.free(self.regex_list);
    }

    pub fn run(self: *const MaskPipeline, args: MaskArgs) !PipelineResult {
        const original_text = std.mem.span(args.original_text);
        std.log.debug("[mask] ner ents from ner_data: {any}", .{args.ner_data});
        // 1) Tokenizer (optional) - skipped
        // 2) Regex recognizers
        var merged = try std.ArrayList(RecogEntity).initCapacity(self.allocator, 4);
        defer merged.deinit(self.allocator);
        // from regex
        for (self.regex_list) |r| {
            const regex_ents = try r.run(original_text);
            std.log.debug("[mask] regex ents += {d}", .{regex_ents.len});
            // append
            try merged.appendSlice(self.allocator, regex_ents);
            self.allocator.free(regex_ents);
        }
        // 3) NER results from args
        const ner_ents = try self.ner_recognizer.run(args.ner_data);
        std.log.debug("[mask] ner ents += {d}", .{ner_ents.len});
        try merged.appendSlice(self.allocator, ner_ents);
        self.allocator.free(ner_ents);

        // 4) SpanMerger: sort, dedup by range, filter by score >= 0.5
        const spans = try merged.toOwnedSlice(self.allocator);
        defer self.allocator.free(spans);
        std.log.debug("[mask] spans before sort/filter: {d}", .{spans.len});
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
        std.log.debug("[mask] final spans: {d}", .{final_spans.len});

        // 5) Anonymizer: build masked text with placeholders
        var out_buf = try std.ArrayList(u8).initCapacity(self.allocator, original_text.len);
        errdefer out_buf.deinit(self.allocator);
        var matched_pii_spans = try std.ArrayList(MatchedPIISpan).initCapacity(self.allocator, final_spans.len);
        errdefer matched_pii_spans.deinit(self.allocator);

        var pos: usize = 0;
        var idx: u32 = 0;
        while (idx < final_spans.len) : (idx += 1) {
            const span_start = final_spans[idx].start;
            const span_end = final_spans[idx].end;
            // Strict bounds/validity checks to avoid corrupt spans
            if (span_end > original_text.len or span_start >= span_end) {
                std.log.warn("[mask] skip invalid span idx={d} start={d} end={d} len={d}", .{ idx, span_start, span_end, original_text.len });
                continue;
            }
            if (span_start > pos) try out_buf.appendSlice(self.allocator, original_text[pos..span_start]);

            var ph_buf: [PLACEHOLDER_MAX_LEN]u8 = undefined;
            const entity_id = idx + 1;
            const ph_text = try writePlaceholder(ph_buf[0..], final_spans[idx].entity_type, entity_id);
            try out_buf.appendSlice(self.allocator, ph_text);
            try matched_pii_spans.append(self.allocator, .{
                .entity_id = entity_id,
                .entity_type = final_spans[idx].entity_type,
                .matched_start = span_start,
                .matched_end = span_end,
            });
            pos = span_end;
        }
        if (pos < original_text.len) try out_buf.appendSlice(self.allocator, original_text[pos..]);

        // add sentinel for masked text
        try out_buf.append(self.allocator, 0);
        const masked_text = try out_buf.toOwnedSlice(self.allocator);
        std.log.debug("[mask] done, out_len={d}, placeholders={d}", .{ masked_text.len, matched_pii_spans.items.len });
        return .{
            .mask = .{
                .masked_text = @as([*:0]u8, @ptrCast(masked_text.ptr)),
                .mask_meta_data = .{
                    .referenced_text = original_text,
                    .matched_pii_spans = try matched_pii_spans.toOwnedSlice(self.allocator),
                    .is_owned_pii_spans = true,
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
        std.log.debug("[restore] begin masked_len={d} spans_count={d}", .{ masked_text.len, args.mask_meta_data.matched_pii_spans.len });
        var out = try std.ArrayList(u8).initCapacity(self.allocator, masked_text.len);
        defer out.deinit(self.allocator);
        var pos: usize = 0;
        for (args.mask_meta_data.matched_pii_spans) |item| {
            if (pos < masked_text.len) {
                // find placeholder occurrence from current pos
                var ph_buf: [PLACEHOLDER_MAX_LEN]u8 = undefined;
                const ph_text = try writePlaceholder(ph_buf[0..], item.entity_type, item.entity_id);
                const found = std.mem.indexOfPos(u8, masked_text, pos, ph_text);
                if (found) |ph_pos| {
                    if (ph_pos > pos) try out.appendSlice(self.allocator, masked_text[pos..ph_pos]);
                    try out.appendSlice(self.allocator, args.mask_meta_data.referenced_text[item.matched_start..item.matched_end]);
                    pos = ph_pos + ph_text.len;
                } else {
                    std.log.warn("[restore] placeholder not found: entity_id={d}", .{item.entity_id});
                }
            }
        }
        if (pos < masked_text.len) try out.appendSlice(self.allocator, masked_text[pos..]);

        // add sentinel for restored text
        try out.append(self.allocator, 0);
        const restored_text = try out.toOwnedSlice(self.allocator);
        std.log.debug("[restore] done, out_len={d}", .{restored_text.len});
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

// Here has a self-reference pointer to ner_recognizer, so the session must be allocated by create().
// If you call init() to initialize the session, you can not copy the session to another variable.
pub const Session = struct {
    allocator: std.mem.Allocator,
    mask_meta_data: ?MaskMetaData = null,
    ner_recognizer: NerRecognizer,
    mask_pipeline: Pipeline,
    restore_pipeline: Pipeline,

    pub fn create(allocator: std.mem.Allocator, init_args: SessionInitArgs) !*Session {
        std.log.info("[core-lib] session create", .{});
        var session = try allocator.create(Session);
        errdefer allocator.destroy(session);
        try session.init(allocator, init_args);
        return session;
    }

    pub fn init(self: *Session, allocator: std.mem.Allocator, init_args: SessionInitArgs) !void {
        // Deprecated for internal use when storing self-pointers; prefer create().
        std.log.info("[core-lib] session init", .{});
        // Build recognizers set (email/url/phone/bank)
        const types = [_]EntityType{ .EMAIL_ADDRESS, .URL_ADDRESS, .PHONE_NUMBER, .BANK_NUMBER };
        var list = try std.ArrayList(RegexRecognizer).initCapacity(allocator, types.len);
        errdefer {
            for (list.items) |r| r.deinit();
            list.deinit(allocator);
        }
        for (types) |t| {
            const empty_specs = &[_]RegexRecognizer.PatternSpec{};
            // empty specs means use default static compiled regexs in RegexRecognizer.
            const r = try RegexRecognizer.init(allocator, empty_specs, t, null);
            list.appendAssumeCapacity(r);
        }
        const regex_list = try list.toOwnedSlice(allocator);

        // NOTE: Returning by value makes inner self-pointers unstable; use create() instead.
        self.* = .{
            .allocator = allocator,
            .mask_meta_data = null,
            .ner_recognizer = NerRecognizer.init(allocator, init_args.ner_recog_type),
            .mask_pipeline = undefined,
            .restore_pipeline = undefined,
        };
        self.mask_pipeline = Pipeline.init(allocator, .{
            .mask = .{
                .regex_list = regex_list,
                .ner_recognizer = &self.ner_recognizer,
            },
        });
        self.restore_pipeline = Pipeline.init(allocator, .{ .restore = .{} });
    }

    pub fn destroy(self: *Session) void {
        self.deinit();
        self.allocator.destroy(self);
    }

    pub fn deinit(self: *Session) void {
        self.mask_pipeline.deinit();
        self.restore_pipeline.deinit();
        self.ner_recognizer.deinit();
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
                .ner_entity_count = @intCast(ner_entities.len),
            },
        } })).mask;
        self.mask_meta_data = mask_result.mask_meta_data;
        return mask_result.masked_text;
    }

    pub fn mask_and_out_meta(self: *Session, text: [*:0]const u8, ner_entities: []const NerRecogEntity, out_mask_meta_data: **anyopaque) ![*:0]u8 {
        const mask_result = (try self.getPipeline(.mask).run(.{ .mask = .{
            .original_text = text,
            .ner_data = .{
                .text = text,
                .ner_entities = ner_entities.ptr,
                .ner_entity_count = @intCast(ner_entities.len),
            },
        } })).mask;
        const serialized_mask_meta_data = try serialize_mask_meta_data(self.allocator, mask_result.mask_meta_data);
        out_mask_meta_data.* = @alignCast(@as(*anyopaque, @ptrCast(serialized_mask_meta_data.ptr)));
        mask_result.mask_meta_data.deinit(self.allocator);
        return mask_result.masked_text;
    }

    /// Get matched PII spans that recognized by RegexRecognizer and NerRecognizer.
    /// The matched_start and matched_end is index in parameter text. So you must
    /// keep alive the parameter text when you use the returned PII spans.
    /// You must free the returned PII spans when you no longer using it.
    pub fn get_pii_spans(self: *Session, text: [*:0]const u8, ner_entities: []const NerRecogEntity) ![]const MatchedPIISpan {
        const mask_result = (try self.getPipeline(.mask).run(.{ .mask = .{
            .original_text = text,
            .ner_data = .{
                .text = text,
                .ner_entities = ner_entities.ptr,
                .ner_entity_count = @intCast(ner_entities.len),
            },
        } })).mask;
        // Avoid leaking masked_text from the mask path; caller will free spans.
        self.allocator.free(std.mem.span(mask_result.masked_text));
        return mask_result.mask_meta_data.matched_pii_spans;
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

    pub fn restore_with_meta(self: *Session, text: [*:0]const u8, mask_meta_data_ptr: *const anyopaque) ![*:0]u8 {
        const serialized_mask_meta_data_ptr = @as([*]const u8, @ptrCast(@alignCast(mask_meta_data_ptr)));
        const len = std.mem.readInt(u32, serialized_mask_meta_data_ptr[0..4], .little);
        const serialized_mask_meta_data = serialized_mask_meta_data_ptr[0..len];
        defer self.allocator.free(serialized_mask_meta_data);
        const mask_meta_data = deserialize_mask_meta_data(serialized_mask_meta_data);
        defer mask_meta_data.deinit(self.allocator);

        return (try self.getPipeline(.restore).run(.{ .restore = .{
            .masked_text = text,
            .mask_meta_data = mask_meta_data,
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
    const session = try Session.create(allocator, .{ .ner_recog_type = .token_classification });
    defer session.destroy();

    const input = "Contact me: a.b+1@test.io and visit https://ziglang.org, my name is John Doe.";
    const ner_entities = [_]NerRecogEntity{
        .{ .entity_type = .USER_MAME, .entity_tag = .Begin, .score = 0.98, .index = 10, .start = 68, .end = 77 },
    };
    const masked_text = try session.mask(input, &ner_entities);
    defer allocator.free(std.mem.span(masked_text));

    const restored_text = try session.restore(masked_text);
    defer allocator.free(std.mem.span(restored_text));
    errdefer std.debug.print("masked={s}\n", .{masked_text});
    errdefer std.debug.print("restored={s}\n", .{restored_text});
    try std.testing.expect(std.mem.eql(u8, std.mem.span(restored_text), input));
}

test "session mask/restore with meta" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.log.warn("[core-lib] allocator leak detected", .{});
    }
    const allocator = gpa.allocator();

    const session = try Session.create(allocator, .{ .ner_recog_type = .token_classification });
    defer session.destroy();

    const input = "Contact me: a.b+1@test.io and visit https://ziglang.org, my name is John Doe.";
    const ner_entities = [_]NerRecogEntity{
        .{ .entity_type = .USER_MAME, .entity_tag = .Begin, .score = 0.98, .index = 10, .start = 68, .end = 77 },
    };

    var out_meta_ptr: *anyopaque = undefined;
    const masked_text = try session.mask_and_out_meta(input, &ner_entities, &out_meta_ptr);
    defer allocator.free(std.mem.span(masked_text));

    const restored_text = try session.restore_with_meta(masked_text, out_meta_ptr);
    defer allocator.free(std.mem.span(restored_text));
    errdefer std.debug.print("masked={s}\n", .{masked_text});
    errdefer std.debug.print("restored={s}\n", .{restored_text});

    try std.testing.expect(std.mem.eql(u8, std.mem.span(restored_text), input));
}

test "session get PII spans" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.log.warn("[core-lib] allocator leak detected", .{});
    }
    const allocator = gpa.allocator();

    const session = try Session.create(allocator, .{ .ner_recog_type = .token_classification });
    defer session.destroy();

    const input = "Contact me: a.b+1@test.io and visit https://ziglang.org, my name is John Doe.";
    const ner_entities = [_]NerRecogEntity{
        .{ .entity_type = .USER_MAME, .entity_tag = .Begin, .score = 0.98, .index = 10, .start = 68, .end = 77 },
    };
    const expected_pii_spans = &[_]MatchedPIISpan{
        .{ .entity_id = 1, .entity_type = .EMAIL_ADDRESS, .matched_start = 12, .matched_end = 25 },
        .{ .entity_id = 2, .entity_type = .URL_ADDRESS, .matched_start = 36, .matched_end = 56 },
        .{ .entity_id = 3, .entity_type = .USER_MAME, .matched_start = 68, .matched_end = 77 },
    };
    const pii_spans = try session.get_pii_spans(input, &ner_entities);
    defer allocator.free(pii_spans);
    try std.testing.expectEqualSlices(MatchedPIISpan, expected_pii_spans, pii_spans);
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

/// ----- C wrapper for Session -----
/// Call this function before the program exits, and call this function only once.
pub export fn aifw_shutdown() void {
    RegexRecognizer.shutdownCache();
    globalAllocatorDeinit();
}

pub export fn aifw_session_create(init_args: *const SessionInitArgs) *allowzero anyopaque {
    const allocator = globalAllocator();
    std.log.info("[c-api] session_create", .{});
    const session = Session.create(allocator, init_args.*) catch {
        std.log.err("[c-api] session_init failed", .{});
        return @ptrFromInt(0);
    };
    std.log.info("[c-api] session_create ok ptr=0x{x}", .{@intFromPtr(session)});
    return session;
}

pub export fn aifw_session_destroy(session_ptr: *allowzero anyopaque) void {
    if (@intFromPtr(session_ptr) == 0) return;

    const session: *Session = @as(*Session, @ptrCast(@alignCast(session_ptr)));
    std.log.info("[c-api] session_destroy ptr=0x{x}", .{@intFromPtr(session)});
    session.destroy();
}

/// Mask the text, return the masked text
pub export fn aifw_session_mask(
    session_ptr: *allowzero anyopaque,
    c_text: [*:0]const u8,
    ner_entities: [*c]const NerRecogEntity,
    ner_entity_count: u32,
    out_masked_text: *[*:0]u8,
) u16 {
    if (@intFromPtr(session_ptr) == 0) return @intFromError(error.InvalidSessionPtr);

    const session: *Session = @as(*Session, @ptrCast(@alignCast(session_ptr)));
    const ner_entities_slice = if (ner_entity_count > 0) ner_entities[0..@intCast(ner_entity_count)] else &[_]NerRecogEntity{};
    const masked_text = session.mask(c_text, ner_entities_slice) catch |err| {
        std.log.err("[c-api] mask failed: {s}", .{@errorName(err)});
        return @intFromError(err);
    };
    out_masked_text.* = masked_text;
    std.log.info("[c-api] mask ok out_ptr=0x{x}", .{@intFromPtr(masked_text)});
    return 0;
}

/// Mask the text, return the masked text and the mask meta data
pub export fn aifw_session_mask_and_out_meta(
    session_ptr: *allowzero anyopaque,
    c_text: [*:0]const u8,
    ner_entities: [*c]const NerRecogEntity,
    ner_entity_count: u32,
    out_masked_text: *[*:0]u8,
    out_mask_meta_data: **anyopaque,
) u16 {
    if (@intFromPtr(session_ptr) == 0) return @intFromError(error.InvalidSessionPtr);

    const session: *Session = @as(*Session, @ptrCast(@alignCast(session_ptr)));
    const ner_entities_slice = if (ner_entity_count > 0) ner_entities[0..@intCast(ner_entity_count)] else &[_]NerRecogEntity{};
    const masked_text = session.mask_and_out_meta(c_text, ner_entities_slice, out_mask_meta_data) catch |err| {
        std.log.err("[c-api] mask_and_out_meta failed: {s}", .{@errorName(err)});
        return @intFromError(err);
    };
    out_masked_text.* = masked_text;
    std.log.info("[c-api] mask_and_out_meta ok out_ptr=0x{x}", .{@intFromPtr(masked_text)});
    return 0;
}

/// Get the matched PII spans from the input text and the NER entities
/// The matched_start and matched_end is index in parameter text. So you must
/// keep alive the parameter text when you use the returned PII spans.
/// You must free the returned PII spans when you no longer using it.
pub export fn aifw_session_get_pii_spans(
    session_ptr: *allowzero anyopaque,
    c_text: [*:0]const u8,
    ner_entities: [*c]const NerRecogEntity,
    ner_entity_count: u32,
    out_pii_spans: *[*c]const MatchedPIISpan,
    out_pii_spans_count: *u32,
) u16 {
    if (@intFromPtr(session_ptr) == 0) return @intFromError(error.InvalidSessionPtr);

    const session: *Session = @as(*Session, @ptrCast(@alignCast(session_ptr)));
    const ner_entities_slice = if (ner_entity_count > 0) ner_entities[0..@intCast(ner_entity_count)] else &[_]NerRecogEntity{};
    const matched_pii_spans = session.get_pii_spans(c_text, ner_entities_slice) catch |err| {
        std.log.err("[c-api] get_matched_pii_list failed: {s}", .{@errorName(err)});
        return @intFromError(err);
    };
    out_pii_spans.* = matched_pii_spans.ptr;
    out_pii_spans_count.* = @intCast(matched_pii_spans.len);
    std.log.info("[c-api] get_matched_pii_list ok out_ptr=0x{x}", .{@intFromPtr(matched_pii_spans.ptr)});
    return 0;
}

/// Restore the text by masked text
pub export fn aifw_session_restore(
    session_ptr: *allowzero anyopaque,
    c_text: [*:0]const u8,
    out_restored_text: *[*:0]u8,
) u16 {
    if (@intFromPtr(session_ptr) == 0) return @intFromError(error.InvalidSessionPtr);

    const session: *Session = @as(*Session, @ptrCast(@alignCast(session_ptr)));
    std.log.info("[c-api] restore enter len={d}", .{std.mem.len(c_text)});
    const restored_text = session.restore(c_text) catch |err| {
        std.log.err("[c-api] restore failed: {s}", .{@errorName(err)});
        return @intFromError(err);
    };
    out_restored_text.* = restored_text;
    std.log.info("[c-api] restore ok out_ptr=0x{x}", .{@intFromPtr(restored_text)});
    return 0;
}

/// Restore the text by masked text and mask meta data
/// This function is used to restore the text by masked text and mask meta data,
/// The mask meta data is obtained by aifw_session_mask_and_out_meta.
pub export fn aifw_session_restore_with_meta(
    session_ptr: *allowzero anyopaque,
    c_text: [*:0]const u8,
    mask_meta_data: *const anyopaque,
    out_restored_text: *[*:0]u8,
) u16 {
    if (@intFromPtr(session_ptr) == 0) return @intFromError(error.InvalidSessionPtr);

    const session: *Session = @as(*Session, @ptrCast(@alignCast(session_ptr)));
    std.log.info("[c-api] restore enter len={d}", .{std.mem.len(c_text)});
    const restored_text = session.restore_with_meta(c_text, mask_meta_data) catch |err| {
        std.log.err("[c-api] restore failed: {s}", .{@errorName(err)});
        return @intFromError(err);
    };
    out_restored_text.* = restored_text;
    std.log.info("[c-api] restore ok out_ptr=0x{x}", .{@intFromPtr(restored_text)});
    return 0;
}

/// Free a NUL-terminated string allocated by the core (masked/restored text)
pub export fn aifw_string_free(str: [*:0]u8) void {
    globalAllocator().free(std.mem.span(str));
}

// Minimal entry point for wasm32-freestanding executable builds
pub export fn _start() void {
    // no-op; JS host calls exported APIs directly
}

/// WASM host buffer allocation helpers
pub export fn aifw_malloc(n: usize) [*:0]allowzero u8 {
    const slice = globalAllocator().alloc(u8, n) catch return @ptrFromInt(0);
    return @ptrCast(slice.ptr);
}

pub export fn aifw_free_sized(ptr: [*:0]allowzero u8, n: usize) void {
    if (@intFromPtr(ptr) == 0) return;
    const p: [*:0]u8 = @ptrCast(ptr);
    globalAllocator().free(p[0..n]);
}
