const std = @import("std");
const entity = @import("recog_entity.zig");
const NerRecognizer = @This();

allocator: std.mem.Allocator,
ner_recog_type: NerRecogType,

pub const RecogEntity = entity.RecogEntity;
pub const EntityType = entity.EntityType;

pub const NerRecogType = enum { token_classification, sequence_classification };

pub const NerRecogData = extern struct {
    /// A constant pointer to the original text
    text: [*:0]const u8,
    /// The array of NER entities
    ner_entities: [*c]const NerRecogEntity,
    /// The count of NER entities
    ner_entity_count: usize,
};

// pub const TokenOffset = extern struct {
//     /// The index of the token
//     index: usize,
//     /// The start index of the token
//     start: usize,
//     /// The end index of the token
//     end: usize,
// };

pub const NerRecogEntity = extern struct {
    /// The identifier string of the entity, for example, "B-PER", "I-PER", "B-ORG", "I-ORG", etc.
    entity: [*:0]const u8,
    /// The score of the entity
    score: f32,
    /// The index of the token in tokenized tokens from text
    index: usize,
    /// The start index of the entity
    start: usize,
    /// The end index of the entity
    end: usize,
};

pub fn init(allocator: std.mem.Allocator, ner_recog_type: NerRecogType) NerRecognizer {
    return .{ .allocator = allocator, .ner_recog_type = ner_recog_type };
}

pub fn deinit(self: *const NerRecognizer) void {
    _ = self;
    // do nothing
}

/// Convert external NER output (already decoded by caller) to RecogEntity list.
/// token_classification: items = []struct{ start:usize, end:usize, score:f32, et:EntityType }
/// sequence_classification: same as token_classification, but items have all tokens of the text,
/// not just recognized tokens.
pub fn run(self: *const NerRecognizer, ner_data: NerRecogData) ![]RecogEntity {
    var pos: usize = 0;
    var idx: usize = 0;
    var out = try std.ArrayList(RecogEntity).initCapacity(self.allocator, ner_data.ner_entity_count);
    defer out.deinit(self.allocator);
    const text = std.mem.span(ner_data.text);
    while (idx < ner_data.ner_entity_count) {
        const e = aggregateNerRecogEntityToRecogEntity(text, &pos, ner_data.ner_entities, ner_data.ner_entity_count, &idx);
        if (e.entity_type != .None) {
            try out.append(self.allocator, .{
                .entity_type = e.entity_type,
                .start = e.start,
                .end = e.end,
                .score = e.score,
                .description = if (self.ner_recog_type == .token_classification)
                    "Get from external NER output with token_classification"
                else
                    "Get from external NER output with sequence_classification",
            });
        }
    }
    return try out.toOwnedSlice(self.allocator);
}

const none_recog_entity = RecogEntity{
    .entity_type = .None,
    .start = 0,
    .end = 0,
    .score = 0.0,
    .description = null,
};

/// Aggregate one or more NerRecogEntity to one RecogEntity
fn aggregateNerRecogEntityToRecogEntity(
    text: []const u8,
    pos: *usize,
    entities: [*c]const NerRecogEntity,
    entities_count: usize,
    idx: *usize,
) RecogEntity {
    var i = idx.*;

    var have_entity = false;
    var recog_entity: RecogEntity = none_recog_entity;

    while (i < entities_count) : (i += 1) {
        const tok = entities[i];
        const entity_str = std.mem.span(tok.entity);
        const is_begin, const ner_type_str = extractEntityString(entity_str) orelse {
            if (have_entity) break else continue;
        };
        const t = mapNerTypeStrToEntityType(ner_type_str);
        if (t == .None) {
            if (have_entity) break else continue;
        }

        if (!have_entity) {
            if (!is_begin) continue;
            have_entity = true;
            recog_entity.entity_type = t;
            recog_entity.start = tok.start;
            recog_entity.end = tok.end;
            recog_entity.score = tok.score;
            recog_entity.description = null;
            continue;
        }

        if (t != recog_entity.entity_type) {
            // another different type entity is found, break the loop
            break;
        }

        const score = (recog_entity.score + tok.score) / 2;
        if (!is_begin) {
            recog_entity.end = tok.end;
            recog_entity.score = score;
            recog_entity.description = null;
        } else if (hasSubwordPrefix(text[tok.start..tok.end])) {
            recog_entity.end = tok.end;
            recog_entity.score = score;
            recog_entity.description = null;
        } else {
            // another same type entity is found, break the loop
            break;
        }
    }

    idx.* = i;
    if (!have_entity) {
        pos.* = text.len;
        return none_recog_entity;
    }
    return recog_entity;
}

fn extractEntityString(entity_str: []const u8) ?struct { bool, []const u8 } {
    if (std.mem.startsWith(u8, entity_str, "B-")) return .{ true, entity_str[2..] };
    if (std.mem.startsWith(u8, entity_str, "I-")) return .{ false, entity_str[2..] };
    return null;
}

fn mapNerTypeStrToEntityType(ner_type_str: []const u8) EntityType {
    if (std.mem.eql(u8, ner_type_str, "PER")) return .USER_MAME;
    if (std.mem.eql(u8, ner_type_str, "ORG")) return .ORGANIZATION;
    if (std.mem.eql(u8, ner_type_str, "LOC")) return .PHYSICAL_ADDRESS;
    if (std.mem.eql(u8, ner_type_str, "MISC")) return .None;
    return .None;
}

fn hasSubwordPrefix(word: []const u8) bool {
    if (word.len >= 2 and word[0] == '#' and word[1] == '#') return true;
    return false;
}
