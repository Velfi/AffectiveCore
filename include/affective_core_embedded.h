#ifndef AFFECTIVE_CORE_EMBEDDED_H
#define AFFECTIVE_CORE_EMBEDDED_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AffectiveCoreEmbedded AffectiveCoreEmbedded;

typedef struct AffectiveCoreEmbeddedString {
    const uint8_t *ptr;
    size_t len;
} AffectiveCoreEmbeddedString;

typedef struct AffectiveCoreEmbeddedConfig {
    AffectiveCoreEmbeddedString brain_id;
    AffectiveCoreEmbeddedString brain_root;
    AffectiveCoreEmbeddedString conversation_models;
    AffectiveCoreEmbeddedString conversation_reasoning_effort;
    AffectiveCoreEmbeddedString image_generation_model;
    AffectiveCoreEmbeddedString image_generation_output_dir;
    AffectiveCoreEmbeddedString memory_path;
    AffectiveCoreEmbeddedString graph_path;
    AffectiveCoreEmbeddedString schedule_path;
    AffectiveCoreEmbeddedString maintenance_state_path;
    AffectiveCoreEmbeddedString face_embeddings_dir;
    AffectiveCoreEmbeddedString host_manifest_json;
} AffectiveCoreEmbeddedConfig;

typedef int (*AffectiveCoreEmbeddedHttpPostJsonFn)(
    void *ctx,
    AffectiveCoreEmbeddedString url,
    AffectiveCoreEmbeddedString headers_json,
    AffectiveCoreEmbeddedString body,
    AffectiveCoreEmbeddedString *out_data,
    AffectiveCoreEmbeddedString *out_error
);

typedef void (*AffectiveCoreEmbeddedFreeHostStringFn)(
    void *ctx,
    AffectiveCoreEmbeddedString string
);

typedef struct AffectiveCoreEmbeddedHostServices {
    void *ctx;
    AffectiveCoreEmbeddedHttpPostJsonFn http_post_json;
    AffectiveCoreEmbeddedFreeHostStringFn free_string;
} AffectiveCoreEmbeddedHostServices;

typedef enum AffectiveCoreEmbeddedStatus {
    AFFECTIVE_CORE_EMBEDDED_OK = 0,
    AFFECTIVE_CORE_EMBEDDED_INVALID_ARGUMENT = 1,
    AFFECTIVE_CORE_EMBEDDED_INITIALIZATION_FAILED = 2,
    AFFECTIVE_CORE_EMBEDDED_RUNTIME_ERROR = 3,
} AffectiveCoreEmbeddedStatus;

int affective_core_embedded_create(
    const AffectiveCoreEmbeddedConfig *config,
    const AffectiveCoreEmbeddedHostServices *host_services,
    AffectiveCoreEmbedded **out_handle,
    AffectiveCoreEmbeddedString *out_error
);

void affective_core_embedded_destroy(AffectiveCoreEmbedded *handle);

// Each handle allows one in-flight mutating call at a time. Concurrent dispatch,
// drain, raw_ref_lookup, export, or import on the same handle returns runtime_error.
void affective_core_embedded_free_global_string(AffectiveCoreEmbeddedString string);

int affective_core_embedded_dispatch_json(
    AffectiveCoreEmbedded *handle,
    const uint8_t *request_json,
    size_t request_json_len,
    AffectiveCoreEmbeddedString *out_data,
    AffectiveCoreEmbeddedString *out_error
);

int affective_core_embedded_drain_events_json(
    AffectiveCoreEmbedded *handle,
    AffectiveCoreEmbeddedString *out_data,
    AffectiveCoreEmbeddedString *out_error
);

int affective_core_embedded_raw_ref_lookup_json(
    AffectiveCoreEmbedded *handle,
    const uint8_t *raw_ref,
    size_t raw_ref_len,
    AffectiveCoreEmbeddedString *out_data,
    AffectiveCoreEmbeddedString *out_error
);

int affective_core_embedded_export_brain(
    AffectiveCoreEmbedded *handle,
    const uint8_t *brain_file_path,
    size_t brain_file_path_len,
    AffectiveCoreEmbeddedString *out_data,
    AffectiveCoreEmbeddedString *out_error
);

int affective_core_embedded_import_brain(
    AffectiveCoreEmbedded *handle,
    const uint8_t *brain_file_path,
    size_t brain_file_path_len,
    const uint8_t *brain_id,
    size_t brain_id_len,
    const uint8_t *brain_root,
    size_t brain_root_len,
    const uint8_t *host_id,
    size_t host_id_len,
    AffectiveCoreEmbeddedString *out_data,
    AffectiveCoreEmbeddedString *out_error
);

int affective_core_embedded_api_e2e(
    const AffectiveCoreEmbeddedConfig *config,
    const AffectiveCoreEmbeddedHostServices *host_services,
    AffectiveCoreEmbeddedString *out_data,
    AffectiveCoreEmbeddedString *out_error
);

#ifdef __cplusplus
}
#endif

#endif
