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

fn endsWithAny(text: []const u8, start: usize, end: usize, toks: []const []const u8) bool {
    if (end <= start) return false;
    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (end >= start + t.len and matchToken(text, end - t.len, t)) return true;
    }
    return false;
}

fn endsWithPoiSuffix(text: []const u8, start: usize, end: usize) bool {
    const POI = [_][]const u8{
        "广场", "中心", "花园", "花苑", "苑", "城", "天地", "大厦", "大楼", "港", "塔", "廊", "坊", "里", "府",
        "廣場", "花園", "大廈", "大樓",
    };
    return endsWithAny(text, start, end, &POI);
}

fn adminSuffixAt(text: []const u8, pos: usize) usize {
    const ADMIN = [_][]const u8{
        "省", "市", "自治州", "自治区", "州", "盟", "地区", "特别行政区", "区", "區", "县", "縣", "旗", "新区", "高新区", "经济技术开发区", "开发区", "街道", "镇", "鎮", "乡", "鄉", "里", "村",
    };
    var i: usize = 0;
    while (i < ADMIN.len) : (i += 1) {
        if (matchToken(text, pos, ADMIN[i])) return ADMIN[i].len;
    }
    return 0;
}

fn roadSuffixAt(text: []const u8, pos: usize) usize {
    const SUF = [_][]const u8{
        "大道", "大街", "环路", "环线", "路", "街", "巷", "弄", "里", "道", "胡同", "段", "期",
        "環路", "環線",
    };
    var i: usize = 0;
    while (i < SUF.len) : (i += 1) {
        if (matchToken(text, pos, SUF[i])) return SUF[i].len;
    }
    return 0;
}

fn endsWithRoadSuffix(text: []const u8, start: u32, end: u32) bool {
    if (end <= start) return false;
    var e: usize = end;
    while (e > start and isAsciiLight(text[e - 1])) : (e -= 1) {}
    const SUF = [_][]const u8{
        "大道", "大街", "环路", "环线", "路", "街", "巷", "弄", "里", "道", "胡同", "段", "期",
        "環路", "環線",
    };
    var i: usize = 0;
    while (i < SUF.len) : (i += 1) {
        const t = SUF[i];
        if (e >= start + t.len and matchToken(text, e - t.len, t)) return true;
    }
    return false;
}

fn detectNextAddressHeadWithin(text: []const u8, start_pos: usize, window: usize) bool {
    const limit = @min(text.len, start_pos + window);
    var p: usize = start_pos;
    while (p < limit) : (p += 1) {
        while (p < limit and isAsciiLight(text[p])) : (p += 1) {}
        if (p >= limit) break;
        const name_start = p;
        while (p < limit) : (p += 1) {
            if (roadSuffixAt(text, p) > 0 or adminSuffixAt(text, p) > 0) {
                if (p > name_start) return true;
            }
            const b = text[p];
            if (isAsciiAlnum(b)) continue;
            if ((b & 0x80) != 0 and !(b >= '0' and b <= '9')) continue;
            break;
        }
        if (p <= name_start) continue;
        var q: usize = p;
        while (q < limit and isAsciiLight(text[q])) : (q += 1) {}
        if (q >= limit) break;
        if (roadSuffixAt(text, q) > 0) return true;
        if (adminSuffixAt(text, q) > 0) return true;
    }
    return false;
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

pub fn hasHouseTailInside(text: []const u8, start: u32, end: u32) bool {
    var i: usize = start;
    const limit: usize = end;
    while (i < limit) : (i += 1) {
        if (!(text[i] >= '0' and text[i] <= '9')) continue;
        var j = i;
        while (j < limit and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
        while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
        if (j < limit and (matchToken(text, j, "号") or matchToken(text, j, "號"))) return true;
        const STRONG = [_][]const u8{ "号楼", "号館", "號樓", "楼", "館", "樓", "栋", "棟", "幢", "座" };
        var k: usize = 0;
        while (k < STRONG.len) : (k += 1) {
            if (matchToken(text, j, STRONG[k])) return true;
        }
        i = j;
    }
    return false;
}

fn prevIsAdminSuffix(text: []const u8, pos: usize) bool {
    const ADMIN = [_][]const u8{
        "省", "市", "自治州", "自治区", "州", "盟", "地区", "特别行政区", "区", "區", "县", "縣", "旗", "新区", "高新区", "经济技术开发区", "开发区", "街道", "镇", "鎮", "乡", "鄉", "里", "村",
    };
    var i: usize = 0;
    while (i < ADMIN.len) : (i += 1) {
        const t = ADMIN[i];
        if (pos >= t.len and matchToken(text, pos - t.len, t)) return true;
    }
    return false;
}

fn absorbTrailingRoomUnit(text: []const u8, pos: usize) usize {
    var i = pos;
    const n = text.len;
    while (i < n and isAsciiLight(text[i])) : (i += 1) {}
    var j = i;
    while (j > 0 and isAsciiLight(text[j - 1])) : (j -= 1) {}
    var p = j;
    var has_digits = false;
    while (p > 0 and text[p - 1] >= '0' and text[p - 1] <= '9') : (p -= 1) {
        has_digits = true;
    }
    if (!has_digits) return pos;
    const UROOM = [_][]const u8{ "单元", "室", "房", "层", "層", "楼" };
    var ur: usize = 0;
    while (ur < UROOM.len) : (ur += 1) {
        if (matchToken(text, i, UROOM[ur])) {
            i += UROOM[ur].len;
            return i;
        }
    }
    return pos;
}

fn leftExtendCnRoadHead(text: []const u8, start_pos: u32, max_bytes: usize) u32 {
    var p: usize = start_pos;
    var consumed: usize = 0;
    while (p > 0 and consumed < max_bytes) {
        const prev = utf8PrevCpStart(text, p);
        if (heavySepAt(text, prev) > 0) break;
        const b = text[prev];
        if (b >= '0' and b <= '9') break;
        if (prevIsAdminSuffix(text, prev)) break;
        if (isAsciiAlpha(b) or (b & 0x80) != 0) {
            consumed += (p - prev);
            p = prev;
            continue;
        }
        break;
    }
    return @intCast(p);
}

fn leftExtendCnAdmin(text: []const u8, start_pos: u32, max_steps: u32) u32 {
    var start_ext: usize = start_pos;
    var steps: u32 = 0;
    while (steps < max_steps and start_ext > 0) : (steps += 1) {
        var p: usize = start_ext;
        while (p > 0) : (p -= 1) {
            const b = text[p - 1];
            if (!isAsciiLight(b)) break;
        }
        const ADMIN = [_][]const u8{
            "省", "市", "自治州", "自治区", "州", "盟", "地区", "特别行政区", "区", "區", "县", "縣", "旗", "新区", "高新区", "经济技术开发区", "开发区", "街道", "镇", "鎮", "乡", "鄉", "里", "村",
        };
        var i: usize = 0;
        var matched: bool = false;
        while (i < ADMIN.len) : (i += 1) {
            const suf = ADMIN[i];
            const st = if (p >= suf.len) p - suf.len else 0;
            if (st > 0 and matchToken(text, st, suf)) {
                matched = true;
                break;
            }
        }
        if (!matched) break;
        var s2: usize = p;
        var cnt: usize = 0;
        while (s2 > 0 and cnt < 32) : (s2 -= 1) {
            const b2 = text[s2 - 1];
            if (isAsciiAlnum(b2) or (b2 & 0x80) != 0) {
                cnt += 1;
            } else break;
        }
        if (cnt < 2) break;
        start_ext = s2;
    }
    return @intCast(start_ext);
}

fn rightExtendCnAddr(text: []const u8, start_end: u32) u32 {
    var i: usize = start_end;
    const n = text.len;
    while (i < n) : (i += 1) {
        const b = text[i];
        if (!isAsciiLight(b)) break;
    }
    const back_start: usize = if (start_end > 128) start_end - 128 else 0;
    const has_prior_anchor = hasHouseTailInside(text, @intCast(back_start), start_end);

    var j: usize = i;
    const d0 = i;
    while (j < n and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
    var ok_head = false;
    if (j > d0) {
        var k: usize = j;
        while (k < n and isAsciiLight(text[k])) : (k += 1) {}
        if (matchToken(text, k, "号")) {
            k += "号".len;
            ok_head = true;
            j = k;
        } else if (matchToken(text, k, "號")) {
            k += "號".len;
            ok_head = true;
            j = k;
        } else {
            const BUILD = [_][]const u8{ "号楼", "号館", "號樓", "楼", "館", "樓", "栋", "棟", "幢", "座" };
            var bi: usize = 0;
            while (bi < BUILD.len) : (bi += 1) {
                if (matchToken(text, k, BUILD[bi])) {
                    k += BUILD[bi].len;
                    ok_head = true;
                    j = k;
                    break;
                }
            }
        }
    }

    if (!ok_head and !has_prior_anchor) return start_end;

    if (ok_head) {
        i = j;
        while (i < n and isAsciiLight(text[i])) : (i += 1) {}
        if (matchToken(text, i, "之")) {
            i += "之".len;
            while (i < n and isAsciiLight(text[i])) : (i += 1) {}
            const d1 = i;
            while (i < n and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
            if (i == d1) {
                i = d1;
            }
        }
        while (i < n and isAsciiLight(text[i])) : (i += 1) {}
        if (i < n and text[i] == '-') {
            var t = i + 1;
            while (t < n and isAsciiLight(text[t])) : (t += 1) {}
            const d2 = t;
            while (t < n and text[t] >= '0' and text[t] <= '9') : (t += 1) {}
            if (t > d2) i = t;
        }
        while (i < n and isAsciiLight(text[i])) : (i += 1) {}
        const room_start = i;
        while (i < n and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
        if (i > room_start) {
            while (i < n and isAsciiLight(text[i])) : (i += 1) {}
            const UNITS = [_][]const u8{ "单元", "室", "房", "层", "層" };
            var ui: usize = 0;
            while (ui < UNITS.len) : (ui += 1) {
                if (matchToken(text, i, UNITS[ui])) {
                    i += UNITS[ui].len;
                    break;
                }
            }
        }
    }

    var loops: u32 = 0;
    const MAX_EXT_BYTES: usize = 96;
    const MAX_EXT_CHARS: usize = 48;
    while (loops < 2) : (loops += 1) {
        if (heavySepAt(text, i) > 0) break;
        if (detectNextAddressHeadWithin(text, i, 48)) break;
        if (i > start_end and (i - start_end) > MAX_EXT_BYTES) break;
        if (countCharsBetween(text, @intCast(start_end), i) > MAX_EXT_CHARS) break;
        while (i < n and isAsciiLight(text[i])) : (i += 1) {}
        const MAX_NAME_CHARS: usize = 16;
        const name_start = i;
        var consumed_chars: usize = 0;
        while (i < n and consumed_chars < MAX_NAME_CHARS) {
            if (heavySepAt(text, i) > 0) break;
            const b = text[i];
            if (b >= '0' and b <= '9') break;
            if (isAsciiAlpha(b)) {
                i += 1;
                consumed_chars += 1;
                continue;
            }
            if ((b & 0x80) != 0) {
                const step = utf8CpLenAt(text, i);
                i += step;
                consumed_chars += 1;
                continue;
            }
            break;
        }
        if (i == name_start and !has_prior_anchor) break;
        const name_end = i;
        const has_poi = endsWithPoiSuffix(text, name_start, name_end);
        while (i < n and isAsciiLight(text[i])) : (i += 1) {}
        const dstart2 = i;
        while (i < n and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
        if (i == dstart2) {
            if (has_prior_anchor) {
                // allow tail absorb
            } else break;
        } else {
            if (!has_poi) {
                const gap = dstart2 - name_end;
                if (gap > 12) break;
            }
            while (i < n and isAsciiLight(text[i])) : (i += 1) {}
            const STRONG = [_][]const u8{ "层", "層", "楼", "号", "號", "号楼", "号館", "號樓", "楼", "館", "樓", "栋", "棟", "幢", "座" };
            var ok2 = false;
            var su: usize = 0;
            while (su < STRONG.len) : (su += 1) {
                if (matchToken(text, i, STRONG[su])) {
                    i += STRONG[su].len;
                    ok2 = true;
                    break;
                }
            }
            if (!ok2) break;
            while (i < n and isAsciiLight(text[i])) : (i += 1) {}
            const r2s = i;
            while (i < n and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
            if (i > r2s) {
                while (i < n and isAsciiLight(text[i])) : (i += 1) {}
                const UROOM = [_][]const u8{ "单元", "室", "房" };
                var ur: usize = 0;
                while (ur < UROOM.len) : (ur += 1) {
                    if (matchToken(text, i, UROOM[ur])) {
                        i += UROOM[ur].len;
                        break;
                    }
                }
            }
        }
    }
    const new_i = absorbTrailingRoomUnit(text, i);
    return @intCast(if (new_i > i) new_i else i);
}

fn findHouseTailFrom(text: []const u8, from_pos: u32, max_lookahead: u32) u32 {
    const n = text.len;
    var i: usize = from_pos;
    const limit = @min(n, from_pos + max_lookahead);
    while (i < limit and !(text[i] >= '0' and text[i] <= '9')) : (i += 1) {
        if (heavySepAt(text, i) > 0) return from_pos;
    }
    if (i >= limit) return from_pos;
    var j: usize = i;
    while (j < limit and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
    if (j >= limit) return from_pos;
    while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
    var ok_head = false;
    if (matchToken(text, j, "号")) {
        j += "号".len;
        ok_head = true;
    } else if (matchToken(text, j, "號")) {
        j += "號".len;
        ok_head = true;
    } else {
        const BUILD = [_][]const u8{ "号楼", "号館", "號樓", "楼", "館", "樓", "栋", "棟", "幢", "座" };
        var bi: usize = 0;
        while (bi < BUILD.len) : (bi += 1) {
            if (matchToken(text, j, BUILD[bi])) {
                j += BUILD[bi].len;
                ok_head = true;
                break;
            }
        }
        if (!ok_head) return from_pos;
    }
    var k: usize = j;
    while (k < limit and isAsciiLight(text[k])) : (k += 1) {}
    if (matchToken(text, k, "之")) {
        k += "之".len;
        while (k < limit and isAsciiLight(text[k])) : (k += 1) {}
        const d0 = k;
        while (k < limit and text[k] >= '0' and text[k] <= '9') : (k += 1) {}
        if (k > d0) j = k;
    }
    while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
    if (j < limit and text[j] == '-') {
        k = j + 1;
        while (k < limit and isAsciiLight(text[k])) : (k += 1) {}
        const d1 = k;
        while (k < limit and text[k] >= '0' and text[k] <= '9') : (k += 1) {}
        if (k > d1) j = k;
    }
    while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
    const rstart = j;
    while (j < limit and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
    if (j > rstart) {
        while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
        const UNITS = [_][]const u8{ "单元", "室", "房", "层", "層" };
        var ui: usize = 0;
        while (ui < UNITS.len) : (ui += 1) {
            if (matchToken(text, j, UNITS[ui])) {
                j += UNITS[ui].len;
                break;
            }
        }
    }
    var loops: u32 = 0;
    const MAX_EXT2_BYTES: usize = 96;
    const MAX_EXT2_CHARS: usize = 48;
    while (loops < 2 and j < limit) : (loops += 1) {
        if (heavySepAt(text, j) > 0) break;
        if (detectNextAddressHeadWithin(text, j, 48)) break;
        if (j > from_pos and (j - from_pos) > MAX_EXT2_BYTES) break;
        if (countCharsBetween(text, @intCast(from_pos), j) > MAX_EXT2_CHARS) break;
        while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
        const MAX_NAME_CHARS2: usize = 16;
        const name_s = j;
        var consumed2_chars: usize = 0;
        while (j < limit and consumed2_chars < MAX_NAME_CHARS2) {
            if (heavySepAt(text, j) > 0) break;
            const b = text[j];
            if (b >= '0' and b <= '9') break;
            if (isAsciiAlpha(b)) {
                j += 1;
                consumed2_chars += 1;
                continue;
            }
            if ((b & 0x80) != 0) {
                const step = utf8CpLenAt(text, j);
                j += step;
                consumed2_chars += 1;
                continue;
            }
            break;
        }
        if (j == name_s) break;
        const name_e = j;
        const has_poi2 = endsWithPoiSuffix(text, name_s, name_e);
        while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
        const d2s = j;
        while (j < limit and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
        if (j == d2s) break;
        if (!has_poi2) {
            const gap2 = d2s - name_e;
            if (gap2 > 12) break;
        }
        while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
        const U2 = [_][]const u8{ "层", "層", "楼", "号", "號", "号楼", "号館", "號樓", "楼", "館", "樓", "栋", "棟", "幢", "座" };
        var ok2 = false;
        var uidx2: usize = 0;
        while (uidx2 < U2.len) : (uidx2 += 1) {
            if (matchToken(text, j, U2[uidx2])) {
                j += U2[uidx2].len;
                ok2 = true;
                break;
            }
        }
        if (!ok2) break;
        while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
        const r2s = j;
        while (j < limit and text[j] >= '0' and text[j] <= '9') : (j += 1) {}
        if (j > r2s) {
            while (j < limit and isAsciiLight(text[j])) : (j += 1) {}
            const UROOM = [_][]const u8{ "单元", "室", "房" };
            var ur: usize = 0;
            while (ur < UROOM.len) : (ur += 1) {
                if (matchToken(text, j, UROOM[ur])) {
                    j += UROOM[ur].len;
                    break;
                }
            }
        }
    }
    const new_j = absorbTrailingRoomUnit(text, j);
    return @intCast(if (new_j > j) new_j else j);
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

fn bitForLevel(lv: AddrLevel) u32 {
    return switch (lv) {
        .L11_country_region => BIT_L11,
        .L10_province => BIT_L10,
        .L9_city => BIT_L9,
        .L8_district => BIT_L8,
        .L7_township => BIT_L7,
        .L6_road => BIT_L6,
        .L5_house_no => BIT_L5,
        .L4_poi => BIT_L4,
        .L3_building => BIT_L3,
        .L2_floor => BIT_L2,
        .L1_unit_room => BIT_L1,
    };
}

fn levelRank(lv: AddrLevel) u8 {
    return switch (lv) {
        .L11_country_region => 11,
        .L10_province => 10,
        .L9_city => 9,
        .L8_district => 8,
        .L7_township => 7,
        .L6_road => 6,
        .L5_house_no => 5,
        .L4_poi => 4,
        .L3_building => 3,
        .L2_floor => 2,
        .L1_unit_room => 1,
    };
}

fn highestRankInBits(bits: u32) u8 {
    var r: u8 = 0;
    if ((bits & BIT_L11) != 0) r = @max(r, levelRank(.L11_country_region));
    if ((bits & BIT_L10) != 0) r = @max(r, levelRank(.L10_province));
    if ((bits & BIT_L9) != 0) r = @max(r, levelRank(.L9_city));
    if ((bits & BIT_L8) != 0) r = @max(r, levelRank(.L8_district));
    if ((bits & BIT_L7) != 0) r = @max(r, levelRank(.L7_township));
    if ((bits & BIT_L6) != 0) r = @max(r, levelRank(.L6_road));
    if ((bits & BIT_L5) != 0) r = @max(r, levelRank(.L5_house_no));
    if ((bits & BIT_L4) != 0) r = @max(r, levelRank(.L4_poi));
    if ((bits & BIT_L3) != 0) r = @max(r, levelRank(.L3_building));
    if ((bits & BIT_L2) != 0) r = @max(r, levelRank(.L2_floor));
    if ((bits & BIT_L1) != 0) r = @max(r, levelRank(.L1_unit_room));
    return r;
}

fn lowestRankInBits(bits: u32) u8 {
    var r: u8 = 0;
    inline for (.{
        .L1_unit_room, .L2_floor,    .L3_building, .L4_poi,       .L5_house_no,        .L6_road,
        .L7_township,  .L8_district, .L9_city,     .L10_province, .L11_country_region,
    }) |lv| {
        if ((bits & bitForLevel(lv)) != 0) {
            r = levelRank(lv);
            break;
        }
    }
    return r;
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

// (removed) hasInlineBuildingBetween: no longer needed since L3 tokens are built during tokenization

fn canRightAttach(
    current_bits: u32,
    cand_level: AddrLevel,
    text: []const u8,
    cur_start: usize,
    cur_end: usize,
    cand_start: usize,
    cand_end: usize,
) bool {
    const low = lowestRankInBits(current_bits);
    const cand_r = levelRank(cand_level);
    if (low == 0) return true; // first token in chain
    // strict adjacency
    if (cand_r + 1 == low) return true;
    // whitelist jump: L7 -> L3 (township directly to building)
    if (low == levelRank(.L7_township) and cand_r == levelRank(.L3_building)) {
        const special_l7_suffixes = &[_][]const u8{ "科技园", "科学园", "工业园", "工业区", "产业园", "科技園", "科學園", "工業園", "工業區", "產業園" };
        if (onlyLightBetween(text, cur_end, cand_start, 4) and
            endsWithAny(text, cur_start, cur_end, special_l7_suffixes)) return true;
    }
    // whitelist jump: L5 -> L7 (house number directly to township)
    if (low == levelRank(.L5_house_no) and cand_r == levelRank(.L7_township)) {
        const special_l7_suffixes = &[_][]const u8{ "科技园", "科学园", "工业园", "工业区", "产业园", "科技園", "科學園", "工業園", "工業區", "產業園" };
        if (endsWithAny(text, cand_start, cand_end, special_l7_suffixes)) {
            if ((cand_start <= cur_end and cand_end > cur_end) or nearCharsBetween(text, cur_end, cand_start, 4)) {
                return true;
            }
        }
    }
    // whitelist jump: L6 -> L4 (road directly to POI), allow near distance (<=4 chars)
    if (low == levelRank(.L6_road) and cand_r == levelRank(.L4_poi)) {
        if (onlyLightBetween(text, cur_end, cand_start, 4)) return true;
    }
    // whiteList jump: L5 -> L2 (house number directly to floor), allow near distance (<=4 chars)
    if (low == levelRank(.L5_house_no) and cand_r == levelRank(.L2_floor)) {
        if (nearCharsBetween(text, cur_end, cand_start, 4)) return true;
    }
    // whitelist jump: L4 -> L2 (POI directly to floor), allow near distance (<=4 chars)
    if (low == levelRank(.L4_poi) and cand_r == levelRank(.L2_floor)) {
        if (nearCharsBetween(text, cur_end, cand_start, 4)) return true;
    }
    // whitelist jump: L4 -> L1 (POI directly to room), allow near distance (<=4 chars)
    if (low == levelRank(.L4_poi) and cand_r == levelRank(.L1_unit_room)) {
        if (nearCharsBetween(text, cur_end, cand_start, 5)) return true;
    }
    // whitelist jump: L3 -> L1 (building directly to room)
    if (low == levelRank(.L3_building) and cand_r == levelRank(.L1_unit_room)) {
        if (nearCharsBetween(text, cur_end, cand_start, 6)) return true;
    }
    // whitelist jump: L8 -> L6 (district directly to road), allow overlap attach
    if (low == levelRank(.L8_district) and cand_r == levelRank(.L6_road)) {
        if (cand_start <= cur_end and cand_end > cur_end) return true;
    }
    // whitelist jump: L9 -> L6 (city directly to road), allow overlap attach
    if (low == levelRank(.L9_city) and cand_r == levelRank(.L6_road)) {
        if (cand_start <= cur_end and cand_end > cur_end) return true;
    }
    return false;
}

fn canLeftAttach(current_bits: u32, cand_level: AddrLevel) bool {
    const high = highestRankInBits(current_bits);
    const cand_low = levelRank(cand_level);
    if (high == 0) return true; // first token in chain
    return cand_low == high + 1;
}

fn levelName(lv: AddrLevel) []const u8 {
    return @tagName(lv);
}

pub fn mergeZhAddressSpans(allocator: std.mem.Allocator, text: []const u8, spans: []const RecogEntity) ![]RecogEntity {
    const merged_adjacent = try mergeAdjacentAddressSpans(allocator, text, spans);
    defer allocator.free(merged_adjacent);

    var merged_zh = try std.ArrayList(RecogEntity).initCapacity(allocator, merged_adjacent.len);
    defer merged_zh.deinit(allocator);

    const SCAN_WIN: usize = 96; // characters scan window per step
    const LOOKAHEAD_STOP: usize = 12; // characters
    const MAX_TOTAL_GROW_CHARS: usize = 48;

    var tokens_buf = try std.ArrayList(ZhToken).initCapacity(allocator, 16);
    defer tokens_buf.deinit(allocator);

    for (merged_adjacent) |sp| {
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
        bits |= try zhTokenizeWindow(allocator, text, sp.start, sp.end, &tokens_buf);
        std.log.debug("[zh-addr] seed span: start={d} end={d} text={s}", .{ sp.start, sp.end, text[sp.start..sp.end] });
        std.log.debug("[zh-addr] seed tokens={d} bits=0x{x}", .{ tokens_buf.items.len, bits });
        for (tokens_buf.items) |tk| {
            std.log.debug("[zh-addr]   seed tk level={s} [{d},{d}) seg={s}", .{ levelName(tk.level), tk.start, tk.end, text[tk.start..tk.end] });
        }

        // right extension
        while (true) {
            if (countCharsBetween(text, sp.end, new_end) >= MAX_TOTAL_GROW_CHARS) break;
            // front lookahead stop: only after reaching privacy threshold
            const has_priv_rt = (bits & (BIT_L5 | BIT_L4 | BIT_L3 | BIT_L2 | BIT_L1)) != 0;
            if (has_priv_rt) {
                if (detectNextAddressHeadWithin(text, new_end, LOOKAHEAD_STOP)) {
                    std.log.debug("[zh-addr] right stop: lookahead head within {d} chars at pos={d}", .{ LOOKAHEAD_STOP, new_end });
                    break;
                }
            }
            const win_end = @min(text.len, new_end + SCAN_WIN);
            if (win_end <= new_end) break;
            tokens_buf.clearRetainingCapacity();
            _ = try zhTokenizeWindow(allocator, text, @intCast(new_end), @intCast(win_end), &tokens_buf);
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
                if (canRightAttach(bits, tk.level, text, new_start, new_end, tk.start, tk.end)) {
                    std.log.debug("[zh-addr]   right accept tk level={s} [{d},{d}) seg={s}", .{ levelName(tk.level), tk.start, tk.end, text[tk.start..tk.end] });
                    bits |= bitForLevel(tk.level);
                    if (tk.start < new_start) {
                        // adjust new_start to the leftmost token
                        new_start = tk.start;
                    }
                    new_end = tk.end;
                    std.log.debug("[zh-addr]   right new_end={d} bits=0x{x}", .{ new_end, bits });
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
            _ = try zhTokenizeWindow(allocator, text, @intCast(win_start), @intCast(new_start), &tokens_buf);
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
                if (tk.end > new_start) continue;
                if (tk.level == .L8_district and (bits & BIT_L8) != 0) {
                    std.log.debug("[zh-addr]   left reject tk level={s} (L8 duplicate) [{d},{d}) seg={s}", .{ levelName(tk.level), tk.start, tk.end, text[tk.start..tk.end] });
                    continue;
                }
                if (canLeftAttach(bits, tk.level)) {
                    std.log.debug("[zh-addr]   left accept tk level={s} [{d},{d}) seg={s}", .{ levelName(tk.level), tk.start, tk.end, text[tk.start..tk.end] });
                    bits |= bitForLevel(tk.level);
                    new_start = tk.start;
                    std.log.debug("[zh-addr]   left new_start={d} bits=0x{x}", .{ new_start, bits });
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
        std.log.debug("[zh-addr] accept final span [{d},{d}) text={s}", .{ out_sp.start, out_sp.end, text[out_sp.start..out_sp.end] });
        try merged_zh.append(allocator, out_sp);
    }

    return try merged_zh.toOwnedSlice(allocator);
}

// ===== M1 tokenization (exported) =====
pub const AddrLevel = enum(u8) {
    L11_country_region,
    L10_province,
    L9_city,
    L8_district,
    L7_township,
    L6_road,
    L5_house_no,
    L4_poi,
    L3_building,
    L2_floor,
    L1_unit_room,
};

const BIT_L11: u32 = 1 << 19;
const BIT_L10: u32 = 1 << 18;
const BIT_L9: u32 = 1 << 17;
const BIT_L8: u32 = 1 << 16;
const BIT_L7: u32 = 1 << 15;
const BIT_L6: u32 = 1 << 14;
const BIT_L5: u32 = 1 << 13;
const BIT_L4: u32 = 1 << 12;
const BIT_L3: u32 = 1 << 11;
const BIT_L2: u32 = 1 << 10;
const BIT_L1: u32 = 1 << 9;

pub const TokenSpan = struct {
    level: AddrLevel,
    start: u32,
    end: u32,
};

fn matchCountryRegionAt(text: []const u8, pos: usize) usize {
    const NAMES = [_][]const u8{
        "中国", "中華人民共和國", "中华人民共和国", "中國大陸", "中国大陆",
        "臺灣", "台湾",                "香港",                "澳門",       "澳门",
        "英國", "英国",                "美國",                "美国",       "日本",
    };
    var i: usize = 0;
    while (i < NAMES.len) : (i += 1) {
        if (matchToken(text, pos, NAMES[i])) return NAMES[i].len;
    }
    return 0;
}

fn provinceSuffixAt(text: []const u8, pos: usize) usize {
    const SUF = [_][]const u8{ "省", "自治区", "自治州", "州", "盟", "地区", "特别行政区" };
    var i: usize = 0;
    while (i < SUF.len) : (i += 1) {
        if (matchToken(text, pos, SUF[i])) return SUF[i].len;
    }
    return 0;
}

fn citySuffixAt(text: []const u8, pos: usize) usize {
    if (matchToken(text, pos, "市")) return "市".len;
    return 0;
}

fn districtSuffixAt(text: []const u8, pos: usize) usize {
    const SUF = [_][]const u8{ "区", "區", "县", "縣", "旗" };
    var i: usize = 0;
    while (i < SUF.len) : (i += 1) {
        if (matchToken(text, pos, SUF[i])) return SUF[i].len;
    }
    return 0;
}

fn townshipSuffixAt(text: []const u8, pos: usize) usize {
    const SUF = [_][]const u8{
        "街道",    "镇",       "鎮",       "乡",                   "鄉",       "里",       "村",
        "新区",    "高新区", "开发区", "经济技术开发区", "科技园", "科学园", "工业园",
        "工业区", "产业园", "科技園", "科學園",             "工業園", "工業區", "產業園",
    };
    var i: usize = 0;
    while (i < SUF.len) : (i += 1) {
        if (matchToken(text, pos, SUF[i])) return SUF[i].len;
    }
    return 0;
}

fn matchTownshipNameAt(text: []const u8, pos: usize) usize {
    // Lightweight HK/MO/CN township/area names (non-exhaustive)
    const NAMES = [_][]const u8{
        "铜锣湾", "銅鑼灣", "北角", "荃湾", "荃灣", "将军澳", "將軍澳", "青衣",
    };
    var i: usize = 0;
    while (i < NAMES.len) : (i += 1) {
        if (matchToken(text, pos, NAMES[i])) return NAMES[i].len;
    }
    return 0;
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

fn findChunkStart(text: []const u8, end_pos: usize, max_chars: usize) usize {
    var p = end_pos;
    var consumed: usize = 0;
    while (p > 0 and consumed < max_chars) {
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

pub fn zhTokenizeWindow(allocator: std.mem.Allocator, text: []const u8, start: u32, end: u32, out_tokens: *std.ArrayList(ZhToken)) !u32 {
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
            i = e - 1;
            continue;
        }
        const suf_prov = provinceSuffixAt(text, i);
        if (suf_prov > 0) {
            const e = i + suf_prov;
            const s = findChunkStart(text, i, 32);
            bits |= BIT_L10;
            try out_tokens.append(allocator, .{ .level = .L10_province, .start = @intCast(s), .end = @intCast(e) });
            i = e - 1;
            continue;
        }
        const suf_city = citySuffixAt(text, i);
        if (suf_city > 0) {
            const e = i + suf_city;
            const s = findChunkStart(text, i, 24);
            bits |= BIT_L9;
            try out_tokens.append(allocator, .{ .level = .L9_city, .start = @intCast(s), .end = @intCast(e) });
            i = e - 1;
            continue;
        }
        const suf_dist = districtSuffixAt(text, i);
        if (suf_dist > 0) {
            const e = i + suf_dist;
            const s = findChunkStart(text, i, 24);
            bits |= BIT_L8;
            try out_tokens.append(allocator, .{ .level = .L8_district, .start = @intCast(s), .end = @intCast(e) });
            i = e - 1;
            continue;
        }
        const l7name = matchTownshipNameAt(text, i);
        if (l7name > 0) {
            const s = i;
            const e = i + l7name;
            bits |= BIT_L7;
            try out_tokens.append(allocator, .{ .level = .L7_township, .start = @intCast(s), .end = @intCast(e) });
            i = e - 1;
            continue;
        }
        const suf_town = townshipSuffixAt(text, i);
        if (suf_town > 0) {
            const e = i + suf_town;
            const s = findChunkStart(text, i, 24);
            bits |= BIT_L7;
            try out_tokens.append(allocator, .{ .level = .L7_township, .start = @intCast(s), .end = @intCast(e) });
            i = e - 1;
            continue;
        }
        const suf_road = roadSuffixAt(text, i);
        if (suf_road > 0) {
            const e = i + suf_road;
            const s = findChunkStart(text, i, 32);
            bits |= BIT_L6;
            try out_tokens.append(allocator, .{ .level = .L6_road, .start = @intCast(s), .end = @intCast(e) });
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
            while (p > start and steps < 12) : (steps += 1) {
                p -= 1;
                if (isAsciiLight(text[p])) break;
                if (isDigit(text[p])) {
                    has_digit = true;
                    dstart = p;
                    while (dstart > start and isDigit(text[dstart - 1])) : (dstart -= 1) {}
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
                bits |= BIT_L4;
                try out_tokens.append(allocator, .{ .level = .L4_poi, .start = @intCast(i), .end = @intCast(poi_end) });
                i = poi_end - 1;
                continue;
            }
        }
        const bu_len = buildingUnitAt(text, i);
        if (bu_len > 0) {
            var p = i;
            var has_digit = false;
            var has_alpha_letter = false;
            var dstart2: usize = i;
            var steps2: usize = 0;
            while (p > start and steps2 < 12) : (steps2 += 1) {
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
                i = e - 1;
                continue;
            } else if (has_alpha_letter) {
                const e = i + bu_len;
                bits |= BIT_L3;
                try out_tokens.append(allocator, .{ .level = .L3_building, .start = @intCast(dstart2), .end = @intCast(e) });
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
            while (p > 0 and steps3 < 8) : (steps3 += 1) {
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
                i = q - 1;
                continue;
            }
        }
        const ru_len = roomUnitAt(text, i);
        if (ru_len > 0) {
            var p = i;
            var has_digit = false;
            var dstart4: usize = i;
            var steps4: usize = 0;
            while (p > 0 and steps4 < 8) : (steps4 += 1) {
                p -= 1;
                if (isAsciiLight(text[p])) break;
                if (isDigit(text[p])) {
                    has_digit = true;
                    dstart4 = p;
                    while (dstart4 > start and isDigit(text[dstart4 - 1])) : (dstart4 -= 1) {}
                    break;
                }
            }
            if (has_digit) {
                const e = i + ru_len;
                bits |= BIT_L1;
                try out_tokens.append(allocator, .{ .level = .L1_unit_room, .start = @intCast(dstart4), .end = @intCast(e) });
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
            bits &= ~bitForLevel(tk.level);
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

/// Compute address depth rank within [start,end): smaller rank means deeper (L1 is 1, ... L11 is 11). 255 = unknown.
pub fn addrDepthRank(allocator: std.mem.Allocator, text: []const u8, start: u32, end: u32) u8 {
    var toks = std.ArrayList(ZhToken).init(allocator);
    defer toks.deinit(allocator);
    const bits = zhTokenizeWindow(allocator, text, start, end, &toks) catch 0;
    if ((bits & BIT_L1) != 0) return 1;
    if ((bits & BIT_L2) != 0) return 2;
    if ((bits & BIT_L3) != 0) return 3;
    if ((bits & BIT_L4) != 0) return 4;
    if ((bits & BIT_L5) != 0) return 5;
    if ((bits & BIT_L6) != 0) return 6;
    if ((bits & BIT_L7) != 0) return 7;
    if ((bits & BIT_L8) != 0) return 8;
    if ((bits & BIT_L9) != 0) return 9;
    if ((bits & BIT_L10) != 0) return 10;
    if ((bits & BIT_L11) != 0) return 11;
    return 255;
}

/// Fast depth rank without allocation, based on unit presence inside [start,end)
/// Priority: L1(room)=1 < L2(floor)=2 < L3(building)=3 < L5(house)=5 < L6(road)=6; 255 unknown
pub fn quickDepthRank(text: []const u8, start: u32, end: u32) u8 {
    if (end <= start or end > text.len) return 255;
    var rank: u8 = 255;
    var i: usize = start;
    while (i < end) : (i += 1) {
        if (roomUnitAt(text, i) > 0) return 1;
        if (rank > 2 and floorUnitAt(text, i) > 0) rank = 2;
        if (rank > 3 and buildingUnitAt(text, i) > 0) rank = 3;
        if (rank > 6 and roadSuffixAt(text, i) > 0) rank = 6;
    }
    if (rank > 5 and hasHouseTailInside(text, start, end)) rank = 5;
    return rank;
}
