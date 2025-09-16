const std = @import("std");

const MAX_RECOG_SCORE: f32 = 1.0;
const MIN_RECOG_SCORE: f32 = 0.0;

pub const EntityType = enum(u8) {
    None, // for normal text, not a PII entity
    PHYSICAL_ADDRESS,
    EMAIL_ADDRESS,
    ORGANIZATION,
    USER_MAME,
    PHONE_NUMBER,
    BANK_NUMBER,
    PAYMENT,
    VERIFICATION_CODE,
    PASSWORD,
    RANDOM_SEED,
    PRIVATE_KEY,
    URL_ADDRESS,
};

pub const RecogEntity = struct {
    entity_type: EntityType = .None,
    start: usize,
    end: usize,
    score: f32,
    description: ?[]const u8,
};
