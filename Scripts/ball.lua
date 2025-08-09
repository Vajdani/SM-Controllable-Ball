Line_ball = class()
local up = sm.vec3.new(0,0,1)
function Line_ball:init( thickness, colour )
    self.effect = sm.effect.createEffect("ShapeRenderable")
	self.effect:setParameter("uuid", sm.uuid.new("628b2d61-5ceb-43e9-8334-a4135566df7a"))
    self.effect:setParameter("color", colour)
    self.effect:setScale( sm.vec3.one() * thickness )

    self.thickness = thickness
	self.spinTime = 0
end

---@param startPos Vec3
---@param endPos Vec3
---@param dt number
---@param spinSpeed number
function Line_ball:update( startPos, endPos, dt, spinSpeed )
	local delta = endPos - startPos
    local length = delta:length()

    if length < 0.0001 then
        --sm.log.warning("Line_ball:update() | Length of 'endPos - startPos' must be longer than 0.")
        return
	end

	local rot = sm.vec3.getRotation(up, delta)
	local deltaTime = dt or 0
	local speed = spinSpeed or 0
	self.spinTime = self.spinTime + deltaTime * speed
	rot = rot * sm.quat.angleAxis( math.rad(self.spinTime), up )

	local distance = sm.vec3.new(self.thickness, self.thickness, length)

	self.effect:setPosition(startPos + delta * 0.5)
	self.effect:setScale(distance)
	self.effect:setRotation(rot)

    if not self.effect:isPlaying() then
        self.effect:start()
    end
end


---@class Ball : ShapeClass
Ball = class()
--Ball.slamCoolDownTicks = 4 * 40
--Ball.slamRadius = 5

dofile "$SURVIVAL_DATA/Scripts/game/util/Timer.lua"
dofile "$SURVIVAL_DATA/Scripts/game/survival_projectiles.lua"
dofile "$SURVIVAL_DATA/Scripts/util.lua"

local vec3_up = sm.vec3.new(0,0,1)
local forceAdjust = sm.vec3.new(0,0,0.25)
local onGroundAdjust = sm.vec3.new(0,0,1.5)
local inAirForceMultiplier = 0.1
local boostCoolDownTicks = 2 * 40
local minDestroyVelocity = 10
local grapplePullStart = 5^2
local maxGrapplePullLength = 5^2

function Ball:server_onCreate()
    self.sv = {}
    self.sv.controls = { false, false, false, false }
    self.sv.controller = nil
    --self.sv.slamming = false
    --self.sv.slamImpulse = sm.vec3.zero()
    self.sv.grappleTarget = nil


    self.shape.body:setDestructable( true )
end

function Ball:sv_updatePlayerControls( controls )
    self.sv.controls = controls
end

function Ball:sv_onInteract( player )
    if not player then
        --self.sv.slamming = false
        --self.sv.slamImpulse = sm.vec3.zero()

        self.sv.controller.character:setWorldPosition( self.shape.worldPosition + vec3_up * 1.5 )
    end
    self.sv.controller = player
    self.sv.grappleTarget = nil

    self.network:sendToClients( "cl_onInteract", player )
end

function Ball:server_onFixedUpdate()
    if self.sv.controller == nil then return end

    local shape = self.shape
    local mass = shape.mass
    ---@type Vec3
    local pos = shape.worldPosition
    local onGround, rayResult = self:isOnGround()
    --[[
    if self.sv.slamming then
        sm.physics.applyImpulse( shape, self.sv.slamImpulse, true )

        if onGround then
            local objs = sm.physics.getSphereContacts( pos, self.slamRadius )
            for k, obj in pairs(objs.bodies) do
                if obj ~= shape.body then
                    ---@type Vec3
                    local objPos = obj:getCenterOfMassPosition()
                    sm.physics.applyImpulse( obj, (pos - objPos):normalize() * 25, true )
                end
            end

            for k, obj in pairs(objs.characters) do
                ---@type Vec3
                local objPos = obj.worldPosition
                sm.physics.applyImpulse( obj, ((objPos - pos):normalize() + vec3_up * 2) * obj.mass * 10, true )
            end

            self.sv.slamImpulse = sm.vec3.zero()
            self.sv.slamming = false
        end
    end
    ]]

    if self.sv.grappleTarget and self:targetExists( self.sv.grappleTarget ) then
        ---@type Vec3
        local targetPos = self:getTargetPos( self.sv.grappleTarget )
        local dir = targetPos - pos

        if dir:length2() >= grapplePullStart then
            ---@type Vec3
            targetPos = targetPos - dir:normalize() * 5
            dir = targetPos - pos
            if dir:length2() > maxGrapplePullLength then dir = dir:normalize() * 2.5 end

            local vel = shape.velocity; vel.z = vel.z * 0.15
            sm.physics.applyImpulse( shape, ((dir * 2) - (vel * 0.3)) * mass * 0.1, true )
        end
    elseif self.sv.grappleTarget ~= nil then
        self:sv_setGrappleTarget( nil )
    end

    ---@type Character
    local char = self.sv.controller.character
    if not char then return end

	local lookDir = self.sv.grappleTarget and (self:getTargetPos( self.sv.grappleTarget ) - pos):normalize() or char:getDirection()
    local camUp = lookDir:rotate(math.rad(90), lookDir:cross(vec3_up))
    local right = lookDir:cross(camUp)

    local input_fwd = BoolToVal(self.sv.controls[3]) - BoolToVal(self.sv.controls[4])
    local input_right = BoolToVal(self.sv.controls[2]) - BoolToVal(self.sv.controls[1])
    local moveDir = right * input_right + (onGround and rayResult.normalWorld:cross(right) or vec3_up:cross(right)) * input_fwd

    if not onGround and not self.sv.grappleTarget then
        moveDir = moveDir * inAirForceMultiplier
    end

    if moveDir ~= sm.vec3.zero() then
        sm.physics.applyImpulse( shape, moveDir * mass / 6 - forceAdjust, true )
    end
end

function Ball:server_onCollision( other, position, selfPointVelocity, otherPointVelocity, normal )
    local velocity = self.shape.velocity:length() + 1
    if velocity < minDestroyVelocity or not isAnyOf(type(other), { "Shape", "Character" }) then return end

    sm.physics.explode(
        position,
        velocity / 2,
        velocity / 7.5,
        velocity / 5,
        5 * velocity,
        "PropaneTank - ExplosionSmall",
        self.shape
    )
end

function Ball:sv_jump()
    sm.physics.applyImpulse( self.shape, vec3_up * 10 * self.shape.mass, true )
end

function Ball:sv_boost()
    local dir = self.sv.controller.character.direction
	local camUp = dir:rotate(math.rad(90), dir:cross(vec3_up))
    sm.physics.applyImpulse( self.shape, vec3_up:cross(dir:cross(camUp)) * 50 * self.shape.mass - forceAdjust, true )
    sm.effect.playEffect("PropaneTank - ExplosionSmall", self.shape.worldPosition)
end

--[[
function Ball:sv_slam()
    local speed = 1
    ---@type Vec3
    local pos = self.shape.worldPosition
    local hit, result = sm.physics.spherecast( pos, pos - sm.vec3.new(0,0,2500), 0.5, self.shape.body )
    if hit then
        speed = (result.pointWorld - pos):length()
    end

    sm.effect.playEffect("PropaneTank - ExplosionSmall", self.shape.worldPosition)
    self.sv.slamImpulse = -vec3_up * speed * self.shape.mass
    self.sv.slamming = true
end
]]

function Ball:sv_setGrappleTarget( target )
    self.sv.grappleTarget = target
    self.network:sendToClients("cl_setGrappleTarget", target)
end


function Ball:client_onCreate()
    self.cl = {}
    self.cl.occupied = false
    self.cl.controller = nil
    self.cl.grappleTarget = nil
    self.cl.grappleLine = Line_ball()
    self.cl.grappleLine:init( 0.1, sm.color.new(0,0,0) )

    self.cl.controllerNameTag = sm.gui.createNameTagGui()
    self.cl.controllerNameTag:setRequireLineOfSight( false )
    self.cl.controllerNameTag:setMaxRenderDistance( 10000 )

    self.cl.controls = { false, false, false, false }

    self.cl.glow = 0.0
	self.cl.effect = sm.effect.createEffect( "Ball", self.interactable )
	self.cl.effect:start()

    self.cl.boostTimer = Timer()
    self.cl.boostTimer:start( boostCoolDownTicks )

    --self.cl.slamTimer = Timer()
    --self.cl.slamTimer:start( self.slamCoolDownTicks )

    self.cl.zoom = 1
end

function Ball:client_canInteract()
    local canEnter = not self.cl.occupied
    if canEnter then
        sm.gui.setInteractionText(
            "Move: "..sm.gui.getKeyBinding("Forward", true)..sm.gui.getKeyBinding("StrafeLeft", true)..sm.gui.getKeyBinding("Backward", true)..sm.gui.getKeyBinding("StrafeRight", true),
            "\tJump: "..sm.gui.getKeyBinding("Jump", true),
            "\tBoost: "..sm.gui.getKeyBinding("Create", true),
            "\tGrapple: "..sm.gui.getKeyBinding("Attack", true) --Slam
        )
        sm.gui.setInteractionText(
            "Adjust Zoom: "..sm.gui.getKeyBinding("NextMenuItem", true).."/"..sm.gui.getKeyBinding("PreviousMenuItem", true),
            "\t"..sm.gui.getKeyBinding( "Use", true ),
            "Enter/Exit Ball"
        )
    elseif self.cl.controller ~= sm.localPlayer.getPlayer() then
        sm.gui.setInteractionText(
            "<p textShadow='false' bg='gui_keybinds_bg_orange' color='#ff0000' spacing='9'>Ball is occupied</p>"
        )
    end

    return canEnter
end

function Ball:client_onInteract( char, state )
    if not state then return end

    sm.audio.play("Blueprint - Build", sm.camera.getPosition())
    sm.gui.displayAlertText("Entered Ball", 2.5)
    sm.camera.setCameraState( 3 )
    sm.camera.setFov( sm.camera.getDefaultFov() )
    self.interactable:setSubMeshVisible("lambert1", self.cl.zoom ~= 0)

    local player = sm.localPlayer.getPlayer()
    player.character:setLockingInteractable(self.interactable)
    self.network:sendToServer( "sv_onInteract", player )
end

function Ball:cl_onInteract( controller )
    self.cl.occupied = controller ~= nil

    local player = sm.localPlayer.getPlayer()
    if self.cl.occupied then
        if player ~= controller then
            controller.character:setNameTag("")
            self.cl.controllerNameTag:setText("Text", controller.name )
        else
            self.cl.controllerNameTag:setText("Text", "You!\n   v" )
        end
        self.cl.controllerNameTag:open()
    else
        if player ~= self.cl.controller then
            self.cl.controller.character:setNameTag(self.cl.controller.name)
        end
        self.cl.controllerNameTag:close()
    end

    self.cl.controller = controller
    self.cl.grappleTarget = nil
    self.cl.grappleLine.effect:stop()
end

function Ball:client_onAction( action, state )
    if self.cl.controls[action] ~= nil then
        self.cl.controls[action] = state
        self.network:sendToServer("sv_updatePlayerControls", self.cl.controls)
    end

    if not state then return true end

    local onGround = self:isOnGround()
    if action == 15 then
        sm.audio.play("Blueprint - Delete", sm.camera.getPosition())
        sm.gui.displayAlertText("Exited Ball", 2.5)
        sm.gui.startFadeToBlack( 0.1, 0.5 )
        sm.camera.setCameraState( 0 )
        sm.localPlayer.getPlayer().character:setLockingInteractable(nil)
        self.interactable:setSubMeshVisible("lambert1", true)
        self.network:sendToServer( "sv_onInteract", nil )
    elseif action == 16 and onGround then
        self.network:sendToServer( "sv_jump" )
    elseif action == 18 then --[[and self.cl.slamTimer:done() and not onGround then
        self.network:sendToServer( "sv_slam" )
        self.cl.slamTimer:reset()]]

        if self.cl.grappleTarget then
            self.network:sendToServer("sv_setGrappleTarget", nil)
            sm.gui.displayAlertText("#ff0000Grapple target reset!", 2.5)
            sm.audio.play("Blueprint - Camera", sm.camera.getPosition())
            return true
        end

        local pos = sm.camera.getPosition()
        local hit, result = sm.physics.spherecast(
            pos,
            pos + sm.camera.getDirection() * 100,
            0.5,
            self.shape.body,
            1 + 2 + 4 + 8 + 128 + 256 + 512
        )

        if not hit or isAnyOf(result.type, { "limiter", "areaTrigger" }) then return true end

        local target = result:getShape() or result:getCharacter() or result.pointWorld
        local final = target
        if type(target) == "Shape" then
            final = {
                shape = target,
                hitPos = target:transformPoint(result.pointWorld)
            }
        end
        self.network:sendToServer("sv_setGrappleTarget", final)
        sm.gui.displayAlertText("#00ff00Grapple target acquired!", 2.5)
        sm.audio.play("Blueprint - Camera", sm.camera.getPosition())
    elseif action == 19 and self.cl.boostTimer:done() then
        self.network:sendToServer( "sv_boost" )
        self.cl.boostTimer:reset()
    elseif action == 20 and self.cl.zoom ~= 0 then
        self.cl.zoom = sm.util.clamp(self.cl.zoom - 1, 0, 10)
        if self.cl.zoom == 0 then
            self.interactable:setSubMeshVisible("lambert1", false)
            sm.gui.startFadeToBlack( 0.1, 0.5 )
            sm.audio.play("Blueprint - Open", sm.camera.getPosition())
        end
        sm.gui.displayAlertText(string.format("Zoom Level:#df7f00 %s", self.cl.zoom), 2.5)
    elseif action == 21 and self.cl.zoom ~= 10 then
        self.cl.zoom = sm.util.clamp(self.cl.zoom + 1, 0, 10)
        if self.cl.zoom == 1 then
            self.interactable:setSubMeshVisible("lambert1", true)
            sm.gui.startFadeToBlack( 0.1, 0.5 )
            sm.audio.play("Blueprint - Close", sm.camera.getPosition())
        end
        sm.gui.displayAlertText(string.format("Zoom Level:#df7f00 %s", self.cl.zoom), 2.5)
    end

    return true
end

function Ball:client_onUpdate( dt )
    self.cl.glow = self.cl.glow + dt
	self.interactable:setGlowMultiplier( math.abs( math.sin( self.cl.glow ) ) * 0.8 + 0.2 );
	self.cl.effect:setParameter( "Velocity_max_50", self.shape:getBody():getAngularVelocity():length() )

    self.cl.boostTimer:tick()
    --self.cl.slamTimer:tick()

    local player = sm.localPlayer.getPlayer()
    local currentPos = sm.camera.getPosition()
    local currentDir = sm.camera.getDirection()
    if self.cl.occupied then
        local shapePos = self.shape.worldPosition
        ---@type Character
        local char = self.cl.controller.character

        if self.cl.controller == player then
            if player.character:isTumbling() then
                sm.audio.play("Blueprint - Delete", sm.camera.getPosition())
                sm.gui.displayAlertText("Exited Ball", 2.5)
                sm.gui.startFadeToBlack( 0.1, 0.5 )
                sm.camera.setCameraState( 0 )
                sm.localPlayer.getPlayer().character:setLockingInteractable(nil)
                self.network:sendToServer( "sv_onInteract", nil )
                return
            end

            local dir = char.direction
            local newPos = self.cl.zoom == 0 and shapePos or shapePos + vec3_up * 2 - (dir * 2) * self.cl.zoom
            local hit, result = sm.physics.spherecast( shapePos, newPos, 0.1, self.shape.body )

            local lerpVal = dt * 10
            local camPos = sm.vec3.lerp( currentPos, hit and result.pointWorld + dir or newPos, lerpVal )
            sm.camera.setPosition( camPos )
            sm.camera.setDirection( sm.vec3.lerp( currentDir, dir, lerpVal ) )

            self.cl.controllerNameTag:setWorldPosition( char.worldPosition + vec3_up, char:getWorld() )

            if self.cl.zoom > 0 then
                self.interactable:setSubMeshVisible("lambert1", (shapePos - camPos):length2() >= 0.5)
            end
        else
            self.cl.controllerNameTag:setWorldPosition( shapePos + vec3_up, char:getWorld() )
        end
    elseif sm.camera.getCameraState() == 0 then
        sm.camera.setPosition( currentPos )
        sm.camera.setDirection( currentDir )
    end


    if self.cl.grappleTarget and self:targetExists( self.cl.grappleTarget ) then
        local endPos = self:getTargetPos( self.cl.grappleTarget )
        local startPos = (self.cl.controller == player and self.cl.zoom == 0) and currentPos + currentDir or self.shape.worldPosition

        self.cl.grappleLine:update( startPos, endPos )
    elseif self.cl.grappleLine.effect:isPlaying() then
        self.cl.grappleLine.effect:stop()
    end
end

function Ball:cl_setGrappleTarget( target )
    self.cl.grappleTarget = target
end

function Ball:client_onDestroy()
    local player = sm.localPlayer.getPlayer()
    if self.cl.controller then
        if self.cl.controller == player then
            player.character:setLockingInteractable( nil )
            sm.camera.setCameraState( 0 )
        else
            self.cl.controller.character:setNameTag(self.cl.controller.name)
        end
    end

    self.cl.controllerNameTag:destroy()
    self.cl.grappleLine.effect:destroy()
end



function Ball:isOnGround()
    local pos = self.shape.worldPosition
    return sm.physics.spherecast( pos, pos - onGroundAdjust, 0.5, self.shape.body )
end

function Ball:getTargetPos( target )
    local type = type(target)
    if type == "Vec3" then
        return target
    elseif type == "Character" then
        return target.worldPosition
    elseif type == "table" then
        return target.shape:transformLocalPoint(target.hitPos)
    end
end

function Ball:targetExists( target )
    if type(target) == "table" then
        return sm.exists(target.shape)
    else
        return sm.exists(target)
    end
end

function BoolToVal( bool )
    return bool and 1 or 0
end