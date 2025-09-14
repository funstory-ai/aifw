const std = @import("std");
const entity = @import("recog_entity.zig");
extern fn aifw_regex_compile(pattern: [*:0]const u8) ?*anyopaque;
extern fn aifw_regex_free(re: *anyopaque) void;
extern fn aifw_regex_find(
    re: *anyopaque,
    hay_ptr: [*]const u8,
    hay_len: usize,
    start: usize,
    out_start: *usize,
    out_end: *usize,
) c_int;
const RegexRecognizer = @This();

allocator: std.mem.Allocator,
compiled_regexs: []CompiledRegex,
supported_entity_type: EntityType,
// The function to validate result of mached text
validate_result_fn: ?ValidateResultFn,

/// Sometimes, regular expression matching is just a preliminary screening. After
/// a successful regular expression match, you need to call the validate_result_fn
/// function to strictly check whether the matched text content is valid. For example,
/// matching web3 addresses, cryptocurrency addresses, etc., require further
/// validation by validate_result_fn.
/// Use function pointer type to avoid comptime-only fn type.
/// The return value is the confidence score.
pub const ValidateResultFn = *const fn ([]const u8) ?f32;

const EntityType = entity.EntityType;
const RecogEntity = entity.RecogEntity;

pub const PatternSpec = struct {
    name: []const u8,
    pattern: []const u8,
    score: f32,
};

const CompiledRegex = struct {
    name: []const u8,
    re: *anyopaque,
    score: f32,
};

pub fn init(
    allocator: std.mem.Allocator,
    specs: []const PatternSpec,
    entity_type: EntityType,
    validate_fn: ?ValidateResultFn,
) !RegexRecognizer {
    var list = try std.ArrayList(CompiledRegex).initCapacity(allocator, specs.len);
    errdefer {
        for (list.items) |c| {
            aifw_regex_free(c.re);
        }
        list.deinit(allocator);
    }
    for (specs) |s| {
        const patz = try std.fmt.allocPrintSentinel(allocator, "{s}", .{s.pattern}, 0);
        defer allocator.free(patz);
        const re_ptr = aifw_regex_compile(patz) orelse return error.RegexCompileFailed;
        list.appendAssumeCapacity(.{ .name = s.name, .re = re_ptr, .score = s.score });
    }
    return RegexRecognizer{
        .allocator = allocator,
        .compiled_regexs = try list.toOwnedSlice(allocator),
        .supported_entity_type = entity_type,
        .validate_result_fn = validate_fn,
    };
}

pub fn deinit(self: *const RegexRecognizer) void {
    for (self.compiled_regexs) |c| aifw_regex_free(c.re);
    self.allocator.free(self.compiled_regexs);
}

pub fn run(self: *const RegexRecognizer, input: []const u8) ![]RecogEntity {
    var out = try std.ArrayList(RecogEntity).initCapacity(self.allocator, 2);
    errdefer out.deinit(self.allocator);

    for (self.compiled_regexs) |c| {
        var pos: usize = 0;
        while (pos <= input.len) {
            var s: usize = 0;
            var e: usize = 0;
            const rc = aifw_regex_find(c.re, input.ptr, input.len, pos, &s, &e);
            if (rc < 0) break; // error
            if (rc == 0) break; // no more
            const score = if (self.validate_result_fn) |validate_result|
                validate_result(input[s..e]) orelse c.score
            else
                c.score;
            try out.append(self.allocator, .{
                .entity_type = self.supported_entity_type,
                .start = s,
                .end = e,
                .score = score,
                .description = null,
            });
            pos = if (e > pos) e else pos + 1;
        }
    }
    return try out.toOwnedSlice(self.allocator);
}

// ------------------------- Preset Patterns -------------------------
/// Return preset pattern specs for a given entity type. Backed by static slices.
pub fn presetSpecsFor(t: EntityType) []const PatternSpec {
    return switch (t) {
        .EMAIL_ADDRESS => EMAIL_SPECS[0..],
        .URL_ADDRESS => URL_SPECS[0..],
        .PHONE_NUMBER => PHONE_SPECS[0..],
        .BANK_NUMBER => BANK_SPECS[0..],
        .PRIVATE_KEY => PRIVKEY_SPECS[0..],
        .VERIFICATION_CODE => VCODE_SPECS[0..],
        .PASSWORD => PASSWORD_SPECS[0..],
        .RANDOM_SEED => SEED_SPECS[0..],
        else => &[_]PatternSpec{},
    };
}

const EMAIL_SPECS = [_]PatternSpec{
    .{ .name = "EMAIL", .pattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", .score = 0.90 },
};

const URL_SPECS = [_]PatternSpec{
    .{ .name = "URL", .pattern = "https?://[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+", .score = 0.80 },
};

const PHONE_SPECS = [_]PatternSpec{
    .{ .name = "PHONE", .pattern = "\\+?\\d[\\d -]{7,}\\d", .score = 0.70 },
};

const BANK_SPECS = [_]PatternSpec{
    // 12-19 digits continuous (typical card/account length ranges)
    .{ .name = "BANK", .pattern = "\\b\\d{12,19}\\b", .score = 0.60 },
};

const PRIVKEY_SPECS = [_]PatternSpec{
    // PEM block headers for common private keys
    .{ .name = "PEM_PRIVKEY", .pattern = "-----BEGIN (?:OPENSSH|RSA|EC|DSA) PRIVATE KEY-----[\\s\\S]*?-----END (?:OPENSSH|RSA|EC|DSA) PRIVATE KEY-----", .score = 0.95 },
    // 64 hex chars (common raw hex private key length)
    .{ .name = "HEX_PRIVKEY", .pattern = "\\b[0-9a-fA-F]{64}\\b", .score = 0.75 },
};

const VCODE_SPECS = [_]PatternSpec{
    // 4-8 digit codes
    .{ .name = "VCODE", .pattern = "\\b\\d{4,8}\\b", .score = 0.50 },
};

const PASSWORD_SPECS = [_]PatternSpec{
    // password: <non-space>, case-insensitive not used; match common literals
    .{ .name = "PASSWORD_LITERAL", .pattern = "(?i)password\\s*[:=]\\s*\\S+", .score = 0.40 },
};

const SEED_SPECS = [_]PatternSpec{
    // seed/mnemonic followed by 12-24 lowercase words (approximate)
    .{ .name = "SEED_PHRASE", .pattern = "(?i)(seed|mnemonic)\\s*[:=]?\\s*([a-z]+\\s+){11,23}[a-z]+", .score = 0.70 },
};

/// Helper to build recognizer for a given entity type.
pub fn buildRecognizerFor(
    allocator: std.mem.Allocator,
    entity_type: EntityType,
    validate_fn: ?ValidateResultFn,
) !RegexRecognizer {
    const specs = presetSpecsFor(entity_type);
    if (specs.len == 0) return error.NoSpecs;
    return RegexRecognizer.init(allocator, specs, entity_type, validate_fn);
}

test "regex recognizer finds simple email" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const specs = [_]PatternSpec{
        .{
            .name = "EMAIL",
            .pattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
            .score = 0.9,
        },
    };
    var rec = try RegexRecognizer.init(alloc, specs[0..], .EMAIL_ADDRESS, null);
    defer rec.deinit();

    const text = "contact me at a.b+1@test.io";
    const ents = try rec.run(text);
    defer alloc.free(ents);

    try std.testing.expect(ents.len == 1);
    try std.testing.expectEqual(.EMAIL_ADDRESS, ents[0].entity_type);
    try std.testing.expectEqualStrings(text[ents[0].start..ents[0].end], "a.b+1@test.io");
}
