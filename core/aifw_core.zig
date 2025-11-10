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
    .log_level = .debug,
    .logFn = logFn,
};

// WASM-specific shims (e.g., C runtime functions) are provided only for freestanding targets
// const _ = if (is_freestanding) @import("wasm_shims.zig") else {};

// export strlen for Rust regex in wasm32-freestanding
pub export fn strlen(s: [*:0]const u8) usize {
    return std.mem.len(s);
}

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

pub const Language = enum(u8) {
    unknown = 0,
    en = 1, // English
    ja = 2, // Japanese
    ko = 3, // Korean

    // All zh languages is from 4 to 9, zh is the unified zh language
    zh = 4, // unified zh language
    zh_cn = 5, // simplified chinese (mainland china)
    zh_tw = 6, // traditional chinese (taiwan)
    zh_hk = 7, // traditional chinese (hong kong)
    zh_hans = 8, // simplified chinese
    zh_hant = 9, // traditional chinese

    // All other languages is from 10
    fr = 10, // French
    de = 11, // German
    ru = 12, // Russian
    es = 13, // Spanish
    it = 14, // Italian
    ar = 15, // Arabic
    pt = 16, // Portuguese
};

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
    language: Language,
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

    fn isSpanOverlapping(a: RecogEntity, b: RecogEntity) bool {
        return !(a.end <= b.start or b.end <= a.start);
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

        // 3.1) Optional zh-specific address merge
        const merged_address_spans = switch (args.language) {
            .zh, .zh_cn, .zh_tw, .zh_hk, .zh_hans, .zh_hant => try mergeZhAddressSpans(self.allocator, original_text, merged.items),
            else => try self.allocator.dupe(RecogEntity, merged.items),
        };
        defer self.allocator.free(merged_address_spans);

        // 4) SpanMerger: sort, dedup by range, filter by score >= 0.5
        const spans = merged_address_spans;
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
        const filtered_spans = try filtered.toOwnedSlice(self.allocator);
        defer self.allocator.free(filtered_spans);
        std.log.debug("[mask] filtered spans: {d}", .{filtered_spans.len});

        // 4.1) De-duplicate overlapping spans by priority (higher score, longer span, earlier start)
        const final_spans = try dedupOverlappingSpans(self.allocator, filtered_spans, original_text);
        defer self.allocator.free(final_spans);
        std.log.debug("[mask] final spans after dedup: {d}", .{final_spans.len});

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

fn isAsciiLight(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r' or b == '\n' or b == ',';
}

fn isAsciiAlnum(b: u8) bool {
    return (b >= '0' and b <= '9') or (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z');
}

fn isAsciiAlpha(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z');
}

fn utf8CpLenAt(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return 1;
    const b = text[pos];
    if (b < 0x80) return 1;
    if ((b & 0xE0) == 0xC0) return if (pos + 1 <= text.len) 2 else 1;
    if ((b & 0xF0) == 0xE0) return if (pos + 2 <= text.len) 3 else 1;
    if ((b & 0xF8) == 0xF0) return if (pos + 3 <= text.len) 4 else 1;
    return 1;
}

fn adminSuffixAt(text: []const u8, pos: usize) usize {
    const ADMIN = [_][]const u8{
        "省", "市", "自治州", "自治区", "州", "盟", "地区", "特别行政区", "区", "區", "县", "縣", "旗", "新区", "高新区", "经济技术开发区", "开发区", "街道", "镇", "鎮", "乡", "鄉", "里", "村",
    };
    var i: usize = 0;
    while (i < ADMIN.len) : (i += 1) {
        if (matchToken(text, pos, ADMIN[i])) return ADMIN[i].len;
    }
    return 0;
}

fn roadSuffixAt(text: []const u8, pos: usize) usize {
    const SUF = [_][]const u8{
        "大道", "大街", "环路", "环线", "路", "街", "巷", "弄", "里", "道", "胡同", "段", "期",
        "環路", "環線",
    };
    var i: usize = 0;
    while (i < SUF.len) : (i += 1) {
        if (matchToken(text, pos, SUF[i])) return SUF[i].len;
    }
    return 0;
}

fn endsWithRoadSuffix(text: []const u8, start: u32, end: u32) bool {
    if (end <= start) return false;
    var e: usize = end;
    while (e > start and isAsciiLight(text[e - 1])) : (e -= 1) {}
    const SUF = [_][]const u8{
        "大道", "大街", "环路", "环线", "路", "街", "巷", "弄", "里", "道", "胡同", "段", "期",
        "環路", "環線",
    };
    var i: usize = 0;
    while (i < SUF.len) : (i += 1) {
        const t = SUF[i];
        if (e >= start + t.len and matchToken(text, e - t.len, t)) return true;
    }
    return false;
}

fn endsWithAny(text: []const u8, start: usize, end: usize, toks: []const []const u8) bool {
    if (end <= start) return false;
    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (end >= start + t.len and matchToken(text, end - t.len, t)) return true;
    }
    return false;
}

fn endsWithPoiSuffix(text: []const u8, start: usize, end: usize) bool {
    const POI = [_][]const u8{
        "广场", "中心", "大厦", "花园", "花苑", "苑", "园", "城",    "天地", "港", "塔", "座", "馆", "廊", "坊", "里", "府", "湾",
        "廣場", "中心", "大廈", "花園", "苑",    "園", "城", "天地", "港",    "塔", "座", "館", "廊", "坊", "里", "府", "灣",
    };
    return endsWithAny(text, start, end, &POI);
}

fn countCharsBetween(text: []const u8, a: usize, b: usize) usize {
    const lo = @min(a, b);
    const hi = @max(a, b);
    var i: usize = lo;
    var count: usize = 0;
    while (i < hi) : (i += 1) {
        const byte = text[i];
        if ((byte & 0xC0) != 0x80) count += 1; // count non-continuation bytes
    }
    return count;
}

fn absorbTrailingRoomUnit(text: []const u8, pos: usize) usize {
    var i = pos;
    const n = text.len;
    while (i < n and isAsciiLight(text[i])) : (i += 1) {}
    // ensure previous non-space run ends with digits
    var j = i;
    while (j > 0 and isAsciiLight(text[j - 1])) : (j -= 1) {}
    var p = j;
    var has_digits = false;
    while (p > 0 and text[p - 1] >= '0' and text[p - 1] <= '9') : (p -= 1) {
        has_digits = true;
    }
    if (!has_digits) return pos;
    // accept room and floor units
    const UROOM = [_][]const u8{ "单元", "室", "房", "层", "層", "楼" };
    var ur: usize = 0;
    while (ur < UROOM.len) : (ur += 1) {
        if (matchToken(text, i, UROOM[ur])) {
            i += UROOM[ur].len;
            return i;
        }
    }
    return pos;
}

fn detectNextAddressHeadWithin(text: []const u8, start_pos: usize, window: usize) bool {
    const limit = @min(text.len, start_pos + window);
    var p: usize = start_pos;
    while (p < limit) : (p += 1) {
        while (p < limit and isAsciiLight(text[p])) : (p += 1) {}
        if (p >= limit) break;
        const name_start = p;
        // scan name and also check suffix inline (e.g., "南昌市")
        while (p < limit) : (p += 1) {
            // inline suffix detection at current p
            if (roadSuffixAt(text, p) > 0 or adminSuffixAt(text, p) > 0) {
                if (p > name_start) return true; // have a prefix chunk before suffix
            }
            const b = text[p];
            if (isAsciiAlnum(b)) continue;
            if ((b & 0x80) != 0 and !(b >= '0' and b <= '9')) continue;
            break;
        }
        if (p <= name_start) continue;
        var q: usize = p;
        while (q < limit and isAsciiLight(text[q])) : (q += 1) {}
        if (q >= limit) break;
        if (roadSuffixAt(text, q) > 0) return true;
        if (adminSuffixAt(text, q) > 0) return true;
    }
    return false;
}

fn heavySepAt(text: []const u8, pos: usize) usize {
    const HEAVY = [_][]const u8{ "。", "！", "？", "；", "：", "、", "（", "）", "/", "\\", "|" };
    var i: usize = 0;
    while (i < HEAVY.len) : (i += 1) {
        if (matchToken(text, pos, HEAVY[i])) return HEAVY[i].len;
    }
    return 0;
}

fn rightExtendCnAddr(text: []const u8, start_end: u32) u32 {
    var i: usize = start_end;
    const n = text.len;
    // skip ASCII light seps
    while (i < n) : (i += 1) {
        const b = text[i];
        if (!isAsciiLight(b)) break;
    }
    // backward window anchor: if there is an existing house tail before end, we may allow generic-only tails
    const back_start: usize = if (start_end > 128) start_end - 128 else 0;
    const has_prior_anchor = hasHouseTailInside(text, @intCast(back_start), start_end);

    var j: usize = i;
    // Try immediate digits + (号/號 or building tokens) as head anchor
    const d0 = i;
    while (j < n and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
    var ok_head = false;
    if (j > d0) {
        // allow spaces between digits and 号/號 or building tokens
        var k: usize = j;
        while (k < n and isAsciiLight(text[k])) : (k += 1) {}
        if (matchToken(text, k, "号")) {
            k += "号".len;
            ok_head = true;
            j = k;
        } else if (matchToken(text, k, "號")) {
            k += "號".len;
            ok_head = true;
            j = k;
        } else {
            const BUILD = [_][]const u8{ "号楼", "号館", "號樓", "楼", "館", "樓", "栋", "棟", "幢", "座" };
            var bi: usize = 0;
            while (bi < BUILD.len) : (bi += 1) {
                if (matchToken(text, k, BUILD[bi])) {
                    k += BUILD[bi].len;
                    ok_head = true;
                    j = k;
                    break;
                }
            }
        }
    }

    if (!ok_head and !has_prior_anchor) return start_end;

    // If head anchor found, continue from j; otherwise stay at i and enter generic tails
    if (ok_head) {
        i = j;
        // optional: spaces then 之 then spaces and digits
        while (i < n and isAsciiLight(text[i])) : (i += 1) {}
        if (matchToken(text, i, "之")) {
            i += "之".len;
            while (i < n and isAsciiLight(text[i])) : (i += 1) {}
            const d1 = i;
            while (i < n and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
            if (i == d1) {
                // rollback if no digits after 之
                i = d1; // no-op keep position
            }
        }
        // optional: spaces, hyphen, spaces, digits
        while (i < n and isAsciiLight(text[i])) : (i += 1) {}
        if (i < n and text[i] == '-') {
            var t = i + 1;
            while (t < n and isAsciiLight(text[t])) : (t += 1) {}
            const d2 = t;
            while (t < n and text[t] >= '0' and text[t] <= '9') : (t += 1) {}
            if (t > d2) i = t;
        }
        // optional: spaces, room digits and unit tokens
        while (i < n and isAsciiLight(text[i])) : (i += 1) {}
        const room_start = i;
        while (i < n and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
        if (i > room_start) {
            while (i < n and isAsciiLight(text[i])) : (i += 1) {}
            const UNITS = [_][]const u8{ "单元", "室", "房", "层", "層" };
            var ui: usize = 0;
            while (ui < UNITS.len) : (ui += 1) {
                if (matchToken(text, i, UNITS[ui])) {
                    i += UNITS[ui].len;
                    break;
                }
            }
        }
    } else {
        // no head anchor at current position, but prior anchor exists; proceed with generic-only tails starting at i
    }

    // optional: generic name+number+unit tails (repeat up to 2 times)
    var loops: u32 = 0;
    const MAX_EXT_BYTES: usize = 96;
    const MAX_EXT_CHARS: usize = 48;
    while (loops < 2) : (loops += 1) {
        // heavy separator boundary
        if (heavySepAt(text, i) > 0) break;
        // forward lookahead blocking (wider window for UTF-8 Han)
        if (detectNextAddressHeadWithin(text, i, 48)) break;
        // total growth caps
        if (i > start_end and (i - start_end) > MAX_EXT_BYTES) break;
        if (countCharsBetween(text, @intCast(start_end), i) > MAX_EXT_CHARS) break;
        while (i < n and isAsciiLight(text[i])) : (i += 1) {}
        // generic name with length cap (<=16 chars); allow empty if we have prior anchor
        const MAX_NAME_CHARS: usize = 16;
        const name_start = i;
        var consumed_chars: usize = 0;
        while (i < n and consumed_chars < MAX_NAME_CHARS) {
            if (heavySepAt(text, i) > 0) break;
            const b = text[i];
            if (b >= '0' and b <= '9') break; // stop before digits
            if (isAsciiAlpha(b)) {
                i += 1;
                consumed_chars += 1;
                continue;
            }
            if ((b & 0x80) != 0) {
                const step = utf8CpLenAt(text, i);
                i += step;
                consumed_chars += 1;
                continue;
            }
            break;
        }
        if (i == name_start and !has_prior_anchor) break;
        const name_end = i;
        const has_poi = endsWithPoiSuffix(text, name_start, name_end);
        while (i < n and isAsciiLight(text[i])) : (i += 1) {}
        // digits
        const dstart2 = i;
        while (i < n and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
        if (i == dstart2) {
            if (has_prior_anchor) {
                // no digits; allow absorbTrailingRoomUnit to catch trailing unit like 楼
            } else break;
        } else {
            // if no poi suffix, enforce near-distance to digits (<=12 bytes)
            if (!has_poi) {
                const gap = dstart2 - name_end;
                if (gap > 12) break;
            }
            while (i < n and isAsciiLight(text[i])) : (i += 1) {}
            // strong units
            const STRONG = [_][]const u8{ "层", "層", "楼", "号", "號", "号楼", "号館", "號樓", "楼", "館", "樓", "栋", "棟", "幢", "座" };
            var ok2 = false;
            var su: usize = 0;
            while (su < STRONG.len) : (su += 1) {
                if (matchToken(text, i, STRONG[su])) {
                    i += STRONG[su].len;
                    ok2 = true;
                    break;
                }
            }
            if (!ok2) break;
            // optional room tail
            while (i < n and isAsciiLight(text[i])) : (i += 1) {}
            const r2s = i;
            while (i < n and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
            if (i > r2s) {
                while (i < n and isAsciiLight(text[i])) : (i += 1) {}
                const UROOM = [_][]const u8{ "单元", "室", "房" };
                var ur: usize = 0;
                while (ur < UROOM.len) : (ur += 1) {
                    if (matchToken(text, i, UROOM[ur])) {
                        i += UROOM[ur].len;
                        break;
                    }
                }
            }
        }
    }
    // absorb trailing unit like 室/房/层/樓 if directly follows digits
    const new_i = absorbTrailingRoomUnit(text, i);
    return @intCast(if (new_i > i) new_i else i);
}

fn matchToken(text: []const u8, pos: usize, token: []const u8) bool {
    if (pos > text.len) return false;
    if (pos + token.len > text.len) return false;
    return std.mem.eql(u8, text[pos .. pos + token.len], token);
}

fn hasHouseTailInside(text: []const u8, start: u32, end: u32) bool {
    var i: usize = start;
    const limit: usize = end;
    while (i < limit) : (i += 1) {
        // digits
        if (!(text[i] >= '0' and text[i] <= '9')) continue;
        var j = i;
        while (j < limit and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
        while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
        // primary head units
        if (j < limit and (matchToken(text, j, "号") or matchToken(text, j, "號"))) return true;
        const STRONG = [_][]const u8{ "号楼", "号館", "號樓", "楼", "館", "樓", "栋", "棟", "幢", "座" };
        var k: usize = 0;
        while (k < STRONG.len) : (k += 1) {
            if (matchToken(text, j, STRONG[k])) return true;
        }
        // otherwise continue scanning from j
        i = j;
    }
    return false;
}

fn endsWithAdminSuffix(text: []const u8, start: u32, end: u32) bool {
    if (end <= start) return false;
    var e: usize = end;
    while (e > start and isAsciiLight(text[e - 1])) : (e -= 1) {}
    const ADMIN = [_][]const u8{
        "省", "市", "自治州", "自治区", "州", "盟", "地区", "特别行政区", "区", "區", "县", "縣", "旗", "新区", "高新区", "经济技术开发区", "开发区", "街道", "镇", "鎮", "乡", "鄉", "里", "村",
    };
    var i: usize = 0;
    while (i < ADMIN.len) : (i += 1) {
        const tok = ADMIN[i];
        if (e >= start + tok.len and matchToken(text, e - tok.len, tok)) return true;
    }
    return false;
}

fn utf8PrevCpStart(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0 and (text[p] & 0xC0) == 0x80) : (p -= 1) {}
    return p;
}

fn prevIsAdminSuffix(text: []const u8, pos: usize) bool {
    // check if any admin suffix ends exactly at pos
    const ADMIN = [_][]const u8{
        "省", "市", "自治州", "自治区", "州", "盟", "地区", "特别行政区", "区", "區", "县", "縣", "旗", "新区", "高新区", "经济技术开发区", "开发区", "街道", "镇", "鎮", "乡", "鄉", "里", "村",
    };
    var i: usize = 0;
    while (i < ADMIN.len) : (i += 1) {
        const t = ADMIN[i];
        if (pos >= t.len and matchToken(text, pos - t.len, t)) return true;
    }
    return false;
}

fn leftExtendCnRoadHead(text: []const u8, start_pos: u32, max_bytes: usize) u32 {
    var p: usize = start_pos;
    var consumed: usize = 0;
    while (p > 0 and consumed < max_bytes) {
        const prev = utf8PrevCpStart(text, p);
        if (heavySepAt(text, prev) > 0) break;
        const b = text[prev];
        // stop at digits
        if (b >= '0' and b <= '9') break;
        // stop if immediately preceded by an admin suffix
        if (prevIsAdminSuffix(text, prev)) break;
        // accept ASCII letters or non-ASCII codepoints
        if (isAsciiAlpha(b) or (b & 0x80) != 0) {
            consumed += (p - prev);
            p = prev;
            continue;
        }
        break;
    }
    return @intCast(p);
}

fn findHouseTailFrom(text: []const u8, from_pos: u32, max_lookahead: u32) u32 {
    const n = text.len;
    var i: usize = from_pos;
    const limit = @min(n, from_pos + max_lookahead);
    // scan forward for digits then 号/號
    while (i < limit and !(text[i] >= '0' and text[i] <= '9')) : (i += 1) {
        if (heavySepAt(text, i) > 0) return from_pos;
    }
    if (i >= limit) return from_pos;
    var j: usize = i;
    while (j < limit and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
    if (j >= limit) return from_pos;
    // allow spaces between digits and 号/號 or building tokens
    while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
    var ok_head = false;
    if (matchToken(text, j, "号")) {
        j += "号".len;
        ok_head = true;
    } else if (matchToken(text, j, "號")) {
        j += "號".len;
        ok_head = true;
    } else {
        const BUILD = [_][]const u8{ "号楼", "号館", "號樓", "楼", "館", "樓", "栋", "棟", "幢", "座" };
        var bi: usize = 0;
        while (bi < BUILD.len) : (bi += 1) {
            if (matchToken(text, j, BUILD[bi])) {
                j += BUILD[bi].len;
                ok_head = true;
                break;
            }
        }
        if (!ok_head) return from_pos;
    }
    // optional 之N with spaces around
    var k: usize = j;
    while (k < limit and isAsciiLight(text[k])) : (k += 1) {}
    if (matchToken(text, k, "之")) {
        k += "之".len;
        while (k < limit and isAsciiLight(text[k])) : (k += 1) {}
        const d0 = k;
        while (k < limit and text[k] >= '0' and text[k] <= '9') : (k += 1) {}
        if (k > d0) j = k;
    }
    // optional -N with spaces around
    while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
    if (j < limit and text[j] == '-') {
        k = j + 1;
        while (k < limit and isAsciiLight(text[k])) : (k += 1) {}
        const d1 = k;
        while (k < limit and text[k] >= '0' and text[k] <= '9') : (k += 1) {}
        if (k > d1) j = k;
    }
    // optional unit / room marker and generic name+number+unit repeats
    while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
    const rstart = j;
    while (j < limit and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
    if (j > rstart) {
        while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
        const UNITS = [_][]const u8{ "单元", "室", "房", "层", "層" };
        var ui: usize = 0;
        while (ui < UNITS.len) : (ui += 1) {
            if (matchToken(text, j, UNITS[ui])) {
                j += UNITS[ui].len;
                break;
            }
        }
    }
    var loops: u32 = 0;
    const MAX_EXT2_BYTES: usize = 96;
    const MAX_EXT2_CHARS: usize = 48;
    while (loops < 2 and j < limit) : (loops += 1) {
        if (heavySepAt(text, j) > 0) break;
        if (detectNextAddressHeadWithin(text, j, 48)) break;
        if (j > from_pos and (j - from_pos) > MAX_EXT2_BYTES) break;
        if (countCharsBetween(text, @intCast(from_pos), j) > MAX_EXT2_CHARS) break;
        while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
        // generic name with length cap (<=16 chars)
        const MAX_NAME_CHARS2: usize = 16;
        const name_s = j;
        var consumed2_chars: usize = 0;
        while (j < limit and consumed2_chars < MAX_NAME_CHARS2) {
            if (heavySepAt(text, j) > 0) break;
            const b = text[j];
            if (b >= '0' and b <= '9') break;
            if (isAsciiAlpha(b)) {
                j += 1;
                consumed2_chars += 1;
                continue;
            }
            if ((b & 0x80) != 0) {
                const step = utf8CpLenAt(text, j);
                j += step;
                consumed2_chars += 1;
                continue;
            }
            break;
        }
        if (j == name_s) break;
        const name_e = j;
        const has_poi2 = endsWithPoiSuffix(text, name_s, name_e);
        while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
        // digits
        const d2s = j;
        while (j < limit and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
        if (j == d2s) break;
        if (!has_poi2) {
            const gap2 = d2s - name_e;
            if (gap2 > 12) break;
        }
        while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
        // strong units
        const U2 = [_][]const u8{ "层", "層", "楼", "号", "號", "号楼", "号館", "號樓", "楼", "館", "樓", "栋", "棟", "幢", "座" };
        var ok2 = false;
        var uidx2: usize = 0;
        while (uidx2 < U2.len) : (uidx2 += 1) {
            if (matchToken(text, j, U2[uidx2])) {
                j += U2[uidx2].len;
                ok2 = true;
                break;
            }
        }
        if (!ok2) break;
        // optional room tail
        while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
        const r2s = j;
        while (j < limit and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
        if (j > r2s) {
            while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
            const UROOM = [_][]const u8{ "单元", "室", "房" };
            var ur: usize = 0;
            while (ur < UROOM.len) : (ur += 1) {
                if (matchToken(text, j, UROOM[ur])) {
                    j += UROOM[ur].len;
                    break;
                }
            }
        }
    }
    const new_j = absorbTrailingRoomUnit(text, j);
    return @intCast(if (new_j > j) new_j else j);
}

fn leftExtendCnAdmin(text: []const u8, start_pos: u32, max_steps: u32) u32 {
    var start_ext: usize = start_pos;
    var steps: u32 = 0;
    while (steps < max_steps and start_ext > 0) : (steps += 1) {
        // skip ASCII light seps before current start
        var p: usize = start_ext;
        while (p > 0) : (p -= 1) {
            const b = text[p - 1];
            if (!isAsciiLight(b)) break;
        }
        // check if an admin suffix ends exactly at p
        const ADMIN = [_][]const u8{
            "省", "市", "自治州", "自治区", "州", "盟", "地区", "特别行政区", "区", "區", "县", "縣", "旗", "新区", "高新区", "经济技术开发区", "开发区", "街道", "镇", "鎮", "乡", "鄉", "里", "村",
        };
        var i: usize = 0;
        var matched: bool = false;
        while (i < ADMIN.len) : (i += 1) {
            const suf = ADMIN[i];
            const st = if (p >= suf.len) p - suf.len else 0;
            if (st > 0 and matchToken(text, st, suf)) {
                matched = true;
                break;
            }
        }
        if (!matched) break;
        // find chunk start before that suffix
        var s2: usize = p;
        var cnt: usize = 0;
        while (s2 > 0 and cnt < 32) : (s2 -= 1) {
            const b2 = text[s2 - 1];
            if (isAsciiAlnum(b2) or (b2 & 0x80) != 0) {
                cnt += 1;
            } else break;
        }
        if (cnt < 2) break;
        start_ext = s2;
    }
    return @intCast(start_ext);
}

fn mergeAdjacentAddressSpans(allocator: std.mem.Allocator, text: []const u8, spans_in: []const RecogEntity) ![]RecogEntity {
    if (spans_in.len == 0) return allocator.alloc(RecogEntity, 0);
    // sort by start, then by end desc
    const tmp_spans = try allocator.dupe(RecogEntity, spans_in);
    defer allocator.free(tmp_spans);
    std.sort.block(RecogEntity, tmp_spans, {}, struct {
        fn lessThan(_: void, a: RecogEntity, b: RecogEntity) bool {
            if (a.start == b.start) return a.end > b.end; // longer first when same start
            return a.start < b.start;
        }
    }.lessThan);

    var out = try std.ArrayList(RecogEntity).initCapacity(allocator, tmp_spans.len);
    errdefer out.deinit(allocator);
    var cur = tmp_spans[0];
    var i: usize = 1;
    while (i < tmp_spans.len) : (i += 1) {
        const nxt = tmp_spans[i];
        if (cur.entity_type == .PHYSICAL_ADDRESS and nxt.entity_type == .PHYSICAL_ADDRESS and nxt.start >= cur.end) {
            // check only ASCII light seps between
            var ok = true;
            var p: usize = cur.end;
            while (p < nxt.start) : (p += 1) {
                if (!isAsciiLight(text[p])) {
                    ok = false;
                    break;
                }
            }
            std.log.debug("[merge] merge adjancent spans: cur={any}, nxt={any}, ok={}", .{ cur, nxt, ok });
            if (ok) {
                var merged = cur;
                merged.end = nxt.end;
                if (nxt.score > merged.score) merged.score = nxt.score;
                cur = merged;
                continue;
            }
        }
        std.log.debug("[merge] append cur={any}, token_text={s}", .{ cur, text[cur.start..cur.end] });
        try out.append(allocator, cur);
        cur = nxt;
    }
    std.log.debug("[merge] append last cur={any}, token_text={s}", .{ cur, text[cur.start..cur.end] });
    try out.append(allocator, cur);
    return try out.toOwnedSlice(allocator);
}

fn mergeZhAddressSpans(allocator: std.mem.Allocator, text: []const u8, spans: []const RecogEntity) ![]RecogEntity {
    for (spans) |span| {
        if (span.entity_type == .PHYSICAL_ADDRESS) {
            std.log.debug("[mergeZhAddressSpans] physical address span: {any}, token_text={s}", .{ span, text[span.start..span.end] });
        }
    }

    const merged_adjacent = try mergeAdjacentAddressSpans(allocator, text, spans);
    defer allocator.free(merged_adjacent);

    // Address validation & expansion: must have house-number tail either inside span,
    // or reachable by right-extending, or grown from admin-suffix seed within a window.
    var merged_zh = try std.ArrayList(RecogEntity).initCapacity(allocator, merged_adjacent.len);
    defer merged_zh.deinit(allocator);
    for (merged_adjacent) |sp| {
        if (sp.entity_type != .PHYSICAL_ADDRESS) {
            try merged_zh.append(allocator, sp);
            continue;
        }
        var keep = false;
        var new_end: u32 = sp.end;

        const has_tail_inside = hasHouseTailInside(text, sp.start, sp.end);
        if (has_tail_inside) keep = true;

        // Always try right-extension from span end to include POI/floor/building tails
        const ext_end = rightExtendCnAddr(text, sp.end);
        if (ext_end > new_end) {
            keep = true;
            new_end = ext_end;
        } else if (!has_tail_inside and endsWithAdminSuffix(text, sp.start, sp.end)) {
            // If no internal tail but ends with admin suffix, try grow to the right within a window to house tail
            const grown_end = findHouseTailFrom(text, sp.end, 96);
            if (grown_end > new_end) {
                keep = true;
                new_end = grown_end;
            }
        }
        if (!keep) continue;

        // // first include road head chunk (e.g., "银城" in "银城中路")
        // const road_start = if (endsWithRoadSuffix(text, sp.start, sp.end)) leftExtendCnRoadHead(text, sp.start, 32) else sp.start;
        // // then include upper administrative units if adjacent
        // const new_start = leftExtendCnAdmin(text, road_start, 3);
        const new_start = leftExtendCnAdmin(text, sp.start, 3);
        var out_sp = sp;
        out_sp.start = new_start;
        out_sp.end = new_end;
        try merged_zh.append(allocator, out_sp);
    }

    return try merged_zh.toOwnedSlice(allocator);
}

fn dedupOverlappingSpans(allocator: std.mem.Allocator, spans: []const RecogEntity, text: []const u8) ![]RecogEntity {
    if (spans.len == 0) return allocator.alloc(RecogEntity, 0);

    // copy spans for sorting by priority: higher score, longer length, earlier start
    const dup_spans = try allocator.dupe(RecogEntity, spans);
    errdefer allocator.free(dup_spans);
    const Ctx = struct { text: []const u8 };
    std.sort.block(RecogEntity, dup_spans, Ctx{ .text = text }, struct {
        fn hasHouse(t: []const u8, s: RecogEntity) bool {
            return if (s.entity_type == .PHYSICAL_ADDRESS) hasHouseTailInside(t, s.start, s.end) else false;
        }
        fn lessThan(ctx: Ctx, a: RecogEntity, b: RecogEntity) bool {
            // For PHYSICAL_ADDRESS, prefer has house, longer first, then earlier start, then higher score
            if (a.entity_type == .PHYSICAL_ADDRESS or b.entity_type == .PHYSICAL_ADDRESS) {
                const ah = hasHouse(ctx.text, a);
                const bh = hasHouse(ctx.text, b);
                if (ah != bh) return ah and !bh; // with house-tail first
                const a_len = a.end - a.start;
                const b_len = b.end - b.start;
                if (a_len != b_len) return a_len > b_len;
                if (a.start != b.start) return a.start < b.start;
                if (a.score != b.score) return a.score > b.score;
                return a.start < b.start;
            }
            // Default: higher score, then longer length, then earlier start
            if (a.score != b.score) return a.score > b.score; // higher first
            const a_len = a.end - a.start;
            const b_len = b.end - b.start;
            if (a_len != b_len) return a_len > b_len; // longer first
            return a.start < b.start; // earlier first
        }
    }.lessThan);

    var selected = try std.ArrayList(RecogEntity).initCapacity(allocator, dup_spans.len);
    errdefer selected.deinit(allocator);
    const overlaps = struct {
        fn f(a: RecogEntity, b: RecogEntity) bool {
            return !(a.end <= b.start or b.end <= a.start);
        }
    };
    for (dup_spans) |cand| {
        var ok = true;
        for (selected.items) |s| {
            if (overlaps.f(cand, s)) {
                ok = false;
                break;
            }
        }
        if (ok) try selected.append(allocator, cand);
    }
    allocator.free(dup_spans);

    // Sort back to start order for downstream placeholder building
    std.sort.block(RecogEntity, selected.items, {}, struct {
        fn lessThan(_: void, a: RecogEntity, b: RecogEntity) bool {
            return if (a.start == b.start) a.end < b.end else a.start < b.start;
        }
    }.lessThan);

    return selected.toOwnedSlice(allocator);
}

pub const RestorePipeline = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, init_args: RestoreInitArgs) RestorePipeline {
        _ = init_args;
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *const RestorePipeline) void {
        _ = self;
    }

    const PlaceHolderPIIText = struct {
        // ph_start and ph_end are references to masked_text
        ph_start: u32,
        ph_end: u32,

        // The matched substirng in original text
        matched_text: []const u8,
    };

    pub fn run(self: *const RestorePipeline, args: RestoreArgs) !PipelineResult {
        // naive restore: sequentially replace placeholders with originals in order
        const masked_text = std.mem.span(args.masked_text);
        std.log.debug("[restore] begin masked_len={d} spans_count={d}", .{ masked_text.len, args.mask_meta_data.matched_pii_spans.len });
        const pii_spans = args.mask_meta_data.matched_pii_spans;
        const spans_len: usize = pii_spans.len;
        var ph_pii_maps = try self.allocator.alloc(PlaceHolderPIIText, spans_len);
        defer self.allocator.free(ph_pii_maps);
        var ph_total_len: usize = 0;
        for (pii_spans, 0..) |span, i| {
            // Regenerate the placeholder text from entity_type and entity_id
            var ph_buf: [PLACEHOLDER_MAX_LEN]u8 = undefined;
            const ph_text = try writePlaceholder(ph_buf[0..], span.entity_type, span.entity_id);
            ph_total_len += ph_text.len;
            // Build map of placeholder and masked_text, the ph_start and ph_end
            // should reference to masked_text
            const found = std.mem.indexOfPos(u8, masked_text, 0, ph_text);
            if (found) |ph_start| {
                ph_pii_maps[i].ph_start = @intCast(ph_start);
                ph_pii_maps[i].ph_end = @intCast(ph_start + ph_text.len);
                ph_pii_maps[i].matched_text = args.mask_meta_data.referenced_text[span.matched_start..span.matched_end];
            } else {
                std.log.warn("[restore] placeholder not found: entity_id={d}", .{span.entity_id});
            }
        }
        std.sort.pdq(PlaceHolderPIIText, ph_pii_maps[0..pii_spans.len], {}, struct {
            fn lessThan(_: void, a: PlaceHolderPIIText, b: PlaceHolderPIIText) bool {
                return a.ph_start < b.ph_start;
            }
        }.lessThan);

        var pos: u32 = 0;
        var out = try std.ArrayList(u8).initCapacity(
            self.allocator,
            masked_text.len + args.mask_meta_data.referenced_text.len - ph_total_len + 1,
        );
        defer out.deinit(self.allocator);
        for (ph_pii_maps[0..spans_len]) |item| {
            if (item.ph_start > pos) out.appendSliceAssumeCapacity(masked_text[pos..item.ph_start]);
            out.appendSliceAssumeCapacity(item.matched_text);
            pos = item.ph_end;
        }
        if (pos < masked_text.len) out.appendSliceAssumeCapacity(masked_text[pos..]);

        // add sentinel for restored text
        out.appendAssumeCapacity(0);
        const restored_text = out.items;
        out = std.ArrayList(u8).empty; // reset to empty list
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
    // u32 is 4 bytes, so 10 decimal digits is enough
    // "__PII_" + name + "_" + 10 decimal digits + "__"
    return 6 + max_name_len + 1 + 10 + 2;
}

const PLACEHOLDER_MAX_LEN: usize = maxPlaceholderLen();

fn writePlaceholder(buf: []u8, t: EntityType, serial: u32) ![]u8 {
    return std.fmt.bufPrint(buf, "__PII_{s}_{d}__", .{ @tagName(t), serial });
}

pub const SessionInitArgs = extern struct {
    ner_recog_type: NerRecogType,
};

// Here has a self-reference pointer to ner_recognizer, so the session must be allocated by create().
// If you call init() to initialize the session, you can not copy the session to another variable.
pub const Session = struct {
    allocator: std.mem.Allocator,
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
        // Build recognizers set (email/url/phone/bank/verification_code/password)
        const entity_type_fields = @typeInfo(EntityType).@"enum".fields;
        var list = try std.ArrayList(RegexRecognizer).initCapacity(allocator, entity_type_fields.len);
        errdefer {
            for (list.items) |r| r.deinit();
            list.deinit(allocator);
        }
        inline for (entity_type_fields) |field| {
            const t: EntityType = @enumFromInt(field.value);
            const empty_specs = &[_]RegexRecognizer.PatternSpec{};
            // empty specs means use default static compiled regexs in RegexRecognizer.
            const r = try RegexRecognizer.init(allocator, empty_specs, t, null);
            list.appendAssumeCapacity(r);
        }
        const regex_list = try list.toOwnedSlice(allocator);

        // NOTE: Returning by value makes inner self-pointers unstable; use create() instead.
        self.* = .{
            .allocator = allocator,
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
    }

    pub fn getPipeline(self: *Session, kind: PipelineKind) *Pipeline {
        return switch (kind) {
            .mask => &self.mask_pipeline,
            .restore => &self.restore_pipeline,
        };
    }

    pub fn mask_and_out_meta(self: *Session, text: [*:0]const u8, ner_entities: []const NerRecogEntity, language: Language, out_mask_meta_data: **anyopaque) ![*:0]u8 {
        const mask_result = (try self.getPipeline(.mask).run(.{ .mask = .{
            .original_text = text,
            .ner_data = .{
                .text = text,
                .ner_entities = ner_entities.ptr,
                .ner_entity_count = @intCast(ner_entities.len),
            },
            .language = language,
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
    pub fn get_pii_spans(self: *Session, text: [*:0]const u8, ner_entities: []const NerRecogEntity, language: Language) ![]const MatchedPIISpan {
        const mask_result = (try self.getPipeline(.mask).run(.{ .mask = .{
            .original_text = text,
            .ner_data = .{
                .text = text,
                .ner_entities = ner_entities.ptr,
                .ner_entity_count = @intCast(ner_entities.len),
            },
            .language = language,
        } })).mask;
        // Avoid leaking masked_text from the mask path; caller will free spans.
        self.allocator.free(std.mem.span(mask_result.masked_text));
        return mask_result.mask_meta_data.matched_pii_spans;
    }

    pub fn restore_with_meta(self: *Session, masked_text: [*:0]const u8, mask_meta_data_ptr: *const anyopaque) ![*:0]u8 {
        const serialized_mask_meta_data_ptr = @as([*]const u8, @ptrCast(@alignCast(mask_meta_data_ptr)));
        const len = std.mem.readInt(u32, serialized_mask_meta_data_ptr[0..4], .little);
        const serialized_mask_meta_data = serialized_mask_meta_data_ptr[0..len];
        defer self.allocator.free(serialized_mask_meta_data);
        const mask_meta_data = deserialize_mask_meta_data(serialized_mask_meta_data);
        defer mask_meta_data.deinit(self.allocator);

        return (try self.getPipeline(.restore).run(.{ .restore = .{
            .masked_text = masked_text,
            .mask_meta_data = mask_meta_data,
        } })).restore.restored_text;
    }
};

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
    const masked_text = try session.mask_and_out_meta(input, &ner_entities, .en, &out_meta_ptr);
    defer allocator.free(std.mem.span(masked_text));

    // Copy out meta BEFORE first restore because restore_with_meta frees the out_meta_ptr
    const out_meta_bytes = @as([*]const u8, @ptrCast(@alignCast(out_meta_ptr)));
    const out_meta_len = std.mem.readInt(u32, out_meta_bytes[0..4], .little);
    const out_meta2_bytes = try allocator.dupe(u8, out_meta_bytes[0..out_meta_len]);

    const restored_text = try session.restore_with_meta(masked_text, out_meta_ptr);
    defer allocator.free(std.mem.span(restored_text));
    errdefer std.debug.print("masked={s}\n", .{masked_text});
    errdefer std.debug.print("restored={s}\n", .{restored_text});
    try std.testing.expect(std.mem.eql(u8, std.mem.span(restored_text), input));

    const mask_meta = deserialize_mask_meta_data(out_meta2_bytes);
    defer mask_meta.deinit(allocator);
    var i: usize = 0;
    // Shuffle the span order to test out-of-order spans in restore_with_meta
    while (i + 1 < mask_meta.matched_pii_spans.len) {
        var span = mask_meta.matched_pii_spans[i];
        var next_span = mask_meta.matched_pii_spans[i + 1];
        const temp_span = span;
        span = next_span;
        next_span = temp_span;
        i += 2;
    }
    const out_meta_ptr2 = @as(*anyopaque, @ptrCast(@alignCast(out_meta2_bytes.ptr)));
    const restored_text2 = try session.restore_with_meta(masked_text, out_meta_ptr2);
    defer allocator.free(std.mem.span(restored_text2));
    errdefer std.debug.print("masked={s}\n", .{masked_text});
    errdefer std.debug.print("restored={s}\n", .{restored_text2});
    try std.testing.expect(std.mem.eql(u8, std.mem.span(restored_text2), input));
}

test "regex recognizer in mask/restore" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.log.warn("[core-lib] allocator leak detected", .{});
    }
    const allocator = gpa.allocator();

    const session = try Session.create(allocator, .{ .ner_recog_type = .token_classification });
    defer session.destroy();

    const input = "use this temporary verification code: 9F4T2A. For the sandbox box, the pwd: S3cure!Passw0rd (I'll reset it after your tests, promise!).";
    const ner_entities = [_]NerRecogEntity{};

    var out_meta_ptr: *anyopaque = undefined;
    const masked_text = try session.mask_and_out_meta(input, &ner_entities, .en, &out_meta_ptr);
    defer allocator.free(std.mem.span(masked_text));

    const restored_text = try session.restore_with_meta(masked_text, out_meta_ptr);
    defer allocator.free(std.mem.span(restored_text));
    errdefer std.debug.print("masked={s}\n", .{masked_text});
    errdefer std.debug.print("restored={s}\n", .{restored_text});
    try std.testing.expect(std.mem.eql(u8, std.mem.span(restored_text), input));
}

test "session restore_with_meta with empty masked text frees meta and returns null" {
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
    const masked_text = try session.mask_and_out_meta(input, &ner_entities, .en, &out_meta_ptr);
    defer allocator.free(std.mem.span(masked_text));

    // Call exported C API restore_with_meta with empty masked text
    const sess_ptr: *allowzero anyopaque = @ptrCast(session);
    const empty_c_text: [*:0]const u8 = "";
    var out_restored: [*:0]allowzero u8 = @ptrFromInt(0);
    const rc: u16 = aifw_session_restore_with_meta(sess_ptr, empty_c_text, out_meta_ptr, &out_restored);
    try std.testing.expect(rc == 0);
    try std.testing.expect(@intFromPtr(out_restored) == 0);
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
    const pii_spans = try session.get_pii_spans(input, &ner_entities, .en);
    defer allocator.free(pii_spans);
    try std.testing.expectEqualSlices(MatchedPIISpan, expected_pii_spans, pii_spans);
}

/// Global allocator selection
/// - Debug (hosted): GeneralPurposeAllocator
/// - Freestanding: page_allocator (WASM)
/// - Release hosted: SmpAllocator
const is_debug = builtin.mode == .Debug;

const HEAP_SIZE: usize = 0; // unused now
var gpa_inst = if (is_freestanding)
    // For wasm32-freestanding, prefer page_allocator which is thread-safe
    std.heap.page_allocator
else if (is_debug)
    std.heap.GeneralPurposeAllocator(.{}){}
else
    std.heap.SmpAllocator{};

// Serialize API entry points to make allocator usage thread-safe in WASM
var api_mutex: std.Thread.Mutex = .{};
const SHOULD_LOCK_API: bool = is_freestanding or is_debug;

fn globalAllocator() std.mem.Allocator {
    if (is_freestanding) {
        return gpa_inst; // page_allocator is already an Allocator
    } else if (is_debug) {
        return gpa_inst.allocator();
    } else {
        return gpa_inst.allocator();
    }
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
    if (SHOULD_LOCK_API) {
        api_mutex.lock();
        defer api_mutex.unlock();
    }
    RegexRecognizer.shutdownCache();
    globalAllocatorDeinit();
}

pub export fn aifw_session_create(init_args: *const SessionInitArgs) *allowzero anyopaque {
    if (SHOULD_LOCK_API) {
        api_mutex.lock();
        defer api_mutex.unlock();
    }
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
    if (SHOULD_LOCK_API) {
        api_mutex.lock();
        defer api_mutex.unlock();
    }
    if (@intFromPtr(session_ptr) == 0) return;

    const session: *Session = @as(*Session, @ptrCast(@alignCast(session_ptr)));
    std.log.info("[c-api] session_destroy ptr=0x{x}", .{@intFromPtr(session)});
    session.destroy();
}

/// Mask the text, return the masked text and the mask meta data
pub export fn aifw_session_mask_and_out_meta(
    session_ptr: *allowzero anyopaque,
    c_text: [*:0]const u8,
    ner_entities: [*c]const NerRecogEntity,
    ner_entity_count: u32,
    language: u8,
    out_masked_text: *[*:0]u8,
    out_mask_meta_data: **anyopaque,
) u16 {
    if (SHOULD_LOCK_API) {
        api_mutex.lock();
        defer api_mutex.unlock();
    }
    if (@intFromPtr(session_ptr) == 0) return @intFromError(error.InvalidSessionPtr);

    const session: *Session = @as(*Session, @ptrCast(@alignCast(session_ptr)));
    const ner_entities_slice = if (ner_entity_count > 0) ner_entities[0..@intCast(ner_entity_count)] else &[_]NerRecogEntity{};
    const masked_text = session.mask_and_out_meta(c_text, ner_entities_slice, @enumFromInt(language), out_mask_meta_data) catch |err| {
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
    language: u8,
    out_pii_spans: *[*c]const MatchedPIISpan,
    out_pii_spans_count: *u32,
) u16 {
    if (SHOULD_LOCK_API) {
        api_mutex.lock();
        defer api_mutex.unlock();
    }
    if (@intFromPtr(session_ptr) == 0) return @intFromError(error.InvalidSessionPtr);

    const session: *Session = @as(*Session, @ptrCast(@alignCast(session_ptr)));
    const ner_entities_slice = if (ner_entity_count > 0) ner_entities[0..@intCast(ner_entity_count)] else &[_]NerRecogEntity{};
    const matched_pii_spans = session.get_pii_spans(c_text, ner_entities_slice, @enumFromInt(language)) catch |err| {
        std.log.err("[c-api] get_matched_pii_list failed: {s}", .{@errorName(err)});
        return @intFromError(err);
    };
    out_pii_spans.* = matched_pii_spans.ptr;
    out_pii_spans_count.* = @intCast(matched_pii_spans.len);
    std.log.info("[c-api] get_matched_pii_list ok out_ptr=0x{x}", .{@intFromPtr(matched_pii_spans.ptr)});
    return 0;
}

/// Restore the text by masked text and mask meta data
/// This function is used to restore the text by masked text and mask meta data,
/// The mask meta data is obtained by aifw_session_mask_and_out_meta.
pub export fn aifw_session_restore_with_meta(
    session_ptr: *allowzero anyopaque,
    masked_c_text: [*:0]const u8,
    mask_meta_data: *const anyopaque,
    out_restored_text: *[*:0]allowzero u8,
) u16 {
    if (SHOULD_LOCK_API) {
        api_mutex.lock();
        defer api_mutex.unlock();
    }
    if (@intFromPtr(session_ptr) == 0) return @intFromError(error.InvalidSessionPtr);

    const session: *Session = @as(*Session, @ptrCast(@alignCast(session_ptr)));
    std.log.info("[c-api] restore enter len={d}", .{std.mem.len(masked_c_text)});
    // Special case: if caller passes empty masked text, just consume/free meta and return null
    if (std.mem.len(masked_c_text) == 0) {
        const serialized_mask_meta_data_ptr = @as([*]const u8, @ptrCast(@alignCast(mask_meta_data)));
        const len = std.mem.readInt(u32, serialized_mask_meta_data_ptr[0..4], .little);
        const serialized_mask_meta_data = serialized_mask_meta_data_ptr[0..len];
        session.allocator.free(serialized_mask_meta_data);
        out_restored_text.* = @ptrFromInt(0);
        std.log.info("[c-api] restore skip (empty input), freed meta", .{});
        return 0;
    }
    const restored_text = session.restore_with_meta(masked_c_text, mask_meta_data) catch |err| {
        std.log.err("[c-api] restore failed: {s}", .{@errorName(err)});
        return @intFromError(err);
    };
    out_restored_text.* = restored_text;
    std.log.info("[c-api] restore ok out_ptr=0x{x}", .{@intFromPtr(restored_text)});
    return 0;
}

/// Free a NUL-terminated string allocated by the core (masked/restored text)
pub export fn aifw_string_free(str: [*:0]u8) void {
    if (SHOULD_LOCK_API) {
        api_mutex.lock();
        defer api_mutex.unlock();
    }
    globalAllocator().free(std.mem.span(str));
}

// Note: Do not export a custom _start here to avoid symbol collisions with std/start on hosted targets.

/// WASM host buffer allocation helpers
pub export fn aifw_malloc(n: usize) [*:0]allowzero u8 {
    if (SHOULD_LOCK_API) {
        api_mutex.lock();
        defer api_mutex.unlock();
    }
    const slice = globalAllocator().alloc(u8, n) catch return @ptrFromInt(0);
    return @ptrCast(slice.ptr);
}

pub export fn aifw_free_sized(ptr: [*:0]allowzero u8, n: usize) void {
    if (SHOULD_LOCK_API) {
        api_mutex.lock();
        defer api_mutex.unlock();
    }
    if (@intFromPtr(ptr) == 0) return;
    const p: [*:0]u8 = @ptrCast(ptr);
    globalAllocator().free(p[0..n]);
}
