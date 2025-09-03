local consts = require("consts")

local session_upstream = {}
session_upstream.__index = session_upstream

function session_upstream.new(session_id, conn_pid, parent_pid)
    local self = setmetatable({}, session_upstream)
    self.session_id = session_id
    self.conn_pid = conn_pid
    self.parent_pid = parent_pid
    return self
end

-- Topic generation methods --

-- Get session-level topic
function session_upstream:get_session_topic()
    return consts.TOPIC_PREFIXES.SESSION .. self.session_id
end

-- Get message-level topic
function session_upstream:get_message_topic(message_id)
    return consts.TOPIC_PREFIXES.SESSION .. self.session_id .. consts.TOPIC_PREFIXES.MESSAGE .. message_id
end

-- SESSION-LEVEL UPDATES --

-- Update session state (status, agent, model, etc.)
function session_upstream:update_session(changes)
    changes["session_id"] = self.session_id
    self:_send_session_update(consts.UPSTREAM_TYPES.UPDATE, changes)
end

-- Report session-level error
function session_upstream:session_error(code, message)
    self:_send_session_update(consts.UPSTREAM_TYPES.ERROR, {
        code = code,
        message = message
    })
end

-- MESSAGE-LEVEL UPDATES --

-- Announce new assistant response beginning
function session_upstream:response_beginning(response_id, message_id)
    self:send_message_update(response_id, consts.UPSTREAM_TYPES.RESPONSE_STARTED, {
        response_id = response_id,
        message_id = message_id,
        timestamp = os.time()
    })
end

-- Confirm message reception
function session_upstream:message_received(message_id, text, file_uuids)
    self:send_message_update(message_id, consts.UPSTREAM_TYPES.RECEIVED, {
        message_id = message_id,
        text = text,
        timestamp = os.time(),
        file_uuids = file_uuids
    })
end

-- Report message-level error
function session_upstream:message_error(message_id, code, message)
    self:send_message_update(message_id, consts.UPSTREAM_TYPES.ERROR, {
        message_id = message_id,
        code = code,
        message = message
    })
end

-- Invalidate message
function session_upstream:invalidate_message(message_id, reason)
    self:send_message_update(message_id, consts.UPSTREAM_TYPES.INVALIDATE, {
        response_id = message_id,
        reason = reason
    })
end

-- Report command success with request_id
function session_upstream:command_success(request_id)
    self:_send_session_update(consts.UPSTREAM_TYPES.COMMAND_RESPONSE, {
        request_id = request_id,
        success = true
    })
end

-- Report command error with request_id
function session_upstream:command_error(request_id, code, message)
    self:_send_session_update(consts.UPSTREAM_TYPES.COMMAND_RESPONSE, {
        request_id = request_id,
        success = false,
        code = code,
        message = message
    })
end

-- PRIVATE METHODS --

-- Send session-level update
function session_upstream:_send_session_update(type, payload)
    local topic = self:get_session_topic()
    local message = { type = type }

    -- Merge payload fields into message
    for k, v in pairs(payload or {}) do
        message[k] = v
    end

    self:_send_message(topic, message)
end

-- Send message-level update
function session_upstream:send_message_update(message_id, type, payload)
    local topic = self:get_message_topic(message_id)
    local message = { type = type }

    -- Merge payload fields into message
    for k, v in pairs(payload or {}) do
        message[k] = v
    end

    self:_send_message(topic, message)
end

-- Send message to appropriate recipients
function session_upstream:_send_message(topic, message)
    -- Send to parent process (which can relay to all connections)
    if self.parent_pid then
        process.send(self.parent_pid, topic, message)
    end
end

return session_upstream
