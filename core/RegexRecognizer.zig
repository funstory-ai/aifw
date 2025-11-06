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
extern fn aifw_regex_find_group(
    re: *anyopaque,
    hay_ptr: [*]const u8,
    hay_len: usize,
    start: u32,
    group_index: u32,
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
    group_index: u32,
};

const CompiledRegex = struct {
    name: []const u8,
    pattern_text: []const u8,
    re: *anyopaque,
    score: f32,
    group_index: u32,
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
            try list.append(allocator, .{ .name = s.name, .pattern_text = s.pattern, .re = re_ptr, .score = s.score, .group_index = s.group_index });
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
            const rc = if (c.group_index == 0)
                aifw_regex_find(c.re, input.ptr, input.len, pos, &s, &e)
            else
                aifw_regex_find_group(c.re, input.ptr, input.len, pos, c.group_index, &s, &e);
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

fn runChineseAddress(self: *const RegexRecognizer, input: []const u8) !?[]RecogEntity {
    var out = try std.ArrayList(RecogEntity).initCapacity(self.allocator, 4);
    errdefer out.deinit(self.allocator);

    var pos: usize = 0;
    while (pos < input.len) : (pos += 1) {
        const rlen = hasRoadSuffix(input, @intCast(pos));
        if (rlen == 0) continue;
        // find left chunk before road suffix
        var s: usize = pos;
        var cnt: usize = 0;
        while (s > 0 and cnt < 32) : (s -= 1) {
            const b = input[s - 1];
            if (isAsciiAlnum(b) or (b & 0x80) != 0) {
                cnt += 1;
            } else break;
        }
        if (cnt < 2) continue;
        const road_end = pos + rlen;
        const end_ext = rightExtendCnAddr(input, @intCast(road_end));

        var start_ext: usize = s;
        var k: usize = 0;
        while (k < 3 and start_ext > 0) : (k += 1) {
            // skip ASCII light separators
            var p: usize = start_ext;
            while (p > 0) : (p -= 1) {
                const b = input[p - 1];
                if (!isAsciiLight(b)) break;
            }
            const ad = hasAdminSuffix(input, @intCast(p));
            if (ad == 0) break;
            // find chunk before admin suffix
            var s2: usize = p;
            var c2: usize = 0;
            while (s2 > 0 and c2 < 32) : (s2 -= 1) {
                const b2 = input[s2 - 1];
                if (isAsciiAlnum(b2) or (b2 & 0x80) != 0) {
                    c2 += 1;
                } else break;
            }
            if (c2 < 2) break;
            start_ext = s2;
        }

        try out.append(self.allocator, .{
            .entity_type = .PHYSICAL_ADDRESS,
            .start = @intCast(start_ext),
            .end = end_ext,
            .score = 0.98,
            .description = null,
        });
        pos = @intCast(end_ext);
    }

    // Merge adjacent address fragments if separated by at most one light connector
    if (out.items.len >= 2) {
        var merged = try std.ArrayList(RecogEntity).initCapacity(self.allocator, out.items.len);
        defer merged.deinit(self.allocator);
        var i: usize = 1;
        var cur = out.items[0];
        while (i < out.items.len) : (i += 1) {
            const nxt = out.items[i];
            const between = if (nxt.start > cur.end) input[cur.end..nxt.start] else input[0..0];
            const trimmed = std.mem.trim(u8, between, " \t\r\n,");
            const contiguous = (trimmed.len == 0);
            if (contiguous and nxt.start >= cur.end) {
                cur.end = nxt.end;
                if (nxt.score > cur.score) cur.score = nxt.score;
            } else {
                try merged.append(self.allocator, cur);
                cur = nxt;
            }
        }
        try merged.append(self.allocator, cur);
        return try merged.toOwnedSlice(self.allocator);
    }
    return try out.toOwnedSlice(self.allocator);
}

fn rightExtendCnAddr(input: []const u8, start_end: u32) u32 {
    var i: usize = start_end;
    const n = input.len;
    // skip ASCII light seps
    while (i < n) : (i += 1) {
        const b = input[i];
        if (!(b == ' ' or b == '\t' or b == '\r' or b == '\n' or b == ',')) break;
    }
    const begin_digits = i;
    // digits
    while (i < n and input[i] >= '0' and input[i] <= '9') : (i += 1) {}
    if (i == begin_digits) return start_end; // no digits -> no tail
    // require 号/號
    if (matchToken(input, i, "号")) {
        i += "号".len;
    } else if (matchToken(input, i, "號")) {
        i += "號".len;
    } else {
        return start_end;
    }
    // optional: 之 + digits
    var j: usize = i;
    if (matchToken(input, j, "之")) {
        j += "之".len;
        const d0 = j;
        while (j < n and input[j] >= '0' and input[j] <= '9') : (j += 1) {}
        if (j > d0) i = j;
    }
    // optional: - + digits
    if (i < n and input[i] == '-') {
        j = i + 1;
        const d1 = j;
        while (j < n and input[j] >= '0' and input[j] <= '9') : (j += 1) {}
        if (j > d1) i = j;
    }
    // optional unit tokens
    const UNITS = [_][]const u8{ "楼", "館", "樓", "栋", "棟", "幢", "座", "单元", "室" };
    for (UNITS) |u| {
        if (matchToken(input, i, u)) {
            i += u.len;
            break;
        }
    }
    return @intCast(i);
}

fn matchToken(hay: []const u8, pos: usize, tok: []const u8) bool {
    if (pos >= hay.len) return false;
    const end = pos + tok.len;
    if (end > hay.len) return false;
    return std.mem.eql(u8, hay[pos..end], tok);
}

fn hasRoadSuffix(text: []const u8, pos: u32) usize {
    // Check whether a known road suffix immediately follows position 'pos'
    const SUF = [_][]const u8{
        "大道", "大街", "环路", "环线", "路", "街", "巷", "弄", "里", "道", "胡同", "段", "期",
        // Traditional forms for safety
        "環路", "環線",
    };
    var i: usize = 0;
    while (i < SUF.len) : (i += 1) {
        if (matchToken(text, pos, SUF[i])) return SUF[i].len;
    }
    return 0;
}

fn hasAdminSuffix(text: []const u8, pos: u32) usize {
    const ADMIN = [_][]const u8{
        "省", "市", "自治州", "自治区", "州", "盟", "地区", "特别行政区", "区", "區", "县", "縣", "旗", "新区", "高新区", "经济技术开发区", "开发区", "街道", "镇", "鎮", "乡", "鄉", "里", "村",
    };
    var i: usize = 0;
    while (i < ADMIN.len) : (i += 1) {
        const suf = ADMIN[i];
        const start = if (pos >= suf.len) pos - suf.len else 0;
        if (start > 0 and matchToken(text, start, suf)) return suf.len;
    }
    return 0;
}

fn isAsciiAlnum(b: u8) bool {
    return (b >= '0' and b <= '9') or (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z');
}

fn isAsciiLight(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r' or b == '\n' or b == ',';
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
    .{ .name = "EMAIL", .pattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", .score = 0.90, .group_index = 0 },
};

const URL_SPECS = [_]PatternSpec{
    .{ .name = "URL", .pattern = "https?://[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+", .score = 0.80, .group_index = 0 },
};

const PHONE_SPECS = [_]PatternSpec{
    .{ .name = "PHONE", .pattern = "\\+?\\d[\\d -]{7,}\\d", .score = 0.70, .group_index = 0 },
};

const BANK_SPECS = [_]PatternSpec{
    // 12-19 digits continuous (typical card/account length ranges)
    .{ .name = "BANK", .pattern = "\\b\\d{12,19}\\b", .score = 0.60, .group_index = 0 },
};

const PRIVKEY_SPECS = [_]PatternSpec{
    // PEM block headers for common private keys
    .{ .name = "PEM_PRIVKEY", .pattern = "-----BEGIN (?:OPENSSH|RSA|EC|DSA) PRIVATE KEY-----[\\s\\S]*?-----END (?:OPENSSH|RSA|EC|DSA) PRIVATE KEY-----", .score = 0.95, .group_index = 0 },
    // 64 hex chars (common raw hex private key length)
    .{ .name = "HEX_PRIVKEY", .pattern = "\\b[0-9a-fA-F]{64}\\b", .score = 0.75, .group_index = 0 },
};

const VCODE_SPECS = [_]PatternSpec{
    // 4-8 digit codes
    .{ .name = "VCODE", .pattern = "\\b\\d{4,8}\\b", .score = 0.50, .group_index = 0 },
    // Labeled alphanumeric verification codes with capturing group 1 for the value
    .{ .name = "VCODE_LABELED_ALNUM", .pattern = "(?i)\\b(?:verification\\s*code|verify\\s*code|otp|2fa\\s*code|auth(?:entication)?\\s*code)\\s*[:=\\-]?\\s*([A-Za-z0-9]{4,12})", .score = 0.80, .group_index = 1 },
};

const PASSWORD_SPECS = [_]PatternSpec{
    // password: <non-space>
    .{ .name = "PASSWORD_LITERAL", .pattern = "(?i)\\bpassword\\s*[:=]\\s*(\\S+)", .score = 0.40, .group_index = 1 },
    // pwd/pass/passwd/passcode: <non-space>
    .{ .name = "PWD_LITERAL", .pattern = "(?i)\\b(?:pwd|pass|passwd|passcode)\\s*[:=]\\s*(\\S+)", .score = 0.60, .group_index = 1 },
};

const SEED_SPECS = [_]PatternSpec{
    // seed/mnemonic followed by 12-24 lowercase words (approximate)
    .{ .name = "SEED_PHRASE", .pattern = "(?i)(seed|mnemonic)\\s*[:=]?\\s*([a-z]+\\s+){11,23}[a-z]+", .score = 0.70, .group_index = 0 },
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
    .{ VCODE_SPECS[1].pattern, 9 },
    .{ PASSWORD_SPECS[1].pattern, 10 },
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
            .group_index = EMAIL_SPECS[0].group_index,
        }),
        .URL_ADDRESS => try list.append(allocator, .{
            .name = URL_SPECS[0].name,
            .pattern_text = URL_SPECS[0].pattern,
            .re = g_static_slots[1].?,
            .score = URL_SPECS[0].score,
            .group_index = URL_SPECS[0].group_index,
        }),
        .PHONE_NUMBER => try list.append(allocator, .{
            .name = PHONE_SPECS[0].name,
            .pattern_text = PHONE_SPECS[0].pattern,
            .re = g_static_slots[2].?,
            .score = PHONE_SPECS[0].score,
            .group_index = PHONE_SPECS[0].group_index,
        }),
        .BANK_NUMBER => try list.append(allocator, .{
            .name = BANK_SPECS[0].name,
            .pattern_text = BANK_SPECS[0].pattern,
            .re = g_static_slots[3].?,
            .score = BANK_SPECS[0].score,
            .group_index = BANK_SPECS[0].group_index,
        }),
        .PRIVATE_KEY => {
            try list.append(allocator, .{
                .name = PRIVKEY_SPECS[0].name,
                .pattern_text = PRIVKEY_SPECS[0].pattern,
                .re = g_static_slots[4].?,
                .score = PRIVKEY_SPECS[0].score,
                .group_index = PRIVKEY_SPECS[0].group_index,
            });
            try list.append(allocator, .{
                .name = PRIVKEY_SPECS[1].name,
                .pattern_text = PRIVKEY_SPECS[1].pattern,
                .re = g_static_slots[5].?,
                .score = PRIVKEY_SPECS[1].score,
                .group_index = PRIVKEY_SPECS[1].group_index,
            });
        },
        .VERIFICATION_CODE => {
            try list.append(allocator, .{
                .name = VCODE_SPECS[0].name,
                .pattern_text = VCODE_SPECS[0].pattern,
                .re = g_static_slots[6].?,
                .score = VCODE_SPECS[0].score,
                .group_index = VCODE_SPECS[0].group_index,
            });
            try list.append(allocator, .{
                .name = VCODE_SPECS[1].name,
                .pattern_text = VCODE_SPECS[1].pattern,
                .re = g_static_slots[9].?,
                .score = VCODE_SPECS[1].score,
                .group_index = VCODE_SPECS[1].group_index,
            });
        },
        .PASSWORD => {
            try list.append(allocator, .{
                .name = PASSWORD_SPECS[0].name,
                .pattern_text = PASSWORD_SPECS[0].pattern,
                .re = g_static_slots[7].?,
                .score = PASSWORD_SPECS[0].score,
                .group_index = PASSWORD_SPECS[0].group_index,
            });
            try list.append(allocator, .{
                .name = PASSWORD_SPECS[1].name,
                .pattern_text = PASSWORD_SPECS[1].pattern,
                .re = g_static_slots[10].?,
                .score = PASSWORD_SPECS[1].score,
                .group_index = PASSWORD_SPECS[1].group_index,
            });
        },
        .RANDOM_SEED => try list.append(allocator, .{
            .name = SEED_SPECS[0].name,
            .pattern_text = SEED_SPECS[0].pattern,
            .re = g_static_slots[8].?,
            .score = SEED_SPECS[0].score,
            .group_index = SEED_SPECS[0].group_index,
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
            .group_index = 0,
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
