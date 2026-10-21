"""Claude Code 2.1.304 human-control inventory (the producer's C4e predicate)."""
HUMAN_SUBTYPES = frozenset({'can_use_tool', 'request_user_dialog', 'elicitation'})
INTERNAL_AGENT_SUBTYPES = frozenset({'hook_callback', 'oauth_token_refresh', 'host_auth_token_refresh',
    'remote_tool_call', 'remote_plumbing_call', 'remote_tools_probe', 'remote_tools_reannounce',
    'remote_control_work_secret', 'ui_copy', 'ui_prompt_read', 'ui_prompt_fill', 'ui_prompt_suggest',
    'ui_read_selection', 'mcp_message'})


CLIENT_SUBTYPES = frozenset("""
apply_flag_settings background_tasks cancel_async_message claim_session export_conversation
file_suggestions get_binary_version get_chrome_browsers get_chrome_dialog get_context_usage
get_hooks_listing get_memory_dialog get_plan get_sandbox_dialog get_session_cost
get_settings get_skills_dialog get_status get_task_output get_usage
get_workspace_diff initialize interrupt list_directory list_models
list_permission_rules mcp_call mcp_read_resource mcp_reconnect mcp_set_servers
mcp_status mcp_toggle message_rated read_file register_device_hooks
register_repo_root reload_output_styles reload_plugins reload_skills remote_tools_announce
rename_session rewind_files seed_read_state select_chrome_browser set_chrome_browser_hints
set_color set_cwd set_max_thinking_tokens set_mcp_permission_mode_override set_model
set_permission_mode set_prompt_suggestions_paused stop_task submit_feedback turn_handoff
ui_attach ui_client_fault ui_client_module ui_client_press ui_close
ui_detach ui_focus ui_input ui_message ui_pane_focus
ui_pane_show ui_panes ui_press ui_prompt_autocomplete ui_prompt_edit
ui_render ui_scroll ui_select update_settings upload_device_hook_template
""".split())


def classify_request(frame):
    request = frame.get('request')
    if not isinstance(request, dict) or not isinstance(request.get('subtype'), str):
        return 'invalid'
    subtype = request['subtype']
    if subtype == 'can_use_tool':
        return ('human' if isinstance(request.get('tool_name'), str) and isinstance(request.get('input'), dict)
            and all(request.get(key) is None or isinstance(request[key], str) for key in ('agent_id', 'tool_use_id')) else 'invalid')
    if subtype == 'request_user_dialog':
        return 'human' if isinstance(request.get('dialog_kind'), str) else 'invalid'
    if subtype == 'elicitation':
        return ('human' if isinstance(request.get('mcp_server_name'), str) and isinstance(request.get('message'), str)
                and request.get('mode', 'form') in ('form', 'url') else 'invalid')
    if subtype in INTERNAL_AGENT_SUBTYPES or subtype in CLIENT_SUBTYPES:
        return 'internal'
    return 'unknown'
