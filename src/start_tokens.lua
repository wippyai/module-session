local crypto = require("crypto")
local base64 = require("base64")
local json = require("json")
local consts = require("consts")

-- Convert hex string to bytes
local function hex_decode(hex_str)
    if not hex_str or #hex_str % 2 ~= 0 then
        return nil, "Invalid hex string"
    end

    local bytes = ""
    for i = 1, #hex_str, 2 do
        local hex_byte = hex_str:sub(i, i + 1)
        local byte_val = tonumber(hex_byte, 16)
        if not byte_val then
            return nil, "Invalid hex character"
        end
        bytes = bytes .. string.char(byte_val)
    end
    return bytes
end

-- Get encryption key from environment configuration
local function get_encryption_key()
    local config = consts.get_config()
    local key_hex = config.encryption_key

    if not key_hex then
        error("ENCRYPTION_KEY environment variable is required but not set")
    end

    -- Decode hex string to get the actual 32-byte key
    local key, err = hex_decode(key_hex)
    if err then
        error("Failed to decode encryption key: " .. err)
    end

    -- Verify key length
    if #key ~= 16 and #key ~= 24 and #key ~= 32 then
        error("Encryption key must be 16, 24, or 32 bytes after decoding, got " .. #key)
    end

    return key
end

-- Pack session parameters table into an encrypted start token
local function pack_start_token(params)
    if type(params) ~= "table" then
        return nil, "Parameters must be provided as a table"
    end

    if not params.agent then return nil, "Agent name is required" end

    -- Create a payload object (clone to avoid modifying the input)
    local payload = {
        agent = params.agent,
        model = params.model,
        kind = params.kind or "",
        issued_at = os.time(),
        start_func = params.start_func,
        start_params = params.start_params,
        context = params.context
    }

    -- Serialize to JSON
    local json_data, err = json.encode(payload)
    if err then
        return nil, "Failed to encode payload: " .. err
    end

    -- Get encryption key from environment
    local encryption_key = get_encryption_key()

    -- Encrypt the payload using AES-GCM from the crypto module
    local encrypted, err = crypto.encrypt.aes(json_data, encryption_key)
    if err then
        return nil, "Encryption error: " .. err
    end

    -- Base64 encode the encrypted data for HTTP transport
    return base64.encode(encrypted)
end

-- Unpack a start token into the original session parameters table
local function unpack_start_token(token)
    if not token then return nil, "No token provided" end

    -- Decode base64 first
    local encrypted_data = base64.decode(token)
    if not encrypted_data then
        return nil, "Invalid token format"
    end

    -- Get encryption key from environment
    local encryption_key = get_encryption_key()

    -- Decrypt the data
    local json_data, err = crypto.decrypt.aes(encrypted_data, encryption_key)
    if err then
        return nil, "Invalid start token: " .. err
    end

    -- Parse JSON
    local payload, err = json.decode(json_data)
    if err then
        return nil, "Malformed token payload: " .. err
    end

    -- Validate token isn't too old (optional, 24 hour expiry)
    local current_time = os.time()
    local issued_at = payload.issued_at or 0
    local token_age = current_time - issued_at

    if token_age > 86400 then -- 24 hours in seconds
        return nil, "Token expired"
    end

    -- Return the parameters as a table
    return {
        agent = payload.agent,
        model = payload.model,
        kind = payload.kind,
        issued_at = payload.issued_at,
        start_func = payload.start_func,
        start_params = payload.start_params,
        context = payload.context
    }
end

return {
    pack = pack_start_token,
    unpack = unpack_start_token
}