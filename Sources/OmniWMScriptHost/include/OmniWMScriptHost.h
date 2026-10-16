// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#ifndef OMNIWM_SCRIPT_HOST_H
#define OMNIWM_SCRIPT_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
#define OMNI_NOEXCEPT noexcept
extern "C" {
#else
#define OMNI_NOEXCEPT
#endif

typedef struct omni_vm omni_vm;
typedef struct omni_instance omni_instance;

typedef enum omni_status {
    OMNI_OK = 0,
    OMNI_ERR_COMPILE = 1,
    OMNI_ERR_RUNTIME = 2,
    OMNI_ERR_MEMORY = 3,
    OMNI_ERR_TIMEOUT = 4,
    OMNI_ERR_REENTRANT = 5,
    OMNI_ERR_INTERNAL = 6,
    OMNI_ERR_COMPONENT = 7,
    OMNI_ERR_STALE_ACTION = 8,
    OMNI_ERR_RELOAD_REQUIRED = 9
} omni_status;

#define OMNI_WIRE_MAGIC 0x4F4D5731u
#define OMNI_WIRE_AUDIO 0x1u
#define OMNI_ACTION_HANDLER 0x80000000u
#define OMNI_ACTION_POPOUT 0x40000000u
#define OMNI_NODE_OPENS_POPOUT 0x1u
#define OMNI_NODE_MENU 0x2u
#define OMNI_NODE_PREVIEW 0x4u
#define OMNI_NODE_DRAG 0x8u
#define OMNI_NODE_DROP 0x100u
#define OMNI_NODE_SCROLL 0x200u
#define OMNI_NODE_ICON_WINDOW 0x400u
#define OMNI_NODE_ICON_PID 0x800u
#define OMNI_NODE_ICON_MASK 0xC00u
#define OMNI_NODE_MATERIAL_SHIFT 12u
#define OMNI_NODE_MATERIAL_MASK 0xF000u
#define OMNI_MATERIAL_POPOVER 7u
#define OMNI_MATERIAL_GLASS 8u
#define OMNI_MATERIAL_CLEAR 9u
#define OMNI_NODE_OPTION_BRIDGE 0x1u
#define OMNI_NODE_OPTION_MASK 0x2u
#define OMNI_NODE_OPTION_EVEN_ODD 0x4u
#define OMNI_NODE_OPTION_ATTACH 0x8u
#define OMNI_NODE_OPTION_LOOP_PAUSED 0x10u
#define OMNI_NODE_OPTION_TRAIL 0x20u
#define OMNI_NODE_OPTION_AUDIO 0x40u
#define OMNI_NODE_OPTION_NO_FOCUS_RING 0x80u
#define OMNI_NODE_ALIGN_SHIFT 4u
#define OMNI_NODE_ALIGN_MASK 0xF0u
#define OMNI_ACTION_HISTORY 4u
#define OMNI_STYLE_BASE_MASK 0xFu
#define OMNI_STYLE_WEIGHT_SHIFT 4u
#define OMNI_STYLE_WEIGHT_MASK 0xF0u
#define OMNI_STYLE_FONT_SHIFT 8u
#define OMNI_STYLE_FONT_MASK 0xF00u
#define OMNI_STYLE_FILLED 0x1000u
#define OMNI_STYLE_QUARTER 0x2000u
#define OMNI_STYLE_SIZE_SHIFT 16u

typedef enum omni_value_tag {
    OMNI_VALUE_NIL = 0,
    OMNI_VALUE_FALSE = 1,
    OMNI_VALUE_TRUE = 2,
    OMNI_VALUE_NUMBER = 3,
    OMNI_VALUE_STRING = 4,
    OMNI_VALUE_ARRAY = 5,
    OMNI_VALUE_MAP = 6
} omni_value_tag;

typedef enum omni_view {
    OMNI_VIEW_BAR = 0,
    OMNI_VIEW_POPOUT = 1,
    OMNI_VIEW_NONE = 2
} omni_view;

typedef enum omni_message_kind {
    OMNI_MESSAGE_REQUEST = 0,
    OMNI_MESSAGE_LOG = 1
} omni_message_kind;

typedef struct omni_desktop_anchor {
    uint64_t epoch;
    uint64_t unit;
    uint64_t key;
} omni_desktop_anchor;

typedef struct omni_anchor_step {
    uint64_t key;
    uint32_t child;
    uint32_t kind;
} omni_anchor_step;

typedef struct omni_wire_header {
    uint32_t magic;
    uint32_t node_count;
    uint32_t string_count;
    uint32_t flags;
    uint64_t deps;
    uint32_t epoch;
} omni_wire_header;

typedef struct omni_wire_node {
    uint8_t kind;
    uint8_t axis;
    uint8_t center_cross;
    uint8_t motion;
    int32_t subtree_end;
    uint64_t key;
    float width;
    float height;
    float grow;
    float gap;
    float padding;
    uint32_t fill;
    uint32_t stroke;
    float stroke_width;
    float corner_radius;
    float opacity;
    uint32_t text;
    uint32_t reserve;
    uint32_t color;
    uint32_t rate;
    uint32_t series;
    uint16_t style;
    uint16_t flags;
    uint32_t action;
    uint32_t hover;
    uint16_t fill_role;
    uint16_t stroke_role;
    uint16_t color_role;
    uint16_t hover_role;
    float params[4];
    uint32_t target;
    float dx;
    float dy;
    float scale;
    float shadow_radius;
    uint32_t shadow;
    uint16_t shadow_role;
    uint8_t hover_motion;
    uint8_t hover_material;
    uint32_t secondary_action;
    uint32_t scroll_action;
    float max_width;
    uint32_t icon_ref;
    uint32_t placeholder;
    float hover_scale;
    float hover_opacity;
    uint32_t help;
    uint8_t lines;
    uint8_t options;
    uint8_t enter_from;
    uint8_t enter_to;
    float open_duration;
    float close_duration;
    float enter_opacity;
    float enter_scale;
    float enter_dx;
    float enter_dy;
    uint8_t enter_curve;
    uint8_t motion_curve;
    uint16_t text_size;
    uint32_t enter_path;
    float view_box[4];
    uint32_t enter_curve_ref;
    uint32_t motion_curve_ref;
    float enter_stretch;
    float rotate;
    uint32_t loop;
    float speed;
    uint32_t hover_action;
    uint32_t press_action;
    uint32_t gesture_action;
    uint32_t key_action;
    uint32_t outside_press_action;
    uint32_t keys;
    float press_scale;
    float press_opacity;
    uint32_t press_fill;
    uint32_t press_motion_curve_ref;
    float hover_delay;
    float hover_grace;
    float gesture_threshold;
    float gesture_lock_distance;
    float gesture_dominance;
    float gesture_commit_distance;
    float gesture_commit_velocity;
    uint16_t press_fill_role;
    uint8_t press_motion;
    uint8_t press_motion_curve;
    uint8_t gesture_axis;
    uint8_t gesture_source;
    uint8_t gesture_direction;
    uint8_t input_flags;
    uint32_t appear;
    uint32_t exit;
    uint32_t gesture_track;
    uint32_t input_commit_action;
    uint32_t input_cancel_action;
    uint32_t input_focus_action;
    uint32_t input_max_length;
    uint32_t resource_image_ref;
    float thumbnail;
    uint32_t resource_drop_action;
    uint32_t resource_hover_action;
    uint32_t resource_accepts;
    uint32_t texture_ref;
    uint32_t resource_drag_ref;
    uint32_t resource_drag_action;
    float blur_radius;
    float saturation;
} omni_wire_node;

#define OMNI_RESOURCE_ACCEPT_FILE 0x1u
#define OMNI_RESOURCE_ACCEPT_URL 0x2u
#define OMNI_RESOURCE_ACCEPT_TEXT 0x4u
#define OMNI_RESOURCE_ACCEPT_IMAGE 0x8u

#define OMNI_INPUT_FOCUSABLE 0x1u
#define OMNI_INPUT_MOMENTUM_DELIVER 0x2u
#define OMNI_INPUT_GESTURE_ALL 0x4u
#define OMNI_INPUT_PRESS_FILL 0x8u
#define OMNI_INPUT_PRESS_SCALE 0x10u
#define OMNI_INPUT_MULTILINE 0x20u
#define OMNI_INPUT_FOCUS_PRESENT 0x40u
#define OMNI_INPUT_FOCUS_VALUE 0x80u

#define OMNI_CURVE_CUSTOM 255u

typedef struct omni_l10n_arg {
    uint8_t kind;
    double number;
    const char *text;
    size_t length;
} omni_l10n_arg;

typedef size_t (*omni_localizer)(void *context, const char *key, size_t key_length, const omni_l10n_arg *args, size_t count, char *out, size_t capacity);

#define OMNI_FORMAT_NUMBER 0u
#define OMNI_FORMAT_PERCENT 1u
#define OMNI_FORMAT_MEMORY 2u
#define OMNI_FORMAT_FILE 3u
#define OMNI_FORMAT_DATE 4u
#define OMNI_FORMAT_OFFSET 5u

typedef size_t (*omni_formatter)(void *context, uint8_t kind, double value, int32_t digits, const char *pattern, size_t pattern_length, const char *zone, size_t zone_length, char *out, size_t capacity);

typedef struct omni_wire_string {
    uint32_t id;
    uint32_t length;
} omni_wire_string;

typedef struct omni_render_stats {
    uint64_t cpu_ns;
    uint64_t encode_cpu_ns;
    uint64_t deps;
    uint32_t new_strings;
    uint32_t changed;
} omni_render_stats;

omni_vm *omni_vm_create(size_t memory_limit_bytes, const char *data_keys, size_t data_keys_length) OMNI_NOEXCEPT;
omni_status omni_vm_destroy(omni_vm *vm) OMNI_NOEXCEPT;
omni_status omni_vm_load(omni_vm *vm, const char *chunk_name, const char *source, size_t source_length, uint64_t budget_ns, char *error, size_t error_capacity) OMNI_NOEXCEPT;
void omni_vm_collect(omni_vm *vm) OMNI_NOEXCEPT;
void omni_vm_set_localizer(omni_vm *vm, omni_localizer localizer, void *context) OMNI_NOEXCEPT;
void omni_vm_set_formatter(omni_vm *vm, omni_formatter formatter, void *context) OMNI_NOEXCEPT;
omni_status omni_vm_global_number(omni_vm *vm, const char *name, double *out) OMNI_NOEXCEPT;
omni_status omni_vm_global_boolean(omni_vm *vm, const char *name, bool *out) OMNI_NOEXCEPT;
omni_status omni_vm_global_function(omni_vm *vm, const char *name) OMNI_NOEXCEPT;
omni_status omni_vm_add_module(omni_vm *vm, const char *path, size_t path_length, const char *source, size_t source_length) OMNI_NOEXCEPT;
omni_status omni_vm_set_module_limit(omni_vm *vm, size_t limit) OMNI_NOEXCEPT;
bool omni_vm_module_matches(const omni_vm *vm, const char *path, size_t path_length, const char *source, size_t source_length) OMNI_NOEXCEPT;
typedef struct omni_module_change {
    const char *path;
    size_t path_length;
    const char *source;
    size_t source_length;
    bool remove;
} omni_module_change;

omni_status omni_vm_reload_components(omni_vm *vm, const uint8_t *widget_names, size_t names_length,
    const omni_module_change *changes, size_t change_count, uint64_t budget_ns, char *error, size_t error_capacity) OMNI_NOEXCEPT;
omni_status omni_vm_configure_components(omni_vm *vm, const uint8_t *value, size_t length, uint64_t budget_ns, char *error, size_t error_capacity) OMNI_NOEXCEPT;
typedef struct omni_capture_stats {
    uint64_t capture_id;
    uint64_t vm_bytes_begin;
    uint64_t vm_bytes;
    uint64_t tree_encodes;
    uint64_t input_handlers;
    uint64_t trigger_handlers;
    uint64_t service_handlers;
    uint64_t provider_handlers;
    uint64_t drop_handlers;
    uint64_t drag_handlers;
    uint64_t json_decodes;
    uint64_t json_decode_successes;
    uint64_t provider_topic_inputs;
    uint64_t provider_topic_decodes;
    uint64_t provider_topic_decode_successes;
    uint64_t provider_event_decodes;
    uint64_t provider_event_decode_successes;
    uint64_t provider_result_decodes;
    uint64_t provider_result_decode_successes;
    uint64_t reservations;
    uint64_t reservation_peak;
    uint64_t owner_reservation_peak;
    uint64_t http_reservations;
    uint64_t http_reservation_peak;
    uint64_t owner_rejections;
    uint64_t package_rejections;
    uint64_t http_rejections;
    uint64_t backlog_rejections;
    uint64_t id_rejections;
} omni_capture_stats;

bool omni_vm_capture_begin(omni_vm *vm, uint64_t capture_id, omni_capture_stats *out) OMNI_NOEXCEPT;
bool omni_vm_capture_snapshot(const omni_vm *vm, uint64_t capture_id, omni_capture_stats *out) OMNI_NOEXCEPT;
bool omni_vm_capture_end(omni_vm *vm, uint64_t capture_id, omni_capture_stats *out) OMNI_NOEXCEPT;

size_t omni_vm_bytes_in_use(const omni_vm *vm) OMNI_NOEXCEPT;
uint32_t omni_vm_string_count(const omni_vm *vm) OMNI_NOEXCEPT;
size_t omni_vm_string_bytes(const omni_vm *vm) OMNI_NOEXCEPT;
void omni_vm_reset_strings(omni_vm *vm) OMNI_NOEXCEPT;

omni_instance *omni_instance_create(omni_vm *vm) OMNI_NOEXCEPT;
void omni_instance_destroy(omni_instance *instance) OMNI_NOEXCEPT;
omni_status omni_instance_set_number(omni_instance *instance, const char *key, double value) OMNI_NOEXCEPT;
omni_status omni_instance_set_string(omni_instance *instance, const char *key, const char *value, size_t length) OMNI_NOEXCEPT;
omni_status omni_instance_set_value(omni_instance *instance, const char *key, const uint8_t *value, size_t length) OMNI_NOEXCEPT;
bool omni_instance_needs_render(omni_instance *instance, omni_view view, uint64_t changed) OMNI_NOEXCEPT;
omni_status omni_instance_render(omni_instance *instance, omni_view view, uint64_t budget_ns, omni_render_stats *stats, char *error, size_t error_capacity) OMNI_NOEXCEPT;
omni_status omni_instance_invoke(omni_instance *instance, omni_view view, uint32_t action, uint64_t source, const uint8_t *event, size_t event_length, uint64_t budget_ns, char *error, size_t error_capacity) OMNI_NOEXCEPT;
omni_status omni_instance_trigger(omni_instance *instance, const uint8_t *event, size_t event_length, uint64_t budget_ns, char *error, size_t error_capacity) OMNI_NOEXCEPT;
const uint8_t *omni_instance_output(const omni_instance *instance, omni_view view, size_t *size) OMNI_NOEXCEPT;
void omni_instance_discard_output(omni_instance *instance, omni_view view) OMNI_NOEXCEPT;
size_t omni_instance_message_count(const omni_instance *instance, omni_message_kind kind) OMNI_NOEXCEPT;
const char *omni_instance_message(const omni_instance *instance, omni_message_kind kind, size_t index, size_t *length) OMNI_NOEXCEPT;
void omni_instance_clear_messages(omni_instance *instance) OMNI_NOEXCEPT;

typedef struct omni_owner_token {
    uint64_t generation;
    uint32_t owner;
    uint32_t epoch;
} omni_owner_token;

bool omni_instance_action_owner(omni_instance *instance, omni_view view, uint32_t action, omni_owner_token *owner) OMNI_NOEXCEPT;

typedef enum omni_render_step_kind {
    OMNI_RENDER_IDLE = 0,
    OMNI_RENDER_ROOT = 1,
    OMNI_RENDER_COMPONENT_VIEW = 2,
    OMNI_RENDER_ACTIVITY = 3,
    OMNI_RENDER_ASSEMBLE = 4
} omni_render_step_kind;

typedef struct omni_render_step_stats {
    omni_render_step_kind kind;
    omni_status unit_status;
    omni_owner_token owner;
    uint64_t unit_id;
    uint32_t unit_epoch;
    uint64_t background_deps;
    bool done;
    omni_render_stats render;
} omni_render_step_stats;

omni_status omni_instance_begin_update(omni_instance *instance, omni_view view, uint64_t changed, bool visible) OMNI_NOEXCEPT;
omni_status omni_instance_step_update(omni_instance *instance, omni_view view, uint64_t budget_ns, omni_render_step_stats *stats, char *error, size_t error_capacity) OMNI_NOEXCEPT;
void omni_instance_cancel_update(omni_instance *instance, omni_view view) OMNI_NOEXCEPT;
uint64_t omni_instance_background_dependencies(const omni_instance *instance) OMNI_NOEXCEPT;

typedef enum omni_service_kind {
    OMNI_SERVICE_TIMER = 0,
    OMNI_SERVICE_STORE = 1,
    OMNI_SERVICE_CONFIG = 2,
    OMNI_SERVICE_HTTP = 3,
    OMNI_SERVICE_PROVIDER = 4,
    OMNI_SERVICE_DROP = 5,
    OMNI_SERVICE_DESKTOP = 6,
    OMNI_SERVICE_RESOURCE = 7,
    OMNI_SERVICE_DRAG = 8
} omni_service_kind;

typedef struct omni_resource_id {
    uint8_t bytes[16];
} omni_resource_id;

typedef struct omni_resource_descriptor {
    const char *name;
    size_t name_length;
    const char *kind;
    size_t kind_length;
    const char *uti;
    size_t uti_length;
} omni_resource_descriptor;

typedef struct omni_resource_token_descriptor {
    omni_resource_id token;
    omni_resource_descriptor descriptor;
} omni_resource_token_descriptor;

omni_status omni_vm_seed_resource_tokens(omni_vm *vm, const char *owner_name, size_t owner_name_length, const omni_resource_token_descriptor *tokens, size_t count, const char *load_error, size_t load_error_length, char *error, size_t error_capacity) OMNI_NOEXCEPT;
omni_status omni_vm_complete_resource(omni_vm *vm, omni_owner_token owner, uint64_t id, bool ok, uint64_t resource_revision, uint64_t size, bool has_size, const char *operation_error, size_t operation_error_length, uint64_t budget_ns, bool *handled, char *error, size_t error_capacity) OMNI_NOEXCEPT;

typedef enum omni_resource_state {
    OMNI_RESOURCE_PENDING = 0,
    OMNI_RESOURCE_READY = 1,
    OMNI_RESOURCE_FAILED = 2
} omni_resource_state;

typedef struct omni_resource_update {
    omni_resource_id id;
    uint64_t revision;
    omni_resource_state state;
    uint64_t size;
    bool has_size;
    const char *error;
    size_t error_length;
} omni_resource_update;

omni_status omni_vm_admit_resources(omni_vm *vm, omni_owner_token owner, const omni_resource_descriptor *descriptors, size_t count, omni_resource_id *ids, char *error, size_t error_capacity) OMNI_NOEXCEPT;
bool omni_vm_release_resources(omni_vm *vm, omni_owner_token owner, const omni_resource_id *ids, size_t count) OMNI_NOEXCEPT;
omni_status omni_vm_update_resources(omni_vm *vm, omni_owner_token owner, const omni_resource_update *updates, size_t count, bool *applied, char *error, size_t error_capacity) OMNI_NOEXCEPT;
size_t omni_vm_resource_count(const omni_vm *vm, omni_owner_token owner) OMNI_NOEXCEPT;
omni_status omni_instance_reserve_drop(omni_instance *instance, omni_view view, uint32_t action, uint64_t source, omni_owner_token *owner, uint64_t *id, char *error, size_t error_capacity) OMNI_NOEXCEPT;
omni_status omni_vm_deliver_drop(omni_vm *vm, omni_owner_token owner, uint64_t id, const omni_resource_id *resources, size_t count, double x, double y, uint64_t budget_ns, bool *handled, char *error, size_t error_capacity) OMNI_NOEXCEPT;
bool omni_vm_finish_drop(omni_vm *vm, omni_owner_token owner, uint64_t id) OMNI_NOEXCEPT;
omni_status omni_instance_reserve_drag(omni_instance *instance, omni_view view, uint32_t declaration, uint32_t action, uint64_t source, omni_owner_token *owner, uint64_t *id, omni_resource_id *resources, size_t capacity, size_t *count, char *error, size_t error_capacity) OMNI_NOEXCEPT;
omni_status omni_vm_begin_drag(omni_vm *vm, omni_owner_token owner, uint64_t id, uint64_t budget_ns, bool *handled, char *error, size_t error_capacity) OMNI_NOEXCEPT;
omni_status omni_vm_finish_drag(omni_vm *vm, omni_owner_token owner, uint64_t id, bool copied, bool deliver, uint64_t budget_ns, bool *handled, char *error, size_t error_capacity) OMNI_NOEXCEPT;
omni_status omni_instance_resolve_anchor(omni_instance *instance, omni_view view, omni_owner_token owner, omni_desktop_anchor anchor, omni_anchor_step *steps, size_t capacity, size_t *count, char *error, size_t error_capacity) OMNI_NOEXCEPT;
omni_status omni_vm_complete_desktop(omni_vm *vm, omni_owner_token owner, uint64_t id, const uint8_t *value, size_t value_length, const omni_resource_id *resources, size_t count, uint64_t budget_ns, bool *handled, bool *resources_transferred, char *error, size_t error_capacity) OMNI_NOEXCEPT;

typedef struct omni_service_request {
    omni_service_kind kind;
    omni_owner_token owner;
    uint64_t id;
    uint64_t revision;
    double seconds;
    bool cancelled;
    const char *owner_name;
    size_t owner_name_length;
    const uint8_t *value;
    size_t value_length;
    uint32_t display;
    omni_view view;
    uint64_t surface;
} omni_service_request;

typedef struct omni_service_stats {
    uint32_t reserved;
    uint32_t pending;
    uint32_t cancellations;
} omni_service_stats;

omni_status omni_vm_set_service_generation(omni_vm *vm, uint64_t generation) OMNI_NOEXCEPT;
omni_status omni_vm_set_configuration_enabled(omni_vm *vm, bool enabled) OMNI_NOEXCEPT;
omni_status omni_vm_seed_store(omni_vm *vm, const char *owner_name, size_t owner_name_length, const uint8_t *value, size_t value_length, const char *store_error, size_t store_error_length, char *error, size_t error_capacity) OMNI_NOEXCEPT;
bool omni_vm_next_service(omni_vm *vm, omni_service_request *out) OMNI_NOEXCEPT;
omni_status omni_vm_complete_service(omni_vm *vm, omni_owner_token owner, uint64_t id, uint64_t revision, const uint8_t *value, size_t value_length, uint64_t budget_ns, bool *handled, char *error, size_t error_capacity) OMNI_NOEXCEPT;
omni_status omni_vm_close_services(omni_vm *vm) OMNI_NOEXCEPT;
omni_service_stats omni_vm_service_stats(const omni_vm *vm) OMNI_NOEXCEPT;
size_t omni_vm_message_count(const omni_vm *vm, omni_message_kind kind) OMNI_NOEXCEPT;
const char *omni_vm_message(const omni_vm *vm, omni_message_kind kind, size_t index, size_t *length) OMNI_NOEXCEPT;
void omni_vm_clear_messages(omni_vm *vm) OMNI_NOEXCEPT;
bool omni_vm_message_origin(const omni_vm *vm, omni_message_kind kind, size_t index, omni_owner_token *owner, uint32_t *display_id) OMNI_NOEXCEPT;
uint32_t omni_instance_display_id(const omni_instance *instance) OMNI_NOEXCEPT;
#define OMNI_NO_DISPLAY UINT32_MAX

bool omni_vm_cancel_service(omni_vm *vm, omni_owner_token owner, uint64_t id) OMNI_NOEXCEPT;

typedef enum omni_provider_status {
    OMNI_PROVIDER_UNCHANGED = 0,
    OMNI_PROVIDER_STARTING = 1,
    OMNI_PROVIDER_RUNNING = 2,
    OMNI_PROVIDER_STOPPED = 3,
    OMNI_PROVIDER_EXITED = 4,
    OMNI_PROVIDER_FAILED = 5
} omni_provider_status;

typedef struct omni_provider_topic {
    const char *name;
    size_t name_length;
    const char *json;
    size_t json_length;
    bool removed;
} omni_provider_topic;

typedef struct omni_provider_snapshot {
    uint64_t incarnation;
    omni_provider_status status;
    const char *error;
    size_t error_length;
    int32_t exit_code;
    const omni_provider_topic *topics;
    size_t topic_count;
} omni_provider_snapshot;

omni_status omni_vm_complete_provider(omni_vm *vm, omni_owner_token owner, uint64_t id, bool ok,
    const char *json, size_t json_length, const omni_resource_id *resources, size_t resource_count,
    uint64_t budget_ns, bool *handled, bool *resources_transferred, char *error, size_t error_capacity) OMNI_NOEXCEPT;

bool omni_vm_component_owner(omni_vm *vm, const char *id, size_t id_length, omni_owner_token *owner) OMNI_NOEXCEPT;
omni_status omni_vm_provider_update(omni_vm *vm, omni_owner_token owner, const omni_provider_snapshot *snapshot,
    uint64_t budget_ns, bool *applied, char *error, size_t error_capacity) OMNI_NOEXCEPT;
omni_status omni_vm_provider_receive(omni_vm *vm, omni_owner_token owner, uint64_t incarnation,
    const char *name, size_t name_length, const char *json, size_t json_length,
    uint64_t budget_ns, bool *handled, char *error, size_t error_capacity) OMNI_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#endif
