-- DFQ 1.5 PC compatibility loader (0.10 -> 11.x)
-- 仅在 LÖVE 11 上应用兼容补丁；安卓 APK 自带 0.10 引擎，打 11 的补丁会导致画面全黑
local _verMajor = 11
if love.getVersion then
    local ok, a = pcall(love.getVersion)
    if ok and type(a) == "number" then _verMajor = a end
end
local IS_LOVE11 = _verMajor >= 11
if IS_LOVE11 then
local ffi = require("ffi")

local function addMethod(obj, name, fn)
    local mt = getmetatable(obj)
    if mt and mt.__index and not mt.__index[name] then
        mt.__index[name] = fn
    end
end
local function scaleColor(c)
    if type(c) == "number" then return c > 1.5 and c / 255 or c
    elseif type(c) == "table" then
        local r = {} for i = 1, #c do r[i] = scaleColor(c[i]) end; return r
    end
    return c
end

-- getData shims:
--   FileData:getData()                          -> raw pointer
--   ImageData/CompressedImageData:getData()     -> self
--   Image:getData()                             -> self
local function shimPointer(obj)
    addMethod(obj, "getData", function(self)
        local p = self.getFFIPointer and self:getFFIPointer() or nil
        if p == nil then p = self:getPointer() end
        return p
    end)
end
local function shimSelf(obj)
    addMethod(obj, "getData", function(self, level)
        if level == nil then return self end
        local p = self.getFFIPointer and self:getFFIPointer(level) or nil
        if p == nil then p = self:getPointer(level) end
        return p
    end)
    local mt = getmetatable(obj)
    if mt and mt.__index and not mt.__index.setFilter then
        mt.__index.setFilter = function(self, ...) end
    end
end
do
    local ok1, fd = pcall(love.filesystem.newFileData, "x", "x.bin"); if ok1 then shimPointer(fd) end
    local ok2, id = pcall(love.image.newImageData, 2, 2); if ok2 then shimSelf(id) end
end
local _newCompressedData = love.image.newCompressedData
local _newImageData = love.image.newImageData
local _newImage = love.graphics.newImage

love.image.newCompressedData = function(...)
    local cd = _newCompressedData(...); shimSelf(cd); return cd
end
love.image.newImageData = function(...)
    local id = _newImageData(...); shimSelf(id); return id
end

love.graphics.newImage = function(...)
    local a = ...
    if type(a) == "userdata" then
        local _, isImg = pcall(a.typeOf, a, "Image")
        if isImg then return a end
    end
    local ok, img = pcall(_newImage, ...)
    if not ok then error(img, 0) end
    addMethod(img, "getData", function(self) return self end)
    return img
end

-- draw() accepted raw ImageData/CompressedImageData -> lazily make Image
local dataTextureCache = setmetatable({}, {__mode = "k"})
local _gfxDraw = love.graphics.draw
local function drawWrapper(obj, ...)
    local tn = type(obj)
    if tn == "userdata" then
        local _, isImg = pcall(obj.typeOf, obj, "Image")
        if not isImg then
            local _, d1 = pcall(obj.typeOf, obj, "ImageData")
            local _, d2 = pcall(obj.typeOf, obj, "CompressedImageData")
            if d1 or d2 then
                local tex = dataTextureCache[obj]
                if not tex then
                    tex = _newImage(obj)
                    dataTextureCache[obj] = tex
                end
                obj = tex
            end
        end
    end
    return _gfxDraw(obj, ...)
end
love.graphics.draw = drawWrapper
do
    local mt = getmetatable(love.graphics)
    if mt and mt.__index and type(mt.__index) == "table" then
        mt.__index.draw = drawWrapper
    end
    rawset(love.graphics, "draw", drawWrapper)
end

-- audio: 0.10 compat — auto-infer source type when missing
do
    local old = love.audio.newSource
    love.audio.newSource = function(a, b)
        if b == nil then
            if type(a) == "userdata" and (a:typeOf("SoundData") or a:typeOf("Decoder")) then b = "static" else b = "stream" end
        end
        return old(a, b)
    end
end

-- colors (0-255 -> 0-1)
do
    local old = love.graphics.setColor
    love.graphics.setColor = function(r, g, b, a)
        if type(r) == "table" then return old(scaleColor(r)) end
        return old(scaleColor(r), scaleColor(g), scaleColor(b), a and scaleColor(a) or nil)
    end
    local oldbg = love.graphics.setBackgroundColor
    love.graphics.setBackgroundColor = function(r, g, b, a)
        if type(r) == "table" then return oldbg(scaleColor(r)) end
        return oldbg(scaleColor(r), scaleColor(g), scaleColor(b), a and scaleColor(a) or nil)
    end
    local oldClear = love.graphics.clear
    love.graphics.clear = function(r, g, b, a, ...)
        if type(r) == "number" then
            return oldClear(scaleColor(r), scaleColor(g or 0), scaleColor(b or 0), a and scaleColor(a) or nil, ...)
        end
        return oldClear(r, g, b, a, ...)
    end
end

love.filesystem.exists = function(path) return love.filesystem.getInfo(path) ~= nil end

-- particles
do
    local patched = false
    local oldNewPS = love.graphics.newParticleSystem
    love.graphics.newParticleSystem = function(...)
        local ps = oldNewPS(...)
        if not patched then
            patched = true
            local idx = getmetatable(ps).__index
            idx.setAreaSpread = idx.setAreaSpread or function(self, dist, dx, dy, angle, scale)
                return self:setEmissionArea(dist or "none", dx or 0, dy or 0, angle or 0, scale == nil and true or scale) end
            idx.setParticleLife = idx.setParticleLife or function(self, ...) return self:setParticleLifetime(...) end
            idx.setSizesVariation = idx.setSizesVariation or function(self, v) return self:setSizeVariation(1, v) end
            idx.setSpriteChange = idx.setSpriteChange or function() end
        end
        return ps
    end
end

_G.loadstring = function(src, name, mode, env)
    if type(src) == "function" then
        local t = {}
        while true do local p = src(); if not p or p == "" then break end; t[#t+1] = p end
        src = table.concat(t)
    end
    if env ~= nil then return load(src, name, mode, env) end
    return load(src, name, mode)
end

end -- IS_LOVE11 兼容补丁结束

-- 加载原版字节码
local chunk = assert(love.filesystem.load("main_orig.lua"))
local ok, rerr = xpcall(chunk, function(e) print("ERROR: " .. tostring(e)); print(debug.traceback("", 2)); return e end)
if not ok then error(rerr, 0) end

-- 调试：写日志到文件
local function log(msg)
    local f = io.open(love.filesystem.getSaveDirectory() .. "/dfq_debug.log", "a")
    if f then f:write(os.date("%H:%M:%S") .. " " .. tostring(msg) .. "\n") f:close() end
end

log("main_orig.lua loaded")
log("package.loaded['map.init'] = " .. tostring(package.loaded["map.init"]))
log("package.loaded['map.init'].Load = " .. tostring(package.loaded["map.init"] and package.loaded["map.init"].Load))

-- 赛利亚房间：覆盖 map.init.Load，timeGate 与 seriaRoom 互换
-- timeGate_real 哨兵用于从房间直达真实时空之门（避免循环重定向）
-- 必须在 main_orig.lua 加载之后，因为 map.init 是字节码里 require 的
local _switchPageFn = nil
local _mapInit = package.loaded["map.init"]
local DUNGEON_SELECT = {} -- 哨兵：表示应打开副本选择页而非直接进副本
local _selecting = false  -- 已打开副本选择页时，后续 Make 真正进副本
local _gameStarted = false -- 至少加载过一次游戏地图后，才把 hall 页重定向到 main
local _mapLoadedOnce = false -- 是否已经真正加载过一张地图（新号开局时还没有）
local _seriaDirectDone = false -- 新号开局：已直接进入赛利亚房间（跳过洛兰副本）
local _lastPage = nil -- 最近一次切换的界面页，用于确认当前处于新号开局的黑屏流程
-- 启动时是否已有存档：有存档=老玩家，首次 dungeon.Go 不做重定向
local _hadSaveAtLaunch = false
pcall(function()
    if love.filesystem.exists then _hadSaveAtLaunch = love.filesystem.exists("game.sav") and true or false end
end)
if not _hadSaveAtLaunch then
    -- 安卓版存档写在 /storage/emulated/0/dfq/game.sav，不在 love 默认存档目录
    pcall(function()
        local f = io.open("/storage/emulated/0/dfq/game.sav", "r")
        if f then f:close(); _hadSaveAtLaunch = true end
    end)
end
if _mapInit and _mapInit.Load then
    log("hadSaveAtLaunch=" .. tostring(_hadSaveAtLaunch))
    local _origLoad = _mapInit.Load
    _mapInit.Load = function(mapName, ...)
        if mapName == DUNGEON_SELECT then
            return -- 忽略，副本选择页已打开
        end
        log("map.init.Load called with: " .. tostring(mapName))
        if mapName == "timeGate" then
            if _G._DFQ_BACK_TO_REAL_TG then
                _G._DFQ_BACK_TO_REAL_TG = false -- 设置页返回城镇：本次保留真时空之门
                log("Back-to-town flag consumed, keep timeGate")
            else
                mapName = "seriaRoom"
                log("Redirecting timeGate -> seriaRoom")
            end
        elseif mapName == "timeGate_real" then
            mapName = "timeGate"
            log("Redirecting timeGate_real -> timeGate")
        end
        -- 城镇地图不显示“冒险开始”横幅（config/ui/main/slogan/start.cfg 会读取这个标记）
        _G._DFQ_MAP_IS_TOWN = (mapName == "seriaRoom" or mapName == "timeGate")
        local result = _origLoad(mapName, ...)
        _mapLoadedOnce = true
        -- 加载游戏地图后强制切到 main 页，避免返回标题重进时停在 black 页黑屏
        if _switchPageFn and mapName ~= "interview" then
            _gameStarted = true
            _switchPageFn("main")
            log("Forced SwitchPage main after map load")
        end
        return result
    end
    log("map.init.Load overridden successfully")

    -- 时空之门右门：type=make map=lorien 时，打开副本选择页而非直接进洛兰
    if _mapInit.Make then
        local _origMake = _mapInit.Make
        _mapInit.Make = function(mapName, e, ...)
            if mapName == "lorien" and not _selecting then
                log("Make(lorien) -> open dungeon select page")
                -- 把玩家移出传送门碰撞区，防止返回后重复触发
                local _CONFIG = package.loaded["config"]
                local player = _CONFIG and _CONFIG.user and _CONFIG.user.player
                if player and player.transform and player.transform.position then
                    local x, y = player.transform.position:Get()
                    player.transform.position:Set(x - 150, y)
                    log("Moved player off collider: " .. tostring(x) .. " -> " .. tostring(x - 150))
                end
                _selecting = true
                if _switchPageFn then _switchPageFn("dungeon") end
                return DUNGEON_SELECT
            end
            _selecting = false
            log("Make passthrough: " .. tostring(mapName))
            return _origMake(mapName, e, ...)
        end
        log("map.init.Make overridden for dungeon select")
    end
else
    log("WARNING: map.init not found in package.loaded")
end

-- 赛利亚房间：大厅 hall 页替换为游戏 main 页（可走动城镇，带摇杆 HUD）
for _name, _mod in pairs(package.loaded) do
    if type(_mod) == "table" and type(rawget(_mod, "SwitchPage")) == "function" then
        local _origSwitchPage = _mod.SwitchPage
        _switchPageFn = _origSwitchPage
        _mod.SwitchPage = function(page, ...)
            log("SwitchPage called with: " .. tostring(page))
            _lastPage = page
            if page == "main" then
                _selecting = false -- 回到地图页，副本选择流程结束
            end
            if page == "hall" and _gameStarted then
                page = "main"
                log("SwitchPage redirected: hall -> main")
            end
            return _origSwitchPage(page, ...)
        end
        log("SwitchPage overridden in module: " .. tostring(_name))
    end
end

-- 设置页“返回标题”改为返回城镇(真时空之门)：BackMenu 复用引擎 BackTown 回城流程(含存档/清理)，
-- 通过标记让 Load 重定向这一次走 timeGate_real，不影响其它 BackTown 调用者(它们仍回赛利亚房间)
for _name, _mod in pairs(package.loaded) do
    if type(_mod) == "table" and type(rawget(_mod, "BackMenu")) == "function"
        and type(rawget(_mod, "BackTown")) == "function" and not rawget(_mod, "__backMenuHooked") then
        local _origBackTown = _mod.BackTown
        _mod.BackMenu = function(...)
            _G._DFQ_BACK_TO_REAL_TG = true
            log("BackMenu intercepted -> BackTown to timeGate_real")
            return _origBackTown(...)
        end
        rawset(_mod, "__backMenuHooked", true)
        log("BackMenu overridden in module: " .. tostring(_name))
    end
end

-- 新号开局：原版 interview 的 StartGame 结尾会调用 user.dungeon:Go(Get("lorien")) 建洛兰副本
-- 这里直接把这次 Go 跳过，改为加载赛利亚的房间，从根源上避免副本刷怪逻辑残留
local _dungeonGoHooked = false
local function _installDungeonGoHook()
    if _dungeonGoHooked then return end
    local _CONFIG = package.loaded["config"]
    local dg = _CONFIG and _CONFIG.user and _CONFIG.user.dungeon
    if not dg or type(dg.Go) ~= "function" then return end
    local _origGo = dg.Go
    dg.Go = function(self, node, ...)
        if _lastPage == "black" and not _hadSaveAtLaunch and not _seriaDirectDone and not _mapLoadedOnce then
            _seriaDirectDone = true
            _mapLoadedOnce = true
            log("Fresh StartGame -> skip dungeon, load seriaRoom directly")
            local r = _mapInit.Load("seriaRoom")
            if _switchPageFn then _switchPageFn("main") end
            return r
        end
        return _origGo(self, node, ...)
    end
    _dungeonGoHooked = true
    log("dungeon.Go overridden for fresh-start seriaRoom")
end

local _saveDbgHooked = false -- 是否已装好存档调试钩子
local _installSaveDebug -- 前置声明，供 love.update 包装内调用
local _origUpdateCb = love.update
if _origUpdateCb then
    love.update = function(dt)
        if not _dungeonGoHooked then _installDungeonGoHook() end
        if not _saveDbgHooked then _installSaveDebug() end
        return _origUpdateCb(dt)
    end
    log("love.update wrapped for dungeon.Go hook")
end

-- 调试：确认存档调用链（谁调用、写盘是否成功）
function _installSaveDebug()
    if _saveDbgHooked then return end
    local _CONFIG = package.loaded["config"]
    local _user = _CONFIG and _CONFIG.user
    local _lf = package.loaded["lib.file"]
    local _waiting = false
    if _lf then
        if type(_lf.Write) == "function" and not _lf.__dbgWrite then
            local _w = _lf.Write
            _lf.Write = function(name, data, ...)
                local ok, err = _w(name, data, ...)
                log("lib.file.Write " .. tostring(name) .. " len=" .. tostring(data and #data or -1)
                    .. " ok=" .. tostring(ok) .. (err and (" err=" .. tostring(err)) or ""))
                return ok, err
            end
            _lf.__dbgWrite = true
            log("lib.file.Write hooked")
        end
    else
        _waiting = true
    end
    if _user then
        if type(_user.Save) == "function" and not _user.__dbgSave then
            local _s = _user.Save
            _user.Save = function(...)
                log("user.Save called")
                local r = _s(...)
                log("user.Save finished")
                return r
            end
            _user.__dbgSave = true
            log("user.Save hooked")
        end
    else
        _waiting = true
    end
    _saveDbgHooked = not _waiting
end

-- 调试：捕获 NewFileData 失败（缺贴图）的调用栈
local _origNewFileData = love.filesystem.newFileData
love.filesystem.newFileData = function(arg, ...)
    if type(arg) ~= "string" and type(arg) ~= "userdata" then
        log("NewFileData BAD ARG: " .. tostring(arg) .. " type=" .. type(arg))
        log("TRACE:\n" .. debug.traceback("", 2))
    end
    return _origNewFileData(arg, ...)
end
log("NewFileData hook installed")

-- 调试：记录所有写盘动作，确认存档是否真的写进 save 目录
pcall(function() log("saveDir=" .. tostring(love.filesystem.getSaveDirectory())) end)
if love.filesystem.write then
    local _origFsWrite = love.filesystem.write
    love.filesystem.write = function(name, data, ...)
        local ok, err = _origFsWrite(name, data, ...)
        log("fs.write " .. tostring(name) .. " bytes=" .. tostring(data and #data or -1)
            .. " ok=" .. tostring(ok) .. (err and (" err=" .. tostring(err)) or ""))
        return ok, err
    end
end
if love.filesystem.newFile then
    local _origNewFile = love.filesystem.newFile
    love.filesystem.newFile = function(name, mode, ...)
        if mode == "w" then log("fs.newFile(w) " .. tostring(name)) end
        return _origNewFile(name, mode, ...)
    end
end
log("fs.write hooks installed")
