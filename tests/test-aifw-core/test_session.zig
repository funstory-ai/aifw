const std = @import("std");
const core = @import("aifw_core");

pub fn main() !void {
    const session = core.aifw_session_create(&.{ .ner_recog_type = .token_classification });
    defer core.aifw_session_destroy(session);

    const input = "Hi, my email is example.test@funstory.com, my phone number is 13800138027";
    var masked_text: [*:0]u8 = undefined;
    var err_no = core.aifw_session_mask(
        session,
        input,
        &[_]core.NerRecognizer.NerRecogEntity{},
        0,
        &masked_text,
    );
    if (err_no != 0) {
        std.log.err("failed to mask, error={s}\n", .{core.getErrorString(err_no)});
        return error.TestFailed;
    }
    // defer allocator.free(std.mem.span(masked_text));

    var restored_text: [*:0]u8 = undefined;
    err_no = core.aifw_session_restore(
        session,
        masked_text,
        &restored_text,
    );
    if (err_no != 0) {
        std.log.err("failed to restore, error={s}\n", .{core.getErrorString(err_no)});
        return error.TestFailed;
    }
    // defer allocator.free(std.mem.span(restored_text));

    std.debug.print("input_text={s}\n", .{input});
    std.debug.print("masked_text={s}\n", .{masked_text});
    std.debug.print("restored_text={s}\n", .{restored_text});
}
