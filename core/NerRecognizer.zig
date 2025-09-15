const std = @import("std");
const entity = @import("recog_entity.zig");
const NerRecognizer = @This();

allocator: std.mem.Allocator,
ner_recog_type: NerRecogType,

pub const RecogEntity = entity.RecogEntity;
pub const EntityType = entity.EntityType;

pub const NerRecogType = enum { token_classification, sequence_classification };

pub const NerRecogData = struct {
    text: []const u8,
    entities: []NerRecogEntity,
};

pub const NerRecogEntity = struct {
    entity: EntityType,
    score: f32,
    index: usize,
    start: usize,
    end: usize,

    pub fn getWordFromText(self: *const NerRecogEntity, text: []const u8) []const u8 {
        return text[self.start..self.end];
    }
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
/// sequence_classification: items = []struct{ score:f32, et:EntityType }, mapped to [0..text.len)
pub fn run(self: *const NerRecognizer, args: NerRecogData) ![]RecogEntity {
    var out = try std.ArrayList(RecogEntity).initCapacity(self.allocator, 8);
    defer out.deinit(self.allocator);
    switch (self.ner_recog_type) {
        .token_classification => {
            for (args.entities) |recog_entity| {
                try out.append(self.allocator, .{
                    .entity_type = recog_entity.entity,
                    .start = recog_entity.start,
                    .end = recog_entity.end,
                    .score = recog_entity.score,
                    .description = "Get from external NER output with token_classification",
                });
            }
        },
        .sequence_classification => {
            for (args.entities) |recog_entity| {
                try out.append(self.allocator, .{
                    .entity_type = recog_entity.entity,
                    .start = recog_entity.start,
                    .end = recog_entity.end,
                    .score = recog_entity.score,
                    .description = "Get from external NER output with sequence_classification",
                });
            }
        },
    }
    return try out.toOwnedSlice(self.allocator);
}
