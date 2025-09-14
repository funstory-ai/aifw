const std = @import("std");
const RegexRecognizer = @import("RegexRecognizer.zig");
const entity = @import("recog_entity.zig");

pub const PipelineKind = enum { mask, restore };

pub const RecogEntity = entity.RecogEntity;
pub const EntityType = entity.EntityType;

pub const MaskArgs = struct {
    original_text: []const u8,
    ner_data: []const RecogEntity, // external NER results
};

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
};

pub const MaskResult = struct {
    masked_text: []u8,
    mask_meta_data: MaskMetaData,
};

pub const RestoreArgs = struct {
    masked_text: []const u8,
    mask_meta_data: MaskMetaData,
};

pub const RestoreResult = struct {
    restored_text: []u8,
};

pub const PipelineArgs = union(PipelineKind) {
    mask: MaskArgs,
    restore: RestoreArgs,
};

pub const PipelineResult = union(PipelineKind) {
    mask: MaskResult,
    restore: RestoreResult,
};

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    kind: PipelineKind,
    // components
    regex_list: []const RegexRecognizer = &[_]RegexRecognizer{},

    pub fn init(allocator: std.mem.Allocator, kind: PipelineKind, regex_list: []const RegexRecognizer) Pipeline {
        return .{ .allocator = allocator, .kind = kind, .regex_list = regex_list };
    }

    pub fn deinit(self: *Pipeline) void {
        for (self.regex_list) |r| r.deinit();
        self.allocator.free(self.regex_list);
    }

    pub fn run(self: *const Pipeline, args: PipelineArgs) !PipelineResult {
        switch (self.kind) {
            .mask => return self.runMask(args.mask),
            .restore => return self.runRestore(args.restore),
        }
    }

    pub fn runMask(self: *const Pipeline, args: MaskArgs) !PipelineResult {
        if (self.kind != .mask) return error.InvalidPipelineKind;

        // 1) Tokenizer (optional) - skipped
        // 2) Regex recognizers
        var merged = try std.ArrayList(RecogEntity).initCapacity(self.allocator, 4);
        defer merged.deinit(self.allocator);
        // from regex
        for (self.regex_list) |r| {
            const ents = try r.run(args.original_text);
            // append
            for (ents) |e| try merged.append(self.allocator, e);
            self.allocator.free(ents);
        }
        // 3) NER results from args
        for (args.ner_data) |e| try merged.append(self.allocator, e);

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
        var out_buf = try std.ArrayList(u8).initCapacity(self.allocator, args.original_text.len);
        defer out_buf.deinit(self.allocator);
        var placeholder_dict = try std.ArrayList(PlaceholderMatchedPair).initCapacity(self.allocator, final_spans.len);
        defer placeholder_dict.deinit(self.allocator);

        var cursor: usize = 0;
        var idx: u32 = 0;
        while (idx < final_spans.len) : (idx += 1) {
            const span_start = final_spans[idx].start;
            const span_end = final_spans[idx].end;
            if (span_start > cursor) try out_buf.appendSlice(self.allocator, args.original_text[cursor..span_start]);
            var ph_buf: [PLACEHOLDER_MAX_LEN]u8 = undefined;
            const ph_text = try writePlaceholder(ph_buf[0..], final_spans[idx].entity_type, idx);
            try out_buf.appendSlice(self.allocator, ph_text);
            try placeholder_dict.append(self.allocator, .{
                .entity_id = idx,
                .entity_type = final_spans[idx].entity_type,
                .matched_text = args.original_text[span_start..span_end],
            });
            cursor = span_end;
        }
        if (cursor < args.original_text.len) try out_buf.appendSlice(self.allocator, args.original_text[cursor..]);

        return .{
            .mask = .{
                .masked_text = try out_buf.toOwnedSlice(self.allocator),
                .mask_meta_data = .{ .placeholder_dict = try placeholder_dict.toOwnedSlice(self.allocator) },
            },
        };
    }

    pub fn runRestore(self: *const Pipeline, args: RestoreArgs) !PipelineResult {
        if (self.kind != .restore) return error.InvalidPipelineKind;

        // naive restore: sequentially replace placeholders with originals in order
        var out = try std.ArrayList(u8).initCapacity(self.allocator, args.masked_text.len);
        defer out.deinit(self.allocator);
        var pos: usize = 0;
        for (args.mask_meta_data.placeholder_dict) |item| {
            if (pos < args.masked_text.len) {
                // find placeholder occurrence from current pos
                var ph_buf: [PLACEHOLDER_MAX_LEN]u8 = undefined;
                const ph_text = try writePlaceholder(ph_buf[0..], item.entity_type, item.entity_id);
                const found = std.mem.indexOfPos(u8, args.masked_text, pos, ph_text);
                if (found) |ph_pos| {
                    if (ph_pos > pos) try out.appendSlice(self.allocator, args.masked_text[pos..ph_pos]);
                    try out.appendSlice(self.allocator, item.matched_text);
                    pos = ph_pos + ph_text.len;
                }
            }
        }
        if (pos < args.masked_text.len) try out.appendSlice(self.allocator, args.masked_text[pos..]);
        return .{ .restore = .{ .restored_text = try out.toOwnedSlice(self.allocator) } };
    }
};

fn maxPlaceholderLen() comptime_int {
    const fields = std.meta.fields(EntityType);
    comptime var max_name: usize = 0;
    inline for (fields) |f| {
        if (f.name.len > max_name) max_name = f.name.len;
    }
    // "__PII_" + name + "_" + 8 hex + "__"
    return 6 + max_name + 1 + 8 + 2;
}

const PLACEHOLDER_MAX_LEN: usize = maxPlaceholderLen();

fn writePlaceholder(buf: []u8, t: EntityType, serial: u32) ![]u8 {
    return std.fmt.bufPrint(buf, "__PII_{s}_{X:0>8}__", .{ @tagName(t), serial });
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    mask_pipeline: Pipeline,
    restore_pipeline: Pipeline,

    pub fn init(allocator: std.mem.Allocator) !Session {
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
        const mask = Pipeline.init(allocator, .mask, regex_list);
        const restore = Pipeline.init(allocator, .restore, &[_]RegexRecognizer{});
        return .{ .allocator = allocator, .mask_pipeline = mask, .restore_pipeline = restore };
    }

    pub fn deinit(self: *Session) void {
        self.mask_pipeline.deinit();
        self.restore_pipeline.deinit();
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

test "session mask/restore" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.log.warn("[core-lib] allocator leak detected", .{});
    }
    const allocator = gpa.allocator();
    var session = try Session.init(allocator);
    defer session.deinit();

    const input = "Contact me: a.b+1@test.io and visit https://ziglang.org";
    const args = MaskArgs{ .original_text = input, .ner_data = &[_]RecogEntity{} };
    const masked = (try session.getPipeline(.mask).run(.{ .mask = args })).mask;
    std.debug.print("masked={s}\n", .{masked.masked_text});
    defer allocator.free(masked.masked_text);
    defer allocator.free(masked.mask_meta_data.placeholder_dict);

    const restored = (try session.getPipeline(.restore).run(.{
        .restore = .{
            .masked_text = masked.masked_text,
            .mask_meta_data = masked.mask_meta_data,
        },
    })).restore;
    std.debug.print("restored={s}\n", .{restored.restored_text});
    defer allocator.free(restored.restored_text);
    try std.testing.expect(restored.restored_text.len == input.len);
}
