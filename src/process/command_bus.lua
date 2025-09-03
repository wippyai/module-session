local command_bus = {}
command_bus.__index = command_bus

function command_bus.new(context)
    local self = setmetatable({}, command_bus)

    self.context = context

    self.ops_channel = channel.new(256)
    self.stop_signal = channel.new()

    self.stopping = false
    self.intercepted = false
    self.intercept_handler = nil

    self.handlers = {}

    return self
end

function command_bus:mount_op_handler(op_type, handler_func)
    if not op_type or type(handler_func) ~= "function" then
        return false, "Operation type and handler function required"
    end
    self.handlers[op_type] = handler_func
    return true, nil
end

function command_bus:queue_op(op)
    if self.stopping then
        return false, "Command bus is stopping"
    end
    self.ops_channel:send(op)
    return true, nil
end

function command_bus:is_fatal_error(err, op_type)
    if not err or type(err) ~= "string" then
        return false
    end

    if string.find(err, "No handler for operation") then
        return true
    end

    if string.find(err, "Missing required arguments") then
        return true
    end

    if string.find(err, "Failed to open session") then
        return true
    end

    if string.find(err, "Cannot open failed session") then
        return true
    end

    return false
end

function command_bus:process_operation(op)
    local handler = self.handlers[op.type]
    if not handler then
        local error_msg = "No handler for operation: " .. tostring(op.type)
        return nil, error_msg
    end

    local result, err = handler(self.context, op)

    if err then
        local is_fatal = self:is_fatal_error(err, op.type)

        if is_fatal then
            return nil, err
        else
            -- Report error but don't change status - that's not the bus's job
            if self.context.upstream and op.request_id then
                self.context.upstream:command_error(op.request_id, "HANDLER_ERROR", err)
            end

            return { error_handled = true, error_message = err }, nil
        end
    end

    if self.intercepted then
        if self.intercept_handler and type(self.intercept_handler) == "function" then
            local next_ops = (result and result.next_ops) or {}
            local intercept_result, intercept_err = self.intercept_handler(self.context, {
                intercepted_ops = next_ops,
                original_result = result
            })
        end

        self.intercepted = false
        self.intercept_handler = nil

        return result, nil
    end

    if result and result.next_ops then
        for _, next_op in ipairs(result.next_ops) do
            self.ops_channel:send(next_op)
        end
    end

    return result, nil
end

function command_bus:intercept(intercept_handler_func)
    self.intercepted = true
    self.intercept_handler = intercept_handler_func
end

function command_bus:stop()
    if self.stopping then
        return
    end
    self.stopping = true
    self.stop_signal:send(true)
end

function command_bus:run()
    while not self.stopping do
        local result = channel.select({
            self.stop_signal:case_receive(),
            self.ops_channel:case_receive()
        })

        if not result.ok then
            break
        end

        if result.channel == self.stop_signal then
            self.stopping = true
        elseif result.channel == self.ops_channel then
            local _, err = self:process_operation(result.value)
            if err then
                local is_fatal = self:is_fatal_error(err, result.value.type)
                if is_fatal then
                    return nil, err
                end
            end
        end
    end

    return true, nil
end

return command_bus
