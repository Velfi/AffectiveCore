const std = @import("std");

pub const AppraisalSignals = struct {
    valence: f32,
    arousal: f32,
    confidence: f32,
    uncertainty: f32,
    social_warmth: f32,
    curiosity: f32,
    stress: f32,
    feeling_label: []const u8,
    action_tendency: []const u8,
    expression: []const u8,
    dynamics: []const u8,
};

pub fn appraise(text: []const u8) AppraisalSignals {
    const uncertainty = estimateUncertainty(text);
    const valence = estimateValence(text);
    const stress = estimateStress(text);
    const curiosity = estimateCuriosity(text);
    const warmth = estimateSocialWarmth(text);
    const arousal = estimateArousal(text, valence, stress, curiosity);
    return .{
        .valence = valence,
        .arousal = arousal,
        .confidence = 1.0 - uncertainty * 0.55,
        .uncertainty = uncertainty,
        .social_warmth = warmth,
        .curiosity = curiosity,
        .stress = stress,
        .feeling_label = emotionLabel(valence, arousal, warmth, curiosity, stress),
        .action_tendency = actionTendency(uncertainty, warmth, curiosity, stress),
        .expression = expressionStyle(valence, arousal, warmth, stress),
        .dynamics = emotionDynamics(arousal, uncertainty, stress),
    };
}

pub fn describe(allocator: std.mem.Allocator, query: []const u8, signals: AppraisalSignals) ![]const u8 {
    const certainty = if (signals.uncertainty > 0.60) "uncertain" else "fairly steady";
    const relation = if (signals.social_warmth > 0.60) "socially warm" else "neutral";
    return std.fmt.allocPrint(
        allocator,
        "This lands as {s}, {s}, and {s}. components: appraisal={s}; bodily_arousal={d:.3}; action_tendency={s}; expression={s}; feeling={s}. dynamics: {s}. Topic: {s}",
        .{ signals.feeling_label, certainty, relation, certainty, signals.arousal, signals.action_tendency, signals.expression, signals.feeling_label, signals.dynamics, query },
    );
}

pub fn estimateValence(text: []const u8) f32 {
    const positive = termHits(text, &.{ "thank", "like", "good", "warm", "love", "joy", "happy", "hope", "safe", "calm", "trust", "relief", "delight", "proud", "care" });
    const negative = termHits(text, &.{ "bad", "fail", "stress", "worry", "afraid", "fear", "angry", "anger", "sad", "grief", "shame", "disgust", "hurt", "loss", "threat", "panic", "broken", "lonely" });
    if (positive == 0 and negative == 0) return 0.0;
    return clampValence(@as(f32, @floatFromInt(positive)) * 0.18 - @as(f32, @floatFromInt(negative)) * 0.20);
}

pub fn estimateUncertainty(text: []const u8) f32 {
    var value: f32 = 0.25;
    if (std.mem.indexOfScalar(u8, text, '?') != null) value += 0.25;
    if (termHits(text, &.{ "maybe", "unsure", "uncertain", "ambivalent", "confusing", "unclear", "mixed", "conflicted" }) > 0) value += 0.35;
    return clampUnit(value);
}

pub fn estimateStress(text: []const u8) f32 {
    var value: f32 = 0.15;
    value += @as(f32, @floatFromInt(termHits(text, &.{ "urgent", "broken", "fail", "help", "threat", "panic", "danger", "crisis", "afraid", "fear" }))) * 0.20;
    value += @as(f32, @floatFromInt(termHits(text, &.{ "worry", "stress", "overwhelm", "hard", "stuck", "problem" }))) * 0.14;
    return clampUnit(value);
}

pub fn estimateSalience(text: []const u8, tags: []const []const u8) f32 {
    var value: f32 = 0.35;
    if (text.len > 80) value += 0.10;
    if (std.mem.indexOfScalar(u8, text, '!') != null or std.mem.indexOfScalar(u8, text, '?') != null) value += 0.10;
    for (tags) |tag| {
        if (std.ascii.eqlIgnoreCase(tag, "preference") or std.ascii.eqlIgnoreCase(tag, "identity") or std.ascii.eqlIgnoreCase(tag, "help") or std.ascii.eqlIgnoreCase(tag, "dream")) value += 0.15;
    }
    return clampUnit(value);
}

fn estimateCuriosity(text: []const u8) f32 {
    var value: f32 = 0.30;
    if (std.mem.indexOfScalar(u8, text, '?') != null) value += 0.30;
    value += @as(f32, @floatFromInt(termHits(text, &.{ "why", "how", "what", "learn", "curious", "wonder", "explore", "discover", "think", "idea", "plan" }))) * 0.08;
    return clampUnit(value);
}

fn estimateSocialWarmth(text: []const u8) f32 {
    var value: f32 = 0.40;
    value += @as(f32, @floatFromInt(termHits(text, &.{ "thank", "friend", "help", "together", "care", "kind", "warm", "trust", "please", "love" }))) * 0.10;
    value -= @as(f32, @floatFromInt(termHits(text, &.{ "angry", "blame", "hate", "threat", "disgust" }))) * 0.12;
    return clampUnit(value);
}

fn estimateArousal(text: []const u8, valence: f32, stress: f32, curiosity: f32) f32 {
    var value: f32 = 0.18 + @abs(valence) * 0.25 + stress * 0.45 + curiosity * 0.18;
    if (std.mem.indexOfScalar(u8, text, '!') != null) value += 0.12;
    if (text.len > 120) value += 0.08;
    if (termHits(text, &.{ "very", "really", "so", "intense", "overwhelm", "urgent", "panic" }) > 0) value += 0.12;
    return clampUnit(value);
}

fn emotionLabel(valence: f32, arousal: f32, warmth: f32, curiosity: f32, stress: f32) []const u8 {
    if (stress >= 0.70 and arousal >= 0.65) return "alarm";
    if (stress >= 0.55 and valence < -0.15) return "worry";
    if (curiosity >= 0.65 and valence >= -0.10) return "interest";
    if (warmth >= 0.65 and valence > 0.10) return "warm appreciation";
    if (valence >= 0.30) return "positive ease";
    if (valence <= -0.30) return "unease";
    if (arousal >= 0.60) return "activated mixed feeling";
    return "quietly mixed";
}

fn actionTendency(uncertainty: f32, warmth: f32, curiosity: f32, stress: f32) []const u8 {
    if (stress >= 0.65) return "resolve, protect, or ask a human";
    if (uncertainty >= 0.65) return "pause and clarify";
    if (curiosity >= 0.65) return "explore and gather context";
    if (warmth >= 0.65) return "approach and connect";
    return "monitor without acting";
}

fn expressionStyle(valence: f32, arousal: f32, warmth: f32, stress: f32) []const u8 {
    if (stress >= 0.65) return "brief, direct, and careful";
    if (warmth >= 0.65 and valence > 0.10) return "open and warm";
    if (arousal >= 0.60) return "energetic and focused";
    if (valence < -0.20) return "soft and cautious";
    return "even and low-key";
}

fn emotionDynamics(arousal: f32, uncertainty: f32, stress: f32) []const u8 {
    if (stress >= 0.65 or uncertainty >= 0.70) return "unstable until the situation is resolved";
    if (arousal >= 0.65) return "short-lived episode with high attention pull";
    if (arousal <= 0.30) return "low-intensity background mood";
    return "moderate episode that can update with new context";
}

fn termHits(text: []const u8, comptime terms: []const []const u8) u32 {
    var hits: u32 = 0;
    inline for (terms) |term| {
        if (std.ascii.indexOfIgnoreCase(text, term) != null) hits += 1;
    }
    return hits;
}

fn clampUnit(value: f32) f32 {
    return @min(1.0, @max(0.0, value));
}

fn clampValence(value: f32) f32 {
    return @min(0.85, @max(-0.85, value));
}
