const std = @import("std");

pub fn isAwaitedHostSense(err: anyerror) bool {
    return err == error.FrontendCaptureRequested or err == error.FrontendOrientationRequested;
}

pub fn isDeferredControlFlow(err: anyerror) bool {
    return isAwaitedHostSense(err);
}

pub fn name(err: anyerror) []const u8 {
    return @errorName(err);
}

pub fn detail(err: anyerror) []const u8 {
    return switch (err) {
        error.FrontendCaptureRequested => "The brain asked the host to capture a camera frame; the conversation pauses until the host sends sense_observation with the photo.",
        error.FrontendOrientationRequested => "The brain asked the host for a one-shot orientation sample; the conversation pauses until the host sends the orientation observation.",
        error.HostHttpPostJsonFailed => "A host HTTP callback failed; check the host-side error detail if one was returned.",
        error.HostHttpTransportRequired => "Embedded runtime has no host HTTP transport configured for provider or recognition callbacks.",
        error.UnsupportedHostCapability => "This host profile does not implement the capability the brain requested.",
        error.MissingOrientationQuery => "The recognize/orientation skill was selected but no orientation query port is wired on this host.",
        error.MissingFileSystem => "Brain runtime is missing a filesystem dependency.",
        error.LocalDateUnavailable => "Brain runtime could not read local time from the IO clock.",
        error.MissingProcessRunner => "This skill requires a process runner that is not configured.",
        error.MissingEmailSmtpUrl => "Email is not configured: missing SMTP URL.",
        error.MissingEmailFrom => "Email is not configured: missing From address.",
        error.MissingEmailBody => "Email send was requested with an empty body.",
        error.MissingEmailUsername => "Email SMTP username is missing while a password is set.",
        error.MissingEmailPassword => "Email SMTP password is missing while a username is set.",
        error.RemoteServiceFailed => "A remote provider returned a retryable failure.",
        error.LocalServiceRequestRejected => "A remote provider rejected the request as invalid or unauthorized.",
        error.LocalServiceResponseInvalid => "A remote provider response was missing, malformed, or not JSON.",
        error.SyntaxError => "JSON parsing failed for a provider or host response.",
        error.MissingMemorySelectionService => "Conversation memory selection requires a configured memory selection LLM service.",
        error.StreamTooLong => "An HTTP or process response exceeded the configured size limit.",
        error.HttpStatusFailed => "An HTTP request returned a non-success status code.",
        error.KnownRecognitionMissingPersonId => "Recognition reported a known match but did not include person_id.",
        error.NoPendingConversationPause => "The brain tried to resume a paused conversation but no pause state exists.",
        error.NoActiveActivity => "The brain tried to manage an activity but no active activity exists.",
        error.ActivityStackOverflow => "The activity stack exceeded its maximum depth while pausing a parent for a subtask.",
        error.ActivityStackEmpty => "The brain tried to resume a parent activity but the activity stack is empty.",
        error.ActiveActivityAlreadyPresent => "The brain tried to resume a stacked parent while another activity is still active.",
        error.ActivityAwaitingHostCheckpoint => "The brain cannot stack an activity that is paused waiting for host-delivered sense.",
        error.MissingSubtaskGoal => "begin_subtask was selected without subtask goal text.",
        error.NoParentActivityToResume => "resume_parent was selected but no paused parent activity exists on the stack.",
        error.NoActiveConversationProcess => "The brain tried to manage an activity but no active activity exists.",
        error.MissingActivityCheckpoint => "The brain tried to resume an activity but its checkpoint is missing.",
        error.MissingChatTurnAfterAwaitedSense => "The brain paused for host sense input but lost the chat turn state needed to resume.",
        error.MissingRuntimeChatTurnSummary => "The conversation turn finished without chat summaries even though the runtime already spoke a recovery message.",
        error.RuntimeMissingChatTurn => "The runtime completed a turn pass but language interpretation never produced a chat turn.",
        error.RuntimeExecutionIncomplete => "The runtime created action proposals but did not finish executing or suppressing them before the turn ended.",
        else => "",
    };
}

pub fn formatFailureDetail(allocator: std.mem.Allocator, err: anyerror, extra: ?[]const u8) ![]const u8 {
    const base = detail(err);
    if (extra) |text| {
        if (base.len > 0) return try std.fmt.allocPrint(allocator, "{s} content={s}", .{ base, text });
        return try allocator.dupe(u8, text);
    }
    if (base.len > 0) return try allocator.dupe(u8, base);
    return try allocator.dupe(u8, name(err));
}

pub fn recognitionStatusDetail(status: @import("identity.zig").MatchStatus, confidence: f32, people_count: u32) []const u8 {
    _ = confidence;
    return switch (status) {
        .none => if (people_count == 0)
            "no face detected in the latest frame"
        else
            "no recognizable face in the latest frame",
        .unknown => "face present but not matched to any enrolled person",
        .uncertain => "possible match to a known person but confidence is below the known threshold",
        .known => "matched a known enrolled person",
        .multiple => "multiple faces detected; identity is ambiguous",
    };
}

pub fn formatTraceError(buffer: []u8, err: anyerror, host_detail: ?[]const u8) ?[]const u8 {
    if (host_detail) |text| {
        if (text.len > 0) {
            return std.fmt.bufPrint(
                buffer,
                "error={s} detail=\"{s}\" host_detail=\"{s}\"",
                .{ name(err), detail(err), text },
            ) catch null;
        }
    }
    return std.fmt.bufPrint(
        buffer,
        "error={s} detail=\"{s}\"",
        .{ name(err), detail(err) },
    ) catch null;
}
