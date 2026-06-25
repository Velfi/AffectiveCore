pub const api = struct {
    pub const audio_client = @import("api/audio_client.zig");
    pub const autonomy_client = @import("api/autonomy_client.zig");
    pub const chat_client = @import("api/chat_client.zig");
    pub const email_client = @import("api/email_client.zig");
    pub const greeting_client = @import("api/greeting_client.zig");
    pub const http_transport = @import("api/http_transport.zig");
    pub const image_client = @import("api/image_client.zig");
    pub const intent_client = @import("api/intent_client.zig");
    pub const openai_client = @import("api/openai_client.zig");
    pub const psyche_client = @import("api/psyche_client.zig");
    pub const random_provider_client = @import("api/random_provider_client.zig");
    pub const recognition_client = @import("api/recognition_client.zig");
    pub const speech_client = @import("api/speech_client.zig");
    pub const transcription_client = @import("api/transcription_client.zig");
    pub const want_achievement_client = @import("api/want_achievement_client.zig");
};

pub const app = struct {
    pub const brain = @import("app/brain.zig");
};

pub const core = struct {
    pub const brain = @import("core/brain.zig");
    pub const config = @import("core/config.zig");
    pub const events = @import("core/events.zig");
    pub const interrupt = @import("core/interrupt.zig");
    pub const maintenance = @import("core/maintenance.zig");
    pub const startup_deps = @import("core/startup_deps.zig");
};

pub const platform = struct {
    pub const common = struct {
        pub const button = @import("platform/common/button.zig");
        pub const camera = @import("platform/common/camera.zig");
        pub const command_log = @import("platform/common/command_log.zig");
        pub const df_storage = @import("platform/common/df_storage.zig");
        pub const facial_expression = @import("platform/common/facial_expression.zig");
        pub const files = @import("platform/common/files.zig");
        pub const input = @import("platform/common/input.zig");
        pub const process = @import("platform/common/process.zig");
        pub const shutdown_signals = @import("platform/common/shutdown_signals.zig");
        pub const speaker = @import("platform/common/speaker.zig");
        pub const system_senses = @import("platform/common/system_senses.zig");
        pub const voice_input = @import("platform/common/voice_input.zig");
    };
};

pub const storage = struct {
    pub const brain_storage = @import("storage/brain_storage.zig");
};
