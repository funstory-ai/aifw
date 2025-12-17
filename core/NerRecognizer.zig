const std = @import("std");
const entity = @import("recog_entity.zig");
const NerRecognizer = @This();

allocator: std.mem.Allocator,
ner_recog_type: NerRecogType,

pub const RecogEntity = entity.RecogEntity;
pub const EntityType = entity.EntityType;
pub const EntityBioTag = entity.EntityBioTag;

pub const NerRecogType = enum(u8) { token_classification, sequence_classification };

pub const NerRecogData = extern struct {
    /// A constant pointer to the original text
    text: [*:0]const u8,
    /// The array of NER entities
    ner_entities: [*c]const NerRecogEntity,
    /// The count of NER entities
    ner_entity_count: u32,
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
    /// The type of the entity, for example, .USER_NAME, .ORGANIZATION, .PHYSICAL_ADDRESS, etc.
    entity_type: EntityType,
    entity_tag: EntityBioTag,

    /// The score of the entity
    score: f32,
    /// The index of the token in tokenized tokens from text
    index: u32,
    /// The start index of the entity
    start: u32,
    /// The end index of the entity
    end: u32,
};

pub fn create(allocator: std.mem.Allocator, ner_recog_type: NerRecogType) !*NerRecognizer {
    const ner_recognizer = allocator.create(NerRecognizer) catch return error.NerRecognizerCreateFailed;
    ner_recognizer.* = init(allocator, ner_recog_type);
    return ner_recognizer;
}

pub fn destroy(self: *const NerRecognizer) void {
    self.deinit();
    self.allocator.destroy(self);
}

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
    std.log.debug("NerRecognizer.run: ner_data.ner_entity_count={d}", .{ner_data.ner_entity_count});
    if (@intFromEnum(std.options.log_level) >= @intFromEnum(std.log.Level.debug)) {
        for (ner_data.ner_entities[0..ner_data.ner_entity_count]) |ent| {
            std.log.debug("NerRecognizer.run: ner ent: {any}", .{ent});
        }
    }
    var out = try std.ArrayList(RecogEntity).initCapacity(self.allocator, ner_data.ner_entity_count);
    defer out.deinit(self.allocator);
    const text = std.mem.span(ner_data.text);
    while (idx < ner_data.ner_entity_count) {
        std.log.debug("NerRecognizer.run: ner_data.ner_entities[{d}]={any}", .{ idx, ner_data.ner_entities[idx] });
        const e = aggregateNerRecogEntityToRecogEntity(text, &pos, ner_data.ner_entities, ner_data.ner_entity_count, &idx);
        std.log.debug("NerRecognizer.run: ner_entity={any}, score={d}, start={d}, end={d}", .{ e.entity_type, e.score, e.start, e.end });
        if (e.entity_type != .None) {
            try out.append(self.allocator, .{
                .entity_type = e.entity_type,
                .start = e.start,
                .end = e.end,
                .score = e.score,
                .description = switch (self.ner_recog_type) {
                    .token_classification => "token",
                    .sequence_classification => "sequence",
                },
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

/// Aggregate one or more same type NerRecogEntity to one RecogEntity
/// for example, if the NER entities are:
/// [
///     { entity_type: .PHYSICAL_ADDRESS, entity_tag: .Begin, start: 0, end: 10, score: 0.9 },
///     { entity_type: .PHYSICAL_ADDRESS, entity_tag: .Inside, start: 10, end: 20, score: 0.8 },
///     { entity_type: .PHYSICAL_ADDRESS, entity_tag: .Inside, start: 20, end: 30, score: 0.7 },
/// ]
/// the function will return the aggregated RecogEntity:
/// { entity_type: .PHYSICAL_ADDRESS, start: 0, end: 30, score: 0.8 }
///
/// If the NER entities are not the same type, the function will return the first entity.
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

    std.log.debug("aggregateNerRecogEntityToRecogEntity: entities_count={d}, idx={d}, pos={d}", .{ entities_count, i, pos.* });
    while (i < entities_count) : (i += 1) {
        const tok = entities[i];
        std.log.debug("aggregateNerRecogEntityToRecogEntity: i={d}, type={any}, tag={any}, start={d}, end={d}, word={s}", .{ i, tok.entity_type, tok.entity_tag, tok.start, tok.end, text[tok.start..tok.end] });
        const t = tok.entity_type;
        const is_begin = tok.entity_tag == .Begin;
        if (t == .None) {
            if (have_entity) break else continue;
        }

        if (!have_entity) {
            if (!is_begin) continue;
            std.log.debug("aggregateNerRecogEntityToRecogEntity: is_begin=true, type={any}", .{t});
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
            std.log.debug("aggregateNerRecogEntityToRecogEntity: is_begin=false, score={d}", .{score});
            recog_entity.end = tok.end;
            recog_entity.score = score;
            recog_entity.description = null;
        } else if (hasSubwordPrefix(text[tok.start..tok.end])) {
            std.log.debug("aggregateNerRecogEntityToRecogEntity: is_begin=true, hasSubwordPrefix=true, score={d}", .{score});
            recog_entity.end = tok.end;
            recog_entity.score = score;
            recog_entity.description = null;
        } else {
            // another same type entity is found, break the loop
            std.log.debug("aggregateNerRecogEntityToRecogEntity: is_begin=true, hasSubwordPrefix=false, score={d}", .{score});
            break;
        }
    }

    idx.* = i;
    if (!have_entity) {
        std.log.debug("aggregateNerRecogEntityToRecogEntity: !have_entity, pos={d}", .{pos.*});
        pos.* = text.len;
        return none_recog_entity;
    }
    std.log.debug("aggregateNerRecogEntityToRecogEntity: return recog_entity, pos={d}", .{pos.*});
    return recog_entity;
}

fn hasSubwordPrefix(word: []const u8) bool {
    if (word.len >= 2 and word[0] == '#' and word[1] == '#') return true;
    return false;
}
