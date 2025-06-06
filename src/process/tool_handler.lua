local json = require("json")
local uuid = require("uuid")
local artifact_repo = require("artifact_repo")

-- Constants
local ARTIFACT_TYPES = {
    VIEW_REF = "view_ref",
    INLINE = "inline"
}

local CONTENT_TYPES = {
    HTML = "text/html",
    MARKDOWN = "text/markdown"
}

local ARTIFACT_STATUS = {
    IDLE = "idle"
}

-- Tool Handler module
local tool_handler = {}

-- Handle the execution and processing of tool calls
function tool_handler.handle_tool_calls(controller, result)
    local state = controller.state
    local upstream = controller.upstream
    local ctx_manager = controller.ctx_manager
    local tool_caller = controller.tool_caller

    -- Phase 1: Validate and pre-process tool calls
    local validated_tools, validate_err = tool_caller:validate(result.tool_calls)
    if validate_err then
        if not validated_tools then
            return false, "Tool validation failed: " .. validate_err
        end
    end

    -- Log tool calls to state and notify clients
    for call_id, tool_call in pairs(validated_tools) do
        if tool_call.valid then
            state:add_function_call(tool_call.name, tool_call.args, {
                call_id = call_id,
                message_id = tool_call.call_id,
                registry_id = tool_call.registry_id,
            })
            upstream:send_message_update(call_id, "function_call", {
                function_name = tool_call.name,
            })
        end
    end

    local session_context, err = ctx_manager:get_full_context()
    if err then
        session_context = {}
    end

    if state.context_data and state.context_data.previous_agent_name then
        session_context.previous_agent_name = state.context_data.previous_agent_name
    end

    -- Phase 2: Execute the validated tools
    local results = tool_caller:execute(session_context, validated_tools)

    -- Process results and handle control results
    for _, result_data in pairs(results) do
        local call_id = result_data.call.call_id
        if result_data.error then
            state:update_function_result(call_id, tostring(result_data.error), false)
            upstream:send_message_update(call_id, "function_error", {
                call_id = call_id,
                function_name = result_data.call.name,
                error = "Function execution failed"
            })
            goto continue
        end

        local tool_result_raw = result_data.result

        local processed_tool_result, control_operations_for_meta, created_artifacts_for_meta, agent_instructions_for_meta =
            tool_handler.process_tool_result(controller,
                tool_result_raw,
                call_id,
                result_data.call.name,
                result_data.call.meta
            )

        local additional_metadata = {}
        if control_operations_for_meta then
            additional_metadata.control_operations = control_operations_for_meta
        end
        if created_artifacts_for_meta and #created_artifacts_for_meta > 0 then
            additional_metadata.created_artifact_refs = created_artifacts_for_meta
        end
        if agent_instructions_for_meta and agent_instructions_for_meta ~= "" then
            additional_metadata.agent_instructions = agent_instructions_for_meta
        end


        state:update_function_result(call_id, processed_tool_result, true, additional_metadata)
        upstream:send_message_update(call_id, "function_success", {
            call_id = call_id,
            function_name = result_data.call.name
        })

        ::continue::
    end

    controller.task_queue:enqueue({ type = controller.TASK_TYPE.TOOL_CONTINUE, message_id = result.message_id })
    return true
end

-- Helper method to create a single artifact
function tool_handler.create_single_artifact(controller, artifact)
    local artifact_id, err = uuid.v7()
    if err then
        return false, "Failed to generate artifact UUID: " .. err, nil
    end

    local artifact_body_for_ref -- This will hold the content/params for the ref

    if artifact.type == ARTIFACT_TYPES.VIEW_REF then
        if not artifact.page_id then
            return false, "Page ID is required for view_ref artifacts", nil
        end
        local meta = {
            content_type = artifact.content_type or CONTENT_TYPES.HTML,
            description = artifact.description,
            icon = artifact.icon,
            status = artifact.status or ARTIFACT_STATUS.IDLE,
            page_id = artifact.page_id,
            display_type = artifact.display_type or "standalone"
        }
        local content_for_db, json_err = json.encode(artifact.params or {})
        if json_err then
            return false, "Failed to encode parameters as JSON: " .. json_err, nil
        end
        artifact_body_for_ref = artifact.params or {} -- Store the Lua table for the ref

        local _, create_err = artifact_repo.create(
            artifact_id,
            controller.state.session_id,
            ARTIFACT_TYPES.VIEW_REF,
            artifact.title or "Page Reference",
            content_for_db,
            meta
        )
        if create_err then
            return false, "Failed to create view_ref artifact in database: " .. create_err, nil
        end
        return true, nil, {
            artifact_id = artifact_id,
            kind = ARTIFACT_TYPES.VIEW_REF,
            title = artifact.title or "Page Reference",
            body = artifact_body_for_ref
        }
    else                                         -- Inline or other types
        artifact_body_for_ref = artifact.content -- Store the actual content for the ref
        local _, create_err = artifact_repo.create(
            artifact_id,
            controller.state.session_id,
            artifact.type or ARTIFACT_TYPES.INLINE,
            artifact.title or "Untitled Content",
            artifact.content, -- Store the actual content in DB
            {
                content_type = artifact.content_type or CONTENT_TYPES.MARKDOWN,
                description = artifact.description,
                icon = artifact.icon,
                status = artifact.status or ARTIFACT_STATUS.IDLE,
                display_type = artifact.display_type or "inline"
            }
        )
        if create_err then
            return false, "Failed to create artifact in database: " .. create_err, nil
        end
        return true, nil, {
            artifact_id = artifact_id,
            kind = artifact.display_type or "inline",
            title = artifact.title or "Untitled Content",
            body = artifact_body_for_ref
        }
    end
end

-- Helper method to update artifact metadata
function tool_handler.update_artifact_metadata(controller, artifact)
    if not artifact.id then
        return false, "Artifact ID is required for updates"
    end
    local updates = {
        title = artifact.title,
        kind = artifact.type,
        meta = {
            content_type = artifact.content_type,
            description = artifact.description,
            icon = artifact.icon,
            status = artifact.status
        }
    }
    if artifact.content then
        updates.content = artifact.content
    end
    local _, err = artifact_repo.update(artifact.id, updates)
    if err then
        return false, "Failed to update artifact in database: " .. err
    end
    return true
end

-- Process artifacts directives from the control protocol
function tool_handler.process_control_artifacts(controller, artifacts)
    local success = true
    local state = controller.state
    local upstream = controller.upstream
    local created_artifact_refs_list = {}

    for _, artifact_data in ipairs(artifacts) do
        if (artifact_data.title and artifact_data.content) or (artifact_data.type == ARTIFACT_TYPES.VIEW_REF and artifact_data.title and artifact_data.page_id) then
            local artifact_success, artifact_err, created_artifact_ref = tool_handler.create_single_artifact(controller,
                artifact_data)
            if not artifact_success then
                success = false
            else
                if created_artifact_ref and created_artifact_ref.artifact_id then
                    table.insert(created_artifact_refs_list, created_artifact_ref)
                    local message = "Artifact created: " .. created_artifact_ref.title
                    state:add_system_message(message, {
                        system_action = "artifact_created",
                        artifact_metadata = {
                            artifact_id = created_artifact_ref.artifact_id,
                            artifact_kind = created_artifact_ref.kind,
                            artifact_title = created_artifact_ref.title
                        }
                    })
                    upstream:update_session({
                        artifact_added = created_artifact_ref.artifact_id
                    })
                    controller:log_event("artifact_created", {
                        id = created_artifact_ref.artifact_id,
                        type = created_artifact_ref.kind,
                        title = created_artifact_ref.title
                    })
                end
            end
        elseif artifact_data.id then
            local update_success, _ = tool_handler.update_artifact_metadata(controller, artifact_data)
            if not update_success then
                success = false
            end
        end
    end
    return success, created_artifact_refs_list
end

-- Process config directives from the control protocol
function tool_handler.process_control_config(controller, config)
    local success = true
    if config.model then
        local model_success, _ = controller:change_model(config.model)
        if not model_success then success = false end
    end
    if config.agent then
        local agent_success, _ = controller:change_agent(config.agent)
        if not agent_success then success = false end
    end
    return success
end

-- Process context directives from the control protocol
function tool_handler.process_control_context(controller, context)
    local state = controller.state
    local upstream = controller.upstream
    local ctx_manager = controller.ctx_manager
    local success = true

    local notify_update_public_meta = function(public_meta)
        local result = {}
        for id, data in pairs(public_meta) do
            result[id] = { id = data.id, title = data.title, url = data.url }
        end
        upstream:update_session({ public_meta = result })
    end

    if context.public_meta then
        local current_meta = state.public_meta or {}
        local changed_public_meta = false

        if context.public_meta.clear and type(context.public_meta.clear) == "string" then
            local to_remove = {}
            for id, public_meta_item in pairs(current_meta) do
                if public_meta_item.type and public_meta_item.type == context.public_meta.clear then
                    table.insert(to_remove, id)
                end
            end
            for _, id in ipairs(to_remove) do
                current_meta[id] = nil
                changed_public_meta = true
            end
        end

        if context.public_meta.set and type(context.public_meta.set) == "table" then
            if #context.public_meta.set > 0 then -- Array of items
                for _, item in ipairs(context.public_meta.set) do
                    if item.id then
                        current_meta[item.id] = item
                        changed_public_meta = true
                    end
                end
            else -- Map of items
                for key, value in pairs(context.public_meta.set) do
                    current_meta[key] = value
                    changed_public_meta = true
                end
            end
        end

        if context.public_meta.delete and type(context.public_meta.delete) == "table" then
            for _, id in ipairs(context.public_meta.delete) do
                if current_meta[id] then
                    current_meta[id] = nil
                    changed_public_meta = true
                end
            end
        end

        if changed_public_meta then
            local meta_success, _ = state:update_session_config({ public_meta = current_meta })
            if not meta_success then
                success = false
            else
                notify_update_public_meta(current_meta)
            end
        end
    end

    if context.session then
        local session_context_success = true

        -- Set session context values
        if context.session.set and type(context.session.set) == "table" then
            for key, value in pairs(context.session.set) do
                local set_success, set_err = ctx_manager:write_context(key, value)
                if not set_success then
                    session_context_success = false
                end
            end
        end

        -- Delete session context values
        if context.session.delete and type(context.session.delete) == "table" then
            for _, key in ipairs(context.session.delete) do
                local delete_success, _ = ctx_manager:delete_context(key)
                if not delete_success then session_context_success = false end
            end
        end

        success = success and session_context_success
    end
    return success
end

-- Process memory directives from the control protocol
function tool_handler.process_control_memory(controller, memory)
    local state = controller.state
    local success = true

    -- Handle memory operations
    if memory.clear then
        local clear_keys = {}
        if type(memory.clear) == "string" then
            clear_keys = { memory.clear }
        elseif type(memory.clear) == "table" then
            clear_keys = memory.clear
        end
        -- Clear all memories of a specific type
        local contexts = state:load_session_contexts()
        if contexts then
            for _, context in ipairs(contexts) do
                for _, clear_key in ipairs(clear_keys) do
                    if context.type == clear_key then
                        state:delete_session_context(context.id)
                    end
                end
            end
        end
    end

    if memory.add and type(memory.add) == "table" then
        for _, mem_item in ipairs(memory.add) do
            if mem_item.type and mem_item.text then
                local memory_id, err = state:add_session_context(mem_item.type, mem_item.text)
                if not memory_id then
                    controller:log_event("memory_add_failed", { type = mem_item.type, error = err })
                    success = false
                else
                    controller:log_event("memory_added", { id = memory_id, type = mem_item.type })
                end
            end
        end
    end

    if memory.delete and type(memory.delete) == "table" then
        for _, mem_id in ipairs(memory.delete) do
            local deleted, err = state:delete_session_context(mem_id)
            if not deleted then
                controller:log_event("memory_delete_failed", { id = mem_id, error = err })
                success = false
            else
                controller:log_event("memory_deleted", { id = mem_id })
            end
        end
    end
    return success
end

-- Process tool result, handle control directives, and extract data for metadata.
-- Returns: processed_tool_result, original_control_data, created_artifact_refs_list, agent_instructions_string
function tool_handler.process_tool_result(controller, tool_result, call_id, function_name, meta)
    if not tool_result or type(tool_result) ~= "table" then
        return tool_result, nil, nil, nil
    end

    local success = true
    local agent_instructions_list = {}
    local created_artifact_refs_list = {}
    local original_control_data = nil

    if tool_result._control and type(tool_result._control) == "table" then
        original_control_data = json.decode(json.encode(tool_result._control))
        local control = tool_result._control

        if control.config and type(control.config) == "table" then
            success = success and tool_handler.process_control_config(controller, control.config)
        end
        if control.context and type(control.context) == "table" then
            success = success and tool_handler.process_control_context(controller, control.context)
        end
        if control.memory and type(control.memory) == "table" then
            success = success and tool_handler.process_control_memory(controller, control.memory)
        end
        if control.artifacts and type(control.artifacts) == "table" then
            local artifacts_success, processed_artifact_refs = tool_handler.process_control_artifacts(controller,
                control.artifacts)
            success = success and artifacts_success
            created_artifact_refs_list = processed_artifact_refs or {}
        end
    end

    for _, artifact_ref in ipairs(created_artifact_refs_list) do
        local body_str = ""
        if artifact_ref.body then
            if type(artifact_ref.body) == "table" then
                local ok, encoded_body = pcall(json.encode, artifact_ref.body)
                if ok then
                    body_str = encoded_body
                else
                    body_str = "[Could not serialize artifact body/params]"
                end
            elseif type(artifact_ref.body) == "string" then
                body_str = artifact_ref.body
                -- Truncate if too long for an instruction
                if #body_str > 200 then -- Arbitrary limit
                    body_str = string.sub(body_str, 1, 197) .. "..."
                end
            else
                body_str = tostring(artifact_ref.body)
            end
        end

        local instruction = string.format(
            'To display the "%s" artifact, insert this exact tag where you want it to appear: <artifact id="%s"/>. Do not wrap this tag in code blocks, quotes, or backticks. The artifact contains the following content or parameters: %s',
            artifact_ref.title or "Untitled",
            artifact_ref.artifact_id,
            body_str
        )
        table.insert(agent_instructions_list, instruction)
    end

    local final_agent_instructions_str = nil
    if #agent_instructions_list > 0 then
        final_agent_instructions_str = table.concat(agent_instructions_list, "\n")
        if type(tool_result.result) == "string" then
            tool_result.result = tool_result.result .. "\n\n" .. final_agent_instructions_str
        elseif type(tool_result.result) == "table" then
            tool_result.result.agent_instructions = final_agent_instructions_str
        else
            tool_result.agent_instructions = final_agent_instructions_str
        end
    end

    if tool_result then
        tool_result._control = nil
    end

    return tool_result, original_control_data, created_artifact_refs_list, final_agent_instructions_str
end

return tool_handler
