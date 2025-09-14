const std = @import("std");
const entity = @import("recog_entity.zig");

pub const RecogEntity = entity.RecogEntity;
pub const EntityType = entity.EntityType;

pub const TaskKind = enum { token_classification, sequence_classification };

pub const NerRecognizer = struct {
    allocator: std.mem.Allocator,
    kind: TaskKind,

    pub fn init(allocator: std.mem.Allocator, kind: TaskKind) NerRecognizer {
        return .{ .allocator = allocator, .kind = kind };
    }

    /// Convert external NER output (already decoded by caller) to RecogEntity list.
    /// token_classification: items = []struct{ start:usize, end:usize, score:f32, et:EntityType }
    /// sequence_classification: items = []struct{ score:f32, et:EntityType }, mapped to [0..text.len)
    pub fn fromExternal(self: *const NerRecognizer, text: []const u8, items: anytype) ![]RecogEntity {
        var out = try std.ArrayList(RecogEntity).initCapacity(self.allocator, 8);
        defer out.deinit(self.allocator);
        switch (self.kind) {
            .token_classification => {
                for (items) |it| {
                    try out.append(self.allocator, .{
                        .entity_type = it.et,
                        .start = it.start,
                        .end = it.end,
                        .score = it.score,
                        .description = null,
                    });
                }
            },
            .sequence_classification => {
                for (items) |it| {
                    try out.append(self.allocator, .{
                        .entity_type = it.et,
                        .start = 0,
                        .end = text.len,
                        .score = it.score,
                        .description = null,
                    });
                }
            },
        }
        return try out.toOwnedSlice(self.allocator);
    }
};
