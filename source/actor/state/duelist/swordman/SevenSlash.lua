--[[
	desc: SevenSlash, a state of Swordman.
	author: Musoucrow
	since: 2018-12-18
	alter: 2026-8-1
]]--
    local Sound          = require("lib.sound")
    local Factory        = require("actor.factory")
    local Aspect         = require("actor.service.aspect")
    local State          = require("actor.service.state")
    local Input          = require("actor.service.input")
    local Motion         = require("actor.service.motion")  
    local Easemove       = require("actor.gear.easemove")
    local Attack         = require("actor.gear.attack")
    local BattleJudge    = require("actor.ai.battleJudge")
    local Base           = require("actor.state.base")
    local class          = require("core.class")
    local MAX_PROCESS    = 7          -- 七段
    local SevenSlash = class(Base)
    ---------------------------------------------------------------------
    -- 构造
    ---------------------------------------------------------------------
    function SevenSlash:Ctor(data, ...)
        Base.Ctor(self, data, ...)
        self._easemoveParams = data.easemove
        self._keyFrame       = data.keyFrame or {}
    end

    ---------------------------------------------------------------------
    -- 初始化
    ---------------------------------------------------------------------
    function SevenSlash:Init(entity)
        Base.Init(self, entity)
        self._attack   = Attack.New(entity)
        self._easemove = Easemove.New(entity.transform, entity.aspect)
        self._judgeAiBack  = BattleJudge.New(entity, self._colliderDataSet[2])
        self._judgeAiFront = BattleJudge.New(entity, self._colliderDataSet[1])
    end

    ---------------------------------------------------------------------
    -- 主更新
    ---------------------------------------------------------------------
    function SevenSlash:NormalUpdate(dt, rate)
        local main  = Aspect.GetPart(self._entity.aspect)
        local tick  = main:GetTick()

        self._easemove:Update(rate)
        self._attack:Update()

        -- 关键帧（绝对数字）
        local kf = (type(self._keyFrame) == "table"
                    and (self._keyFrame[self._process] or 0))
                    or  (tonumber(self._keyFrame) or 0)

        -- 到点检测碰撞 + 输入
        if tick >= kf then
            local frontHit = self._judgeAiFront:Tick()
            local backHit  = self._judgeAiBack:Tick()
            if frontHit or backHit then
                local keyFront, keyBack = Input.GetKeyWithDirection(self._entity.transform.direction)
                self._directionKey = frontHit and keyFront or keyBack
            end
        end

        -- 实时按住方向键（方向盘左右）
        if self._directionKey then
            Input.Press(self._entity.input, self._directionKey)
        end

        -- 连段
        if self._hasPressed and tick >= kf and self._process < MAX_PROCESS then
            self:SetProcess(self._process + 1)
        end

        if main:TickEnd() then
            State.Play(self._entity.states, self._nextState)
        end
    end

    ---------------------------------------------------------------------
    -- 进入
    ---------------------------------------------------------------------
    function SevenSlash:Enter(lastState, skill)
        if lastState ~= self then
            Base.Enter(self)
            self._skill = skill
            self._easemove:Exit()
            self._judgeAiBack.key  = skill:GetKey()
            self._judgeAiFront.key = skill:GetKey()
            self:SetProcess(1)
        else
            self._hasPressed = true
        end
    end

    ---------------------------------------------------------------------
    -- 退出
    ---------------------------------------------------------------------
    function SevenSlash:Exit(nextState)
        if nextState == self then return end
        self._skill:CoolDown()
        Base.Exit(self, nextState)
        if self._moveEffect then
            self._moveEffect.identity.destroyProcess = 1
            self._moveEffect = nil
        end
    end

    ---------------------------------------------------------------------
    -- 切换段数
    ---------------------------------------------------------------------
    function SevenSlash:SetProcess(process)
        self._process      = process
        self._directionKey = nil
        self._hasPressed   = false

        -- 转向（方向盘）
        Motion.TurnDirection(self._entity.transform, self._entity.input)

        if process < MAX_PROCESS then
            self._skill:Reset()
        end

        self:EnterAttack()
        Aspect.Play(self._entity.aspect, self._frameaniDataSets[process], false)
    end

    ---------------------------------------------------------------------
    -- 生成攻击
    ---------------------------------------------------------------------
    function SevenSlash:EnterAttack()
        local transform = self._entity.transform
        local attackData = {
            x = transform.position.x,
            y = transform.position.y,
            z = transform.position.z,
            direction = transform.direction,
            entity    = self._entity
        }

        -- 资源检查
        local slashData = self._actorDataSet.slash[self._process]
        if not slashData then
            printWarn("SevenSlash 第"..self._process.."段缺少 slash 资源")
            return
        end

        -- 攻击判定
        self._attack:Enter(
            self._attackDataSet[self._process],
            self._skill.attackValues[1],
            nil, nil, true
        )

        -- 特效 & 音效
        local slashObj = Factory.New(slashData, attackData)
        Sound.Play(self._soundDataSet.voice[self._process])
        Sound.Play(self._soundDataSet.swing[self._process])

        -- 位移特效
        local moveIdx = (self._process == 1 or self._process == MAX_PROCESS) and 1 or 2
        self._moveEffect = Factory.New(self._actorDataSet.move[moveIdx], attackData)

        -- 位移
        local ep = self._easemoveParams
        self._easemove:Enter("x", ep.power, ep.speed, transform.direction)

        -- 碰撞绑定
        self._attack.collision[Aspect.GetPart(slashObj.aspect)] = "attack"
    end

    return SevenSlash