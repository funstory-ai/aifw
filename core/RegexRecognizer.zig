const std = @import("std");
const entity = @import("recog_entity.zig");
const StringHashMap = std.StringHashMap(*anyopaque);
const StaticStringMap = std.StaticStringMap(usize);
extern fn aifw_regex_compile(pattern: [*:0]const u8) ?*anyopaque;
extern fn aifw_regex_free(re: *anyopaque) void;
extern fn aifw_regex_find(
    re: *anyopaque,
    hay_ptr: [*]const u8,
    hay_len: usize,
    start: u32,
    out_start: *u32,
    out_end: *u32,
) c_int;
const RegexRecognizer = @This();

allocator: std.mem.Allocator,
compiled_regexs: []CompiledRegex,
supported_entity_type: EntityType,
// The function to validate result of mached text
validate_result_fn: ?ValidateResultFn,
// Compiled regex lifetime is global; recognizer only holds references

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
    pattern_text: []const u8,
    re: *anyopaque,
    score: f32,
};

/// The specs maybe empty, if the specs is empty, the list of compiled regexs of
/// this recognizer is default static compiled regexs initialized by buildStaticOnce.
pub fn init(
    allocator: std.mem.Allocator,
    specs: []const PatternSpec,
    entity_type: EntityType,
    validate_fn: ?ValidateResultFn,
) !RegexRecognizer {
    try buildStaticOnce(allocator);
    var list = try std.ArrayList(CompiledRegex).initCapacity(allocator, 2);
    errdefer list.deinit(allocator);
    // Always include static compiled regexes for this entity type (copy into owned storage)
    try appendStaticCompiledForEntity(allocator, entity_type, &list);
    if (specs.len > 0) {
        for (specs) |s| {
            // Skip if this dynamic pattern is already included by the static set for this entity
            const is_exist, const re_ptr = try getCompiledForPattern(allocator, s.pattern);
            if (is_exist) continue;
            try list.append(allocator, .{ .name = s.name, .pattern_text = s.pattern, .re = re_ptr, .score = s.score });
        }
    }
    return RegexRecognizer{
        .allocator = allocator,
        .compiled_regexs = try list.toOwnedSlice(allocator),
        .supported_entity_type = entity_type,
        .validate_result_fn = validate_fn,
    };
}

pub fn deinit(self: *const RegexRecognizer) void {
    // Only free the slice; compiled regex objects are managed globally
    self.allocator.free(self.compiled_regexs);
}

pub fn run(self: *const RegexRecognizer, input: []const u8) ![]RecogEntity {
    var out = try std.ArrayList(RecogEntity).initCapacity(self.allocator, 2);
    errdefer out.deinit(self.allocator);

    std.log.debug("[regex] run type={s} compiled={d}", .{ @tagName(self.supported_entity_type), self.compiled_regexs.len });
    for (self.compiled_regexs) |c| {
        std.log.debug("[regex] try pattern: {s} / {s}", .{ c.name, c.pattern_text });
        var pos: u32 = 0;
        while (pos <= input.len) {
            var s: u32 = 0;
            var e: u32 = 0;
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
    std.log.debug("[regex] primary matches: {d}", .{out.items.len});
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

// --- Global caches: static presets (StaticStringMap -> index -> slot) and dynamic patterns ---
var g_cache_inited: bool = false;
var g_cache_alloc: ?std.mem.Allocator = null;

// Static mapping of pattern -> index (comptime)
const KV_PATTERN_SLOT = struct { []const u8, usize };

const KVS_PATTERN_SLOT = [_]KV_PATTERN_SLOT{
    .{ EMAIL_SPECS[0].pattern, 0 },
    .{ URL_SPECS[0].pattern, 1 },
    .{ PHONE_SPECS[0].pattern, 2 },
    .{ BANK_SPECS[0].pattern, 3 },
    .{ PRIVKEY_SPECS[0].pattern, 4 },
    .{ PRIVKEY_SPECS[1].pattern, 5 },
    .{ VCODE_SPECS[0].pattern, 6 },
    .{ PASSWORD_SPECS[0].pattern, 7 },
    .{ SEED_SPECS[0].pattern, 8 },
};
const STATIC_MAP = StaticStringMap.initComptime(&KVS_PATTERN_SLOT);

var g_static_slots: [KVS_PATTERN_SLOT.len]?*anyopaque = undefined;

// Dynamic map for runtime-added patterns
var g_dynamic_map: StringHashMap = undefined;
var g_dynamic_keys: std.ArrayListUnmanaged([]u8) = .{}; // own copies of dynamic pattern strings

fn ensureMapsInit(allocator: std.mem.Allocator) void {
    if (g_cache_inited) return;
    g_dynamic_map = StringHashMap.init(allocator);
    g_dynamic_keys = .{};
    // init static slots
    for (&g_static_slots) |*slot| slot.* = null;
    g_cache_alloc = allocator;
    g_cache_inited = true;
}

fn compileRegex(allocator: std.mem.Allocator, pattern: []const u8) !*anyopaque {
    const patz = try std.fmt.allocPrintSentinel(allocator, "{s}", .{pattern}, 0);
    defer allocator.free(patz);
    const re_ptr = aifw_regex_compile(patz) orelse return error.RegexCompileFailed;
    return re_ptr;
}

fn buildStaticOnce(allocator: std.mem.Allocator) !void {
    ensureMapsInit(allocator);
    // If already compiled, skip
    if (g_static_slots[0] != null) return;
    var i: usize = 0;
    while (i < KVS_PATTERN_SLOT.len) : (i += 1) {
        const re = try compileRegex(allocator, KVS_PATTERN_SLOT[i].@"0");
        g_static_slots[i] = re;
    }
}

fn appendStaticCompiledForEntity(
    allocator: std.mem.Allocator,
    entity_type: EntityType,
    list: *std.ArrayList(CompiledRegex),
) !void {
    switch (entity_type) {
        .EMAIL_ADDRESS => try list.append(allocator, .{
            .name = EMAIL_SPECS[0].name,
            .pattern_text = EMAIL_SPECS[0].pattern,
            .re = g_static_slots[0].?,
            .score = EMAIL_SPECS[0].score,
        }),
        .URL_ADDRESS => try list.append(allocator, .{
            .name = URL_SPECS[0].name,
            .pattern_text = URL_SPECS[0].pattern,
            .re = g_static_slots[1].?,
            .score = URL_SPECS[0].score,
        }),
        .PHONE_NUMBER => try list.append(allocator, .{
            .name = PHONE_SPECS[0].name,
            .pattern_text = PHONE_SPECS[0].pattern,
            .re = g_static_slots[2].?,
            .score = PHONE_SPECS[0].score,
        }),
        .BANK_NUMBER => try list.append(allocator, .{
            .name = BANK_SPECS[0].name,
            .pattern_text = BANK_SPECS[0].pattern,
            .re = g_static_slots[3].?,
            .score = BANK_SPECS[0].score,
        }),
        .PRIVATE_KEY => {
            try list.append(allocator, .{
                .name = PRIVKEY_SPECS[0].name,
                .pattern_text = PRIVKEY_SPECS[0].pattern,
                .re = g_static_slots[4].?,
                .score = PRIVKEY_SPECS[0].score,
            });
            try list.append(allocator, .{
                .name = PRIVKEY_SPECS[1].name,
                .pattern_text = PRIVKEY_SPECS[1].pattern,
                .re = g_static_slots[5].?,
                .score = PRIVKEY_SPECS[1].score,
            });
        },
        .VERIFICATION_CODE => try list.append(allocator, .{
            .name = VCODE_SPECS[0].name,
            .pattern_text = VCODE_SPECS[0].pattern,
            .re = g_static_slots[6].?,
            .score = VCODE_SPECS[0].score,
        }),
        .PASSWORD => try list.append(allocator, .{
            .name = PASSWORD_SPECS[0].name,
            .pattern_text = PASSWORD_SPECS[0].pattern,
            .re = g_static_slots[7].?,
            .score = PASSWORD_SPECS[0].score,
        }),
        .RANDOM_SEED => try list.append(allocator, .{
            .name = SEED_SPECS[0].name,
            .pattern_text = SEED_SPECS[0].pattern,
            .re = g_static_slots[8].?,
            .score = SEED_SPECS[0].score,
        }),
        else => {},
    }
}

fn getCompiledForPattern(allocator: std.mem.Allocator, pattern: []const u8) !struct { bool, *anyopaque } {
    ensureMapsInit(allocator);
    if (STATIC_MAP.get(pattern)) |idx| {
        if (g_static_slots[idx]) |p| return .{ true, p };
        const re2 = try compileRegex(allocator, pattern);
        g_static_slots[idx] = re2;
        return .{ false, re2 };
    }
    if (g_dynamic_map.get(pattern)) |re| return .{ true, re };
    // compile dynamically and insert into dynamic map; own the key copy
    const key_copy = try allocator.dupe(u8, pattern);
    errdefer allocator.free(key_copy);
    const re = try compileRegex(allocator, pattern);
    try g_dynamic_map.put(key_copy, re);
    try g_dynamic_keys.append(allocator, key_copy);
    return .{ false, re };
}

pub fn shutdownCache() void {
    if (!g_cache_inited) return;
    // Free all regex pointers from both caches
    for (&g_static_slots) |*slot|
        if (slot.*) |regex| {
            aifw_regex_free(regex);
            slot.* = null;
        };

    {
        var it2 = g_dynamic_map.iterator();
        while (it2.next()) |e| {
            aifw_regex_free(e.value_ptr.*);
        }
    }
    // Free dynamic keys we allocated
    if (g_cache_alloc) |alloc| {
        for (g_dynamic_keys.items) |k| alloc.free(k);
        g_dynamic_keys.deinit(alloc);
    }
    g_dynamic_map.deinit();
    g_cache_inited = false;
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
