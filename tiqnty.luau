
-- Discord: tiqnty | Roblox: Venttex30

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local spider = ReplicatedStorage:WaitForChild("Spider"):Clone()
local body = spider:WaitForChild("Body")
local pathFolder = workspace:WaitForChild("Path")
spider.Parent = workspace

-- segment lengths come off the rig itself
local upperLen = spider:WaitForChild("Upper1").Size.Z
local lowerLen = spider:WaitForChild("Lower1").Size.Z

local stepHeight = 2
local stepTime = 0.16
local stepTrigger = 1.2 -- foot drift before a step
local leadFactor = 1.6
local moveSpeed = 14
local turnLerp = 6
local heightLerp = 7
local tiltLerp = 5
local arriveDist = 5
local probeDist = 5 -- lookahead for missing ground
local maxJump = 22
local crouchTime = 0.32
local crouchDip = 2.2 -- crouch depth
local jumpArc = 4

local waypoints = {}
while true do
	local point = pathFolder:WaitForChild("P"..(#waypoints + 1), 2)
	if not point then
		break
	end
	waypoints[#waypoints + 1] = point.Position
end
assert(#waypoints >= 2, "Path needs at least P1 and P2")

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
rayParams.FilterDescendantsInstances = {spider, pathFolder}

-- keep characters out of the leg rays
local function watchPlayer(pl)
	pl.CharacterAdded:Connect(function(char)
		rayParams:AddToFilter(char)
	end)
	if pl.Character then
		rayParams:AddToFilter(pl.Character)
	end
end
Players.PlayerAdded:Connect(watchPlayer)
for _, pl in ipairs(Players:GetPlayers()) do
	watchPlayer(pl)
end

-- cast from above, feet can end up under slopes mid step
local function groundBelow(pos)
	local hit = workspace:Raycast(pos + Vector3.new(0, 20, 0), Vector3.new(0, -60, 0), rayParams)
	if hit then
		return hit.Position, hit.Normal
	end
	return nil
end

-- per leg state: rest/hip offsets, the planted foot and its ground normal,
-- step progress, and the parts that draw it
local Leg = {}
Leg.__index = Leg

function Leg.new(restLocal, hipLocal)
	return setmetatable({
		restLocal = restLocal,
		hipLocal = hipLocal,
		foot = Vector3.zero,
		groundY = 0,
		normal = Vector3.yAxis,
		group = 1,
		ring = 0,
		stepping = false,
		t = 0,
		from = Vector3.zero,
		to = Vector3.zero,
		toN = Vector3.yAxis,
	}, Leg)
end

function Leg:startStep(target, n)
	self.stepping = true
	self.t = 0
	self.from = self.foot
	self.to = target
	self.toN = n
	self.groundY = target.Y
end

function Leg:update(dt)
	if not self.stepping then
		return false
	end
	self.t += dt / stepTime
	if self.t >= 1 then
		self.stepping = false
		self.foot = self.to
		self.normal = self.toN
		return false
	end
	-- sine arc to clear edges
	local flat = self.from:Lerp(self.to, self.t)
	self.foot = flat + Vector3.new(0, math.sin(self.t * math.pi) * stepHeight, 0)
	return true
end

-- leg layout comes from how the rig is posed. Hip1-6 are attachments on the
-- body, so their Position is already a local offset
local legs = {}
for i = 1, 6 do
	local foot = spider:WaitForChild("Foot"..i)
	local leg = Leg.new(body.CFrame:PointToObjectSpace(foot.Position), body:WaitForChild("Hip"..i).Position)
	leg.ring = (math.deg(math.atan2(-leg.restLocal.X, -leg.restLocal.Z)) + 360) % 360
	leg.upperPart = spider:WaitForChild("Upper"..i)
	leg.lowerPart = spider:WaitForChild("Lower"..i)
	leg.tipPart = foot
	legs[i] = leg
end
local rideHeight = -legs[1].restLocal.Y

-- split tripods by angle, not index, or adjacent legs swing together
local ring = table.clone(legs)
table.sort(ring, function(x, y)
	return x.ring < y.ring
end)
for i, leg in ipairs(ring) do
	leg.group = i % 2 == 1 and 1 or 2
end

-- law of cosines for the knee
local function solveKnee(hip, foot)
	local toFoot = foot - hip
	if toFoot.Magnitude < 0.01 then
		return hip - Vector3.new(0, upperLen, 0)
	end
	local dir = toFoot.Unit
	local d = math.clamp(toFoot.Magnitude, math.abs(upperLen - lowerLen) + 0.05, upperLen + lowerLen - 0.05)
	local ang = math.acos(math.clamp((upperLen^2 + d^2 - lowerLen^2) / (2 * upperLen * d), -1, 1))
	local axis = dir:Cross(Vector3.yAxis)
	if axis.Magnitude < 1e-4 then
		axis = Vector3.xAxis -- leg pointing straight up/down
	end
	axis = axis.Unit
	local a = hip + (CFrame.fromAxisAngle(axis, ang) * dir) * upperLen
	local b = hip + (CFrame.fromAxisAngle(axis, -ang) * dir) * upperLen
	-- mirror solutions, knee goes up
	if a.Y >= b.Y then
		return a
	end
	return b
end

-- avg ground height under the planted feet
local function avgGroundY()
	local sum = 0
	for _, leg in ipairs(legs) do
		sum += leg.groundY
	end
	return sum / #legs
end

-- scan ahead for somewhere to land, a few studs past the near edge when possible
local function findLanding(fromPos, dir, fromY)
	for d = probeDist + 2, maxJump do
		local g = groundBelow(fromPos + dir * d)
		if g and math.abs(g.Y - fromY) < 4 then
			local far = groundBelow(fromPos + dir * (d + 4))
			if far and math.abs(far.Y - g.Y) < 2 then
				return far
			end
			return g
		end
	end
	return nil
end

local bodyPos = Vector3.new(0, 4, 0)
local facing = Vector3.new(0, 0, -1)
local upVec = Vector3.yAxis
local activeGroup = 1
local swinging = false
local wpIndex = 2
local state = "walk"
local stateT = 0
local jumpFrom = Vector3.zero
local jumpTo = Vector3.zero
local jumpDur = 0.6

-- lookAt wants a forward thats actually perpendicular to up
local function bodyCFrame(pos, heading, up)
	local right = heading:Cross(up)
	if right.Magnitude < 1e-3 then
		right = Vector3.xAxis
	end
	right = right.Unit
	return CFrame.lookAt(pos, pos + up:Cross(right).Unit, up)
end

local function alpha(rate, dt)
	return math.clamp(rate * dt, 0, 1)
end

-- initial pose at P1
local start = waypoints[1]
local startGround = groundBelow(start)
if startGround then
	bodyPos = startGround + Vector3.new(0, rideHeight, 0)
end
facing = Vector3.new(waypoints[2].X - start.X, 0, waypoints[2].Z - start.Z).Unit
local startCf = bodyCFrame(bodyPos, facing, upVec)
for _, leg in ipairs(legs) do
	local rest = startCf:PointToWorldSpace(leg.restLocal)
	local p, n = groundBelow(rest)
	leg.foot = p or rest
	leg.groundY = leg.foot.Y
	leg.normal = n or Vector3.yAxis
end

local function drawBone(part, a, b)
	part.Size = Vector3.new(part.Size.X, part.Size.Y, math.max((b - a).Magnitude, 0.05))
	part.CFrame = CFrame.lookAt((a + b) / 2, b)
end

-- walk >> crouch >> air >> walk. walk owns the path and the gait, crouch folds
-- down with the feet still planted, air carries the body over the gap
RunService.Heartbeat:Connect(function(dt)
	local target = waypoints[wpIndex]
	local toWp = Vector3.new(target.X - bodyPos.X, 0, target.Z - bodyPos.Z)
	local dir = toWp.Magnitude > 0.01 and toWp.Unit or facing

	if state == "walk" then
		facing = facing:Lerp(dir, alpha(turnLerp, dt))
		facing = Vector3.new(facing.X, 0, facing.Z).Unit

		-- height from ground, not from feet, those arc during steps
		local footY = avgGroundY()
		local moved = bodyPos + facing * moveSpeed * dt
		bodyPos = Vector3.new(moved.X, bodyPos.Y + (footY + rideHeight - bodyPos.Y) * alpha(heightLerp, dt), moved.Z)

		if toWp.Magnitude < arriveDist then
			wpIndex = wpIndex % #waypoints + 1
		end

		-- gap check, skip while turning
		if facing:Dot(dir) > 0.9 then
			local ahead = groundBelow(bodyPos + facing * probeDist)
			if not ahead or footY - ahead.Y > 4 then
				local landing = findLanding(bodyPos, facing, footY)
				if landing then
					state = "crouch"
					stateT = 0
					jumpTo = landing + Vector3.new(0, rideHeight, 0)
					jumpDur = math.clamp((landing - bodyPos).Magnitude / 24, 0.45, 0.8)
				end
			end
		end
	elseif state == "crouch" then
		-- crouch, feet stay planted
		stateT += dt / crouchTime
		local dipY = avgGroundY() + rideHeight - crouchDip * math.min(stateT, 1)
		bodyPos = Vector3.new(bodyPos.X, bodyPos.Y + (dipY - bodyPos.Y) * alpha(14, dt), bodyPos.Z)
		if stateT >= 1 then
			state = "air"
			stateT = 0
			jumpFrom = bodyPos
		end
	elseif state == "air" then
		stateT += dt / jumpDur
		local t = math.min(stateT, 1)
		local flat = jumpFrom:Lerp(jumpTo, t)
		bodyPos = flat + Vector3.new(0, jumpArc * 4 * t * (1 - t), 0)
		if stateT >= 1 then
			-- land slightly low, body springs back
			bodyPos = jumpTo - Vector3.new(0, 1, 0)
			local landCf = bodyCFrame(bodyPos, facing, Vector3.yAxis)
			local landGroundY = jumpTo.Y - rideHeight
			for _, leg in ipairs(legs) do
				local rest = landCf:PointToWorldSpace(leg.restLocal)
				local p, n = groundBelow(rest)
				if p and math.abs(p.Y - landGroundY) < 4 then
					leg.foot = p
					leg.normal = n
					leg.groundY = p.Y
				else
					-- rear spots can still hang over the gap
					leg.foot = rest
					leg.normal = Vector3.yAxis
					leg.groundY = landGroundY
				end
				leg.stepping = false
			end
			swinging = false
			state = "walk"
		end
	end

	local nsum = Vector3.zero
	for _, leg in ipairs(legs) do
		nsum += leg.normal
	end
	upVec = upVec:Lerp(nsum.Magnitude > 0 and nsum.Unit or Vector3.yAxis, alpha(tiltLerp, dt)).Unit

	local cf = bodyCFrame(bodyPos, facing, upVec)
	body.CFrame = cf

	if state == "walk" then
		local busy = false
		for _, leg in ipairs(legs) do
			if leg:update(dt) then
				busy = true
			end
		end
		if swinging and not busy then
			swinging = false
		end
		-- swing the other tripod once something drifted far enough
		if not swinging then
			local worst = 0
			for _, leg in ipairs(legs) do
				local rest = cf:PointToWorldSpace(leg.restLocal)
				local d = (Vector3.new(leg.foot.X, 0, leg.foot.Z) - Vector3.new(rest.X, 0, rest.Z)).Magnitude
				if d > worst then
					worst = d
				end
			end
			if worst > stepTrigger then
				activeGroup = 3 - activeGroup
				local lead = facing * (moveSpeed * stepTime * leadFactor)
				local groundLevel = avgGroundY()
				for _, leg in ipairs(legs) do
					if leg.group == activeGroup then
						-- aim ahead of the rest spot, raycast the actual landing point
						local target = cf:PointToWorldSpace(leg.restLocal) + lead
						local p, n = groundBelow(target)
						-- over a gap the ray hits the pit floor, skip those
						if p and math.abs(p.Y - groundLevel) < 4 then
							leg:startStep(p, n)
						end
					end
				end
				swinging = true
			end
		end
	elseif state == "air" then
		-- pull the feet in so they dont trail behind over the gap
		for _, leg in ipairs(legs) do
			local tuck = cf:PointToWorldSpace(leg.restLocal * Vector3.new(0.55, 0.4, 0.55))
			leg.foot = leg.foot:Lerp(tuck, alpha(10, dt))
		end
	end

	for _, leg in ipairs(legs) do
		local hip = cf:PointToWorldSpace(leg.hipLocal)
		local knee = solveKnee(hip, leg.foot)
		drawBone(leg.upperPart, hip, knee)
		drawBone(leg.lowerPart, knee, leg.foot)
		leg.tipPart.Position = leg.foot
	end
end)
