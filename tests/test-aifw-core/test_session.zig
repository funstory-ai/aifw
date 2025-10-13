const std = @import("std");
const core = @import("aifw_core");

pub fn main() !void {
    defer core.aifw_shutdown();

    try test_session_mask_and_restore_with_meta();
}

fn test_session_mask_and_restore_with_meta() !void {
    const session = core.aifw_session_create(&.{ .ner_recog_type = .token_classification });
    if (@intFromPtr(session) == 0) {
        std.log.err("failed to create session\n", .{});
        return error.TestFailed;
    }
    defer core.aifw_session_destroy(session);

    const input1 = "Hi, my email is example.test@funstory.com, my phone number is 13800138027, my name is John Doe";
    const ner_entities1 = [_]core.NerRecognizer.NerRecogEntity{
        .{ .entity_type = .USER_MAME, .entity_tag = .Begin, .score = 0.98, .index = 14, .start = 86, .end = 90 },
        .{ .entity_type = .USER_MAME, .entity_tag = .Inside, .score = 0.98, .index = 15, .start = 91, .end = 94 },
    };
    var masked_text1: [*:0]u8 = undefined;
    var mask_meta_data1: *anyopaque = undefined;
    var err_no = core.aifw_session_mask_and_out_meta(
        session,
        input1,
        &ner_entities1,
        ner_entities1.len,
        &masked_text1,
        &mask_meta_data1,
    );
    if (err_no != 0) {
        std.log.err("failed to mask, error={s}\n", .{core.getErrorString(err_no)});
        return error.TestFailed;
    }
    defer core.aifw_string_free(masked_text1);

    const input2 = "Contact me: a.b+1@test.io and visit https://ziglang.org, my name is John Doe.";
    const ner_entities2 = [_]core.NerRecognizer.NerRecogEntity{
        .{ .entity_type = .USER_MAME, .entity_tag = .Begin, .score = 0.98, .index = 10, .start = 68, .end = 77 },
    };
    var masked_text2: [*:0]u8 = undefined;
    var mask_meta_data2: *anyopaque = undefined;
    err_no = core.aifw_session_mask_and_out_meta(
        session,
        input2,
        &ner_entities2,
        ner_entities2.len,
        &masked_text2,
        &mask_meta_data2,
    );
    if (err_no != 0) {
        std.log.err("failed to mask, error={s}\n", .{core.getErrorString(err_no)});
        return error.TestFailed;
    }
    defer core.aifw_string_free(masked_text2);

    var restored_text1: [*:0]allowzero u8 = undefined;
    err_no = core.aifw_session_restore_with_meta(
        session,
        masked_text1,
        mask_meta_data1,
        &restored_text1,
    );
    if (err_no != 0) {
        std.log.err("failed to restore, error={s}\n", .{core.getErrorString(err_no)});
        return error.TestFailed;
    }
    try std.testing.expect(@intFromPtr(restored_text1) != 0);
    const restored_text1_nonzero = @as([*:0]u8, @ptrCast(restored_text1));
    defer core.aifw_string_free(@as([*:0]u8, @ptrCast(restored_text1_nonzero)));
    std.debug.print("input_text1={s}\n", .{input1});
    std.debug.print("masked_text1={s}\n", .{masked_text1});
    std.debug.print("restored_text1={s}\n", .{restored_text1_nonzero});
    try std.testing.expect(std.mem.eql(u8, std.mem.span(restored_text1_nonzero), input1));

    var restored_text2: [*:0]allowzero u8 = undefined;
    err_no = core.aifw_session_restore_with_meta(
        session,
        masked_text2,
        mask_meta_data2,
        &restored_text2,
    );
    if (err_no != 0) {
        std.log.err("failed to restore, error={s}\n", .{core.getErrorString(err_no)});
        return error.TestFailed;
    }
    try std.testing.expect(@intFromPtr(restored_text2) != 0);
    const restored_text2_nonzero = @as([*:0]u8, @ptrCast(restored_text2));
    defer core.aifw_string_free(@as([*:0]u8, @ptrCast(restored_text2_nonzero)));
    std.debug.print("input_text2={s}\n", .{input2});
    std.debug.print("masked_text2={s}\n", .{masked_text2});
    std.debug.print("restored_text2={s}\n", .{restored_text2_nonzero});
    try std.testing.expect(std.mem.eql(u8, std.mem.span(restored_text2_nonzero), input2));
}
