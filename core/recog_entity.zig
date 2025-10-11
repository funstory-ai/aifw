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

/// The kind of the entity, for example, .Begin, .Inside, etc.
/// Response the string "B-", "I-", etc. in the external NER output.
pub const EntityBioTag = enum(u8) {
    None, // Outside of the entity
    Begin, // Begin of the entity
    Inside, // Inside of the entity
};

pub const RecogEntity = struct {
    entity_type: EntityType = .None,
    start: u32,
    end: u32,
    score: f32,
    description: ?[]const u8,
};
