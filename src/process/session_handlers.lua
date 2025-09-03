local json = require("json")
local uuid = require("uuid")
local funcs = require("funcs")
local consts = require("consts")
local tool_caller = require("tool_caller")
local time = require("time")

local session_handlers = {}

function session_handlers.execute_function(ctx, op)
    if not op.function_id then
        return nil, "Function ID is required"
    end

    local session_context, ctx_err = ctx.reader:get_full_context()
    if ctx_err then
        session_context = {}
    end

    local call_id = op.function_id
    local validated_tools = {
        [call_id] = {
            valid = true,
            name = op.function_id,
            args = op.function_params or {},
            call_id = call_id,
            registry_id = op.function_id
        }
    }

    local caller = tool_caller.new()
    local results = caller:execute(session_context, validated_tools)

    if not results or not results[call_id] then
        return nil, "No function result returned"
    end

    local result_data = results[call_id]

    if result_data.error then
        ctx.writer:add_message(consts.MSG_TYPE.SYSTEM, "Function execution failed: " .. tostring(result_data.error), {
            system_action = "init_function_error",
            function_id = op.function_id,
            error = tostring(result_data.error)
        })
        return nil, "Function execution failed: " .. tostring(result_data.error)
    end

    local tool_result = result_data.result
    local next_ops = {}
    local control_ops = {}

    if tool_result and type(tool_result) == "table" and tool_result._control then
        local control = tool_result._control

        if control.artifacts and #control.artifacts > 0 then
            table.insert(control_ops, {
                type = consts.OP_TYPE.CONTROL_ARTIFACTS,
                artifacts = control.artifacts
            })
        end

        if control.context then
            table.insert(control_ops, {
                type = consts.OP_TYPE.CONTROL_CONTEXT,
                context_operations = control.context
            })
        end

        if control.memory then
            table.insert(control_ops, {
                type = consts.OP_TYPE.CONTROL_MEMORY,
                memory_operations = control.memory
            })
        end

        if control.config then
            table.insert(control_ops, {
                type = consts.OP_TYPE.CONTROL_CONFIG,
                config_changes = control.config
            })
        end

        tool_result._control = nil
    end

    ctx.writer:add_message(consts.MSG_TYPE.SYSTEM, "Initialization function executed", {
        system_action = "init_function_executed",
        function_id = op.function_id,
        function_result = tool_result,
        control_operations = control
    })

    for _, control_op in ipairs(control_ops) do
        table.insert(next_ops, control_op)
    end

    return {
        completed = true,
        function_id = op.function_id,
        result = tool_result,
        next_ops = next_ops
    }
end

function session_handlers.intercept_execution(ctx, op)
    ctx.writer:update_status(consts.STATUS.IDLE)
    ctx.upstream:update_session({ status = consts.STATUS.IDLE })

    return {
        completed = true,
        intercepted = true
    }
end

function session_handlers.check_background_triggers(ctx, op)
    local next_ops = {}
    local tokens = op.tokens
    local message_id = op.message_id

    if not tokens or not message_id then
        return { skipped = true }
    end

    local checkpoint_needed = false
    local title_needed = false

    local session_data = ctx.reader:state()

    if ctx.config.checkpoint_function_id and tokens.prompt_tokens then
        local token_threshold = ctx.config.token_checkpoint_threshold

        if tokens.prompt_tokens > token_threshold then
            checkpoint_needed = true
            table.insert(next_ops, {
                type = consts.OP_TYPE.CREATE_CHECKPOINT,
                checkpoint_id = message_id,
                message_id = message_id,
                trigger_tokens = tokens.prompt_tokens
            })
        end
    end

    if ctx.config.title_function_id and not checkpoint_needed then
        local has_title = session_data.title and session_data.title ~= ""

        if not has_title then
            local total_count, err = ctx.reader:messages():count()

            if not err and total_count and total_count >= consts.INTERNAL.TITLE_TRIGGER_MESSAGE_COUNT then
                title_needed = true
                table.insert(next_ops, {
                    type = consts.OP_TYPE.GENERATE_TITLE,
                    session_id = ctx.session_id,
                    current_checkpoint_id = ctx.reader:get_context(consts.CONTEXT_KEYS.CURRENT_CHECKPOINT_ID)
                })
            end
        end
    end

    -- Don't set status here - this is transitory
    -- Status will be set by the final operation in the chain
    if #next_ops == 0 then
        return { skipped = true }
    end

    return {
        checkpoint_triggered = checkpoint_needed,
        title_triggered = title_needed,
        next_ops = next_ops
    }
end

function session_handlers.generate_title(ctx, op)
    if not ctx.config.title_function_id then
        return nil, "No title function ID configured"
    end

    local session_context, ctx_err = ctx.reader:get_full_context()
    if ctx_err then
        session_context = {}
    end

    local result, title_err = funcs.new():with_context(session_context):call(ctx.config.title_function_id, {
        session_id = ctx.session_id
    })

    if title_err then
        return nil, title_err
    end

    if not result or not result.title then
        return nil, "No title returned"
    end

    local success, err = ctx.writer:update_title(result.title)
    if not success then
        return nil, err
    end

    ctx.reader:reset()

    ctx.upstream:update_session({ title = result.title })

    local msg_id, msg_err = ctx.writer:add_message(consts.MSG_TYPE.SYSTEM, "Session title generated", {
        system_action = "title_generated",
        title = result.title
    })

    -- Don't set status here - this is transitory
    return {
        completed = true,
        title = result.title,
        tokens = result.tokens
    }
end

function session_handlers.create_checkpoint(ctx, op)
    if not ctx.config.checkpoint_function_id then
        return nil, "No summary function ID configured"
    end

    if not op.checkpoint_id then
        return nil, "Checkpoint ID required"
    end

    local session_context, ctx_err = ctx.reader:get_full_context()
    if ctx_err then
        session_context = {}
    end

    local result, func_err = funcs.new():with_context(session_context):call(ctx.config.checkpoint_function_id, {
        session_id = ctx.session_id
    })

    if func_err then
        return nil, func_err
    end

    if not result or not result.summary then
        return nil, "No summary returned"
    end

    local checkpoint_metadata = {
        checkpoint_summary = result.summary,
        checkpoint_reason = "token_threshold_exceeded",
        checkpoint_id = op.checkpoint_id,
        trigger_tokens = op.trigger_tokens or 0,
        checkpoint_generated_at = time.now():format(time.RFC3339),
        checkpoint_tokens = result.tokens or {}
    }

    local success, err = ctx.writer:update_message_meta(op.message_id, checkpoint_metadata)
    if not success then
        return nil, err
    end

    local session_data = ctx.reader:state()
    local current_meta = session_data.meta or {}

    if not current_meta.checkpoints or type(current_meta.checkpoints) ~= "table" then
        current_meta.checkpoints = {}
    end

    table.insert(current_meta.checkpoints, {
        checkpoint_id = op.checkpoint_id,
        message_id = op.message_id,
        created_at = time.now():format(time.RFC3339),
        trigger_tokens = op.trigger_tokens or 0,
        checkpoint_tokens = result.tokens or {}
    })

    local meta_success, meta_err = ctx.writer:update_meta({ meta = current_meta })
    if not meta_success then
    else
    end

    local success1, err1 = ctx.writer:set_context(consts.CONTEXT_KEYS.CURRENT_CHECKPOINT_ID, op.checkpoint_id)
    if not success1 then
        return nil, err1
    end

    local deleted_result, del_err = ctx.writer:delete_session_contexts_by_type(consts.CONTEXT_TYPES.CONVERSATION_SUMMARY)

    local summary_id, ctx_err = ctx.writer:add_session_context(consts.CONTEXT_TYPES.CONVERSATION_SUMMARY, result.summary)
    if ctx_err then
        return nil, ctx_err
    end

    local next_ops = {}
    if ctx.config.title_function_id then
        table.insert(next_ops, {
            type = consts.OP_TYPE.GENERATE_TITLE,
            session_id = ctx.session_id,
            current_checkpoint_id = op.checkpoint_id
        })
    end

    -- Don't set status here - let the operation chain complete naturally
    return {
        completed = true,
        checkpoint_id = op.checkpoint_id,
        tokens = result.tokens,
        next_ops = next_ops
    }
end

function session_handlers.agent_change(ctx, op)
    if not op.agent_id then
        return nil, "Agent ID is required"
    end

    local session_data = ctx.reader:state()
    local current_config = session_data.config or {}
    local previous_agent = current_config.agent_id

    current_config.agent_id = op.agent_id

    local success, err = ctx.writer:update_meta({ config = current_config })
    if not success then
        return nil, "Failed to update agent config: " .. (err or "unknown error")
    end

    ctx.config.agent_id = op.agent_id

    ctx.reader:reset()

    local switch_success, switch_err = ctx.agent_ctx:switch_to_agent(op.agent_id, {
        model = ctx.config.model
    })

    local setup_message = string.format("Agent changed to: %s", op.agent_id)
    ctx.writer:add_message(consts.MSG_TYPE.SYSTEM, setup_message, {
        system_action = "agent_change",
        from_agent = previous_agent,
        to_agent = op.agent_id
    })

    ctx.upstream:update_session({
        agent = op.agent_id
    })

    return {
        completed = true,
        previous_agent = previous_agent,
        new_agent = op.agent_id
    }
end

function session_handlers.model_change(ctx, op)
    if not op.model then
        return nil, "Model name is required"
    end

    local session_data = ctx.reader:state()
    local current_config = session_data.config or {}
    local previous_model = current_config.model

    current_config.model = op.model

    local success, err = ctx.writer:update_meta({ config = current_config })
    if not success then
        return nil, "Failed to update model config: " .. (err or "unknown error")
    end

    ctx.config.model = op.model

    ctx.reader:reset()

    if ctx.config.agent_id then
        local switch_success, switch_err = ctx.agent_ctx:switch_to_model(op.model)
    end

    local change_message = string.format("Model changed to: %s", op.model)
    ctx.writer:add_message(consts.MSG_TYPE.SYSTEM, change_message, {
        system_action = "model_change",
        from_model = previous_model,
        to_model = op.model
    })

    ctx.upstream:update_session({
        model = op.model
    })

    return {
        completed = true,
        previous_model = previous_model,
        new_model = op.model
    }
end

return session_handlers
