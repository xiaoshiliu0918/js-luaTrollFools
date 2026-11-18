-- hello.lua —— Lua 版最小验证
-- 需要打包时内置 Lua（third_party/lua 存在），否则容器会提示「本包不含 Lua」

local n = 0

native.log("hello from " .. (native.bid or "?") .. " pid " .. tostring(native.pid))

function on_tick(dt)
    n = n + 1
    if n % 300 == 0 then
        native.log(string.format("alive %d frames, dt=%.3f", n, dt))
    end
end

function on_unload()
    native.log("unload after " .. n .. " frames")
end
