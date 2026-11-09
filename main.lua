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

-- 记录由 ImageData 创建的 Image，getData 返回原始 ImageData
-- （截图留念链路：newImage(newScreenshot()):getData():encode("png")）
local imgDataMap = setmetatable({}, {__mode = "k"})
love.graphics.newImage = function(...)
    local a = ...
    if type(a) == "userdata" then
        local _, isImg = pcall(a.typeOf, a, "Image")
        if isImg then return a end
    end
    local ok, img = pcall(_newImage, ...)
    if not ok then error(img, 0) end
    if type(a) == "userdata" then
        local _, isID = pcall(a.typeOf, a, "ImageData")
        if isID then imgDataMap[img] = a end
    end
    addMethod(img, "getData", function(self) return imgDataMap[self] or self end)
    return img
end

-- newScreenshot: 0.10 API，LÖVE 11 已移除（只剩异步 captureScreenshot）。
-- Boss 死亡时游戏同步截图留念（Shot → newImage(newScreenshot(true)) → Write 存 PNG），
-- 11 无同步读屏能力，返回透明 ImageData 兜底，保证 Shot/Write 不崩（PNG 内容为空白）。
if not love.graphics.newScreenshot then
    love.graphics.newScreenshot = function(copyAlpha)
        local w, h = love.graphics.getDimensions()
        local id = _newImageData(w, h)
        if not copyAlpha then
            id:mapPixel(function() return 0, 0, 0, 1 end)
        end
        return id
    end
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


-- LÖVE 11 分辨率适配（必须在 main_orig.lua 之前安装，游戏启动时会缓存这些函数）
-- Android 上 love.graphics 的绘制坐标系是 dp（如 640x360），但 window.getMode()
-- 返回物理像素（如 2560x1440）。游戏用 getMode 的像素数计算整体缩放，于是在 dp
-- 坐标系里被放大约 4 倍并裁切（头像巨大、摇杆和技能栏跑出屏幕）。老 0.10 引擎的
-- window 和 graphics 都返回物理像素，所以原版没有这个问题。
-- 让 window 的尺寸 API 与 love.graphics 对齐后，游戏算出的缩放才正确。
if IS_LOVE11 then
    local W = love.window
    local _gdim = love.graphics.getDimensions
    local gw, gh = _gdim()
    local pw, ph = gw, gh
    if love.graphics.getPixelDimensions then
        pw, ph = love.graphics.getPixelDimensions()
    end
    if pw ~= gw or ph ~= gh then
        W.getMode = function()
            local w, h = _gdim()
            return w, h, { fullscreen = true, fullscreentype = "desktop", vsync = 0, msaa = 0, borderless = true, resizable = false, minwidth = 1, minheight = 1 }
        end
        W.getWidth = function() return (_gdim()) end
        W.getHeight = function() local _, h = _gdim(); return h end
        W.getDimensions = function() return _gdim() end
        W.getDesktopDimensions = function() return _gdim() end
    end
end

-- 加载原版字节码
local chunk = assert(love.filesystem.load("main_orig.lua"))
local ok, rerr = xpcall(chunk, function(e) print("ERROR: " .. tostring(e)); print(debug.traceback("", 2)); return e end)
if not ok then error(rerr, 0) end

-- 调试：写日志到文件
local function log(msg)
    local f = io.open(love.filesystem.getSaveDirectory() .. "/dfq_debug.log", "a")
    if f then f:write(os.date("%H:%M:%S") .. " " .. tostring(msg) .. "\n") f:close() end
end

-- 崩溃时把堆栈写进日志（蓝屏信息不留痕，排查困难）
local _origErrhand = love.errhand
love.errhand = function(msg)
    log("FATAL: " .. tostring(msg))
    local ok2, err2 = pcall(function()
        for level = 0, 14 do
            local info = debug.getinfo(level, "Sln")
            if not info then break end
            log(string.format("[%d] src=%s cur=%s def=%s-%s what=%s name=%s", level, tostring(info.short_src), tostring(info.currentline), tostring(info.linedefined), tostring(info.lastlinedefined), tostring(info.what), tostring(info.name)))
            if info.what == "Lua" then
                for i = 1, 14 do
                    local n, v = debug.getlocal(level + 1, i)
                    if not n then break end
                    local vs = tostring(v)
                    if #vs > 70 then vs = vs:sub(1, 70) end
                    log("   local " .. n .. " = " .. vs)
                end
            end
        end
    end)
    if not ok2 then log("stackdump failed: " .. tostring(err2)) end
    log(debug.traceback("", 2))
    if _origErrhand then return _origErrhand(msg) end
end

-- xueqi skill: alias bullet component module to blastBlood's (engine requires module by bullet name)
do
    local orig = "actor.component.bullet.swordman.blastBlood"
    local new = "actor.component.bullet.swordman.xueqi"
    if not package.preload[new] then
        package.preload[new] = function()
            local m = package.loaded[orig]
            if not m and package.preload[orig] then
                m = package.preload[orig]()
                package.loaded[orig] = m
            end
            if not m then m = {} end
            return m
        end
    end
end
-- 技能孔扩展：按键映射表补 skill7~skill10
-- 按键表在 config.code（动作→物理键）和 config.anticode（物理键→动作），
-- 原版只到 skill6，触屏按下 skill7~10 时 code[动作名] 为 nil，
-- 传入 input.Pressed(nil) 后用 nil 作索引写状态表 → table index is nil 崩溃
do
    local cfg = package.loaded["config"]
    if cfg and cfg.code then
        local extra = { skill7 = "j", skill8 = "k", skill9 = "l", skill10 = "u" }
        for name, key in pairs(extra) do
            if not cfg.code[name] then cfg.code[name] = key end
            if cfg.anticode and not cfg.anticode[key] then cfg.anticode[key] = name end
        end
        log("skill7~10 key bindings added to config.code/anticode")
    else
        log("WARNING: config.code not found, skill key bindings NOT applied")
    end
end

log("main_orig.lua loaded")
log("package.loaded['map.init'] = " .. tostring(package.loaded["map.init"]))
log("package.loaded['map.init'].Load = " .. tostring(package.loaded["map.init"] and package.loaded["map.init"].Load))

-- 赛利亚房间：覆盖 map.init.Load，timeGate 与 seriaRoom 互换
-- timeGate_real 哨兵用于从房间直达真实时空之门（避免循环重定向）
-- 必须在 main_orig.lua 加载之后，因为 map.init 是字节码里 require 的
local _switchPageFn = nil
local _backTownFn = nil -- director.BackTown 引用（副本选择页返回时走回城流程用）
local _mapInit = package.loaded["map.init"]
local DUNGEON_SELECT = {} -- 哨兵：表示应打开副本选择页而非直接进副本（保留占位，Load 入口防御）
local _gameStarted = false -- 至少加载过一次游戏地图后，才把 hall 页重定向到 main
local _mapLoadedOnce = false -- 是否已经真正加载过一张地图（新号开局时还没有）
local _seriaDirectDone = false -- 新号开局：已直接进入赛利亚房间（跳过洛兰副本）
local _lastPage = nil -- 最近一次切换的界面页，用于确认当前处于新号开局的黑屏流程
-- 进入赫尔马顿：黑屏转场替换为过场图（实现在文件末尾，这里先声明供 Load 钩子调用）
local _armHmCutscene = nil
local _extendHmCutscene = nil
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
        _G._DFQ_MAP_IS_TOWN = (mapName == "seriaRoom" or mapName == "timeGate" or mapName == "hellmaton" or mapName == "moonlightTavern")
        local _loadT0 = love.timer.getTime()
        if mapName == "hellmaton" and _armHmCutscene then _armHmCutscene() end
        local result = _origLoad(mapName, ...)
        if mapName == "hellmaton" and _extendHmCutscene then
            _extendHmCutscene(love.timer.getTime() - _loadT0)
        end
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

    -- 时空之门右门已改用引擎原生 transport.type="dungeon"（见 article/timeGate/pathgate/right.cfg），
    -- 不再需要劫持 map.init.Make；此前按地图名 lorien 全局拦截会误伤副本内的 make 门
    -- （导致每次进副本后第一个门被弹回副本选择页）
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
            local _prevPage = _lastPage
            _lastPage = page
            if page == "hall" and _gameStarted then
                if _prevPage == "dungeon" and _backTownFn then
                    -- 副本选择页左上返回：角色还站在右门碰撞盒里，hall→main 会让
                    -- type="dungeon" 传送门立刻重触发，死循环弹回选择页；
                    -- 改为回城流程重载真时空之门（出生点远离右门）
                    _G._DFQ_BACK_TO_REAL_TG = true
                    log("Back from dungeon select -> BackTown to real timeGate")
                    return _backTownFn()
                end
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
        _backTownFn = _origBackTown
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

-- 技能槽扩展：技能界面把可放置槽位名 skill1~skill6 硬编码在闭包 upvalue 的列表里，
-- 配置新增的 skill7~10 节点因此不会被拖拽落点判定识别（能显示但拖不进去）。
-- 用 debug.getupvalue 找到该列表并追加后 4 项，不必反编译改字节码。
local _skillSlotPatched = false
local function _patchSkillSlotList()
    if _skillSlotPatched then return end
    local mod = package.loaded["ui.object.advanced.esc.skill.init"]
    if type(mod) ~= "table" then mod = package.loaded["ui.object.advanced.esc.skill"] end
    if type(mod) ~= "table" then return end
    local function extend(fn)
        if type(fn) ~= "function" then return false end
        for i = 1, 60 do
            local name, val = debug.getupvalue(fn, i)
            if not name then return false end
            if type(val) == "table" then
                local hasSkill1, last = false, 0
                for j = 1, #val do
                    local s = val[j]
                    if type(s) == "string" then
                        if s == "skill1" then hasSkill1 = true end
                        local n = tonumber(s:match("^skill(%d+)$"))
                        if n and n > last then last = n end
                    end
                end
                if hasSkill1 and last < 10 then
                    for j = last + 1, 10 do val[#val + 1] = "skill" .. j end
                    return true
                end
            end
        end
        return false
    end
    local hit = false
    for _, fn in pairs(mod) do
        if type(fn) == "function" and extend(fn) then hit = true end
    end
    if hit then
        _skillSlotPatched = true
        log("skill slot list extended to 10")
    end
end

-- 备选技能（技能书仓库）从 5 格扩到 10 格：
-- 技能界面 AdjustList 按 user.bag.skill.max 循环取配置里的 1..max 号格子，
-- 所以把上限改到 10，并给技能书列表补足 10 项，避免空格子取到 nil。
local _skillDepotPatched = false
local function _patchSkillDepot()
    if _skillDepotPatched then return end
    local cfg = package.loaded["config"]
    local u = cfg and cfg.user
    if type(u) ~= "table" then return end
    local bag = u.bag and u.bag.skill
    if type(bag) ~= "table" or type(bag.max) ~= "number" then return end
    if bag.max >= 10 then
        _skillDepotPatched = true
        return
    end
    bag.max = 10
    local lst = bag.list
    if type(lst) == "table" then
        local first = nil
        for i = 1, 20 do
            local v = lst[i]
            if v == nil then break end
            first = first or v
        end
        if first then
            for i = 6, 10 do
                if lst[i] == nil then
                    if type(lst.Add) == "function" then pcall(lst.Add, first)
                    else lst[i] = first end
                end
            end
        end
    end
    _skillDepotPatched = true
    log("skill depot max extended to 10")
end

-- 装备栏容量：引擎在 user.Ctor 里调用 user.bag.New(event, 5, 6, 5, ...)，
-- 武器上限 5 / 道具上限 6 / 技能上限 5 是硬编码的。读档时超出上限的装备会被静默丢弃，
-- 导致移植进来的装备“消失”。这里在构造时把上限放大（技能同步放宽到 10）。
local _bagCapPatched = false
local function _patchBagCapacity()
    if _bagCapPatched then return end
    local ub = package.loaded["user.bag"]
    if type(ub) ~= "table" or type(ub.New) ~= "function" then return end
    local _origNew = ub.New
    ub.New = function(ev, wmax, smax, kmax, ...)
        return _origNew(ev, 40, 12, 10, ...)
    end
    -- 双保险：user.Load 读档前，直接把已建好的 bag 容器上限改大
    local um = package.loaded["user"]
    if type(um) == "table" and type(um.Load) == "function" and not um.__capLoad then
        local _origLoad = um.Load
        um.Load = function(...)
            local cu = package.loaded["config"] and package.loaded["config"].user
            if type(cu) == "table" and type(cu.bag) == "table" then
                if type(cu.bag.weapon) == "table" then cu.bag.weapon.max = 40 end
                if type(cu.bag.suptool) == "table" then cu.bag.suptool.max = 12 end
                if type(cu.bag.skill) == "table" then cu.bag.skill.max = 10 end
            end
            return _origLoad(...)
        end
        um.__capLoad = true
    end
    _bagCapPatched = true
    -- 引擎模块加载时可能已经建好 config.user.bag，这里直接改现存容器
    local cu0 = package.loaded["config"] and package.loaded["config"].user
    if type(cu0) == "table" and type(cu0.bag) == "table" then
        if type(cu0.bag.weapon) == "table" then cu0.bag.weapon.max = 40 end
        if type(cu0.bag.suptool) == "table" then cu0.bag.suptool.max = 12 end
        if type(cu0.bag.skill) == "table" then cu0.bag.skill.max = 10 end
    end
end
_patchBagCapacity()

-- 初始存档自带“血气爆发 / 不动明王阵”：
-- 新档的备选技能仓库（user.bag.skill.list）是空的，技能栏也只有普通攻击等基础项。
-- 玩家对象就绪后把这两个技能补进仓库并自动占用空技能槽；已有存档里已有的不重复添加、不改绑定。
local _initialSkillSeeded = false
local INITIAL_SKILLS = { "swordman/xueqi", "swordman/budong" }
function _seedInitialSkills()
    local cfg = package.loaded["config"]
    local u = cfg and cfg.user
    if type(u) ~= "table" or type(u.player) ~= "table" then return end
    local p = u.player
    if type(p.skills) ~= "table" or type(p.skills.container) ~= "table" then return end
    local resmgr = package.loaded["actor.resmgr"]
    local svc = package.loaded["actor.service.skill"]
    local bag = u.bag and u.bag.skill
    if type(resmgr) ~= "table" or type(resmgr.GetItemData) ~= "function" or type(bag) ~= "table" then return end
    local list = bag.list
    if type(list) ~= "table" or type(list.GetLength) ~= "function" then return end
    for _, path in ipairs(INITIAL_SKILLS) do
        local found = false
        for i = 1, list:GetLength() do
            local e = list:Get(i)
            if type(e) == "table" and e.path == path then found = true break end
        end
        if not found then
            local ok, data = pcall(resmgr.GetItemData, "skill/" .. path)
            if ok and type(data) == "table" then
                local okA, errA = pcall(u.bag.Add, u.bag, data)
                local ok2, r = false, nil
                if type(svc) == "table" and type(svc.Add) == "function" then
                    ok2, r = pcall(svc.Add, p, data)
                end
                log(string.format("initial skill added: %s addOk=%s err=%s bindOk=%s slot=%s len=%d",
                    path, tostring(okA), tostring(errA), tostring(ok2), tostring(r), list:GetLength()))
            else
                log("initial skill add failed: " .. path .. " " .. tostring(data))
            end
        end
    end
    _initialSkillSeeded = true
end

local _saveDbgHooked = false -- 是否已装好存档调试钩子
local _installSaveDebug -- 前置声明，供 love.update 包装内调用
local _origUpdateCb = love.update
if _origUpdateCb then
    love.update = function(dt)
        if not _dungeonGoHooked then _installDungeonGoHook() end
        if not _saveDbgHooked then _installSaveDebug() end
        if not _skillSlotPatched then _patchSkillSlotList() end
        if not _skillDepotPatched then _patchSkillDepot() end
        if not _bagCapPatched then _patchBagCapacity() end
        if not _initialSkillSeeded and _gameStarted then _seedInitialSkills() end
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

-- ── 进入赫尔马顿：把转场黑屏换成过场图 ─────────────────────────────
-- 引擎跨地图时用 graphics.curtain 铺满纯黑幕布做转场。这里在 map.init.Load("hellmaton")
-- 前后点亮一个时间窗，在 love.draw 最上层用 cover 方式铺满过场图（800x600 原图），
-- 窗口结束时淡出，恢复游戏画面；其他地图/页面切换不受影响。
local _hmFrom, _hmUntil = 0, 0
local _hmImg, _hmTried = nil, false

local function _getHmImage()
    if _hmTried then return _hmImg end
    _hmTried = true
    local ok, img = pcall(love.graphics.newImage, "asset/image2/ui/cutscene/hendonmyre.png")
    if ok and img then
        _hmImg = img
        log("Hendon Myre cutscene image loaded " .. tostring(img:getWidth()) .. "x" .. tostring(img:getHeight()))
    else
        log("Hendon Myre cutscene image FAILED: " .. tostring(img))
    end
    return _hmImg
end

function _armHmCutscene()
    local now = love.timer.getTime()
    _hmFrom = now
    _hmUntil = now + 0.1 -- 加载期间的保底；加载结束后由 _extendHmCutscene 延长
end

function _extendHmCutscene(loadDur)
    local now = love.timer.getTime()
    -- 覆盖“加载完成后的黑幕淡出”约 0.9 秒
    _hmUntil = math.max(_hmUntil, now + 0.9)
    log(string.format("Hendon Myre cutscene window %.0fms (load %.0fms)", (_hmUntil - _hmFrom) * 1000, (loadDur or 0) * 1000))
end

-- 转场时序日志：确认 map.Load 是否发生在 director.Curtain 同步调用内
do
    local d = package.loaded["director"]
    if type(d) == "table" and type(d.Curtain) == "function" and not d.__hmCurtainDbg then
        local oc = d.Curtain
        d.Curtain = function(...)
            local t0 = love.timer.getTime()
            log("Curtain begin")
            local r = oc(...)
            log(string.format("Curtain end (%.0fms)", (love.timer.getTime() - t0) * 1000))
            return r
        end
        d.__hmCurtainDbg = true
    end
end

local _origDrawCb = love.draw
if _origDrawCb then
    love.draw = function()
        _origDrawCb()
        local now = love.timer.getTime()
        if now >= _hmUntil then return end
        local img = _getHmImage()
        if not img then return end
        local a = 1
        local fadeIn = 0.12
        if now - _hmFrom < fadeIn then a = (now - _hmFrom) / fadeIn end
        local fadeOut = 0.25
        local remain = _hmUntil - now
        if remain < fadeOut then a = math.min(a, remain / fadeOut) end
        if a < 0 then a = 0 end

        if IS_LOVE11 then love.graphics.push("all") else love.graphics.push() end
        local sx, sy, sw2, sh2 = love.graphics.getScissor()
        love.graphics.setScissor()
        love.graphics.setShader()
        love.graphics.setBlendMode("alpha")
        love.graphics.origin()
        local w, h = love.graphics.getDimensions()
        local iw, ih = img:getWidth(), img:getHeight()
        local s = math.max(w / iw, h / ih)
        local dw, dh = iw * s, ih * s
        love.graphics.setColor(1, 1, 1, a)
        love.graphics.draw(img, (w - dw) / 2, (h - dh) / 2, 0, s, s)
        love.graphics.setColor(1, 1, 1, 1)
        if sx then love.graphics.setScissor(sx, sy, sw2, sh2) end
        love.graphics.pop()
    end
    log("love.draw wrapped for Hendon Myre cutscene")
end
