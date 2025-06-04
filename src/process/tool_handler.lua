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
        -- We can do custom pre-filter or handling here
        if tool_call.valid then
            -- At this point we can add custom tool handler since we know both tool call and meta

            state:add_function_call(tool_call.name, tool_call.args, {
                call_id = call_id,
                message_id = tool_call.call_id,
                registry_id = tool_call.registry_id,
            })
            upstream:send_message_update(call_id, "function_call", { function_name = tool_call.name })
        end
    end

    local session_context, err = ctx_manager:get_full_context()
    if err then
        session_context = {} -- Fallback to empty context on error
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

        local meta = result_data.call.meta
        local tool_result = result_data.result

        -- Process the tool result to handle control directives and get a modified result
        local processed_result = tool_handler.process_tool_result(controller,
            tool_result,
            call_id,
            result_data.call.name,
            result_data.call.meta
        )

        -- Always store as json and always unpack as json
        state:update_function_result(call_id, processed_result, true)
        upstream:send_message_update(call_id, "function_success", {
            call_id = call_id,
            function_name = result_data.call.name
        })

        ::continue::
    end

    -- Enqueue continuation task for after tool call processing
    controller.task_queue:enqueue({ type = controller.TASK_TYPE.TOOL_CONTINUE, message_id = result.message_id })

    return true
end

-- Helper method to create a single artifact
function tool_handler.create_single_artifact(controller, artifact)
    -- Always generate a new UUID v7 for the artifact
    local artifact_id, err = uuid.v7()
    if err then
        return false, "Failed to generate artifact UUID: " .. err, nil
    end

    -- Special handling for view_ref artifacts
    if artifact.type == ARTIFACT_TYPES.VIEW_REF then
        -- Validate required fields
        if not artifact.page_id then
            return false, "Page ID is required for view_ref artifacts", nil
        end

        -- Prepare metadata with basic reference info
        local meta = {
            content_type = artifact.content_type or CONTENT_TYPES.HTML,
            description = artifact.description,
            icon = artifact.icon,
            status = artifact.status or ARTIFACT_STATUS.IDLE,
            page_id = artifact.page_id,
            display_type = artifact.display_type or "standalone"
        }

        -- Create JSON content with just params
        local content, json_err = json.encode(artifact.params or {})
        if json_err then
            return false, "Failed to encode parameters as JSON: " .. json_err, nil
        end

        -- Create the artifact with JSON content
        local created_artifact, err = artifact_repo.create(
            artifact_id,
            controller.state.session_id,
            ARTIFACT_TYPES.VIEW_REF,
            artifact.title or "Page Reference",
            content,
            meta
        )

        if err then
            return false, "Failed to create view_ref artifact in database: " .. err, nil
        end

        -- Return the created artifact with clear ID
        return true, nil, {
            artifact_id = artifact_id,
            kind = ARTIFACT_TYPES.VIEW_REF,
            title = artifact.title or "Page Reference"
        }
    end

    -- Standard artifact creation for other types
    local created_artifact, err = artifact_repo.create(
        artifact_id,
        controller.state.session_id,
        artifact.type or ARTIFACT_TYPES.INLINE,
        artifact.title or "Untitled Content",
        artifact.content,
        {
            content_type = artifact.content_type or CONTENT_TYPES.MARKDOWN,
            description = artifact.description,
            icon = artifact.icon,
            status = artifact.status or ARTIFACT_STATUS.IDLE,
            display_type = artifact.display_type or "inline"
        }
    )

    if err then
        return false, "Failed to create artifact in database: " .. err, nil
    end

    -- Return the created artifact with clear ID
    return true, nil, {
        artifact_id = artifact_id,
        kind = artifact.display_type or "inline",
        title = artifact.title or "Untitled Content"
    }
end

-- Helper method to update artifact metadata
function tool_handler.update_artifact_metadata(controller, artifact)
    if not artifact.id then
        return false, "Artifact ID is required for updates"
    end

    -- Extract metadata for update
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

    -- Update content if provided
    if artifact.content then
        updates.content = artifact.content
    end

    -- Update in the repository
    local result, err = artifact_repo.update(artifact.id, updates)
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
    local created_artifact_refs = {}

    -- Process each artifact
    for _, artifact in ipairs(artifacts) do
        -- Modified condition to handle view_ref artifacts that don't have content
        if (artifact.title and artifact.content) or (artifact.type == ARTIFACT_TYPES.VIEW_REF and artifact.title and artifact.page_id) then
            -- Create new artifact
            local artifact_success, artifact_err, created_artifact = tool_handler.create_single_artifact(controller, artifact)

            if not artifact_success then
                success = false
            else
                -- Store reference to created artifact for instructions
                if created_artifact and created_artifact.artifact_id then
                    table.insert(created_artifact_refs, created_artifact)

                    -- Record in session state
                    local message = "Artifact created: " .. created_artifact.title
                    state:add_system_message(message, {
                        system_action = "artifact_created",
                        artifact_metadata = {
                            artifact_id = created_artifact.artifact_id,
                            artifact_kind = created_artifact.kind,
                            artifact_title = created_artifact.title
                        }
                    })

                    -- Notify clients
                    upstream:update_session({
                        artifact_added = created_artifact.artifact_id
                    })

                    -- Log for debugging
                    controller:log_event("artifact_created", {
                        id = created_artifact.artifact_id,
                        type = created_artifact.kind,
                        title = created_artifact.title
                    })
                end
            end
        elseif artifact.id then
            -- Update existing artifact
            local update_success, update_err = tool_handler.update_artifact_metadata(controller, artifact)
            if not update_success then
                success = false
            end
        end
    end

    -- Return the created artifacts for instruction generation
    return success, created_artifact_refs
end

-- Process config directives from the control protocol
function tool_handler.process_control_config(controller, config)
    local success = true

    -- Handle model change
    if config.model then
        local model_success, model_err = controller:change_model(config.model)
        if not model_success then
            success = false
        end
    end

    -- Handle agent change
    if config.agent then
        local agent_success, agent_err = controller:change_agent(config.agent)
        if not agent_success then
            success = false
        end
    end

    return success
end

-- Process context directives from the control protocol
function tool_handler.process_control_context(controller, context)
    local state = controller.state
    local upstream = controller.upstream
    local ctx_manager = controller.ctx_manager

    local success = true

    local notify_update_public_meta = function (public_meta)
        local result = {}
        for id, data in pairs(public_meta) do
            result[id] = {id = data.id, title = data.title, url = data.url}
        end
        upstream:update_session({public_meta = result})
    end

    -- Handle public_meta operations
    if context.public_meta then
        if context.public_meta.clear and type(context.public_meta.clear) == "string" then
            -- Get current public_meta from state
            local current_meta = state.public_meta or {}

            -- Remove specified type
            local to_remove = {}
            for id, public_meta in pairs(current_meta) do
                if public_meta.type and public_meta.type == context.public_meta.clear then
                    table.insert(to_remove, id)
                end
            end
            for _, id in ipairs(to_remove) do
                current_meta[id] = nil
            end

            -- Update public_meta in state
            local meta_success, meta_err = state:update_session_config({
                public_meta = current_meta
            })

            if not meta_success then
                success = false
            else
                -- Notify clients about public_meta update
                notify_update_public_meta(current_meta)
            end
        end

        if context.public_meta.set and type(context.public_meta.set) == "table" then
            -- Get current public_meta from state
            local current_meta = state.public_meta or {}

            -- Convert array to map if needed
            if #context.public_meta.set > 0 then
                for _, item in ipairs(context.public_meta.set) do
                    if item.id then
                        current_meta[item.id] = item
                    end
                end
            else
                -- Handle direct map assignment
                for key, value in pairs(context.public_meta.set) do
                    current_meta[key] = value
                end
            end

            -- Update public_meta in state
            local meta_success, meta_err = state:update_session_config({
                public_meta = current_meta
            })

            if not meta_success then
                success = false
            else
                -- Notify clients about public_meta update
                notify_update_public_meta(current_meta)
            end
        end

        if context.public_meta.delete and type(context.public_meta.delete) == "table" then
            -- Get current public_meta from state
            local current_meta = state.public_meta or {}

            -- Remove specified items
            for _, id in ipairs(context.public_meta.delete) do
                current_meta[id] = nil
            end

            -- Update public_meta in state
            local meta_success, meta_err = state:update_session_config({
                public_meta = current_meta
            })

            if not meta_success then
                success = false
            else
                -- Notify clients about public_meta update
                notify_update_public_meta(current_meta)
            end
        end
    end

    -- Handle session context operations
    if context.session then
        local session_context_success = true

        -- Delete session context values
        if context.session.delete and type(context.session.delete) == "table" then
            for _, key in ipairs(context.session.delete) do
                local delete_success, delete_err = ctx_manager:delete_context(key)
                if not delete_success then
                    session_context_success = false
                end
            end
        end

        -- Set session context values
        if context.session.set and type(context.session.set) == "table" then
            for key, value in pairs(context.session.set) do
                local set_success, set_err = ctx_manager:write_context(key, value)
                if not set_success then
                    session_context_success = false
                end
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
        for _, mem in ipairs(memory.add) do
            if mem.type and mem.text then
                local memory_id, err = state:add_session_context(mem.type, mem.text)
                if not memory_id then
                    controller:log_event("memory_add_failed", {
                        type = mem.type,
                        error = err
                    })
                    success = false
                else
                    controller:log_event("memory_added", {
                        id = memory_id,
                        type = mem.type
                    })
                end
            end
        end
    end

    -- Handle memory deletion operations
    if memory.delete and type(memory.delete) == "table" then
        for _, mem_id in ipairs(memory.delete) do
            local deleted, err = state:delete_session_context(mem_id)
            if not deleted then
                controller:log_event("memory_delete_failed", {
                    id = mem_id,
                    error = err
                })
                success = false
            else
                controller:log_event("memory_deleted", {
                    id = mem_id
                })
            end
        end
    end

    return success
end

-- Process tool result and handle control directives
function tool_handler.process_tool_result(controller, tool_result, call_id, function_name, meta)
    if not tool_result or type(tool_result) ~= "table" then
        return tool_result
    end

    local success = true
    local agent_instructions = {}
    local created_artifacts = {}

    -- Process control directives
    if tool_result._control and type(tool_result._control) == "table" then
        local control = tool_result._control

        -- Process config changes
        if control.config and type(control.config) == "table" then
            success = success and tool_handler.process_control_config(controller, control.config)
        end

        -- Process context changes
        if control.context and type(control.context) == "table" then
            success = success and tool_handler.process_control_context(controller, control.context)
        end

        -- Process memory changes
        if control.memory and type(control.memory) == "table" then
            success = success and tool_handler.process_control_memory(controller, control.memory)
        end

        -- Process artifacts
        if control.artifacts and type(control.artifacts) == "table" then
            local artifacts_success, artifact_refs = tool_handler.process_control_artifacts(controller, control.artifacts)
            success = success and artifacts_success
            created_artifacts = artifact_refs or {}
        end
    end

    -- Generate instructions for displaying artifacts
    for _, artifact in ipairs(created_artifacts) do
        local instruction = string.format(
            'To display the "%s", insert this exact tag where you want it to appear: <artifact id="%s"/>. Do not wrap this tag in code blocks, quotes, or backticks.',
            artifact.title,
            artifact.artifact_id -- Using the exact same UUID from database
        )

        table.insert(agent_instructions, instruction)
    end

    -- Add agent instructions to the tool result
    if #agent_instructions > 0 then
        if type(tool_result.result) == "string" then
            tool_result.result = tool_result.result .. "\n\n" .. table.concat(agent_instructions, "\n")
        else
            tool_result.agent_instructions = table.concat(agent_instructions, "\n")
        end
    end

    -- Remove the _control field before returning
    tool_result._control = nil

    return tool_result
end

-- Legacy method for creating tool messages (kept for compatibility)
function tool_handler.create_tool_message(controller, message, artifacts, call_id, function_name)
    -- Implementation would depend on how tool messages are handled
    -- This is just a placeholder maintaining the same interface
    return true
end

-- Legacy method for applying context changes (kept for compatibility)
function tool_handler.apply_context_changes(controller, context)
    -- Redirect to the new context processing method for consistency
    return tool_handler.process_control_context(controller, { session = { set = context } })
end

return tool_handler