const std = @import("std");
const entity = @import("recog_entity.zig");

pub const RecogEntity = entity.RecogEntity;

fn isAsciiLight(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r' or b == '\n' or b == ',';
}

fn isAsciiAlnum(b: u8) bool {
    return (b >= '0' and b <= '9') or (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z');
}

fn isAsciiAlpha(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z');
}

fn utf8CpLenAt(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return 1;
    const b = text[pos];
    if (b < 0x80) return 1;
    if ((b & 0xE0) == 0xC0) return if (pos + 1 <= text.len) 2 else 1;
    if ((b & 0xF0) == 0xE0) return if (pos + 2 <= text.len) 3 else 1;
    if ((b & 0xF8) == 0xF0) return if (pos + 3 <= text.len) 4 else 1;
    return 1;
}

fn utf8PrevCpStart(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0 and (text[p] & 0xC0) == 0x80) : (p -= 1) {}
    return p;
}

fn matchToken(text: []const u8, pos: usize, token: []const u8) bool {
    if (pos > text.len) return false;
    if (pos + token.len > text.len) return false;
    return std.mem.eql(u8, text[pos .. pos + token.len], token);
}

fn heavySepAt(text: []const u8, pos: usize) usize {
    const HEAVY = [_][]const u8{ "。", "！", "？", "；", "：", "、", "（", "）", "/", "\\", "|" };
    var i: usize = 0;
    while (i < HEAVY.len) : (i += 1) {
        if (matchToken(text, pos, HEAVY[i])) return HEAVY[i].len;
    }
    return 0;
}

fn countCharsBetween(text: []const u8, a: usize, b: usize) usize {
    const lo = @min(a, b);
    const hi = @max(a, b);
    var i: usize = lo;
    var count: usize = 0;
    while (i < hi) : (i += 1) {
        const byte = text[i];
        if ((byte & 0xC0) != 0x80) count += 1;
    }
    return count;
}

fn onlyLightBetween(text: []const u8, a_end: usize, b_start: usize, max_chars: usize) bool {
    var p = a_end;
    var chars: usize = 0;
    while (p < b_start) : (p += 1) {
        if (!isAsciiLight(text[p])) return false;
        const byte = text[p];
        if ((byte & 0xC0) != 0x80) chars += 1;
        if (chars > max_chars) return false;
    }
    return true;
}

fn nearCharsBetween(text: []const u8, a_end: usize, b_start: usize, max_chars: usize) bool {
    const dist = countCharsBetween(text, a_end, b_start);
    return dist <= max_chars;
}

fn endsWithAny(text: []const u8, start: usize, end: usize, toks: []const []const u8) bool {
    if (end <= start) return false;
    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (end >= start + t.len and matchToken(text, end - t.len, t)) return true;
    }
    return false;
}

/// Address level enum. Each bit in the u32 bits represents a address level.
/// The u32 bits is a bitmask of all the address levels.
/// The bits range is from bit8 to bit18.
pub const AddrLevel = enum(u5) {
    L1_unit_room = 1,
    L2_floor,
    L3_building,
    L4_poi,
    L5_house_no,
    L6_road,
    L7_township,
    L8_district,
    L9_city,
    L10_province,
    L11_country_region,
};

const LEVEL_BIT_OFFSET = 8;
const LEVEL_BITS_LEN = @intFromEnum(AddrLevel.L11_country_region) - @intFromEnum(AddrLevel.L1_unit_room) + 1;
const LEVEL_BITS_MASK = ((1 << LEVEL_BITS_LEN) - 1) << LEVEL_BIT_OFFSET;

const BIT_L1: u32 = 1 << (LEVEL_BIT_OFFSET + 0);
const BIT_L2: u32 = 1 << (LEVEL_BIT_OFFSET + 1);
const BIT_L3: u32 = 1 << (LEVEL_BIT_OFFSET + 2);
const BIT_L4: u32 = 1 << (LEVEL_BIT_OFFSET + 3);
const BIT_L5: u32 = 1 << (LEVEL_BIT_OFFSET + 4);
const BIT_L6: u32 = 1 << (LEVEL_BIT_OFFSET + 5);
const BIT_L7: u32 = 1 << (LEVEL_BIT_OFFSET + 6);
const BIT_L8: u32 = 1 << (LEVEL_BIT_OFFSET + 7);
const BIT_L9: u32 = 1 << (LEVEL_BIT_OFFSET + 8);
const BIT_L10: u32 = 1 << (LEVEL_BIT_OFFSET + 9);
const BIT_L11: u32 = 1 << (LEVEL_BIT_OFFSET + 10);

pub const TokenSpan = struct {
    level: AddrLevel,
    start: u32,
    end: u32,
};

fn levelName(lv: AddrLevel) []const u8 {
    return @tagName(lv);
}

fn bitFromLevel(lv: AddrLevel) u32 {
    return @as(u32, 1) << @as(u5, @intFromEnum(lv) + (LEVEL_BIT_OFFSET - 1));
}

fn levelRank(lv: AddrLevel) u8 {
    return @intFromEnum(lv);
}

fn highestRankInBits(bits: u32) u8 {
    const checked_bits = bits & LEVEL_BITS_MASK;
    if (checked_bits == 0) return 0;
    const lead_zero_bits = @clz(checked_bits);
    return (31 - lead_zero_bits) - (LEVEL_BIT_OFFSET - 1);
}

fn lowestRankInBits(bits: u32) u8 {
    const checked_bits = bits & LEVEL_BITS_MASK;
    if (checked_bits == 0) return 0;
    const tail_zero_bits = @ctz(checked_bits);
    return tail_zero_bits - (LEVEL_BIT_OFFSET - 1);
}

fn mergeAdjacentAddressSpans(allocator: std.mem.Allocator, text: []const u8, spans_in: []const RecogEntity) ![]RecogEntity {
    if (spans_in.len == 0) return allocator.alloc(RecogEntity, 0);
    const tmp_spans = try allocator.dupe(RecogEntity, spans_in);
    defer allocator.free(tmp_spans);
    std.sort.block(RecogEntity, tmp_spans, {}, struct {
        fn lessThan(_: void, a: RecogEntity, b: RecogEntity) bool {
            if (a.start == b.start) return a.end > b.end;
            return a.start < b.start;
        }
    }.lessThan);

    var out = try std.ArrayList(RecogEntity).initCapacity(allocator, tmp_spans.len);
    errdefer out.deinit(allocator);
    var cur = tmp_spans[0];
    var i: usize = 1;
    while (i < tmp_spans.len) : (i += 1) {
        const nxt = tmp_spans[i];
        // skip non-address spans
        if (cur.entity_type != .PHYSICAL_ADDRESS and
            cur.entity_type != .ORGANIZATION)
        {
            std.log.debug("[zh-addr] filter out non-address/organization span: entity_type={s} [{d},{d}) seg={s}", .{ @tagName(cur.entity_type), cur.start, cur.end, text[cur.start..cur.end] });
            cur = nxt;
            continue;
        }
        // merge adjacent address spans
        if (cur.entity_type == .PHYSICAL_ADDRESS and nxt.entity_type == .PHYSICAL_ADDRESS and nxt.start >= cur.end) {
            var ok = true;
            var p: usize = cur.end;
            while (p < nxt.start) : (p += 1) {
                if (!isAsciiLight(text[p])) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                var merged = cur;
                merged.end = nxt.end;
                if (nxt.score > merged.score) merged.score = nxt.score;
                cur = merged;
                continue;
            }
        }
        try out.append(allocator, cur);
        cur = nxt;
    }
    // append last only if it's address, organization, or user name
    if (cur.entity_type == .PHYSICAL_ADDRESS or
        cur.entity_type == .ORGANIZATION)
    {
        try out.append(allocator, cur);
    }
    return try out.toOwnedSlice(allocator);
}

// return the new bits after right attach
fn canRightAttach(
    current_bits: u32,
    cand_level: AddrLevel,
    text: []const u8,
    cur_start: usize,
    cur_end: usize,
    cand_start: usize,
    cand_end: usize,
) u32 {
    const low = lowestRankInBits(current_bits);
    const cand_r = levelRank(cand_level);
    // first token in chain: accept any candidate level and set its bit
    if (low == 0) return current_bits | bitFromLevel(cand_level);
    // strict adjacency
    if (cand_r + 1 == low) return current_bits | bitFromLevel(cand_level);
    // whitelist jump: L11 -> L7 (country region directly to township)
    if (low == levelRank(.L11_country_region) and cand_r == levelRank(.L7_township)) {
        const special_l11_suffixes = &[_][]const u8{"香港"};
        if (onlyLightBetween(text, cur_end, cand_start, 4) and
            endsWithAny(text, cur_start, cur_end, special_l11_suffixes))
        {
            return current_bits | bitFromLevel(cand_level);
        }
    }
    // whitelist jump: L7 -> L3 (township directly to building)
    if (low == levelRank(.L7_township) and cand_r == levelRank(.L3_building)) {
        const special_l7_suffixes = &[_][]const u8{ "科技园", "科学园", "工业园", "工业区", "产业园", "科技園", "科學園", "工業園", "工業區", "產業園" };
        if (onlyLightBetween(text, cur_end, cand_start, 4) and
            endsWithAny(text, cur_start, cur_end, special_l7_suffixes))
        {
            return current_bits | bitFromLevel(cand_level);
        }
    }
    // whitelist jump: L5 -> L7 (house number directly to township)
    if (low == levelRank(.L5_house_no) and cand_r == levelRank(.L7_township)) {
        const special_l7_suffixes = &[_][]const u8{ "科技园", "科学园", "工业园", "工业区", "产业园", "科技園", "科學園", "工業園", "工業區", "產業園" };
        if (endsWithAny(text, cand_start, cand_end, special_l7_suffixes)) {
            if ((cand_start <= cur_end and cand_end > cur_end) or nearCharsBetween(text, cur_end, cand_start, 4)) {
                return current_bits | bitFromLevel(cand_level);
            }
        }
    }
    // whitelist jump: L6 -> L4 (road directly to POI), allow near distance (<=4 chars)
    if (low == levelRank(.L6_road) and cand_r == levelRank(.L4_poi)) {
        if (onlyLightBetween(text, cur_end, cand_start, 4)) {
            return current_bits | bitFromLevel(cand_level);
        }
    }
    // whiteList jump: L5 -> L2 (house number directly to floor), allow near distance (<=4 chars)
    if (low == levelRank(.L5_house_no) and cand_r == levelRank(.L2_floor)) {
        if (nearCharsBetween(text, cur_end, cand_start, 4)) {
            return current_bits | bitFromLevel(cand_level);
        }
    }
    // whitelist jump: L4 -> L6 (POI directly to road), allow overlap attach
    if (low == levelRank(.L4_poi) and cand_r == levelRank(.L6_road)) {
        // For special cases like "沙田银城 + 街 = 沙田银城街", allow overlap attach road tokan just only has road suffix.
        if (cur_end + roadSuffixAt(text, cur_end) == cand_end) {
            // clear L4 bit to avoid can not right attach L5, because L5 can not attach to L4.
            return (current_bits | bitFromLevel(cand_level)) & ~BIT_L4;
        }
    }
    // whitelist jump: L4 -> L2 (POI directly to floor), allow near distance (<=4 chars)
    if (low == levelRank(.L4_poi) and cand_r == levelRank(.L2_floor)) {
        if (nearCharsBetween(text, cur_end, cand_start, 4)) {
            return current_bits | bitFromLevel(cand_level);
        }
    }
    // whitelist jump: L4 -> L1 (POI directly to room), allow near distance (<=4 chars)
    if (low == levelRank(.L4_poi) and cand_r == levelRank(.L1_unit_room)) {
        if (nearCharsBetween(text, cur_end, cand_start, 5)) {
            return current_bits | bitFromLevel(cand_level);
        }
    }
    // whitelist jump: L3 -> L1 (building directly to room)
    if (low == levelRank(.L3_building) and cand_r == levelRank(.L1_unit_room)) {
        if (nearCharsBetween(text, cur_end, cand_start, 6)) {
            return current_bits | bitFromLevel(cand_level);
        }
    }
    // whitelist jump: L8 -> L6 (district directly to road), allow overlap attach
    if (low == levelRank(.L8_district) and cand_r == levelRank(.L6_road)) {
        if (cand_start <= cur_end and cand_end > cur_end) {
            return current_bits | bitFromLevel(cand_level);
        }
    }
    // whitelist jump: L9 -> L6 (city directly to road), allow overlap attach
    if (low == levelRank(.L9_city) and cand_r == levelRank(.L6_road)) {
        if (cand_start <= cur_end and cand_end > cur_end) {
            return current_bits | bitFromLevel(cand_level);
        }
    }
    return 0;
}

// return the new bits after left attach
fn canLeftAttach(
    current_bits: u32,
    cand_level: AddrLevel,
    text: []const u8,
    cur_start: usize,
    cand_start: usize,
    cand_end: usize,
) u32 {
    const high = highestRankInBits(current_bits);
    const cand_l = levelRank(cand_level);
    if (high == 0) return current_bits; // first token in chain
    if (cand_l == high + 1) return current_bits | bitFromLevel(cand_level);

    // whitelist jump: L6 -> L8 for specific district names (e.g. "新界", "九龙"),
    if (high == levelRank(.L6_road) and cand_l == levelRank(.L8_district)) {
        const special_l8_suffixes = &[_][]const u8{ "新界", "九龙", "九龍" };
        if (endsWithAny(text, cand_start, cand_end, special_l8_suffixes) and
            onlyLightBetween(text, cand_end, cur_start, 4))
        {
            return current_bits | bitFromLevel(cand_level);
        }
    }
    return 0;
}

const COUNTRY_REGION_NAMES = [_][]const u8{
    "中国", "中華人民共和國", "中华人民共和国", "中國大陸", "中国大陆",
    "臺灣", "台湾",                "香港",                "澳門",       "澳门",
    "英國", "英国",                "美國",                "美国",       "日本",
};

fn matchCountryRegionAt(text: []const u8, pos: usize) usize {
    for (COUNTRY_REGION_NAMES) |name| {
        if (matchToken(text, pos, name)) {
            return name.len;
        }
    }
    return 0;
}

const PROVINCE_SUFFIXES = [_][]const u8{ "省", "自治区", "自治州", "盟", "地区", "特别行政区" };

fn provinceSuffixAt(text: []const u8, pos: usize) usize {
    for (PROVINCE_SUFFIXES) |suffix| {
        if (matchToken(text, pos, suffix)) {
            return suffix.len;
        }
    }
    return 0;
}

fn citySuffixAt(text: []const u8, pos: usize) usize {
    // handle "市" specially to avoid treating common nouns like "城市" as
    // administrative suffixes. For example, in "新城市廣場" we do NOT want
    // the inner "市" to be recognized as a city-level suffix.
    if (matchToken(text, pos, "市")) {
        // avoid treating "...城市..." (common noun) as a city-level suffix.
        // We check the previous UTF-8 codepoint: if it starts a "城市"
        // sequence like "...城市廣場", we skip this "市" as admin suffix.
        const prev = utf8PrevCpStart(text, pos);
        if (prev < text.len and matchToken(text, prev, "城市")) {
            return 0;
        }
        return "市".len;
    }
    return 0;
}

const DISTRICT_SUFFIXES = [_][]const u8{ "区", "區", "县", "縣", "旗" };

fn districtSuffixAt(text: []const u8, pos: usize) usize {
    for (DISTRICT_SUFFIXES) |suffix| {
        if (matchToken(text, pos, suffix)) {
            return suffix.len;
        }
    }
    return 0;
}

const DISTRICT_NAMES = [_][]const u8{ "新界", "九龙", "九龍" };

fn matchDistrictNameAt(text: []const u8, pos: usize) usize {
    for (DISTRICT_NAMES) |name| {
        if (matchToken(text, pos, name)) {
            return name.len;
        }
    }
    return 0;
}

const TOWNSHIP_SUFFIXES = [_][]const u8{
    "街道",    "镇",                   "鎮",       "乡",       "鄉",
    "开发区", "经济技术开发区", "科技园", "科学园", "工业园",
    "工业区", "产业园",             "科技園", "科學園", "工業園",
    "工業區", "產業園",
};

fn townshipSuffixAt(text: []const u8, pos: usize) usize {
    for (TOWNSHIP_SUFFIXES) |suffix| {
        if (matchToken(text, pos, suffix)) {
            return suffix.len;
        }
    }
    return 0;
}

// Lightweight HK/MO/CN township/area names (non-exhaustive).
const TOWNSHIP_NAMES = [_][]const u8{
    "铜锣湾", "銅鑼灣", "北角", "荃湾", "荃灣", "将军澳", "將軍澳", "青衣", "上环", "上環",
};

fn matchTownshipNameAt(text: []const u8, pos: usize) usize {
    for (TOWNSHIP_NAMES) |name| {
        if (matchToken(text, pos, name)) {
            return name.len;
        }
    }
    return 0;
}

const POI_SUFFIXES = [_][]const u8{
    "广场",       "中心",          "花园", "花苑", "苑",    "城",    "天地",       "大厦",          "大楼", "港", "塔", "廊", "坊", "里", "府",
    "购物公园", "购物艺术馆", "廣場", "花園", "大廈", "大樓", "購物公園", "購物藝術館",
};

fn endsWithPoiSuffix(text: []const u8, start: usize, end: usize) bool {
    if (end <= start) return false;
    for (POI_SUFFIXES) |suffix| {
        if (end >= start + suffix.len and matchToken(text, end - suffix.len, suffix)) {
            // Special handling for "城": if immediately followed by "区/縣/县/區"
            // (ignoring light ASCII spaces), we treat the whole segment as
            // administrative (e.g. "上城区") rather than a POI ending with "城".
            if (std.mem.eql(u8, suffix, "城")) {
                var p: usize = end;
                while (p < text.len and isAsciiLight(text[p])) : (p += 1) {}
                if (p < text.len and
                    (matchToken(text, p, "区") or matchToken(text, p, "區") or
                        matchToken(text, p, "县") or matchToken(text, p, "縣") or
                        matchToken(text, p, "市")))
                {
                    return false;
                }
            }
            return true;
        }
    }
    return false;
}

fn findRoadSuffixInsideEnd(text: []const u8, start: usize, end: usize) usize {
    var p: usize = start;
    while (p < end) : (p += 1) {
        const suf_len = roadSuffixAt(text, p);
        if (suf_len > 0) return p + suf_len;
    }
    return 0;
}

const ROAD_SUFFIXES = [_][]const u8{
    // longer suffixes first
    "大道", "大街", "环路", "环线", "道中", "道东", "道西", "道南", "道北",
    "路",    "街",    "巷",    "弄",    "里",    "道",    "胡同", "段",    "環路",
    "環線",
};

fn roadSuffixAt(text: []const u8, pos: usize) usize {
    for (ROAD_SUFFIXES) |suffix| {
        if (matchToken(text, pos, suffix)) {
            return suffix.len;
        }
    }
    return 0;
}

fn endsWithRoadSuffix(text: []const u8, start: u32, end: u32) bool {
    if (end <= start) return false;
    var e: usize = end;
    while (e > start and isAsciiLight(text[e - 1])) : (e -= 1) {}
    for (ROAD_SUFFIXES) |suffix| {
        if (e >= start + suffix.len and matchToken(text, e - suffix.len, suffix)) {
            return true;
        }
    }
    return false;
}

fn buildingUnitAt(text: []const u8, pos: usize) usize {
    // Note: do NOT include standalone "楼/樓" here to avoid classifying "18楼" as building.
    // Keep "号楼/號樓" as building, and leave "楼/樓" to floorUnitAt().
    const TOKS = [_][]const u8{ "号楼", "号館", "號樓", "館", "栋", "棟", "幢", "座" };
    var i: usize = 0;
    while (i < TOKS.len) : (i += 1) {
        if (matchToken(text, pos, TOKS[i])) return TOKS[i].len;
    }
    return 0;
}

fn floorUnitAt(text: []const u8, pos: usize) usize {
    const TOKS = [_][]const u8{ "层", "層", "樓", "楼" };
    var i: usize = 0;
    while (i < TOKS.len) : (i += 1) {
        if (matchToken(text, pos, TOKS[i])) return TOKS[i].len;
    }
    return 0;
}

fn roomUnitAt(text: []const u8, pos: usize) usize {
    const TOKS = [_][]const u8{ "单元", "室", "房" };
    var i: usize = 0;
    while (i < TOKS.len) : (i += 1) {
        if (matchToken(text, pos, TOKS[i])) return TOKS[i].len;
    }
    return 0;
}

fn findChunkStart(text: []const u8, start_pos: usize, end_pos: usize, max_chars: usize) usize {
    var p = end_pos;
    var consumed: usize = 0;
    while (p > start_pos and consumed < max_chars) {
        const prev = utf8PrevCpStart(text, p);
        const b = text[prev];
        if (isAsciiLight(b) or heavySepAt(text, prev) > 0) break;
        consumed += (p - prev);
        p = prev;
    }
    return p;
}

fn isDigit(b: u8) bool {
    return b >= '0' and b <= '9';
}

pub const ZhToken = struct {
    level: AddrLevel,
    start: u32,
    end: u32,
};

/// Given an initial chunk start `s0` for a token whose suffix is at `suffix_pos`,
/// trim the start so that we do not cross the boundary of the previous
/// administrative region or road suffix.
/// 例如 "江苏省南京市鼓楼区广州路" 中：
/// - 在 "市" 处识别 L9_city 时，应当从 "南" 开始，而不是从 "江"；
/// - 在 "区" 处识别 L8_district 时，应当从 "鼓" 开始；
/// - 在 "路" 处识别 L6_road 时，应当从 "广" 开始，而不是从 "江"。
fn adjustAdminRoadChunkStart(text: []const u8, addr_level: AddrLevel, s0: usize, suffix_pos: usize) usize {
    var p: usize = s0;
    var last_end: usize = s0;
    const maybe_check_fn: ?*const fn (text: []const u8, pos: usize) usize = switch (addr_level) {
        .L10_province => &matchCountryRegionAt,
        .L9_city => &provinceSuffixAt,
        .L8_district => &citySuffixAt,
        .L7_township => &districtSuffixAt,
        .L6_road => &townshipSuffixAt,
        else => null,
    };

    const check_fn = maybe_check_fn orelse {
        return s0;
    };
    while (p < suffix_pos) {
        const admin_len = check_fn(text, p);
        if (admin_len > 0) {
            last_end = p + admin_len;
            p += admin_len;
            continue;
        }
        const utf8_char_len = utf8CpLenAt(text, p);
        if (utf8_char_len == 0) break;
        p += utf8_char_len;
    }
    return last_end;
}

pub fn zhTokenizeWindow(allocator: std.mem.Allocator, text: []const u8, start: u32, end: u32, out_tokens: *std.ArrayList(ZhToken), new_end: *usize) !u32 {
    var bits: u32 = 0;
    if (end <= start or end > text.len) return 0;
    var i: usize = start;
    const limit: usize = end;
    while (i < limit) : (i += 1) {
        if (isAsciiLight(text[i])) continue;
        const l11 = matchCountryRegionAt(text, i);
        if (l11 > 0) {
            const s = i;
            const e = i + l11;
            bits |= BIT_L11;
            try out_tokens.append(allocator, .{ .level = .L11_country_region, .start = @intCast(s), .end = @intCast(e) });
            new_end.* = e;
            i = e - 1;
            continue;
        }
        const suf_prov = provinceSuffixAt(text, i);
        if (suf_prov > 0) {
            const e = i + suf_prov;
            const s0 = findChunkStart(text, start, i, 32);
            const s = adjustAdminRoadChunkStart(text, .L10_province, s0, i);
            bits |= BIT_L10;
            try out_tokens.append(allocator, .{ .level = .L10_province, .start = @intCast(s), .end = @intCast(e) });
            new_end.* = e;
            i = e - 1;
            continue;
        }
        const suf_city = citySuffixAt(text, i);
        if (suf_city > 0) {
            const e = i + suf_city;
            const s0 = findChunkStart(text, start, i, 24);
            const s = adjustAdminRoadChunkStart(text, .L9_city, s0, i);
            bits |= BIT_L9;
            try out_tokens.append(allocator, .{ .level = .L9_city, .start = @intCast(s), .end = @intCast(e) });
            new_end.* = e;
            i = e - 1;
            continue;
        }
        const l8name = matchDistrictNameAt(text, i);
        if (l8name > 0) {
            const s = i;
            const e = i + l8name;
            bits |= BIT_L8;
            try out_tokens.append(allocator, .{ .level = .L8_district, .start = @intCast(s), .end = @intCast(e) });
            new_end.* = e;
            i = e - 1;
            continue;
        }
        const suf_dist = districtSuffixAt(text, i);
        if (suf_dist > 0) {
            const e = i + suf_dist;
            const s0 = findChunkStart(text, start, i, 24);
            const s = adjustAdminRoadChunkStart(text, .L8_district, s0, i);
            bits |= BIT_L8;
            try out_tokens.append(allocator, .{ .level = .L8_district, .start = @intCast(s), .end = @intCast(e) });
            new_end.* = e;
            i = e - 1;
            continue;
        }
        const l7name = matchTownshipNameAt(text, i);
        if (l7name > 0) {
            const s = i;
            const e = i + l7name;
            bits |= BIT_L7;
            try out_tokens.append(allocator, .{ .level = .L7_township, .start = @intCast(s), .end = @intCast(e) });
            new_end.* = e;
            i = e - 1;
            continue;
        }
        const suf_town = townshipSuffixAt(text, i);
        if (suf_town > 0) {
            const e = i + suf_town;
            const s0 = findChunkStart(text, start, i, 24);
            const s = adjustAdminRoadChunkStart(text, .L7_township, s0, i);
            bits |= BIT_L7;
            try out_tokens.append(allocator, .{ .level = .L7_township, .start = @intCast(s), .end = @intCast(e) });
            new_end.* = e;
            i = e - 1;
            continue;
        }
        const suf_road = roadSuffixAt(text, i);
        if (suf_road > 0) {
            const e = i + suf_road;
            const s0 = findChunkStart(text, start, i, 32);
            const s = adjustAdminRoadChunkStart(text, .L6_road, s0, i);
            bits |= BIT_L6;
            try out_tokens.append(allocator, .{ .level = .L6_road, .start = @intCast(s), .end = @intCast(e) });
            new_end.* = e;
            i = e - 1;
            continue;
        }
        if ((matchToken(text, i, "号") or matchToken(text, i, "號")) and
            (!(matchToken(text, i, "号楼") or matchToken(text, i, "號樓"))))
        {
            var p = i;
            var has_digit = false;
            var dstart: usize = i;
            var steps: usize = 0;
            while (p > start and steps < 8) : (steps += 1) {
                p -= 1;
                if (isAsciiLight(text[p])) continue;
                if (isDigit(text[p])) {
                    has_digit = true;
                    dstart = p;
                    // backtrack to include all preceding digits, independent of window start
                    while (dstart > 0 and isDigit(text[dstart - 1])) : (dstart -= 1) {}
                    break;
                }
            }
            if (has_digit) {
                var e: usize = i + "号".len;
                if (matchToken(text, i, "號")) e = i + "號".len;
                var q = e;
                while (q < limit and isAsciiLight(text[q])) : (q += 1) {}
                if (q < limit and matchToken(text, q, "之")) {
                    q += "之".len;
                    while (q < limit and isAsciiLight(text[q])) : (q += 1) {}
                    const d0 = q;
                    while (q < limit and isDigit(text[q])) : (q += 1) {}
                    if (q > d0) e = q;
                } else if (q < limit and text[q] == '-') {
                    q += 1;
                    while (q < limit and isAsciiLight(text[q])) : (q += 1) {}
                    const d1 = q;
                    while (q < limit and isDigit(text[q])) : (q += 1) {}
                    if (q > d1) e = q;
                }
                bits |= BIT_L5;
                try out_tokens.append(allocator, .{ .level = .L5_house_no, .start = @intCast(dstart), .end = @intCast(e) });
                new_end.* = e;
                i = e - 1;
                continue;
            }
        }
        {
            var j = i;
            var consumed_chars: usize = 0;
            const MAX_NAME: usize = 16;
            var found_poi: bool = false;
            var poi_end: usize = i;
            while (j < limit and consumed_chars < MAX_NAME) {
                if (heavySepAt(text, j) > 0) break;
                const b = text[j];
                if (isDigit(b)) break;
                if (isAsciiAlpha(b)) {
                    j += 1;
                    consumed_chars += 1;
                } else if ((b & 0x80) != 0) {
                    const step = utf8CpLenAt(text, j);
                    j += step;
                    consumed_chars += 1;
                } else {
                    break;
                }
                if (j > i and endsWithPoiSuffix(text, i, j)) {
                    found_poi = true;
                    poi_end = j;
                    break;
                }
            }
            if (found_poi) {
                // if there is a road suffix inside [i, poi_end), this POI span very likely
                // covers a road like "德輔道中恒生大廈"。In that case we skip creating a POI
                // starting at '德', so that later iterations can first recognize the road
                // (e.g. "德輔道中") as L6 and then a POI starting at the true POI head
                // (e.g. "恒生大廈").
                const road_suffix_end = findRoadSuffixInsideEnd(text, i, poi_end);
                if (road_suffix_end == 0) {
                    bits |= BIT_L4;
                    try out_tokens.append(allocator, .{ .level = .L4_poi, .start = @intCast(i), .end = @intCast(poi_end) });
                    new_end.* = poi_end;
                    i = poi_end - 1;
                    continue;
                } else {
                    std.log.debug("[zh-addr] The POI span covers a road = {s}", .{text[i..road_suffix_end]});
                    bits |= BIT_L6 | BIT_L4;
                    try out_tokens.append(allocator, .{ .level = .L6_road, .start = @intCast(i), .end = @intCast(road_suffix_end) });
                    try out_tokens.append(allocator, .{ .level = .L4_poi, .start = @intCast(road_suffix_end), .end = @intCast(poi_end) });
                    new_end.* = poi_end;
                    i = poi_end - 1;
                    continue;
                }
            }
        }
        const bu_len = buildingUnitAt(text, i);
        if (bu_len > 0) {
            var p = i;
            var has_digit = false;
            var has_alpha_letter = false;
            var dstart2: usize = i;
            var steps2: usize = 0;
            while (p > start and steps2 < 8) : (steps2 += 1) {
                p -= 1;
                if (isAsciiLight(text[p])) continue; // skip light separators when scanning back for letters/digits
                if (isDigit(text[p])) {
                    has_digit = true;
                    dstart2 = p;
                    while (dstart2 > start and
                        (isDigit(text[dstart2 - 1]) or isAsciiAlpha(text[dstart2 - 1]))) : (dstart2 -= 1)
                    {}
                    break;
                }
                if (isAsciiAlpha(text[p])) {
                    has_alpha_letter = true;
                    dstart2 = p;
                    while (dstart2 > start and isAsciiAlpha(text[dstart2 - 1])) : (dstart2 -= 1) {}
                    break;
                }
            }
            if (has_digit) {
                const e = i + bu_len;
                bits |= BIT_L3;
                try out_tokens.append(allocator, .{ .level = .L3_building, .start = @intCast(dstart2), .end = @intCast(e) });
                new_end.* = e;
                i = e - 1;
                continue;
            } else if (has_alpha_letter) {
                const e = i + bu_len;
                bits |= BIT_L3;
                try out_tokens.append(allocator, .{ .level = .L3_building, .start = @intCast(dstart2), .end = @intCast(e) });
                new_end.* = e;
                i = e - 1;
                continue;
            }
        }
        const fu_len = floorUnitAt(text, i);
        if (fu_len > 0) {
            var p = i;
            var has_digit = false;
            var dstart3: usize = i;
            var steps3: usize = 0;
            while (p > start and steps3 < 8) : (steps3 += 1) {
                p -= 1;
                if (isAsciiLight(text[p])) break;
                if (isDigit(text[p])) {
                    has_digit = true;
                    dstart3 = p;
                    while (dstart3 > start and isDigit(text[dstart3 - 1])) : (dstart3 -= 1) {}
                    break;
                }
            }
            if (has_digit) {
                const e = i + fu_len;
                bits |= BIT_L2;
                try out_tokens.append(allocator, .{ .level = .L2_floor, .start = @intCast(dstart3), .end = @intCast(e) });
                new_end.* = e;
                i = e - 1;
                continue;
            }
        } else if (text[i] == 'F') {
            var q = i + 1;
            const d0 = q;
            while (q < limit and isDigit(text[q])) : (q += 1) {}
            if (q > d0) {
                bits |= BIT_L2;
                try out_tokens.append(allocator, .{ .level = .L2_floor, .start = @intCast(i), .end = @intCast(q) });
                new_end.* = q;
                i = q - 1;
                continue;
            }
        }
        // support "之+digits" tail as L1 (e.g., "18楼之3")
        if (matchToken(text, i, "之")) {
            var q = i + "之".len;
            while (q < limit and isAsciiLight(text[q])) : (q += 1) {}
            const d0 = q;
            while (q < limit and isDigit(text[q])) : (q += 1) {}
            if (q > d0) {
                bits |= BIT_L1;
                try out_tokens.append(allocator, .{ .level = .L1_unit_room, .start = @intCast(i), .end = @intCast(q) });
                new_end.* = q;
                i = q - 1;
                continue;
            }
        }
        const ru_len = roomUnitAt(text, i);
        if (ru_len > 0) {
            var p = i;
            var has_digit = false;
            var has_alpha_letter = false;
            var dstart4: usize = i;
            var steps4: usize = 0;
            while (p > start and steps4 < 8) : (steps4 += 1) {
                p -= 1;
                if (isAsciiLight(text[p])) break;
                if (isDigit(text[p])) {
                    has_digit = true;
                    dstart4 = p;
                    while (dstart4 > start and isDigit(text[dstart4 - 1])) : (dstart4 -= 1) {}
                    break;
                }
                if (isAsciiAlpha(text[p])) {
                    has_alpha_letter = true;
                    dstart4 = p;
                    while (dstart4 > start and isAsciiAlpha(text[dstart4 - 1])) : (dstart4 -= 1) {}
                    break;
                }
            }
            if (has_digit or has_alpha_letter) {
                const e = i + ru_len;
                bits |= BIT_L1;
                try out_tokens.append(allocator, .{ .level = .L1_unit_room, .start = @intCast(dstart4), .end = @intCast(e) });
                new_end.* = e;
                i = e - 1;
                continue;
            }
        }
    }

    if (out_tokens.items.len < 2) return bits;

    // Check if there has a token level lower than last token level,
    // if so, clear this token's bit and remove this token from out_tokens
    const last_level: AddrLevel = out_tokens.items[out_tokens.items.len - 1].level;
    var idx: isize = @intCast(out_tokens.items.len - 2);
    while (idx >= 0) : (idx -= 1) {
        const tk = out_tokens.items[@intCast(idx)];
        if (levelRank(tk.level) < levelRank(last_level)) {
            bits &= ~bitFromLevel(tk.level);
            _ = out_tokens.orderedRemove(@intCast(idx));
            std.log.debug("[zh-addr] remove token seg={s} level={s} less than last level={s} [{d},{d})", .{
                text[tk.start..tk.end],
                levelName(tk.level),
                levelName(last_level),
                tk.start,
                tk.end,
            });
        }
    }
    return bits;
}

pub fn mergeZhAddressSpans(allocator: std.mem.Allocator, text: []const u8, spans: []const RecogEntity) ![]RecogEntity {
    const merged_adjacent = try mergeAdjacentAddressSpans(allocator, text, spans);
    defer allocator.free(merged_adjacent);

    // track which merged seeds have already been covered by an earlier merged address span
    var consumed = try allocator.alloc(bool, merged_adjacent.len);
    defer allocator.free(consumed);
    var ci: usize = 0;
    while (ci < consumed.len) : (ci += 1) {
        consumed[ci] = false;
    }

    var merged_zh = try std.ArrayList(RecogEntity).initCapacity(allocator, merged_adjacent.len);
    defer merged_zh.deinit(allocator);

    const SCAN_WIN: usize = 96; // characters scan window per step
    const MAX_TOTAL_GROW_CHARS: usize = 48;

    var tokens_buf = try std.ArrayList(ZhToken).initCapacity(allocator, 16);
    defer tokens_buf.deinit(allocator);

    var idx: usize = 0;
    while (idx < merged_adjacent.len) : (idx += 1) {
        const sp = merged_adjacent[idx];
        if (consumed[idx]) {
            std.log.debug("[zh-addr] skip covered seed: entity_type={s} [{d},{d}) seg={s}", .{ @tagName(sp.entity_type), sp.start, sp.end, text[sp.start..sp.end] });
            continue;
        }
        // skip non-address seeds completely
        if (sp.entity_type != .PHYSICAL_ADDRESS and
            sp.entity_type != .ORGANIZATION)
        {
            std.log.debug("[zh-addr] skip non-address/organization seed: entity_type={s} [{d},{d}) seg={s}", .{ @tagName(sp.entity_type), sp.start, sp.end, text[sp.start..sp.end] });
            continue;
        }
        var new_start: usize = sp.start;
        var new_end: usize = sp.end;
        var bits: u32 = 0;

        tokens_buf.clearRetainingCapacity();
        bits |= try zhTokenizeWindow(allocator, text, sp.start, sp.end, &tokens_buf, &new_end);
        std.log.debug("[zh-addr] seed span: start={d} end={d} text={s}", .{ sp.start, sp.end, text[sp.start..sp.end] });
        std.log.debug("[zh-addr] seed tokens={d} bits=0x{x}", .{ tokens_buf.items.len, bits });
        for (tokens_buf.items) |tk| {
            std.log.debug("[zh-addr]   seed tk level={s} [{d},{d}) seg={s}", .{ levelName(tk.level), tk.start, tk.end, text[tk.start..tk.end] });
        }

        // right extension
        while (true) {
            if (countCharsBetween(text, sp.end, new_end) >= MAX_TOTAL_GROW_CHARS) break;
            // after reaching privacy threshold, do not cross heavy separators
            // like '，' into the next clause.
            const has_priv_rt = (bits & (BIT_L5 | BIT_L4 | BIT_L3 | BIT_L2 | BIT_L1)) != 0;
            if (has_priv_rt) {
                if (heavySepAt(text, new_end) > 0) {
                    std.log.debug("[zh-addr] right stop: heavy separator at pos={d}", .{new_end});
                    break;
                }
            }
            const win_end = @min(text.len, new_end + SCAN_WIN);
            var new_win_end: usize = win_end;
            if (win_end <= new_end) break;
            tokens_buf.clearRetainingCapacity();
            _ = try zhTokenizeWindow(allocator, text, @intCast(new_end), @intCast(win_end), &tokens_buf, &new_win_end);
            std.log.debug("[zh-addr] right scan window=[{d},{d}) tokens={d} cur_bits=0x{x}", .{ new_end, win_end, tokens_buf.items.len, bits });
            if (tokens_buf.items.len == 0) {
                std.log.debug("[zh-addr] right stop: no tokens in window", .{});
                break;
            }
            // pick the first acceptable candidate
            var accepted: bool = false;
            var i: usize = 0;
            while (i < tokens_buf.items.len) : (i += 1) {
                const tk = tokens_buf.items[i];
                // mutual exclusion for L8: only accept if not already present
                if (tk.level == .L8_district and (bits & BIT_L8) != 0) {
                    std.log.debug("[zh-addr]   right reject tk level={s} (L8 duplicate) [{d},{d}) seg={s}", .{ levelName(tk.level), tk.start, tk.end, text[tk.start..tk.end] });
                    continue;
                }
                // if we already reached privacy threshold and encounter a
                // new high-level admin token (L8+), treat it as the head of
                // the next address and stop extending the current one.
                if (has_priv_rt and levelRank(tk.level) >= levelRank(.L8_district)) {
                    std.log.debug("[zh-addr] right stop: new address head token level={s} [{d},{d}) seg={s}", .{ levelName(tk.level), tk.start, tk.end, text[tk.start..tk.end] });
                    accepted = false;
                    break;
                }
                const new_bits = canRightAttach(bits, tk.level, text, new_start, new_end, tk.start, tk.end);
                if (new_bits != 0) {
                    std.log.debug("[zh-addr]   right accept tk level={s} [{d},{d}) seg={s}", .{ levelName(tk.level), tk.start, tk.end, text[tk.start..tk.end] });
                    bits = new_bits;
                    if (tk.start < new_start) {
                        // adjust new_start to the leftmost token
                        new_start = tk.start;
                    }
                    new_end = tk.end;
                    std.log.debug("[zh-addr]   right new_end={d} bits=0x{x}, seg={s}", .{ new_end, bits, text[new_start..new_end] });
                    accepted = true;
                    break;
                } else {
                    std.log.debug("[zh-addr]   right reject tk level={s} (not adjacent/whitelist) [{d},{d})", .{ levelName(tk.level), tk.start, tk.end });
                }
            }
            if (!accepted) {
                std.log.debug("[zh-addr] right stop: no acceptable token", .{});
                break;
            }
        }

        // left extension
        while (true) {
            const win_start = if (new_start > SCAN_WIN) new_start - SCAN_WIN else 0;
            if (win_start == new_start) break;
            tokens_buf.clearRetainingCapacity();
            var new_win_end: usize = new_start;
            _ = try zhTokenizeWindow(allocator, text, @intCast(win_start), @intCast(new_start), &tokens_buf, &new_win_end);
            std.log.debug("[zh-addr] left scan window=[{d},{d}) tokens={d} cur_bits=0x{x}", .{ win_start, new_start, tokens_buf.items.len, bits });
            if (tokens_buf.items.len == 0) {
                std.log.debug("[zh-addr] left stop: no tokens in window", .{});
                break;
            }
            // pick the last token that can attach on the left (closest to start)
            var accepted: bool = false;
            var j: isize = @as(isize, @intCast(tokens_buf.items.len)) - 1;
            while (j >= 0) : (j -= 1) {
                const tk = tokens_buf.items[@as(usize, @intCast(j))];
                if (tk.level == .L8_district and (bits & BIT_L8) != 0) {
                    std.log.debug("[zh-addr]   left reject tk level={s} (L8 duplicate) [{d},{d}) seg={s}", .{ levelName(tk.level), tk.start, tk.end, text[tk.start..tk.end] });
                    continue;
                }
                const new_bits = canLeftAttach(bits, tk.level, text, new_start, tk.start, tk.end);
                if (new_bits != 0) {
                    std.log.debug("[zh-addr]   left accept tk level={s} [{d},{d}) seg={s}", .{ levelName(tk.level), tk.start, tk.end, text[tk.start..tk.end] });
                    bits = new_bits;
                    new_start = tk.start;
                    std.log.debug("[zh-addr]   left new_start={d} bits=0x{x}, seg={s}", .{ new_start, bits, text[tk.start..new_end] });
                    accepted = true;
                    break;
                } else {
                    std.log.debug("[zh-addr]   left reject tk level={s} (not adjacent) [{d},{d})", .{ levelName(tk.level), tk.start, tk.end });
                }
            }
            if (!accepted) {
                std.log.debug("[zh-addr] left stop: no acceptable token", .{});
                break;
            }
        }

        // privacy threshold: require L5 or below, or accept L4 + (L2|L1)
        const has_priv = (bits & BIT_L5) != 0 or
            ((bits & BIT_L4) != 0 and (((bits & BIT_L2) != 0) or ((bits & BIT_L1) != 0)));
        if (!has_priv) {
            std.log.debug("[zh-addr] skip: privacy threshold not reached bits=0x{x}", .{bits});
            continue;
        }

        var out_sp = sp;
        out_sp.entity_type = .PHYSICAL_ADDRESS;
        out_sp.start = @intCast(new_start);
        out_sp.end = @intCast(new_end);
        const lowest_level = lowestRankInBits(bits);
        // the score is a function of the lowest level, the lower the level, the higher the score.
        // score = 0.9999 - lowest_level * 0.0025
        out_sp.score = @as(f32, 0.9999 - @as(f32, @floatFromInt(lowest_level)) * 0.0025);
        try merged_zh.append(allocator, out_sp);
        std.log.debug("[zh-addr] accept final span score={d} [{d},{d}) seg={s}", .{ out_sp.score, out_sp.start, out_sp.end, text[out_sp.start..out_sp.end] });

        // mark subsequent seeds fully covered by this merged span as consumed
        var j = idx + 1;
        while (j < merged_adjacent.len) : (j += 1) {
            const spj = merged_adjacent[j];
            if (spj.start >= out_sp.start and spj.end <= out_sp.end and
                (spj.entity_type == .PHYSICAL_ADDRESS or spj.entity_type == .ORGANIZATION))
            {
                consumed[j] = true;
            }
        }
    }

    return try merged_zh.toOwnedSlice(allocator);
}
