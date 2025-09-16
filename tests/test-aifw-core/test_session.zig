const std = @import("std");
const core = @import("aifw_core");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var session = try core.Session.init(allocator, .{ .ner_recog_type = .token_classification });
    defer session.deinit();

    const input = "Hi, my email is example.test@funstory.com, my phone number is 13800138027";
    const out_mask = (try session.getPipeline(.mask).run(.{
        .mask = .{
            .original_text = input,
            .ner_data = .{
                .text = input,
                .ner_entities = &[_]core.NerRecognizer.NerRecogEntity{},
                .ner_entity_count = 0,
            },
        },
    })).mask;
    defer out_mask.deinit(allocator);

    const out_restore = (try session.getPipeline(.restore).run(.{
        .restore = .{
            .masked_text = out_mask.masked_text,
            .mask_meta_data = out_mask.mask_meta_data,
        },
    })).restore;
    defer out_restore.deinit(allocator);

    std.debug.print("input_text={s}\n", .{input});
    std.debug.print("masked_text={s}\n", .{out_mask.masked_text});
    std.debug.print("restored_text={s}\n", .{out_restore.restored_text});
}
