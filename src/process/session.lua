local json = require("json")
local consts = require("consts")
local reader = require("reader")
local writer = require("writer")
local upstream = require("upstream")
local command_bus = require("command_bus")
local message_handlers = require("message_handlers")
local control_handlers = require("control_handlers")
local session_handlers = require("session_handlers")
local agent_context = require("agent_context")
local tools = require("tools")

local function run(args)
    if not args or not args.user_id or not args.session_id then
        error(consts.ERR.MISSING_ARGS)
    end

    local session_reader, err = reader.open(args.session_id)
    if err then
        error("Failed to open session: " .. err)
    end

    local session_data = session_reader:state()
    if session_data.status == consts.STATUS.FAILED then
        error("Cannot open failed session")
    end

    local session_writer, writer_err = writer.new(args.session_id)
    if not session_writer then
        error("Failed to create session writer: " .. writer_err)
    end

    local session_upstream = upstream.new(args.session_id, args.conn_pid, args.parent_pid)

    -- Initialize agent context using session config
    local agent_ctx = agent_context.new({
        enable_cache = session_data.config.enable_agent_cache,
        context = {}
    })

    -- Configure delegation if enabled
    if session_data.config.delegation_func_id then
        local delegation_schema = nil
        local tool_schema, schema_err = tools.get_tool_schema(session_data.config.delegation_func_id)
        if tool_schema and tool_schema.schema then
            delegation_schema = tool_schema.schema
        end

        agent_ctx:configure_delegate_tools({
            enabled = true,
            description_suffix = session_data.config.delegation_description_suffix,
            default_schema = delegation_schema
        })
    end

    local context = {
        session_id = args.session_id,
        user_id = args.user_id,
        reader = session_reader,
        writer = session_writer,
        upstream = session_upstream,
        config = session_data.config,
        agent_ctx = agent_ctx,
        queue_empty_callback = function()
            session_writer:update_status(consts.STATUS.IDLE)
            session_upstream:update_session({ status = consts.STATUS.IDLE })
        end
    }

    local bus = command_bus.new(context)

    local function intercept_handler(ctx, op)
        return {
            completed = true,
            intercepted = true,
            intercepted_count = #op.intercepted_ops
        }
    end

    -- Mount all operation handlers
    bus:mount_op_handler(consts.OP_TYPE.HANDLE_MESSAGE, message_handlers.handle_message)
    bus:mount_op_handler(consts.OP_TYPE.AGENT_STEP, message_handlers.agent_step)
    bus:mount_op_handler(consts.OP_TYPE.PROCESS_TOOLS, message_handlers.process_tools)
    bus:mount_op_handler(consts.OP_TYPE.AGENT_CONTINUE, message_handlers.agent_continue)

    bus:mount_op_handler(consts.OP_TYPE.CONTROL_ARTIFACTS, control_handlers.control_artifacts)
    bus:mount_op_handler(consts.OP_TYPE.CONTROL_CONTEXT, control_handlers.control_context)
    bus:mount_op_handler(consts.OP_TYPE.CONTROL_MEMORY, control_handlers.control_memory)
    bus:mount_op_handler(consts.OP_TYPE.CONTROL_CONFIG, control_handlers.control_config)

    bus:mount_op_handler(consts.OP_TYPE.AGENT_CHANGE, session_handlers.agent_change)
    bus:mount_op_handler(consts.OP_TYPE.MODEL_CHANGE, session_handlers.model_change)
    bus:mount_op_handler(consts.OP_TYPE.GENERATE_TITLE, session_handlers.generate_title)
    bus:mount_op_handler(consts.OP_TYPE.CREATE_CHECKPOINT, session_handlers.create_checkpoint)
    bus:mount_op_handler(consts.OP_TYPE.CHECK_BACKGROUND_TRIGGERS, session_handlers.check_background_triggers)
    bus:mount_op_handler(consts.OP_TYPE.EXECUTE_FUNCTION, session_handlers.execute_function)
    bus:mount_op_handler(consts.OP_TYPE.HANDLE_CONTEXT_COMMAND, control_handlers.handle_context_command)

    if args.create then
        session_writer:update_status(consts.STATUS.IDLE)

        if session_data.config.agent_id and session_data.config.agent_id ~= "" then
            bus:queue_op({
                type = consts.OP_TYPE.AGENT_CHANGE,
                agent_id = session_data.config.agent_id,
                init = true
            })
        end

        if session_data.config.model and session_data.config.model ~= "" then
            bus:queue_op({
                type = consts.OP_TYPE.MODEL_CHANGE,
                model = session_data.config.model,
                init = true
            })
        end

        if session_data.config.init_function_id and session_data.config.init_function_id ~= "" then
            bus:queue_op({
                type = consts.OP_TYPE.EXECUTE_FUNCTION,
                function_id = session_data.config.init_function_id,
                function_params = session_data.config.init_function_params,
            })
        end
    end

    -- Send initial session data to client
    session_upstream:update_session({
        agent = session_data.config.agent_id,
        model = session_data.config.model,
        status = consts.STATUS.IDLE,
        last_message_date = session_data.last_message_date,
        public_meta = session_data.public_meta,
    })

    process.registry.register("session." .. args.session_id)

    local session_state = {
        stopping = false,
        finishing = false,
        bus_done_received = false
    }
    local bus_done = channel.new()

    coroutine.spawn(function()
        local _, bus_err = bus:run()
        if bus_err then
            print("Command bus error:", bus_err)
        end
        bus_done:send(true)
    end)

    local inbox = process.inbox()
    local events = process.events()

    while not session_state.stopping do
        local result = channel.select({
            inbox:case_receive(),
            events:case_receive(),
            bus_done:case_receive()
        })

        if not result.ok then
            break
        end

        if result.channel == inbox then
            local msg = result.value
            local topic = msg:topic()
            local payload = msg:payload()

            if topic == consts.TOPICS.MESSAGE then
                local payload_data = payload:data()
                if payload_data.conn_pid then
                    session_upstream.conn_pid = payload_data.conn_pid
                end

                -- Reject messages if session is finishing
                if session_state.finishing then
                    if payload_data.request_id then
                        session_upstream:command_error(payload_data.request_id, "SESSION_FINISHING", "Session is finishing and cannot accept new messages")
                    end
                else
                    -- Set RUNNING status when user message received
                    session_writer:update_status(consts.STATUS.RUNNING)
                    session_upstream:update_session({ status = consts.STATUS.RUNNING })

                    bus:queue_op({
                        type = consts.OP_TYPE.HANDLE_MESSAGE,
                        data = payload_data.data,
                        request_id = payload_data.request_id
                    })
                end
            elseif topic == consts.TOPICS.COMMAND then
                local payload_data = payload:data()
                if payload_data.conn_pid then
                    session_upstream.conn_pid = payload_data.conn_pid
                end

                if payload_data.command == consts.COMMANDS.CONTEXT then
                    bus:queue_op({
                        type = consts.OP_TYPE.HANDLE_CONTEXT_COMMAND,
                        action = payload_data.action,
                        key = payload_data.key,
                        data = payload_data.data,
                        from_pid = payload_data.from_pid,
                        request_id = payload_data.request_id
                    })
                elseif payload_data.command == consts.COMMANDS.STOP then
                    bus:intercept(intercept_handler)
                elseif payload_data.command == consts.COMMANDS.AGENT then
                    if payload_data.name then
                        bus:queue_op({
                            type = consts.OP_TYPE.AGENT_CHANGE,
                            agent_id = payload_data.name,
                            request_id = payload_data.request_id
                        })
                    end
                elseif payload_data.command == consts.COMMANDS.MODEL then
                    if payload_data.name then
                        bus:queue_op({
                            type = consts.OP_TYPE.MODEL_CHANGE,
                            model = payload_data.name,
                            request_id = payload_data.request_id
                        })
                    end
                elseif payload_data.command == consts.COMMANDS.ARTIFACT then
                    if payload_data.artifact_id then
                        local message_id, err = session_writer:add_message(consts.MSG_TYPE.ARTIFACT, "", {
                            artifact_id = payload_data.artifact_id
                        })

                        if err then
                            session_upstream:command_error(payload_data.request_id, consts.ERROR_CODES.STORAGE_ERROR, "Failed to reference artifact")
                        else
                            session_upstream:send_message_update(message_id, "artifact", {
                                message_id = message_id,
                                artifact_id = payload_data.artifact_id
                            })
                            session_upstream:command_success(payload_data.request_id)
                        end
                    elseif payload_data.artifacts then
                        bus:queue_op({
                            type = consts.OP_TYPE.CONTROL_ARTIFACTS,
                            artifacts = payload_data.artifacts,
                            request_id = payload_data.request_id
                        })
                    else
                        session_upstream:command_error(payload_data.request_id, consts.ERROR_CODES.INVALID_JSON, "Either artifact_id or artifacts array required")
                    end
                end
            elseif topic == consts.TOPICS.FINISH_AND_EXIT then
                session_state.finishing = true
                bus:finish()
            elseif topic == consts.TOPICS.CONTINUE then
                print("Continue signal received")
            elseif topic == consts.TOPICS.STOP then
                bus:intercept(intercept_handler)
            end
        elseif result.channel == events then
            local event = result.value

            if event.kind == process.event.CANCEL then
                session_state.stopping = true
                bus:stop()
                break
            elseif event.kind == process.event.EXIT then
                print("Child process exited:", event.from)
            elseif event.kind == process.event.LINK_DOWN then
                print("Linked process failed:", event.from)
            end
        elseif result.channel == bus_done then
            session_state.bus_done_received = true
            if session_state.finishing then
                session_state.stopping = true
                break
            end
        end
    end

    if not session_state.bus_done_received then
        bus_done:receive()
    end

    return { status = "shutdown", session_id = args.session_id }
end

return { run = run }
