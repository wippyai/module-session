local test = require("test")
local start_tokens = require("start_tokens")
local base64 = require("base64")
local wait_for_boot = require("wait_for_boot")

local function define_tests()
    describe("Start Tokens", function()
        before_all(function()
            wait_for_boot.run()
        end)

        it("should create and unpack valid token", function()
            local params = {
                agent = "test_agent",
                model = "claude-3-7-sonnet",
                kind = "test_session"
            }

            local token, err = start_tokens.pack(params)
            test.is_nil(err)
            test.not_nil(token)

            local result, err = start_tokens.unpack(token :: string)
            test.is_nil(err)
            test.is_table(result)

            test.eq(result.agent, params.agent)
            test.eq(result.model, params.model)
            test.eq(result.kind, params.kind)
            test.is_number(result.issued_at)
        end)

        it("should create token with minimal params", function()
            local params = {
                agent = "minimal_agent",
                model = "gpt-4o"
            }

            local token, err = start_tokens.pack(params)
            test.is_nil(err)

            local result, err = start_tokens.unpack(token :: string)
            test.is_nil(err)
            test.eq(result.agent, params.agent)
            test.eq(result.model, params.model)
            test.eq(result.kind, "")
        end)

        it("should error on missing required params", function()
            local token1, err1 = start_tokens.pack({model = "test-model"})
            test.is_nil(token1)
            test.not_nil(err1)
            test.contains(tostring(err1), "Agent name is required")

            local token3, err3 = start_tokens.pack("not a table")
            test.is_nil(token3)
            test.not_nil(err3)
            test.contains(tostring(err3), "Parameters must be provided as a table")
        end)

        it("should error on invalid token format", function()
            local result1, err1 = start_tokens.unpack(nil)
            test.is_nil(result1)
            test.not_nil(err1)
            test.contains(tostring(err1), "No token provided")

            local result2, err2 = start_tokens.unpack("not a valid token")
            test.is_nil(result2)
            test.not_nil(err2)
            test.contains(tostring(err2), "Invalid token format")

            local result3, err3 = start_tokens.unpack(base64.encode("just some random data"))
            test.is_nil(result3)
            test.not_nil(err3)
        end)

        it("should detect expired tokens", function()
            mock("os.time", function() return 1640995200 end)

            local params = {
                agent = "expired_agent",
                model = "expired_model",
                kind = "expired_session"
            }

            local token, _ = start_tokens.pack(params)

            mock("os.time", function() return 1640995200 + 90000 end)

            local result, err = start_tokens.unpack(token :: string)
            test.is_nil(result)
            test.not_nil(err)
            test.contains(tostring(err), "Token expired")
        end)
    end)
end

return test.run_cases(define_tests)
