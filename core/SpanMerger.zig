const std = @import("std");
const entity = @import("recog_entity.zig");

pub const RecogEntity = entity.RecogEntity;
pub const EntityType = entity.EntityType;

pub const Config = struct {
    whitelist: []const EntityType, // accept only these if non-empty
    blacklist: []const EntityType, // drop these if present
    threshold: f32, // min score
};

fn inSet(set: []const EntityType, t: EntityType) bool {
    var i: usize = 0;
    while (i < set.len) : (i += 1) {
        if (set[i] == t) return true;
    }
    return false;
}

pub fn merge(allocator: std.mem.Allocator, a: []const RecogEntity, b: []const RecogEntity, cfg: Config) ![]RecogEntity {
    var tmp = try std.ArrayList(RecogEntity).initCapacity(allocator, a.len + b.len);
    defer tmp.deinit(allocator);
    for (a) |e| try tmp.append(allocator, e);
    for (b) |e| try tmp.append(allocator, e);

    var spans = try tmp.toOwnedSlice(allocator);
    errdefer allocator.free(spans);

    var filtered = try std.ArrayList(RecogEntity).initCapacity(allocator, spans.len);
    defer filtered.deinit(allocator);
    for (spans) |e| {
        if (e.score < cfg.threshold) continue;
        if (cfg.whitelist.len > 0 and !inSet(cfg.whitelist, e.entity_type)) continue;
        if (cfg.blacklist.len > 0 and inSet(cfg.blacklist, e.entity_type)) continue;
        try filtered.append(allocator, e);
    }
    allocator.free(spans);
    spans = try filtered.toOwnedSlice(allocator);

    std.sort.block(RecogEntity, spans, {}, struct {
        fn lessThan(_: void, a: RecogEntity, b: RecogEntity) bool {
            return if (a.start == b.start) a.end < b.end else a.start < b.start;
        }
    }.lessThan);

    var out = try std.ArrayList(RecogEntity).initCapacity(allocator, spans.len);
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < spans.len) : (i += 1) {
        const cur = spans[i];
        if (out.items.len == 0) {
            try out.append(allocator, cur);
        } else {
            const last = out.items[out.items.len - 1];
            if (cur.start == last.start and cur.end == last.end) {
                if (cur.score > last.score) out.items[out.items.len - 1] = cur;
            } else {
                try out.append(allocator, cur);
            }
        }
    }
    allocator.free(spans);
    return try out.toOwnedSlice(allocator);
}
