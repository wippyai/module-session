local json = require("json")
local uuid = require("uuid")
local consts = require("consts")

type ArtifactData = {
    id: string?,
    title: string?,
    content: string?,
    content_type: string?,
    description: string?,
    icon: string?,
    status: string?,
    type: string?,
    page_id: string?,
    params: {[string]: any}?,
    display_type: string?,
    preview: string?,
    instructions: boolean?,
}

local control_handlers = {}

function control_handlers.handle_context_command(ctx, op)
    if not op.action then
        return nil, consts.ERR.CONTEXT_ACTION_REQUIRED
    end

    if op.action == consts.CONTEXT_ACTIONS.WRITE then
        return control_handlers.context_write(ctx, op)
    elseif op.action == consts.CONTEXT_ACTIONS.DELETE then
        return control_handlers.context_delete(ctx, op)
    else
        return nil, consts.ERR.INVALID_CONTEXT_ACTION
    end
end

function control_handlers.context_write(ctx, op)
    if not op.key then
        return nil, consts.ERR.CONTEXT_KEY_REQUIRED
    end

    local success, err = ctx.writer:set_context(op.key, op.data)
    if not success then
        return nil, consts.ERR.CONTEXT_UPDATE_FAILED .. ": " .. (err or "unknown error")
    end

    ctx.reader:reset()

    local context_data, get_err = ctx.reader:get_full_context()
    if get_err then
        context_data = {}
    end

    if op.from_pid and process and process.send then
        process.send(op.from_pid, consts.CONTEXT_COMMANDS.COMMAND_SUCCESS, {
            action = consts.CONTEXT_ACTIONS.WRITE,
            key = op.key,
            context = context_data
        })
    end

    return {
        completed = true,
        action = consts.CONTEXT_ACTIONS.WRITE,
        key = op.key,
        context = context_data
    }
end

function control_handlers.context_delete(ctx, op)
    if not op.key then
        return nil, consts.ERR.CONTEXT_KEY_REQUIRED
    end

    local success, err = ctx.writer:delete_context(op.key)
    if not success then
        return nil, consts.ERR.CONTEXT_UPDATE_FAILED .. ": " .. (err or "unknown error")
    end

    ctx.reader:reset()

    local context_data, get_err = ctx.reader:get_full_context()
    if get_err then
        context_data = {}
    end

    if op.from_pid and process and process.send then
        process.send(op.from_pid, consts.CONTEXT_COMMANDS.COMMAND_SUCCESS, {
            action = consts.CONTEXT_ACTIONS.DELETE,
            key = op.key,
            context = context_data
        })
    end

    return {
        completed = true,
        action = consts.CONTEXT_ACTIONS.DELETE,
        key = op.key,
        context = context_data
    }
end

function control_handlers.control_artifacts(ctx, op)
    if not op.artifacts or #op.artifacts == 0 then
        return nil, "No artifacts provided"
    end

    local created_artifacts = {}
    local instructions = {}

    for _, artifact_data in ipairs(op.artifacts) do
        if artifact_data.title and (artifact_data.content or artifact_data.page_id) then
            local artifact_id, err = uuid.v7()
            if err then
                return nil, "Failed to generate artifact ID: " .. err
            end

            if artifact_data.type == consts.ARTIFACT_TYPES.VIEW_REF then
                if not artifact_data.page_id then
                    return nil, "Page ID is required for view_ref artifacts"
                end

                local content_for_db = "{}"
                if artifact_data.params then
                    local encoded, encode_err = json.encode(artifact_data.params)
                    if encode_err then
                        return nil, "Failed to encode artifact params: " .. encode_err
                    end
                    content_for_db = encoded
                end

                local success, create_err = ctx.writer:create_artifact(
                    artifact_id,
                    consts.ARTIFACT_TYPES.VIEW_REF,
                    artifact_data.title,
                    content_for_db,
                    {
                        content_type = artifact_data.content_type or consts.CONTENT_TYPES.HTML,
                        description = artifact_data.description,
                        icon = artifact_data.icon,
                        status = artifact_data.status or consts.ARTIFACT_STATUS.IDLE,
                        page_id = artifact_data.page_id,
                        display_type = artifact_data.display_type or consts.ARTIFACT_DISPLAY.STANDALONE
                    }
                )

                if success then
                    table.insert(created_artifacts, {
                        artifact_id = artifact_id,
                        title = artifact_data.title,
                        kind = consts.ARTIFACT_TYPES.VIEW_REF
                    })

                    if artifact_data.instructions ~= false then
                        local instruction_text
                        if artifact_data.preview and artifact_data.preview ~= "" then
                            instruction_text = string.format(
                                consts.ARTIFACT_INSTRUCTIONS.VIEW_REF_TEMPLATE,
                                artifact_data.title,
                                artifact_id,
                                artifact_data.preview
                            )
                        else
                            instruction_text = string.format(
                                consts.ARTIFACT_INSTRUCTIONS.REFERENCE_TEMPLATE,
                                artifact_data.title,
                                artifact_id
                            )
                        end
                        table.insert(instructions, instruction_text)
                    end
                end
            else
                local success, create_err = ctx.writer:create_artifact(
                    artifact_id,
                    artifact_data.type or consts.ARTIFACT_TYPES.INLINE,
                    artifact_data.title,
                    artifact_data.content or "",
                    {
                        content_type = artifact_data.content_type or consts.CONTENT_TYPES.MARKDOWN,
                        description = artifact_data.description,
                        icon = artifact_data.icon,
                        status = artifact_data.status or consts.ARTIFACT_STATUS.IDLE,
                        display_type = artifact_data.display_type or consts.ARTIFACT_DISPLAY.INLINE
                    }
                )

                if success then
                    table.insert(created_artifacts, {
                        artifact_id = artifact_id,
                        title = artifact_data.title,
                        kind = artifact_data.type or consts.ARTIFACT_TYPES.INLINE
                    })

                    if artifact_data.instructions ~= false then
                        local instruction_text
                        if artifact_data.preview and artifact_data.preview ~= "" then
                            instruction_text = string.format(
                                consts.ARTIFACT_INSTRUCTIONS.WITH_PREVIEW_TEMPLATE,
                                artifact_data.title,
                                artifact_id,
                                artifact_data.preview
                            )
                        else
                            instruction_text = string.format(
                                consts.ARTIFACT_INSTRUCTIONS.REFERENCE_TEMPLATE,
                                artifact_data.title,
                                artifact_id
                            )
                        end
                        table.insert(instructions, instruction_text)
                    end
                end
            end

            if #created_artifacts > 0 then
                ctx.writer:add_message(consts.MSG_TYPE.SYSTEM, "Artifact created: " .. artifact_data.title, {
                    system_action = consts.SYSTEM_ACTIONS.ARTIFACT_CREATED,
                    artifact_id = artifact_id
                })

                ctx.upstream:update_session({
                    artifact_added = artifact_id
                })
            end
        elseif artifact_data.id then
            local updates = {
                title = artifact_data.title,
                content = artifact_data.content,
                meta = {
                    content_type = artifact_data.content_type,
                    description = artifact_data.description,
                    icon = artifact_data.icon,
                    status = artifact_data.status
                }
            }

            local success, update_err = ctx.writer:update_artifact(artifact_data.id, updates)
        end
    end

    if #instructions > 0 then
        local instruction_text = table.concat(instructions, "\n\n")
        ctx.writer:add_message(consts.MSG_TYPE.DEVELOPER, instruction_text, {
            system_action = "artifact_instructions",
            created_artifacts = created_artifacts
        })
    end

    return {
        completed = true,
        created_artifacts = created_artifacts
    }
end

function control_handlers.control_context(ctx, op)
    if not op.context_operations then
        return nil, "No context operations provided"
    end

    local success = true

    if op.context_operations.public_meta then
        local session_data = ctx.reader:state()
        local current_meta = session_data.public_meta or {}
        local changed_public_meta = false

        if op.context_operations.public_meta.clear and type(op.context_operations.public_meta.clear) == "string" then
            local to_remove = {}
            for id, public_meta_item in pairs(current_meta) do
                if public_meta_item.type and public_meta_item.type == op.context_operations.public_meta.clear then
                    table.insert(to_remove, id)
                end
            end
            for _, id in ipairs(to_remove) do
                current_meta[id] = nil
                changed_public_meta = true
            end
        end

        if op.context_operations.public_meta.set and type(op.context_operations.public_meta.set) == "table" then
            for key, value in pairs(op.context_operations.public_meta.set) do
                current_meta[key] = value
                changed_public_meta = true
            end
        end

        if op.context_operations.public_meta.delete and type(op.context_operations.public_meta.delete) == "table" then
            for _, id in ipairs(op.context_operations.public_meta.delete) do
                if current_meta[id] then
                    current_meta[id] = nil
                    changed_public_meta = true
                end
            end
        end

        if changed_public_meta then
            local update_success, update_err = ctx.writer:update_meta({ public_meta = current_meta })
            if not update_success then
                success = false
            else
                local result = {}
                for id, data in pairs(current_meta) do
                    table.insert(result, {
                        id = data.id or id,
                        title = data.title,
                        url = data.url,
                        display_name = data.display_name
                    })
                end
                ctx.upstream:update_session({ public_meta = result })
            end
        end
    end

    if op.context_operations.session then
        if op.context_operations.session.set and type(op.context_operations.session.set) == "table" then
            for key, value in pairs(op.context_operations.session.set) do
                local set_success, set_err = ctx.writer:set_context(key, value)
                if not set_success then
                    success = false
                end
            end
        end

        if op.context_operations.session.delete and type(op.context_operations.session.delete) == "table" then
            for _, key in ipairs(op.context_operations.session.delete) do
                local delete_success, delete_err = ctx.writer:delete_context(key)
                if not delete_success then
                    success = false
                end
            end
        end
    end

    if not success then
        return nil, "Failed to process some context operations"
    end

    ctx.reader:reset()

    return { completed = true }
end

function control_handlers.control_memory(ctx, op)
    if not op.memory_operations then
        return nil, "No memory operations provided"
    end

    local success = true

    if op.memory_operations.clear then
        local clear_keys = {}
        if type(op.memory_operations.clear) == "string" then
            clear_keys = { op.memory_operations.clear }
        elseif type(op.memory_operations.clear) == "table" then
            clear_keys = op.memory_operations.clear
        end

        local contexts, err = ctx.reader:contexts():all()
        if err then
            success = false
        else
            for _, context in ipairs(contexts) do
                for _, clear_key in ipairs(clear_keys) do
                    if context.type == clear_key then
                        local delete_success, delete_err = ctx.writer:delete_session_context(context.id)
                        if not delete_success then
                            success = false
                        end
                    end
                end
            end
        end
    end

    if op.memory_operations.add and type(op.memory_operations.add) == "table" then
        for _, mem_item in ipairs(op.memory_operations.add) do
            if mem_item.type and mem_item.text then
                local memory_id, err = ctx.writer:add_session_context(mem_item.type, mem_item.text)
                if not memory_id then
                    success = false
                end
            end
        end
    end

    if op.memory_operations.delete and type(op.memory_operations.delete) == "table" then
        for _, mem_id in ipairs(op.memory_operations.delete) do
            local deleted, err = ctx.writer:delete_session_context(mem_id)
            if not deleted then
                success = false
            end
        end
    end

    if not success then
        return nil, "Failed to process some memory operations"
    end

    return { completed = true }
end

function control_handlers.control_config(ctx, op)
    if not op.config_changes then
        return nil, "No config changes provided"
    end

    local session_data = ctx.reader:state()
    local current_config = session_data.config or {}
    local config_changed = false
    local agent_changed = false
    local model_changed = false
    local previous_agent = current_config.agent_id
    local previous_model = current_config.model

    if op.config_changes.agent then
        current_config.agent_id = op.config_changes.agent
        config_changed = true
        agent_changed = true
    end

    if op.config_changes.model then
        current_config.model = op.config_changes.model
        config_changed = true
        model_changed = true
    end

    if config_changed then
        ctx.reader:reset()

        if agent_changed and not model_changed then
            -- Agent changed but no explicit model - use new agent's default model
            local switch_success, switch_err = ctx.agent_ctx:switch_to_agent(current_config.agent_id)

            if switch_success then
                -- Get the new agent's default model and update config
                local new_model = ctx.agent_ctx.current_model
                current_config.model = new_model
                ctx.config.model = new_model

                ctx.upstream:update_session({
                    agent = current_config.agent_id,
                    model = new_model
                })
            else
                return nil, "Failed to switch to agent: " .. (switch_err or "unknown error")
            end
        elseif agent_changed and model_changed then
            -- Both agent and model explicitly changed
            local switch_success, switch_err = ctx.agent_ctx:switch_to_agent(current_config.agent_id, {
                model = current_config.model
            })

            if not switch_success then
                return nil, "Failed to switch to agent with model: " .. (switch_err or "unknown error")
            end

            ctx.upstream:update_session({
                agent = current_config.agent_id,
                model = current_config.model
            })
        elseif model_changed then
            -- Only model changed
            local switch_success, switch_err = ctx.agent_ctx:switch_to_model(current_config.model)

            if not switch_success then
                return nil, "Failed to switch model: " .. (switch_err or "unknown error")
            end

            ctx.upstream:update_session({ model = current_config.model })
        end

        local success, err = ctx.writer:update_meta({ config = current_config })
        if not success then
            return nil, "Failed to update session config: " .. err
        end

        for k, v in pairs(current_config) do
            ctx.config[k] = v
        end

        -- Add system message if agent or model changed
        if agent_changed or model_changed then
            local change_parts = {}
            if agent_changed then
                table.insert(change_parts, string.format("agent: %s", current_config.agent_id))
            end
            if model_changed or (agent_changed and not model_changed) then
                table.insert(change_parts, string.format("model: %s", current_config.model))
            end

            local change_message = string.format("Configuration changed (%s)", table.concat(change_parts, ", "))
            ctx.writer:add_message(consts.MSG_TYPE.SYSTEM, change_message, {
                system_action = "config_change",
                previous_agent = previous_agent,
                new_agent = agent_changed and current_config.agent_id or nil,
                previous_model = previous_model,
                new_model = current_config.model
            })
            ctx.writer:add_message(consts.MSG_TYPE.DEVELOPER, change_message)
        end
    end

    return { completed = true }
end

return control_handlers
