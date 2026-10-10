/* SPDX-License-Identifier: Apache-2.0 */
#include "paceman_service.h"
#include "paceman_face_layout.h"
#include "paceman_navigation.h"

#include "applib/app.h"
#include "applib/app_timer.h"
#include "applib/app_focus_service.h"
#include "applib/event_service_client.h"
#include "applib/graphics/text.h"
#include "applib/tick_timer_service.h"
#include "applib/ui/app_window_stack.h"
#include "applib/ui/ui.h"
#include "applib/ui/menu_layer.h"
#include "kernel/pbl_malloc.h"
#include "process_management/pebble_process_md.h"
#include "process_state/app_state/app_state.h"
#include "resource/resource_ids.auto.h"
#include <pbl/services/clock.h>
#include <stdio.h>

typedef struct {
  Window window;
  Layer canvas;
  MenuLayer sessions;
  PacemanSessionView session_view;
  GColor session_accent;
  bool session_current, session_reload;
  EventServiceInfo updates;
  bool expanded, handoff_open;
  AppTimer *handoff_timeout;
  PacemanNavigation navigation;
  AppTimer *expiry, *motion;
  uint32_t revision;
  uint8_t motion_frames;
} Face;

static void prv_text(GContext *ctx, const char *text, const char *font, GRect rect,
                     GTextAlignment alignment) {
  graphics_draw_text(ctx, text, fonts_get_system_font(font), rect,
                     GTextOverflowModeTrailingEllipsis, alignment, NULL);
}

static const char *prv_status(uint8_t state) {
  switch (state) {
    case OMARCHY_ACTIVITY_WORKING:
      return "Working";
    case OMARCHY_ACTIVITY_ATTENTION:
      return "Needs input";
    case OMARCHY_ACTIVITY_FINISHED:
      return "Finished";
    case OMARCHY_ACTIVITY_FAILED:
      return "Failed";
    default:
      return "No active agents";
  }
}

static void prv_expired(void *context) {
  Face *face = context;
  face->expiry = NULL;
  layer_mark_dirty(&face->canvas);
}

static void prv_schedule_expiry(Face *face, const PacemanView *view, uint32_t now) {
  if (face->expiry) {
    app_timer_cancel(face->expiry);
    face->expiry = NULL;
  }
  uint32_t next = UINT32_MAX;
  if (view->connected)
    for (size_t i = 0; i < view->source_count; ++i)
      if (view->sources[i].availability == PacemanSourceCurrent &&
          view->sources[i].expires_at > now && view->sources[i].expires_at < next)
        next = view->sources[i].expires_at;
  if (next != UINT32_MAX)
    face->expiry = app_timer_register((uint32_t)MIN((uint64_t)(next - now + 1) * 1000, UINT32_MAX),
                                      prv_expired, face);
}

static GColor prv_state_color(uint8_t state) {
  switch (state) {
    case OMARCHY_ACTIVITY_WORKING: return GColorDarkGreen;
    case OMARCHY_ACTIVITY_ATTENTION: return GColorWindsorTan;
    case OMARCHY_ACTIVITY_FINISHED: return GColorCobaltBlue;
    case OMARCHY_ACTIVITY_FAILED: return GColorRed;
    default: return GColorDarkGray;
  }
}

/* The Paceman mark, drawn at the watch's native resolution. */
static void prv_robot(GContext *ctx, GPoint origin, uint8_t state, GColor color) {
  const int x = origin.x, y = origin.y;
  graphics_context_set_fill_color(ctx, color);
  GRect head = GRect(x + 3, y + 7, 24, 19);
  graphics_fill_round_rect(ctx, &head, 6, GCornersAll);
  graphics_fill_circle(ctx, GPoint(x + 15, y + 2), 2);
  GRect antenna = GRect(x + 14, y + 3, 2, 6);
  graphics_fill_rect(ctx, &antenna);
  GRect ear = GRect(x, y + 14, 2, 5);
  graphics_fill_round_rect(ctx, &ear, 1, GCornersAll);
  ear.origin.x = x + 28;
  graphics_fill_round_rect(ctx, &ear, 1, GCornersAll);
  graphics_context_set_fill_color(ctx, GColorWhite);
  graphics_context_set_stroke_color(ctx, GColorWhite);
  graphics_context_set_stroke_width(ctx, 2);
  for (int i = 0; i < 2; ++i) {
    const int eye = x + 11 + 8 * i;
    if (state == OMARCHY_ACTIVITY_FINISHED) {
      graphics_draw_line(ctx, GPoint(eye - 3, y + 19), GPoint(eye - 2, y + 17));
      graphics_draw_line(ctx, GPoint(eye - 2, y + 17), GPoint(eye, y + 16));
      graphics_draw_line(ctx, GPoint(eye, y + 16), GPoint(eye + 2, y + 17));
      graphics_draw_line(ctx, GPoint(eye + 2, y + 17), GPoint(eye + 3, y + 19));
    } else if (state == OMARCHY_ACTIVITY_ATTENTION) {
      graphics_draw_line(ctx, GPoint(eye - 2, y + 19), GPoint(eye, y + 16));
      graphics_draw_line(ctx, GPoint(eye, y + 16), GPoint(eye + 2, y + 19));
    } else if (state == OMARCHY_ACTIVITY_FAILED) {
      graphics_draw_line(ctx, GPoint(eye - 2, y + 15), GPoint(eye + 2, y + 19));
      graphics_draw_line(ctx, GPoint(eye + 2, y + 15), GPoint(eye - 2, y + 19));
    } else {
      GRect slot = GRect(eye - 1, y + 14, 2, 5);
      graphics_fill_round_rect(ctx, &slot, 1, GCornersAll);
    }
  }
  graphics_context_set_stroke_width(ctx, 1);
}

static void prv_detail(const PacemanSource *source, char *text, size_t size) {
  const unsigned total = source->working + source->attention + source->finished + source->failed;
  const unsigned kinds = !!source->working + !!source->attention + !!source->finished + !!source->failed;
  if (kinds > 1) {
    const unsigned counts[] = {source->attention, source->failed, source->working, source->finished};
    const char *labels[] = {"needs input", "failed", "working", "finished"};
    unsigned first = 0, second = 1;
    while (!counts[first]) ++first;
    second = first + 1;
    while (!counts[second]) ++second;
    snprintf(text, size, "%u %s · %u %s", counts[first], labels[first], counts[second], labels[second]);
  } else if (total) {
    const char *provider = source->providers == 1 ? "Codex" : source->providers == 2 ? "Claude" : source->providers == 3 ? "Codex + Claude" : "Agents";
    snprintf(text, size, "%s · %u session%s", provider, total, total == 1 ? "" : "s");
  } else {
    snprintf(text, size, "%s", source->state == OMARCHY_ACTIVITY_NONE ? "No active sessions" : "");
  }
}

static void prv_card(GContext *ctx, GRect card, const PacemanView *view,
                     const PacemanSource *source, uint32_t now, GColor accent, bool selected) {
  const char *title = source ? source->name : "Agent activity";
  const uint8_t activity = source ? source->state : view->activity.state;
  const char *state = activity == OMARCHY_ACTIVITY_NONE ? "Idle" : prv_status(activity);
  char context[64] = "";
  const char *detail = context;
  bool current = source ? paceman_source_is_current(source, view->connected, now)
                        : view->received && view->connected;
  bool robot = view->received || source;
  if (current && source) prv_detail(source, context, sizeof(context));
  if (!current) detail = "Last known";
  if (source && source->availability == PacemanSourceEmpty) {
    state = "No activity yet";
    detail = view->connected ? "Waiting for activity" : "Waiting for iPhone";
    robot = false;
  } else if (view->sources_received && !view->source_count) {
    state = "No computers"; detail = "Add computer in Paceman"; robot = false;
  }
  if (!view->storage_ready) {
    title = "Watch setup"; state = "Setup unavailable"; detail = "Reset pairing required"; robot = false;
  } else if (!view->record.owned) {
    title = "Paceman"; state = "Connect iPhone"; detail = "Find watch in Paceman"; robot = false;
  } else if (!view->received && !view->sources_received) {
    state = "No activity yet"; detail = view->connected ? "Waiting for activity" : "Waiting for iPhone"; robot = false;
  }
  graphics_context_set_fill_color(ctx, GColorWhite);
  graphics_fill_round_rect(ctx, &card, 7, GCornersAll);
  graphics_context_set_stroke_color(ctx, selected ? accent : GColorLightGray);
  graphics_draw_round_rect(ctx, &card, 7);
  graphics_context_set_text_color(ctx, GColorBlack);
  prv_text(ctx, title, FONT_KEY_PACEMAN_DATE_14,
           GRect(card.origin.x + 9, card.origin.y + 3, card.size.w - (selected ? 32 : 18), 18), GTextAlignmentLeft);
  if (selected && source) {
    const int x = card.origin.x + card.size.w - 12, y = card.origin.y + 12;
    graphics_context_set_stroke_color(ctx, accent);
    graphics_draw_line(ctx, GPoint(x - 3, y - 3), GPoint(x, y));
    graphics_draw_line(ctx, GPoint(x, y), GPoint(x - 3, y + 3));
  }
  const GColor color = current ? prv_state_color(activity) : GColorDarkGray;
  Face *face = app_state_get_user_data();
  if (robot) prv_robot(ctx, GPoint(card.origin.x + 8,
      card.origin.y + 24 + (current ? face->motion_frames % 2 : 0)), activity, color);
  graphics_context_set_text_color(ctx, color);
  prv_text(ctx, state, FONT_KEY_PACEMAN_STATUS_21,
           GRect(card.origin.x + (robot ? 44 : 9), card.origin.y + 22,
                 card.size.w - (robot ? 53 : 18), 28), GTextAlignmentLeft);
  graphics_context_set_text_color(ctx, GColorDarkGray);
  prv_text(ctx, detail, FONT_KEY_PACEMAN_TEXT_13,
           GRect(card.origin.x + 9, card.origin.y + 51, card.size.w - 18, 19), GTextAlignmentLeft);
}

static uint16_t prv_session_count(MenuLayer *menu, uint16_t section, void *context) {
  Face *face = context;
  return face->session_view.source.session_count;
}

static int16_t prv_session_height(MenuLayer *menu, MenuIndex *index, void *context) {
  return 65;
}

static void prv_session_row(GContext *ctx, const Layer *cell, MenuIndex *index, void *context) {
  Face *face = context;
  const int width = cell->bounds.size.w, y = 2;
  const PacemanSession *session = &face->session_view.sessions[index->row];
  const char *provider = session->provider == 1 ? "Codex" : session->provider == 2 ? "Claude" : "Agent";
  const GRect card = GRect(10, y, width - 20, 61);
  graphics_context_set_fill_color(ctx, GColorWhite);
  graphics_fill_round_rect(ctx, &card, 7, GCornersAll);
  if (index->row == face->navigation.session_index) {
    graphics_context_set_stroke_color(ctx, face->session_accent);
    graphics_draw_round_rect(ctx, &card, 7);
  }
  const GColor color = face->session_current ? prv_state_color(session->state) : GColorDarkGray;
  prv_robot(ctx, GPoint(18, y + 14), session->state, color);
  graphics_context_set_text_color(ctx, face->session_current ? GColorBlack : GColorDarkGray);
  prv_text(ctx, provider, FONT_KEY_PACEMAN_DATE_14,
           GRect(56, y + 3, width - 75, 18), GTextAlignmentLeft);
  graphics_context_set_text_color(ctx, color);
  prv_text(ctx, prv_status(session->state), FONT_KEY_PACEMAN_TEXT_13,
           GRect(56, y + 23, width - 75, 18), GTextAlignmentLeft);
  graphics_context_set_text_color(ctx, GColorDarkGray);
  prv_text(ctx, session->workspace, FONT_KEY_PACEMAN_TEXT_13,
           GRect(56, y + 40, width - 75, 18), GTextAlignmentLeft);
}

static void prv_handoff_expired(void *context) {
  Face *face = context;
  face->handoff_timeout = NULL;
  layer_mark_dirty(&face->canvas);
}

static void prv_continue(Face *face) {
  if (!face->navigation.session_selected || face->handoff_open) return;
  face->handoff_open = true;
  paceman_service_continue_on_phone(face->navigation.source_id, face->navigation.session_id);
  face->handoff_timeout = app_timer_register(11000, prv_handoff_expired, face);
  layer_mark_dirty(&face->canvas);
}

static void prv_session_activate(MenuLayer *menu, MenuIndex *index, void *context) {
  prv_continue(context);
}

static void prv_session_selected(MenuLayer *menu, MenuIndex next, MenuIndex previous, void *context) {
  Face *face = context;
  if (next.row >= face->session_view.source.session_count) return;
  face->navigation.session_index = next.row;
  face->navigation.session_selected = true;
  memcpy(face->navigation.session_id, face->session_view.sessions[next.row].id, 16);
  layer_mark_dirty(&face->canvas);
}

static const MenuLayerCallbacks s_session_callbacks = {
  .get_num_rows = prv_session_count,
  .get_cell_height = prv_session_height,
  .draw_row = prv_session_row,
  .selection_changed = prv_session_selected,
  .select_click = prv_session_activate,
};

static void prv_sessions(GContext *ctx, Face *face, uint32_t now, GColor accent) {
  PacemanSessionView view;
  paceman_service_get_sessions(face->navigation.source_id, &view);
  if (!view.found) {
    layer_set_hidden(menu_layer_get_layer(&face->sessions), true);
    face->navigation.sessions_open = false;
    layer_mark_dirty(&face->canvas);
    return;
  }
  const PacemanSource *source = &view.source;
  const bool current = paceman_source_is_current(source, view.connected, now);
  const int width = face->canvas.bounds.size.w, height = face->canvas.bounds.size.h;
  graphics_context_set_text_color(ctx, GColorBlack);
  prv_text(ctx, source->name, FONT_KEY_PACEMAN_DATE_14,
           GRect(10, 5, width - 20, 20), GTextAlignmentLeft);
  char heading[48];
  const unsigned total = source->working + source->attention + source->finished + source->failed;
  paceman_navigation_sessions(&face->navigation, view.sessions, source->session_count);
  if (source->session_count)
    snprintf(heading, sizeof(heading), "%s · %u/%u", current ? "Sessions" : "Last known",
             face->navigation.session_index + 1, source->session_count);
  else
    snprintf(heading, sizeof(heading), "%s", current ?
             (source->state == OMARCHY_ACTIVITY_NONE ? "Sessions" : "Activity") : "Last known activity");
  if (source->availability == PacemanSourceEmpty) heading[0] = 0;
  graphics_context_set_text_color(ctx, GColorDarkGray);
  prv_text(ctx, heading, FONT_KEY_PACEMAN_TEXT_13,
           GRect(10, 25, width - 20, 19), GTextAlignmentLeft);
  if (!source->session_count) {
    layer_set_hidden(menu_layer_get_layer(&face->sessions), true);
    face->session_reload = true;
    const char *message = source->availability == PacemanSourceEmpty ? "No activity yet" :
                          source->state != OMARCHY_ACTIVITY_NONE ? prv_status(source->state) : "No active sessions";
    prv_text(ctx, message, FONT_KEY_PACEMAN_STATUS_21,
             GRect(10, 70, width - 20, 58), GTextAlignmentLeft);
    return;
  }
  const bool truncated = total > source->session_count;
  const GRect frame = GRect(0, 45, width, height - 45 - (truncated ? 23 : 0));
  const bool reload = face->session_reload ||
      memcmp(&view, &face->session_view, sizeof(view)) != 0;
  const uint8_t selected = face->navigation.session_index;
  face->session_view = view;
  face->session_accent = accent;
  face->session_current = current;
  layer_set_hidden(menu_layer_get_layer(&face->sessions), false);
  if (reload) {
    scroll_layer_set_frame(menu_layer_get_scroll_layer(&face->sessions), frame);
    menu_layer_reload_data(&face->sessions);
    menu_layer_set_selected_index(&face->sessions, (MenuIndex){.row = selected},
                                 MenuRowAlignCenter, false);
    face->session_reload = false;
  }
  layer_mark_dirty(menu_layer_get_layer(&face->sessions));
  if (truncated) {
    graphics_context_set_fill_color(ctx, GColorWhite);
    const GRect footer = GRect(0, height - 23, width, 23);
    graphics_fill_rect(ctx, &footer);
    graphics_context_set_text_color(ctx, GColorDarkGray);
    snprintf(heading, sizeof(heading), "Showing %u of %u sessions", source->session_count, total);
    prv_text(ctx, heading, FONT_KEY_PACEMAN_TEXT_13,
             GRect(10, height - 21, width - 20, 19), GTextAlignmentLeft);
  }
}

static void prv_draw(Layer *layer, GContext *ctx) {
  Face *face = app_state_get_user_data();
  PacemanView view;
  paceman_service_get_view(&view);
  const uint32_t now_seconds = rtc_get_time();
  prv_schedule_expiry(face, &view, now_seconds);
  paceman_navigation_sources(&face->navigation, view.sources, view.source_count,
                             face->expanded, view.connected, now_seconds);
  omarchy_profile_v3_t colors = {0};
  memcpy(&colors, view.record.profile, MIN(view.record.profile_size, sizeof(colors)));
  GColor accent = GColorWindsorTan;
  if (view.record.profile_size >= sizeof(omarchy_profile_v3_t)) {
    /* Darken the phone accent for legible clock text on the fixed light face. */
    const uint8_t *rgb = colors.accent_rgb;
    const unsigned peak = MAX(rgb[0], MAX(rgb[1], rgb[2]));
    const unsigned floor = MIN(rgb[0], MIN(rgb[1], rgb[2]));
    if (peak > 170 && peak > floor)
      accent = GColorFromRGB((rgb[0] - floor) * 170 / (peak - floor),
                            (rgb[1] - floor) * 170 / (peak - floor),
                            (rgb[2] - floor) * 170 / (peak - floor));
    else
      accent = peak == floor ? GColorDarkGray : GColorFromRGB(rgb[0], rgb[1], rgb[2]);
  }
  graphics_context_set_fill_color(ctx, GColorWhite);
  graphics_fill_rect(ctx, &layer->bounds);
  graphics_context_set_text_color(ctx, GColorBlack);
  const int width = layer->bounds.size.w;
  if (face->expanded && face->handoff_open) {
    layer_set_hidden(menu_layer_get_layer(&face->sessions), true);
    prv_text(ctx, "Continue on phone", FONT_KEY_PACEMAN_DATE_14,
             GRect(10, 8, width - 20, 22), GTextAlignmentLeft);
    const PacemanHandoffStatus status = paceman_service_handoff_status();
    const char *title = status == PacemanHandoffReady ? "Ready on phone" :
        status == PacemanHandoffNotification ? "Check your phone" :
        status == PacemanHandoffOpenPhone ? "Open Paceman" :
        status == PacemanHandoffUnavailable ? "Session unavailable" :
        status == PacemanHandoffSending ? "Sending…" : "Phone unavailable";
    const char *detail = status == PacemanHandoffReady ? "Continue in Paceman on your iPhone." :
        status == PacemanHandoffNotification ? "Tap the Paceman notification to continue." :
        status == PacemanHandoffOpenPhone ? "Your selection is ready in the iPhone app." :
        status == PacemanHandoffUnavailable ? "Check the latest activity on your phone." :
        status == PacemanHandoffSending ? "Keep your phone nearby." :
        "Open Paceman on your phone, then try again.";
    prv_text(ctx, title, FONT_KEY_PACEMAN_STATUS_21,
             GRect(10, 53, width - 20, 58), GTextAlignmentLeft);
    prv_text(ctx, detail, FONT_KEY_PACEMAN_DATE_14,
             GRect(10, 118, width - 20, 70), GTextAlignmentLeft);
    return;
  }
  if (face->expanded && face->navigation.sessions_open) {
    prv_sessions(ctx, face, now_seconds, accent);
    return;
  }
  layer_set_hidden(menu_layer_get_layer(&face->sessions), true);
  if (!face->expanded) {
    struct tm now;
    clock_get_time_tm(&now);
    char date[28], time[8];
    strftime(date, sizeof(date), "%a, %b %e", &now);
    strftime(time, sizeof(time), clock_is_24h_style() ? "%H:%M" : "%I:%M", &now);
    const char *digits = !clock_is_24h_style() && time[0] == '0' ? time + 1 : time;
    prv_text(ctx, date, FONT_KEY_PACEMAN_DATE_14, GRect(8, 25, width - 16, 19), GTextAlignmentCenter);
    graphics_context_set_text_color(ctx, accent);
    prv_text(ctx, digits, FONT_KEY_ROBOTO_BOLD_SUBSET_49, GRect(5, 45, width - 10, 59), GTextAlignmentCenter);
    GRect card = GRect(PACEMAN_FACE_CARD_MARGIN, PACEMAN_FACE_CARD_Y,
                      width - 2 * PACEMAN_FACE_CARD_MARGIN, PACEMAN_FACE_CARD_HEIGHT);
    graphics_context_set_stroke_color(ctx, GColorLightGray);
    for (int i = MIN(view.source_count, 3) - 1; i > 0; --i) {
      GRect behind = GRect(card.origin.x + 3 * i, card.origin.y + 4 * i, card.size.w - 6 * i, card.size.h);
      graphics_draw_round_rect(ctx, &behind, 7);
    }
    prv_card(ctx, card, &view, view.source_count ? &view.sources[face->navigation.source_index] : NULL,
             now_seconds, accent, false);
  } else {
    char heading[24];
    snprintf(heading, sizeof(heading), view.source_count > 1 ? "Computers · %u/%u" : "Computers",
             face->navigation.source_index + 1, view.source_count);
    prv_text(ctx, heading, FONT_KEY_PACEMAN_DATE_14, GRect(10, 6, width - 20, 20), GTextAlignmentLeft);
    /* Keep the face's card dimensions; scroll through the complete computer list. */
    const unsigned top = face->navigation.source_index ? face->navigation.source_index - 1 : 0;
    const unsigned count = MAX(1, view.source_count);
    for (unsigned i = top; i < count; ++i) {
      const int y = 35 + ((int)i - (int)top) * 85;
      if (y >= layer->bounds.size.h) break;
      prv_card(ctx, GRect(10, y, width - 20, 75), &view,
               view.source_count ? &view.sources[i] : NULL, now_seconds, accent, i == face->navigation.source_index);
    }
  }
}

static void prv_motion(void *context) {
  Face *face = context;
  face->motion = NULL;
  if (face->motion_frames) --face->motion_frames;
  layer_mark_dirty(&face->canvas);
  if (face->motion_frames) face->motion = app_timer_register(180, prv_motion, face);
}

static void prv_changed(PebbleEvent *event, void *context) {
  Face *face = context;
  PacemanView view;
  paceman_service_get_view(&view);
  if (!view.connected || view.activity.revision != face->revision) {
    if (face->motion) { app_timer_cancel(face->motion); face->motion = NULL; }
    face->motion_frames = 0;
  }
  if (view.connected && view.received && view.activity.revision > face->revision &&
      (view.activity.state == OMARCHY_ACTIVITY_WORKING ||
       (view.activity.flags & OMARCHY_ACTIVITY_ALERT))) {
    face->motion_frames = 4;
    face->motion = app_timer_register(180, prv_motion, face);
  }
  face->revision = view.activity.revision;
  layer_mark_dirty(&face->canvas);
}

static void prv_tick(struct tm *time, TimeUnits changed) {
  Face *face = app_state_get_user_data();
  layer_mark_dirty(&face->canvas);
}

static void prv_focus(bool focused) {
  if (focused)
    prv_tick(NULL, 0);
}

static void prv_navigate(ClickRecognizerRef recognizer, void *context) {
  Face *face = context;
  if (face->handoff_open) return;
  const int step = click_recognizer_get_button_id(recognizer) == BUTTON_ID_DOWN ? 1 : -1;
  if (face->navigation.sessions_open) {
    menu_layer_set_selected_next(&face->sessions, step < 0, MenuRowAlignCenter, true);
    return;
  }
  PacemanView view;
  paceman_service_get_view(&view);
  paceman_navigation_sources(&face->navigation, view.sources, view.source_count, true, view.connected, rtc_get_time());
  paceman_navigation_move_source(&face->navigation, view.sources, view.source_count, step);
  layer_mark_dirty(&face->canvas);
}

static void prv_select(ClickRecognizerRef recognizer, void *context) {
  Face *face = context;
  if (face->navigation.sessions_open) { prv_continue(face); return; }
  PacemanView view;
  paceman_service_get_view(&view);
  paceman_navigation_sources(&face->navigation, view.sources, view.source_count, true, view.connected, rtc_get_time());
  if (!view.source_count) return;
  face->navigation.sessions_open = true;
  face->session_reload = true;
  face->navigation.session_selected = false;
  face->navigation.session_index = 0;
  layer_mark_dirty(&face->canvas);
}

static void prv_back(ClickRecognizerRef recognizer, void *context) {
  Face *face = context;
  if (face->handoff_open) {
    face->handoff_open = false;
    if (face->handoff_timeout) { app_timer_cancel(face->handoff_timeout); face->handoff_timeout = NULL; }
    layer_mark_dirty(&face->canvas);
    return;
  }
  if (face->navigation.sessions_open) {
    face->navigation.sessions_open = false;
    layer_mark_dirty(&face->canvas);
  } else {
    app_window_stack_pop(true);
  }
}

static void prv_clicks(void *context) {
  window_single_repeating_click_subscribe(BUTTON_ID_UP, 150, prv_navigate);
  window_single_repeating_click_subscribe(BUTTON_ID_DOWN, 150, prv_navigate);
  window_single_click_subscribe(BUTTON_ID_SELECT, prv_select);
  window_single_click_subscribe(BUTTON_ID_BACK, prv_back);
}

static void prv_run(bool expanded) {
  Face *face = app_zalloc_check(sizeof(*face));
  face->expanded = expanded;
  PacemanView initial;
  paceman_service_get_view(&initial);
  face->revision = initial.activity.revision;
  app_state_set_user_data(face);
  window_init(&face->window, WINDOW_NAME("Paceman"));
  if (expanded)
    window_set_click_config_provider_with_context(&face->window, prv_clicks, face);
  layer_init(&face->canvas, &face->window.layer.bounds);
  layer_set_update_proc(&face->canvas, prv_draw);
  layer_add_child(window_get_root_layer(&face->window), &face->canvas);
  const GRect sessions_frame = GRect(0, 45, face->canvas.bounds.size.w,
                                   face->canvas.bounds.size.h - 45);
  menu_layer_init(&face->sessions, &sessions_frame);
  menu_layer_set_callbacks(&face->sessions, face, &s_session_callbacks);
  menu_layer_set_normal_colors(&face->sessions, GColorWhite, GColorBlack);
  menu_layer_set_highlight_colors(&face->sessions, GColorWhite, GColorBlack);
  menu_layer_pad_bottom_enable(&face->sessions, false);
  layer_set_hidden(menu_layer_get_layer(&face->sessions), true);
  layer_add_child(window_get_root_layer(&face->window), menu_layer_get_layer(&face->sessions));
  app_window_stack_push(&face->window, true);
  face->updates =
      (EventServiceInfo){.type = PEBBLE_PACEMAN_EVENT, .handler = prv_changed, .context = face};
  event_service_client_subscribe(&face->updates);
  tick_timer_service_subscribe(MINUTE_UNIT, prv_tick);
  app_focus_service_subscribe_handlers((AppFocusHandlers){.did_focus = prv_focus});
  app_event_loop();
  if (face->handoff_timeout) app_timer_cancel(face->handoff_timeout);
  if (face->motion)
    app_timer_cancel(face->motion);
  if (face->expiry)
    app_timer_cancel(face->expiry);
  app_focus_service_unsubscribe();
  tick_timer_service_unsubscribe();
  event_service_client_unsubscribe(&face->updates);
  menu_layer_deinit(&face->sessions);
  layer_deinit(&face->canvas);
  window_deinit(&face->window);
  app_free(face);
}

static void prv_face_main(void) {
  prv_run(false);
}
static void prv_viewer_main(void) {
  prv_run(true);
}

const PebbleProcessMd *paceman_face_get_app_info(void) {
  static const PebbleProcessMdSystem metadata = {
    .common =
        {.uuid =
             {0x7f, 0x51, 0, 0x10, 0x1b, 0x15, 0x4f, 0x0d, 0xb7, 0xa5, 0x4c, 0xf3, 0xa2, 0xc9, 0x8e,
              0xe1},
         .main_func = prv_face_main,
         .process_type = ProcessTypeWatchface},
    .icon_resource_id = RESOURCE_ID_MENU_ICON_TICTOC_WATCH,
    .name = "Paceman"
  };
  return (const PebbleProcessMd *)&metadata;
}

const PebbleProcessMd *paceman_viewer_get_app_info(void) {
  static const PebbleProcessMdSystem metadata = {
    .common =
        {.uuid =
             {0x7f, 0x51, 0, 0x11, 0x1b, 0x15, 0x4f, 0x0d, 0xb7, 0xa5, 0x4c, 0xf3, 0xa2, 0xc9, 0x8e,
              0xe1},
         .main_func = prv_viewer_main,
         .process_type = ProcessTypeApp,
         .visibility = ProcessVisibilityHidden},
    .icon_resource_id = RESOURCE_ID_MENU_ICON_TICTOC_WATCH,
    .name = "Agents"
  };
  return (const PebbleProcessMd *)&metadata;
}
