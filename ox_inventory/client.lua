if not lib then return end

require 'modules.bridge.client'
require 'modules.interface.client'

local Utils = require 'modules.utils.client'
local Weapon = require 'modules.weapon.client'
local currentWeapon

exports('getCurrentWeapon', function()
	return currentWeapon
end)

RegisterNetEvent('ox_inventory:disarm', function(noAnim)
	currentWeapon = Weapon.Disarm(currentWeapon, noAnim)
end)

RegisterNetEvent('ox_inventory:clearWeapons', function()
	Weapon.ClearAll(currentWeapon)
end)

local StashTarget

exports('setStashTarget', function(id, owner)
	StashTarget = id and {id=id, owner=owner}
end)

---@type boolean | number
local invBusy = true

---@type boolean?
local invOpen = false
local IsPedCuffed = IsPedCuffed
local playerPed = cache.ped

lib.onCache('ped', function(ped)
	playerPed = ped
	Utils.WeaponWheel()
end)

client.player:set('invBusy', true)
client.player:set('invHotkeys', false)
client.player:set('canUseWeapons', false)

local function canOpenInventory()
    if not PlayerData.loaded then
        return shared.info('cannot open inventory', '(player inventory has not loaded)')
    end

    if IsPauseMenuActive() or invOpen == nil then return end

    if invBusy or (currentWeapon?.timer or 0) > 0 then
        return shared.info('cannot open inventory', '(is busy)')
    end

    if PlayerData.dead or IsPedFatallyInjured(playerPed) then
        return shared.info('cannot open inventory', '(fatal injury)')
    end

    if PlayerData.cuffed or IsPedCuffed(playerPed) then
        return shared.info('cannot open inventory', '(cuffed)')
    end

    return true
end

---@param ped number
---@return boolean
local function canOpenTarget(ped)
	return IsPedFatallyInjured(ped)
	or IsEntityPlayingAnim(ped, 'dead', 'dead_a', 3)
	or IsPedCuffed(ped)
	or IsEntityPlayingAnim(ped, 'mp_arresting', 'idle', 3)
	or IsEntityPlayingAnim(ped, 'missminuteman_1ig_2', 'handsup_base', 3)
	or IsEntityPlayingAnim(ped, 'missminuteman_1ig_2', 'handsup_enter', 3)
	or IsEntityPlayingAnim(ped, 'random@mugging3', 'handsup_standing_base', 3)
end

---@class OpenInventory
---@field id string | integer
---@field label string
---@field type string
---@field slots integer
---@field weight integer
---@field maxWeight integer
---@field coords? vector3
---@field distance? integer
---@field instance? string | number
---@field [string] unknown
local defaultInventory = {
	type = 'newdrop',
	slots = shared.dropslots,
	weight = 0,
	maxWeight = shared.dropweight,
	items = {}
}

local currentInventory = defaultInventory

local function closeTrunk()
	if currentInventory.type == 'trunk' then
		local coords = GetEntityCoords(playerPed, true)
		---@todo animation for vans?
		Utils.PlayAnimAdvanced(0, 'anim@heists@fleeca_bank@scope_out@return_case', 'trevor_action', coords.x, coords.y, coords.z, 0.0, 0.0, GetEntityHeading(playerPed), 2.0, 2.0, 1000, 49, 0.25)

		CreateThread(function()
			local entity = currentInventory.entity
			local door = currentInventory.door
			Wait(900)

			if type(door) == 'table' then
				for i = 1, #door do
					SetVehicleDoorShut(entity, door[i], false)
				end
			else
				SetVehicleDoorShut(entity, door, false)
			end
		end)
	end
end

local CraftingBenches = require 'modules.crafting.client'
local Vehicles = lib.load('data.vehicles')
local Inventory = require 'modules.inventory.client'

---@param inv string?
---@param data any?
---@return boolean?
function client.openInventory(inv, data)
	if invOpen == nil then return end

	if invOpen then
		if not inv and currentInventory.type == 'newdrop' then
			return client.closeInventory()
		end

		if IsNuiFocused() then
			if inv == 'container' and currentInventory.id == PlayerData.inventory[data].metadata.container then
				return client.closeInventory()
			end

			if currentInventory.type == 'drop' and (not data or currentInventory.id == (type(data) == 'table' and data.id or data)) then
				return client.closeInventory()
			end

			if inv ~= 'drop' and inv ~= 'container' then
				if (data?.id or data) == currentInventory.id then
					-- Triggering exports.ox_inventory:openInventory('stash', 'mystash') twice in rapid succession is weird behaviour
					return warn(("script tried to open inventory, but it is already open\n%s"):format(Citizen.InvokeNative(`FORMAT_STACK_TRACE` & 0xFFFFFFFF, nil, 0, Citizen.ResultAsString())))
				else
					return client.closeInventory()
				end
			end
		end
	elseif IsNuiFocused() then
		-- If triggering from another nui, may need to wait for focus to end.
		Wait(100)

        -- People still complain about this being an "error" and ask "how fix" despite being a warning
        -- for people with above room-temperature iqs to look into resource conflicts on their own.
		-- if IsNuiFocused() then
		-- 	warn('other scripts have nui focus and may cause issues (e.g. disable focus, prevent input, overlap inventory window)')
		-- end
	end

	if inv == 'dumpster' and cache.vehicle then
		return lib.notify({ id = 'inventory_right_access', type = 'error', description = locale('inventory_right_access') })
	end

	if not canOpenInventory() then
        return lib.notify({ id = 'inventory_player_access', type = 'error', description = locale('inventory_player_access') })
    end

    local left, right, accessError

    if inv == 'player' and data ~= cache.serverId then
        local targetId, targetPed, serverId

        if not data then
            targetId, targetPed = Utils.GetClosestPlayer()
            serverId = targetId and GetPlayerServerId(targetId)
            data = serverId
        else
            serverId = type(data) == 'table' and data.id or data
            targetId = serverId and GetPlayerFromServerId(serverId)
            targetPed = targetId and GetPlayerPed(targetId)
        end

        if serverId == cache.serverId then return end

        local targetCoords = targetPed and GetEntityCoords(targetPed)

        if not targetCoords or #(targetCoords - GetEntityCoords(playerPed)) > 1.8 or (not client.hasGroup(shared.police) and not Player(serverId).state.canSteal) then
            return lib.notify({ id = 'inventory_right_access', type = 'error', description = locale('inventory_right_access') })
        end
    end

    if inv == 'shop' and invOpen == false then
        if cache.vehicle then
            return lib.notify({ id = 'cannot_perform', type = 'error', description = locale('cannot_perform') })
        end

        left, right, accessError = lib.callback.await('ox_inventory:openShop', 200, data)
    elseif inv == 'crafting' then
        if cache.vehicle then
            return lib.notify({ id = 'cannot_perform', type = 'error', description = locale('cannot_perform') })
        end

        left, right, accessError = lib.callback.await('ox_inventory:openCraftingBench', 200, data.id, data.index)

        if left then
            right = CraftingBenches[data.id]

            if not right?.items then return end

            local coords, distance

            if not right.zones and not right.points then
                coords = GetEntityCoords(cache.ped)
                distance = 2
            else
                coords = shared.target and right.zones and right.zones[data.index].coords or right.points and right.points[data.index]
                distance = coords and shared.target and right.zones[data.index].distance or 2
            end

            right = {
                type = 'crafting',
                id = data.id,
                label = right.label or locale('crafting_bench'),
                index = data.index,
                slots = right.slots,
                items = right.items,
                coords = coords,
                distance = distance
            }
        end
    elseif invOpen ~= nil then
        if inv == 'policeevidence' then
            if not data then
                local input = lib.inputDialog(locale('police_evidence'), {
                    { label = locale('locker_number'), type = 'number', required = true, icon = 'calculator' }
                }) --[[@as number[]? ]]

                if not input then return end

                data = input[1]
            end
        end

        left, right, accessError = lib.callback.await('ox_inventory:openInventory', false, inv, data)
    end

    if accessError then
        return lib.notify({ id = accessError, type = 'error', description = locale(accessError) })
    end

    -- Stash does not exist
    if not left then
        if left == false then return false end

        if invOpen == false then
            return lib.notify({ id = 'inventory_right_access', type = 'error', description = locale('inventory_right_access') })
        end

        if invOpen then return client.closeInventory() end
    end


    if not cache.vehicle then
        if inv == 'player' then
            Utils.PlayAnim(0, 'mp_common', 'givetake1_a', 8.0, 1.0, 2000, 50, 0.0, 0, 0, 0)
        elseif inv ~= 'trunk' then
            Utils.PlayAnim(0, 'pickup_object', 'putdown_low', 5.0, 1.5, 1000, 48, 0.0, 0, 0, 0)
        end
    end

	client.player:set('invOpen', true)

    SetInterval(client.interval, 100)
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(true)
    closeTrunk()

    if client.screenblur then Utils.blurIn() end

    currentInventory = right or defaultInventory
    left.items = PlayerData.inventory
    left.groups = PlayerData.groups

    SendNUIMessage({
        action = 'setupInventory',
        data = {
            leftInventory = left,
            rightInventory = currentInventory
        }
    })

    if inv and not currentInventory.coords and inv ~= 'container' and inv ~= 'glovebox' then
        currentInventory.coords = GetEntityCoords(playerPed)
    end

    if inv == 'trunk' then
        SetTimeout(200, function()
            ---@todo animation for vans?
            Utils.PlayAnim(0, 'anim@heists@prison_heiststation@cop_reactions', 'cop_b_idle', 3.0, 3.0, -1, 49, 0.0, 0, 0, 0)

            local entity = data.entity or NetworkGetEntityFromNetworkId(data.netid)
            currentInventory.entity = entity
            currentInventory.door = data.door

            if not currentInventory.door then
                local vehicleHash = GetEntityModel(entity)
                local vehicleClass = GetVehicleClass(entity)
                currentInventory.door = vehicleClass == 12 and { 2, 3 } or Vehicles.Storage[vehicleHash] and 4 or 5
            end

            while currentInventory.entity == entity and invOpen and DoesEntityExist(entity) and Inventory.CanAccessTrunk(entity) do
                Wait(100)
            end

            if invOpen then client.closeInventory() end
        end)
    end

    return true
end

RegisterNetEvent('ox_inventory:openInventory', client.openInventory)
exports('openInventory', client.openInventory)

RegisterNetEvent('ox_inventory:forceOpenInventory', function(left, right)
	if source == '' then return end

	client.player:set('invOpen', true)

	SetInterval(client.interval, 100)
	SetNuiFocus(true, true)
	SetNuiFocusKeepInput(true)
	closeTrunk()

	if client.screenblur then Utils.blurIn() end

	currentInventory = right or defaultInventory
	currentInventory.ignoreSecurityChecks = true
	left.items = PlayerData.inventory
	left.groups = PlayerData.groups

	SendNUIMessage({
		action = 'setupInventory',
		data = {
			leftInventory = left,
			rightInventory = currentInventory
		}
	})
end)

local Animations = lib.load('data.animations')
local Items = require 'modules.items.client'
local Equipment = shared.equipment
local Categories = (function()
    local Categories = {
        list = {},
        palette = {},
    }

    local entries = {
        { name = 'weapon', label = 'Weapon', colour = '#ff6b6b', weapon = true },
        { name = 'ammo', label = 'Ammo', colour = '#ffb050', ammo = true },
        { name = 'money', label = 'Money', colour = '#5be37d', items = { 'money', 'black_money', 'cash' } },
        { name = 'medical', label = 'Medical', colour = '#4fd1a5', items = { 'bandage', 'firstaid', 'ifaks', 'painkillers', 'armour', 'oxy' } },
        { name = 'food', label = 'Food', colour = '#f2c94c', status = 'hunger', items = { 'sandwich' } },
        { name = 'drink', label = 'Drink', colour = '#5cc8ff', status = 'thirst', items = { 'coffee', 'beer', 'wine', 'vodka', 'whiskey', 'grapejuice' } },
        { name = 'tool', label = 'Tool', colour = '#9aa4b2', items = { 'lockpick', 'advancedlockpick', 'screwdriverset', 'electronickit', 'repairkit', 'advancedrepairkit', 'cleaningkit', 'drill', 'thermite', 'shovel', 'pocket_scale', 'handcuffs', 'harness', 'jerry_can', 'lighter', 'binoculars' } },
        { name = 'document', label = 'Document', colour = '#e8e8e8', items = { 'id_card', 'driver_license', 'weaponlicense', 'lawyerpass', 'bank_card', 'document', 'security_card_01', 'security_card_02' } },
        { name = 'valuable', label = 'Valuable', colour = '#ffd866', items = { 'diamond', 'diamond_ring', 'rolex', 'goldbar', 'goldchain', '10kgoldchain' } },
    }

    for _, entry in ipairs(entries) do
        local items = {}

        for _, name in ipairs(entry.items or {}) do
            items[name] = true
        end

        Categories.list[#Categories.list + 1] = {
            name = entry.name,
            label = entry.label or entry.name,
            colour = entry.colour or '#ffffff',
            weapon = entry.weapon,
            ammo = entry.ammo,
            status = entry.status,
            items = items,
            patterns = entry.patterns or {},
        }

        Categories.palette[entry.name] = { label = entry.label or entry.name, colour = entry.colour or '#ffffff' }
    end

    function Categories.of(name, definition)
        if definition and definition.category and Categories.palette[definition.category] then
            return definition.category
        end

        local status = definition and definition.client and definition.client.status

        for i = 1, #Categories.list do
            local entry = Categories.list[i]

            if entry.items[name] then return entry.name end

            if definition then
                if entry.weapon and (definition.weapon or definition.component or definition.tint) then return entry.name end
                if entry.ammo and definition.ammo then return entry.name end

                if entry.status and type(status) == 'table' and type(status[entry.status]) == 'number' and status[entry.status] > 0 then
                    return entry.name
                end
            end

            for p = 1, #entry.patterns do
                if name:find(entry.patterns[p]) then return entry.name end
            end
        end
    end

    return Categories
end)()
local Rarity = (function()
    local Rarity = {
        palette = {},
        items = {},
        patterns = {},
    }

    local config = {
        tiers = {
            { name = 'uncommon', label = 'Uncommon', colour = '#5be37d' },
            { name = 'rare', label = 'Rare', colour = '#5cc8ff' },
            { name = 'epic', label = 'Epic', colour = '#b07cff' },
            { name = 'legendary', label = 'Legendary', colour = '#ffb050' },
        },

        items = {
            armour = 'uncommon',
            goldchain = 'uncommon',
            rolex = 'rare',
            diamond = 'rare',
            diamond_ring = 'rare',
            cryptostick = 'rare',
            trojan_usb = 'rare',
            coke_brick = 'rare',
            thermite = 'epic',
            goldbar = 'epic',
            ['10kgoldchain'] = 'epic',
        },

        patterns = {
            ['^WEAPON_'] = 'uncommon',
        },
    }

    for _, tier in ipairs(config.tiers or {}) do
        Rarity.palette[tier.name] = { label = tier.label or tier.name, colour = tier.colour or '#ffffff' }
    end

    for name, tier in pairs(config.items or {}) do
        if Rarity.palette[tier] then Rarity.items[name] = tier end
    end

    for pattern, tier in pairs(config.patterns or {}) do
        if Rarity.palette[tier] then Rarity.patterns[#Rarity.patterns + 1] = { pattern = pattern, tier = tier } end
    end

    function Rarity.of(name, definition)
        if definition and Rarity.palette[definition.rarity] then return definition.rarity end
        if Rarity.items[name] then return Rarity.items[name] end

        for i = 1, #Rarity.patterns do
            if name:find(Rarity.patterns[i].pattern) then return Rarity.patterns[i].tier end
        end
    end

    return Rarity
end)()
;(function()
    if not GetConvarBool('inventory:statusboxes', true) then return end

    local function metadataValue(player, key)
        local value = player and player.metadata and player.metadata[key]

        return type(value) == 'number' and value or 100
    end

    local function frameworkData()
        local ok, player

        if GetResourceState('qbx_core') == 'started' then
            ok, player = pcall(function()
                return exports.qbx_core:GetPlayerData()
            end)
        elseif GetResourceState('qb-core') == 'started' then
            ok, player = pcall(function()
                return exports['qb-core']:GetCoreObject().Functions.GetPlayerData()
            end)
        end

        return ok and type(player) == 'table' and player or nil
    end

    local function snapshot()
        local ped = cache.ped
        local maxHealth = math.max(1, GetEntityMaxHealth(ped) - 100)
        local data = {
            health = math.floor(math.max(0, GetEntityHealth(ped) - 100) / maxHealth * 100),
            armour = GetPedArmour(ped),
            hunger = 100,
            thirst = 100,
            id = cache.serverId,
            cash = 0,
            bank = 0,
        }

        local player = frameworkData()

        if player then
            data.hunger = metadataValue(player, 'hunger')
            data.thirst = metadataValue(player, 'thirst')
            data.cash = player.money and player.money.cash or 0
            data.bank = player.money and player.money.bank or 0
        end

        return data
    end

    CreateThread(function()
        while true do
            if client.player:get('invOpen') then
                SendNUIMessage({ action = 'status', data = snapshot() })
                Wait(1000)
            else
                Wait(400)
            end
        end
    end)
end)()
;(function()
    local config = {
        startsAt = 0.7,
        noSprintAt = 1.0,
        slowestRun = 0.78,
        breathless = {
            after = 6000,
            duration = 3500,
            dict = 're@construction',
            name = 'out_of_breath',
        },
    }
    local enabled = GetConvarBool('inventory:weightpenalty', true)

    if not enabled then return end

    local startsAt = config.startsAt or 0.7
    local noSprintAt = config.noSprintAt or 1.0
    local slowestRun = config.slowestRun or 0.78
    local breathless = config.breathless or {}
    local sprintingSince
    local lastBreath = -1000000
    local appliedAt = 0

    local function ratio()
        local weight = PlayerData.weight
        local limit = shared.playerweight

        if not weight or not limit or limit <= 0 then return 0 end

        return weight / limit
    end

    local function pant()
        if not breathless.dict or not breathless.name then return end
        if IsPedInAnyVehicle(cache.ped, false) or IsPedRagdoll(cache.ped) then return end
        if not pcall(lib.requestAnimDict, breathless.dict, 1000) then return end

        TaskPlayAnim(cache.ped, breathless.dict, breathless.name, 3.0, 3.0, breathless.duration or 3500, 49, 0.0, false, false, false)
        RemoveAnimDict(breathless.dict)
    end

    CreateThread(function()
        local playerId = cache.playerId
        local applied = 1.0

        while true do
            local load = ratio()

            if load >= startsAt then
                local over = math.min(1.0, (load - startsAt) / math.max(0.01, noSprintAt - startsAt))
                local multiplier = 1.0 - (1.0 - slowestRun) * over

                local now = GetGameTimer()

                if multiplier ~= applied or now - appliedAt > 2000 then
                    applied = multiplier
                    appliedAt = now
                    SetRunSprintMultiplierForPlayer(playerId, multiplier)
                end

                local blocking = load >= noSprintAt

                if blocking then
                    DisableControlAction(0, 21, true)
                end

                if IsPedSprinting(cache.ped) then
                    sprintingSince = sprintingSince or GetGameTimer()

                    if now - sprintingSince > (breathless.after or 6000) and now - lastBreath > 12000 then
                        lastBreath = now
                        sprintingSince = nil
                        pant()
                    end
                else
                    sprintingSince = nil
                end

                Wait(blocking and 0 or 250)
            else
                if applied ~= 1.0 then
                    applied = 1.0
                    SetRunSprintMultiplierForPlayer(playerId, 1.0)
                end

                sprintingSince = nil
                Wait(500)
            end
        end
    end)
end)()
local Pickup = (function()
    local Pickup = {
        enabled = GetConvarBool('inventory:pickup', true) and GetResourceState('ox_target') == 'started',
    }

    local OPTION = 'ox_inventory:pickup'
    local busy = false

    local function collect(dropId)
        if busy then return end

        busy = true

        if pcall(lib.requestAnimDict, 'pickup_object', 1000) then
            TaskPlayAnim(cache.ped, 'pickup_object', 'pickup_low', 8.0, 1.0, 900, 48, 0.0, false, false, false)
            RemoveAnimDict('pickup_object')
        end

        Wait(450)

        local moved, total = lib.callback.await('ox_inventory:pickupDrop', false, dropId)

        if moved and moved > 0 then
            lib.notify({
                type = moved == total and 'success' or 'warning',
                description = moved == total and locale('pickup_done', moved) or locale('pickup_some', moved, total),
            })
        else
            lib.notify({ type = 'error', description = locale('pickup_none') })
        end

        busy = false
    end

    function Pickup.add(entity, dropId)
        if not Pickup.enabled or not entity or not DoesEntityExist(entity) then return end

        exports.ox_target:addLocalEntity(entity, {
            {
                name = OPTION,
                icon = 'fa-solid fa-hand',
                label = locale('pickup_label'),
                distance = 2.0,
                canInteract = function()
                    return not busy and not cache.vehicle and not client.player:get('invOpen')
                end,
                onSelect = function()
                    collect(dropId)
                end,
            },
        })
    end

    function Pickup.remove(entity)
        if not Pickup.enabled or not entity then return end

        pcall(function()
            exports.ox_target:removeLocalEntity(entity, OPTION)
        end)
    end

    return Pickup
end)()
local WeaponView = (function()
    local config = {
        altitude = 150.0,
        fov = 38.0,
        fit = 1.8,
        spin = 0.0,
        zoom = { min = 0.6, max = 1.6 },
        light = { range = 3.5, intensity = 9.0 },

        anchors = {
            muzzle = { bones = { 'WAPSupp', 'gun_vfx_muzzle' }, at = { 0.0, 1.0, 0.25 } },
            sight = { bones = { 'WAPScop' }, at = { 0.0, 0.1, 0.9 } },
            flashlight = { bones = { 'WAPFlshLasr' }, at = { 0.0, 0.65, -0.5 } },
            magazine = { bones = { 'WAPClip' }, at = { 0.0, -0.25, -0.9 } },
            grip = { bones = { 'WAPGrip' }, at = { 0.0, 0.1, -0.55 } },
            barrel = { bones = {}, at = { 0.0, 0.8, 0.3 } },
            skin = { bones = {}, at = { 0.0, 0.0, 0.0 } },
        },
    }
    local enabled = GetConvarBool('inventory:weaponview', true)

    local WeaponView = {}

    local camera
    local object
    local active = false
    local origin
    local direction
    local distance = 1.0
    local centre = vec3(0.0, 0.0, 0.0)
    local half = vec3(0.1, 0.1, 0.1)
    local yaw = 0.0
    local pitch = 0.0
    local zoom = 1.0
    local dragUntil = 0

    local function stop(restoreBlur)
        if not active then return end

        active = false

        if object and DoesEntityExist(object) then
            DeleteEntity(object)
        end

        object = nil

        ClearFocus()

        if restoreBlur and client.screenblur and client.player:get('invOpen') then TriggerScreenblurFadeIn(250) end

        if camera then
            local handle = camera

            camera = nil
            RenderScriptCams(false, true, 300, true, false)
            SetTimeout(350, function()
                DestroyCam(handle, false)
            end)
        end
    end

    local function directionOf(headingDegrees)
        local z = math.rad(headingDegrees)

        return vec3(-math.sin(z), math.cos(z), 0.0)
    end

    local function anchorOf(definition)
        for i = 1, #(definition.bones or {}) do
            local index = GetEntityBoneIndexByName(object, definition.bones[i])

            if index and index ~= -1 then
                return GetWorldPositionOfEntityBone(object, index)
            end
        end

        local at = definition.at or { 0.0, 0.0, 0.0 }

        return GetOffsetFromEntityInWorldCoords(object, centre.x + at[1] * half.x, centre.y + at[2] * half.y, centre.z + at[3] * half.z)
    end

    local function place(target, heading)
        SetEntityRotation(object, pitch, 0.0, heading + yaw, 2, true)

        local centred = GetOffsetFromEntityInWorldCoords(object, centre.x, centre.y, centre.z)
        local position = GetEntityCoords(object)

        SetEntityCoordsNoOffset(object, position.x + (target.x - centred.x), position.y + (target.y - centred.y), position.z + (target.z - centred.z), false, false, false)
    end

    local function run(heading)
        local last = GetGameTimer()
        local sent = -1000
        local light = config.light or {}

        while active do
            if not client.player:get('invOpen') or cache.vehicle or not object or not DoesEntityExist(object) then
                stop()
                SendNUIMessage({ action = 'weaponClosed' })
                break
            end

            local now = GetGameTimer()
            local step = (now - last) / 1000.0

            last = now

            if now > dragUntil and (config.spin or 0.0) ~= 0.0 then
                yaw = yaw + config.spin * step
            end

            local target = origin + direction * (distance * zoom)

            place(target, heading - 90.0)

            DrawLightWithRange(target.x - direction.x * 0.5, target.y - direction.y * 0.5, target.z + 0.25, 255, 255, 255, light.range or 3.5, light.intensity or 9.0)

            if now - sent >= 33 then
                sent = now

                local anchors = {}

                for name, definition in pairs(config.anchors or {}) do
                    local position = anchorOf(definition)
                    local onScreen, x, y = GetScreenCoordFromWorldCoord(position.x, position.y, position.z)

                    if onScreen then anchors[name] = { x = x, y = y } end
                end

                SendNUIMessage({ action = 'weaponAnchors', data = anchors })
            end

            Wait(0)
        end
    end

    function WeaponView.start(hash, components)
        if not enabled or active or cache.vehicle then return false end

        if not pcall(lib.requestWeaponAsset, hash, 5000, 31, 31) then return false end

        local ped = cache.ped
        local base = GetEntityCoords(ped)
        local heading = GetEntityHeading(ped)

        origin = vec3(base.x, base.y, base.z + (config.altitude or 150.0))
        direction = directionOf(heading)

        local entity = CreateWeaponObject(hash, 0, origin.x, origin.y, origin.z, true, 1.0, 0)

        if not entity or entity == 0 then return false end

        object = entity

        SetEntityCollision(object, false, false)
        FreezeEntityPosition(object, true)

        for i = 1, #(components or {}) do
            if DoesWeaponTakeWeaponComponent(hash, components[i]) then
                GiveWeaponComponentToWeaponObject(object, components[i])
            end
        end

        local minimum, maximum = GetModelDimensions(GetEntityModel(object))

        centre = vec3((minimum.x + maximum.x) / 2.0, (minimum.y + maximum.y) / 2.0, (minimum.z + maximum.z) / 2.0)
        half = vec3(math.max(0.01, (maximum.x - minimum.x) / 2.0), math.max(0.01, (maximum.y - minimum.y) / 2.0), math.max(0.01, (maximum.z - minimum.z) / 2.0))

        local fov = config.fov or 38.0
        local size = math.max(half.x, half.y, half.z) * 2.0

        distance = math.max(0.45, size / (2.0 * math.tan(math.rad(fov) / 2.0)) * (config.fit or 2.4))
        yaw = 0.0
        pitch = 0.0
        zoom = 1.0
        dragUntil = 0

        camera = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', origin.x, origin.y, origin.z, 0.0, 0.0, heading, fov, false, 2)
        SetCamActive(camera, true)
        RenderScriptCams(true, true, 500, true, false)
        SetFocusPosAndVel(origin.x, origin.y, origin.z, 0.0, 0.0, 0.0)

        if client.screenblur then TriggerScreenblurFadeOut(250) end

        active = true
        CreateThread(function()
            run(heading)
        end)

        return true
    end

    function WeaponView.stop()
        stop()
    end

    function WeaponView.isActive()
        return active
    end

    AddEventHandler('ox_inventory:updateWeaponComponent', function(action, component)
        if not active or not object or not DoesEntityExist(object) or not component then return end

        if action == 'added' then
            GiveWeaponComponentToWeaponObject(object, component)
        elseif action == 'removed' then
            RemoveWeaponComponentFromWeaponObject(object, component)
        end
    end)

    RegisterNUICallback('weaponView', function(data, cb)
        cb(1)

        if type(data) == 'table' and not data.open then stop(data.back == true) end
    end)

    RegisterNUICallback('weaponRotate', function(data, cb)
        cb(1)

        if not active or type(data) ~= 'table' then return end

        yaw = yaw + (tonumber(data.dx) or 0.0) * 0.5
        pitch = math.max(-40.0, math.min(40.0, pitch + (tonumber(data.dy) or 0.0) * 0.3))
        dragUntil = GetGameTimer() + 2500
    end)

    RegisterNUICallback('weaponZoom', function(data, cb)
        cb(1)

        if not active or type(data) ~= 'table' then return end

        local limits = config.zoom or {}

        zoom = math.max(limits.min or 0.6, math.min(limits.max or 1.6, zoom + (tonumber(data.delta) or 0.0) * 0.0012))
    end)

    AddEventHandler('onResourceStop', function(resource)
        if resource == cache.resource then stop() end
    end)

    return WeaponView
end)()
local Throwing = (function()
    local config = {
        minDistance = 1.5,
        maxDistance = 7.0,
        metresPerKilogram = 0.8,
        wallClearance = 0.35,
        maxDrop = 3.5,
        closeInventory = true,
        cooldown = 600,
        animation = { dict = 'anim@heists@narcotics@trash', clip = 'throw_a', duration = 900 },
    }

    local Throwing = {}

    local lastThrow = -1000000

    function Throwing.ready()
        return GetGameTimer() - lastThrow >= (config.cooldown or 600)
    end

    function Throwing.mark()
        lastThrow = GetGameTimer()
    end

    function Throwing.distance(kilograms)
        local minimum = config.minDistance or 1.5
        local maximum = config.maxDistance or 7.0

        return math.max(minimum, math.min(maximum, maximum - math.max(0.0, kilograms) * (config.metresPerKilogram or 0.8)))
    end

    function Throwing.target(ped, grams)
        local coords = GetEntityCoords(ped)
        local forward = GetEntityForwardVector(ped)
        local origin = vec3(coords.x, coords.y, coords.z + 0.3)
        local reach = Throwing.distance((grams or 0) / 1000.0)
        local goal = vec3(origin.x + forward.x * reach, origin.y + forward.y * reach, origin.z)

        local handle = StartShapeTestLosProbe(origin.x, origin.y, origin.z, goal.x, goal.y, goal.z, 1 | 2 | 16, ped, 4)
        local result, hit, hitCoords = 1, false, nil

        for _ = 1, 20 do
            result, hit, hitCoords = GetShapeTestResult(handle)

            if result ~= 1 then break end

            Wait(0)
        end

        local distance = reach

        if result == 2 and hit and hitCoords then
            local blocked = math.sqrt((hitCoords.x - origin.x) ^ 2 + (hitCoords.y - origin.y) ^ 2)

            distance = math.max(0.6, math.min(reach, blocked - (config.wallClearance or 0.35)))
        end

        local x = origin.x + forward.x * distance
        local y = origin.y + forward.y * distance
        local found, ground = GetGroundZFor_3dCoord(x, y, origin.z + 1.5, false)
        local z = coords.z - 0.9

        if found and math.abs(ground - coords.z) <= (config.maxDrop or 3.5) + 1.0 then z = ground end

        return vec3(x, y, z), distance
    end

    function Throwing.animate(ped)
        local animation = config.animation

        if not animation or not pcall(lib.requestAnimDict, animation.dict, 1000) then return end

        TaskPlayAnim(ped, animation.dict, animation.clip, 3.0, 3.0, animation.duration or 900, 48, 0.0, false, false, false)
        RemoveAnimDict(animation.dict)
    end

    function Throwing.closes()
        return config.closeInventory ~= false
    end

    return Throwing
end)()
local usingItem = false

---@param data { name: string, label: string, count: number, slot: number, metadata: table<string, any>, weight: number }
lib.callback.register('ox_inventory:usingItem', function(data, noAnim)
	local item = Items[data.name]

	if item and usingItem then
		if not item.client then return true end
		---@cast item +OxClientProps
		item = item.client

		if type(item.anim) == 'string' then
			item.anim = Animations.anim[item.anim]
		end

		if item.prop then
			if item.prop[1] then
				for i = 1, #item.prop do
					if type(item.prop) == 'string' then
						item.prop = Animations.prop[item.prop[i]]
					end
				end
			elseif type(item.prop) == 'string' then
				item.prop = Animations.prop[item.prop]
			end
		end

		if not item.disable then
			item.disable = { combat = true }
		elseif item.disable.combat == nil then
			-- Backwards compatibility; you probably don't want people shooting while eating and bandaging anyway
			item.disable.combat = true
		end

		local success = (not item.usetime or noAnim or lib.progressBar({
			duration = item.usetime,
			label = item.label or locale('using', data.metadata.label or data.label),
			useWhileDead = item.useWhileDead,
			canCancel = item.cancel,
			disable = item.disable,
			anim = item.anim or item.scenario,
			prop = item.prop --[[@as ProgressProps]]
		})) and not PlayerData.dead

		if success then
			if item.notification then
				lib.notify({ description = item.notification })
			end

			if item.status then
				if client.setPlayerStatus then
					client.setPlayerStatus(item.status)
				end
			end

			return true
		end
	end
end)

local function canUseItem(isAmmo)
	local ped = cache.ped

	return not usingItem
    and (not isAmmo or currentWeapon)
	and PlayerData.loaded
	and not PlayerData.dead
	and not invBusy
	and not lib.progressActive()
	and not IsPedRagdoll(ped)
	and not IsPedFalling(ped)
    and not IsPedShooting(playerPed)
end

---@param data table
---@param cb fun(response: SlotWithItem | false)?
---@param noAnim? boolean
local function useItem(data, cb, noAnim)
	local slotData, result = PlayerData.inventory[data.slot]

	if not slotData or not canUseItem(data.ammo and true) then
        if currentWeapon then
            return lib.notify({ id = 'cannot_perform', type = 'error', description = locale('cannot_perform') })
        end

        return
    end

	if currentWeapon and currentWeapon.timer ~= 0 then
        if not currentWeapon.timer or currentWeapon.timer - GetGameTimer() > 100 then return end

        DisablePlayerFiring(cache.playerId, true)
    end

    if invOpen and data.close then client.closeInventory() end

    usingItem = true
    ---@type boolean?
    result = lib.callback.await('ox_inventory:useItem', 200, data.name, data.slot, slotData.metadata, noAnim)

	if result and cb then
		local success, response = pcall(cb, result and slotData)

		if not success and response then
			warn(('^1An error occurred while calling item "%s" callback!\n^1SCRIPT ERROR: %s^0'):format(slotData.name, response))
		end
	end

    if result then
        TriggerEvent('ox_inventory:usedItem', slotData.name, slotData.slot, next(slotData.metadata) and slotData.metadata)
    end

	Wait(500)
    usingItem = false
end

AddEventHandler('ox_inventory:usedItem', function(name, slot, metadata)
    TriggerServerEvent('ox_inventory:usedItemInternal', slot)
    SendNUIMessage({ action = 'hotbarState', data = { used = slot, equipped = currentWeapon and currentWeapon.slot or false, open = invOpen } })
end)

AddEventHandler('ox_inventory:item', useItem)
exports('useItem', useItem)

---@param slot number
---@return boolean?
local function useSlot(slot, noAnim)
	local item = PlayerData.inventory[slot]
	if not item then return end

	local data = Items[item.name]
	if not data then return end

	if canUseItem(data.ammo and true) then
		if data.component and not currentWeapon then
			return lib.notify({ id = 'weapon_hand_required', type = 'error', description = locale('weapon_hand_required') })
		end

		local durability = item.metadata.durability --[[@as number?]]
		local consume = data.consume --[[@as number?]]
		local label = item.metadata.label or item.label --[[@as string]]

		-- Naive durability check to get an early exit
		-- People often don't call the 'useItem' export and then complain about "broken" items being usable
		-- This won't work with degradation since we need access to os.time on the server
		if durability and durability <= 100 and consume then
			if durability <= 0 then
				return lib.notify({ type = 'error', description = locale('no_durability', label) })
			elseif consume ~= 0 and consume < 1 and durability < consume * 100 then
				return lib.notify({ type = 'error', description = locale('not_enough_durability', label) })
			end
		end

		data.slot = slot

		if item.metadata.container then
			return client.openInventory('container', item.slot)
		elseif data.client then
			if invOpen and data.close then client.closeInventory() end

			if data.export then
				return data.export(data, {name = item.name, slot = item.slot, metadata = item.metadata})
			elseif data.client.event then -- re-add it, so I don't need to deal with morons taking screenshots of errors when using trigger event
				return TriggerEvent(data.client.event, data, {name = item.name, slot = item.slot, metadata = item.metadata})
			end
		end

		if data.effect then
			data:effect({name = item.name, slot = item.slot, metadata = item.metadata})
		elseif data.weapon then
			if EnableWeaponWheel or not client.player:get('canUseWeapons') then return end

			if IsCinematicCamRendering() then SetCinematicModeActive(false) end

			if currentWeapon then
                if not currentWeapon.timer or currentWeapon.timer ~= 0 then return end

				local weaponSlot = currentWeapon.slot
				currentWeapon = Weapon.Disarm(currentWeapon)

				if weaponSlot == data.slot then return end
			end

            GiveWeaponToPed(playerPed, data.hash, 0, false, true)
            SetCurrentPedWeapon(playerPed, data.hash, false)

            if data.hash ~= GetSelectedPedWeapon(playerPed) then
                lib.print.info(('failed to equip %s (cause unknown)'):format(item.name))
                return lib.notify({ type = 'error', description = locale('cannot_use', data.label) })
            end

            RemoveWeaponFromPed(cache.ped, data.hash)

			useItem(data, function(result)
				if result then
                    local sleep
					currentWeapon, sleep = Weapon.Equip(item, data, noAnim)

					if sleep then Wait(sleep) end
				end
			end, noAnim)
		elseif currentWeapon then
			if data.ammo then
				if EnableWeaponWheel or currentWeapon.metadata.durability <= 0 then return end

				local clipSize = GetMaxAmmoInClip(playerPed, currentWeapon.hash, true)
				local currentAmmo = GetAmmoInPedWeapon(playerPed, currentWeapon.hash)
				local _, maxAmmo = GetMaxAmmo(playerPed, currentWeapon.hash)

				if maxAmmo < clipSize then clipSize = maxAmmo end

				if currentAmmo == clipSize then return end

				useItem(data, function(resp)
					if not resp or resp.name ~= currentWeapon?.ammo then return end

					if currentWeapon.metadata.specialAmmo ~= resp.metadata.type and type(currentWeapon.metadata.specialAmmo) == 'string' then
						local clipComponentKey = ('%s_CLIP'):format(Items[currentWeapon.name].model:gsub('WEAPON_', 'COMPONENT_'))
						local specialClip = ('%s_%s'):format(clipComponentKey, (resp.metadata.type or currentWeapon.metadata.specialAmmo):upper())

						if type(resp.metadata.type) == 'string' then
							if not HasPedGotWeaponComponent(playerPed, currentWeapon.hash, specialClip) then
								if not DoesWeaponTakeWeaponComponent(currentWeapon.hash, specialClip) then
									warn('cannot use clip with this weapon')
									return
								end

								local defaultClip = ('%s_01'):format(clipComponentKey)

								if not HasPedGotWeaponComponent(playerPed, currentWeapon.hash, defaultClip) then
									warn('cannot use clip with currently equipped clip')
									return
								end

								if currentAmmo > 0 then
									warn('cannot mix special ammo with base ammo')
									return
								end

								currentWeapon.metadata.specialAmmo = resp.metadata.type

								GiveWeaponComponentToPed(playerPed, currentWeapon.hash, specialClip)
							end
						elseif HasPedGotWeaponComponent(playerPed, currentWeapon.hash, specialClip) then
							if currentAmmo > 0 then
								warn('cannot mix special ammo with base ammo')
								return
							end

							currentWeapon.metadata.specialAmmo = nil

							RemoveWeaponComponentFromPed(playerPed, currentWeapon.hash, specialClip)
						end
					end

					if maxAmmo > clipSize then
						clipSize = GetMaxAmmoInClip(playerPed, currentWeapon.hash, true)
					end

					currentAmmo = GetAmmoInPedWeapon(playerPed, currentWeapon.hash)
					local missingAmmo = clipSize - currentAmmo
					local addAmmo = resp.count > missingAmmo and missingAmmo or resp.count
					local newAmmo = currentAmmo + addAmmo

					if newAmmo == currentAmmo then return end

                    AddAmmoToPed(playerPed, currentWeapon.hash, addAmmo)

					if cache.vehicle then
						if cache.seat > -1 or IsVehicleStopped(cache.vehicle) then
							TaskReloadWeapon(playerPed, true)
                        else
                            -- This is a hacky solution for forcing ammo to properly load into the
                            -- weapon clip while driving; without it, ammo will be added but won't
                            -- load until the player stops doing anything. i.e. if you keep shooting,
                            -- the weapon will not reload until the clip empties.
                            -- And yes - for some reason RefillAmmoInstantly needs to run in a loop.
                            lib.waitFor(function()
                                RefillAmmoInstantly(playerPed)

                                local _, ammo = GetAmmoInClip(playerPed, currentWeapon.hash)
                                return ammo == newAmmo or nil
                            end)
                        end
					else
						Wait(100)
						MakePedReload(playerPed)

						SetTimeout(100, function()
							while IsPedReloading(playerPed) do
								DisableControlAction(0, 22, true)
								Wait(0)
							end
						end)
					end

					lib.callback.await('ox_inventory:updateWeapon', false, 'load', newAmmo, false, currentWeapon.metadata.specialAmmo)
				end)
			elseif data.component then
				local components = data.client.component

                if not components then return end

				local componentType = data.type
				local weaponComponents = PlayerData.inventory[currentWeapon.slot].metadata.components

				-- Checks if the weapon already has the same component type attached
				for componentIndex = 1, #weaponComponents do
					if componentType == Items[weaponComponents[componentIndex]].type then
						return lib.notify({ id = 'component_slot_occupied', type = 'error', description = locale('component_slot_occupied', componentType) })
					end
				end

				for i = 1, #components do
					local component = components[i]

					if DoesWeaponTakeWeaponComponent(currentWeapon.hash, component) then
						if HasPedGotWeaponComponent(playerPed, currentWeapon.hash, component) then
							lib.notify({ id = 'component_has', type = 'error', description = locale('component_has', label) })
						else
							useItem(data, function(data)
								if data then
									local success = lib.callback.await('ox_inventory:updateWeapon', false, 'component', tostring(data.slot), currentWeapon.slot)

									if success then
										GiveWeaponComponentToPed(playerPed, currentWeapon.hash, component)
										TriggerEvent('ox_inventory:updateWeaponComponent', 'added', component, data.name)
									end
								end
							end)
						end
						return
					end
				end
				lib.notify({ id = 'component_invalid', type = 'error', description = locale('component_invalid', label) })
			elseif data.allowArmed then
				useItem(data)
            else
                return lib.notify({ id = 'cannot_perform', type = 'error', description = locale('cannot_perform') })
			end
		elseif not data.ammo and not data.component then
			useItem(data)
		end
    end
end
exports('useSlot', useSlot)

---@param id number
---@param slot number
local function useButton(id, slot)
	if PlayerData.loaded and not invBusy and not lib.progressActive() then
		local item = PlayerData.inventory[slot]
		if not item then return end

		local data = Items[item.name]
		local buttons = data?.buttons

		if buttons and buttons[id]?.action then
			buttons[id].action(slot)
		end
	end
end

local function openNearbyInventory() client.openInventory('player') end

exports('openNearbyInventory', openNearbyInventory)

local currentInstance
local playerCoords
local Shops = require 'modules.shops.client'

---@todo remove or replace when the bridge module gets restructured
function OnPlayerData(key, val)
	if key ~= 'groups' and key ~= 'ped' and key ~= 'dead' then return end

	if key == 'groups' then
		Inventory.Stashes()
		Inventory.Evidence()
		Shops.refreshShops()
	elseif key == 'dead' and val then
		currentWeapon = Weapon.Disarm(currentWeapon)
		client.closeInventory()
	end

	Utils.WeaponWheel()
end

-- People consistently ignore errors when one of the "modules" failed to load
if not Utils or not Weapon or not Items or not Inventory then return end

local invHotkeys = false

---@type function?
local function registerCommands()
	if client.enablestealcommand then
		RegisterCommand('steal', openNearbyInventory, false)
	end

	local function openGlovebox(vehicle)
		if not IsPedInAnyVehicle(playerPed, false) or not NetworkGetEntityIsNetworked(vehicle) then return end

		if IsEntityDead(vehicle) then return end

		local vehicleHash = GetEntityModel(vehicle)
		local vehicleClass = GetVehicleClass(vehicle)
		local checkVehicle = Vehicles.Storage[vehicleHash]

		-- No storage or no glovebox
		if (checkVehicle == 0 or checkVehicle == 2) or (not Vehicles.glovebox[vehicleClass] and not Vehicles.glovebox.models[vehicleHash]) then return end

		local isOpen = client.openInventory('glovebox', { netid = NetworkGetNetworkIdFromEntity(vehicle) })

		if isOpen then
			currentInventory.entity = vehicle
		end
	end

	local primary = lib.addKeybind({
		name = 'inv',
		description = locale('open_player_inventory'),
		defaultKey = client.keys[1],
		onPressed = function()
			if invOpen then
				return client.closeInventory()
			end

			local canOpenGlovebox = (not client.gloveboxseatrestriction and cache.vehicle) or (cache.vehicle and (cache.seat == -1 or cache.seat == 0))
			if canOpenGlovebox then
				return openGlovebox(cache.vehicle)
			end

			local closest = lib.points.getClosestPoint()

			if closest and closest.currentDistance < 1.2 and (not closest.instance or closest.instance == currentInstance) then
				if closest.inv == 'crafting' then
					return client.openInventory('crafting', { id = closest.id, index = closest.index })
				elseif closest.inv ~= 'license' and closest.inv ~= 'policeevidence' then
					return client.openInventory(closest.inv or 'drop', { id = closest.invId, type = closest.type })
				end
			end

			return client.openInventory()
		end
	})

	lib.addKeybind({
		name = 'inv2',
		description = locale('open_secondary_inventory'),
		defaultKey = client.keys[2],
		onPressed = function(self)
            if primary:getCurrentKey() == self:getCurrentKey() then
                return warn(("secondary inventory keybind '%s' disabled (keybind cannot match primary inventory keybind)"):format(self:getCurrentKey()))
            end

			if invOpen then
				return client.closeInventory()
			end

			if invBusy or not canOpenInventory() then
				return lib.notify({ id = 'inventory_player_access', type = 'error', description = locale('inventory_player_access') })
			end

			if StashTarget then
				return client.openInventory('stash', StashTarget)
			end

			local canOpenGlovebox = (not client.gloveboxseatrestriction and cache.vehicle) or (cache.vehicle and (cache.seat == -1 or cache.seat == 0))
			if canOpenGlovebox then
				return openGlovebox(cache.vehicle)
			end

			local entity, entityType = Utils.Raycast(2|16)

			if not entity then return end

			if not shared.target and entityType == 3 then
				local model = GetEntityModel(entity)

				if Inventory.Dumpsters:includes(model) then
					return Inventory.OpenDumpster(entity)
				end
			end

			if entityType ~= 2 then return end

			Inventory.OpenTrunk(entity)
		end
	})

	lib.addKeybind({
		name = 'reloadweapon',
		description = locale('reload_weapon'),
		defaultKey = 'r',
		onPressed = function(self)
			if not currentWeapon or EnableWeaponWheel or not canUseItem(true) then return end

			if currentWeapon.ammo then
				if currentWeapon.metadata.durability > 0 then
					local slotId = Inventory.GetSlotIdWithItem(currentWeapon.ammo, { type = currentWeapon.metadata.specialAmmo }, false)

					if slotId then
						useSlot(slotId)
					end
				else
					lib.notify({ id = 'no_durability', type = 'error', description = locale('no_durability', currentWeapon.label) })
				end
			end
		end
	})

	lib.addKeybind({
		name = 'hotbar',
		description = locale('disable_hotbar'),
		defaultKey = client.keys[3],
		onPressed = function()
			if EnableWeaponWheel or not invHotkeys or IsNuiFocused() or lib.progressActive() then return end
			SendNUIMessage({ action = 'hotbarState', data = { equipped = currentWeapon and currentWeapon.slot or false } })
			SendNUIMessage({ action = 'toggleHotbar' })
		end
	})

	for i = 1, 5 do
		lib.addKeybind({
			name = ('hotkey%s'):format(i),
			description = locale('use_hotbar', i),
			defaultKey = tostring(i),
			onPressed = function()
				if invOpen or EnableWeaponWheel or not invHotkeys or IsNuiFocused() then return end
				useSlot(i)
			end
		})
	end

	registerCommands = nil
end

function client.closeInventory()
	if not client.interval then return end

	if invOpen then
		invOpen = nil
		SetNuiFocus(false, false)
		SetNuiFocusKeepInput(false)
		Utils.blurOut()
		closeTrunk()
		SendNUIMessage({ action = 'closeInventory' })
		SetInterval(client.interval, 200)
		Wait(200)

		if invOpen ~= nil then return end

		TriggerServerEvent('ox_inventory:closeInventory')

		currentInventory = defaultInventory
		client.player:set('invOpen', false)
		defaultInventory.coords = nil
	end
end

RegisterNetEvent('ox_inventory:closeInventory', client.closeInventory)
exports('closeInventory', client.closeInventory)

---@param data updateSlot[]
---@param weight number
local function updateInventory(data, weight)
	local changes = {}
    ---@type table<string, number>
	local itemCount = {}

	for i = 1, #data do
		local v = data[i]

		if not v.inventory or v.inventory == cache.serverId then
			v.inventory = 'player'
			local item = v.item

			if currentWeapon?.slot == item?.slot then
                if item.metadata then
				    currentWeapon.metadata = item.metadata
				    TriggerEvent('ox_inventory:currentWeapon', currentWeapon)
                else
                    currentWeapon = Weapon.Disarm(currentWeapon, true)
                end
			end

			local curItem = PlayerData.inventory[item.slot]

			if curItem and curItem.name then
				itemCount[curItem.name] = (itemCount[curItem.name] or 0) - curItem.count
			end

			if item.count then
				itemCount[item.name] = (itemCount[item.name] or 0) + item.count
			end

			changes[item.slot] = item.count and item or false
			if not item.count then item.name = nil end
			PlayerData.inventory[item.slot] = item.name and item or nil
		end
	end

	SendNUIMessage({ action = 'refreshSlots', data = { items = data, itemCount = itemCount} })

    if weight ~= PlayerData.weight then client.setPlayerData('weight', weight) end

	for itemName, count in pairs(itemCount) do
		local item = Items(itemName)

        if item then
            item.count += count

            TriggerEvent('ox_inventory:itemCount', item.name, item.count)

            if count < 0 then
                if shared.framework == 'esx' then
                    TriggerEvent('esx:removeInventoryItem', item.name, item.count)
                end

                if item.client?.remove then
                    item.client.remove(item.count)
                end
            elseif count > 0 then
                if shared.framework == 'esx' then
                    TriggerEvent('esx:addInventoryItem', item.name, item.count)
                end

                if item.client?.add then
                    item.client.add(item.count)
                end
            end
        end
	end

	client.setPlayerData('inventory', PlayerData.inventory)
	TriggerEvent('ox_inventory:updateInventory', changes)
end

RegisterNetEvent('ox_inventory:updateSlots', function(items, weights)
	if source ~= '' and next(items) then updateInventory(items, weights) end
end)

RegisterNetEvent('ox_inventory:inventoryReturned', function(data)
	if source == '' then return end
	if currentWeapon then currentWeapon = Weapon.Disarm(currentWeapon) end

	lib.notify({ description = locale('items_returned') })
	client.closeInventory()

	local num, items = 0, {}

	for _, slotData in pairs(data[1]) do
		num += 1
		items[num] = { item = slotData, inventory = cache.serverId }
	end

	updateInventory(items, data[3])
end)

RegisterNetEvent('ox_inventory:inventoryConfiscated', function(message)
	if source == '' then return end
	if message then lib.notify({ description = locale('items_confiscated') }) end
	if currentWeapon then currentWeapon = Weapon.Disarm(currentWeapon) end

	client.closeInventory()

	local num, items = 0, {}

	for slot in pairs(PlayerData.inventory) do
		num += 1
		items[num] = { item = { slot = slot }, inventory = cache.serverId }
	end

	updateInventory(items, 0)
end)


---@param point CPoint
local function nearbyDrop(point)
	if not point.instance or point.instance == currentInstance then
        DrawMarker(client.dropmarker.type, point.coords.x, point.coords.y, point.coords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, client.dropmarker.scale[1], client.dropmarker.scale[2], client.dropmarker.scale[3],
        ---@diagnostic disable-next-line: param-type-mismatch
        client.dropmarker.colour[1], client.dropmarker.colour[2], client.dropmarker.colour[3], 222, false, false, 0, true, false, false, false)
    end
end

---@param point CPoint
local function onEnterDrop(point)
	if not point.instance or point.instance == currentInstance and not point.entity then
		local model = point.model or client.dropmodel

        -- Prevent breaking inventory on invalid point.model instead use default client.dropmodel
        if not IsModelValid(model) and not IsModelInCdimage(model) then
            model = client.dropmodel
        end
		lib.requestModel(model)

		local entity = CreateObject(model, point.coords.x, point.coords.y, point.coords.z, false, true, true)

		SetModelAsNoLongerNeeded(model)
		PlaceObjectOnGroundProperly(entity)
		FreezeEntityPosition(entity, true)
		SetEntityCollision(entity, false, true)

		point.entity = entity
		Pickup.add(entity, point.invId)
	end
end

local function onExitDrop(point)
	local entity = point.entity

	if entity then
		Pickup.remove(entity)
		Utils.DeleteEntity(entity)
		point.entity = nil
	end
end

local function createDrop(dropId, data)
	local point = lib.points.new({
		coords = data.coords,
		distance = 16,
		invId = dropId,
		instance = data.instance,
		model = data.model
	})

	if point.model or client.dropprops or Pickup.enabled then
		point.distance = 30
		point.onEnter = onEnterDrop
		point.onExit = onExitDrop
	else
		point.nearby = nearbyDrop
	end

	client.drops[dropId] = point
end

RegisterNetEvent('ox_inventory:createDrop', function(dropId, data, owner, slot)
	if client.drops then
		createDrop(dropId, data)
	end

	if owner == cache.serverId then
		if currentWeapon?.slot == slot then
			currentWeapon = Weapon.Disarm(currentWeapon)
		end

		if invOpen and #(GetEntityCoords(playerPed) - data.coords) <= 1 then
			if not cache.vehicle then
				client.openInventory('drop', dropId)
			else
				SendNUIMessage({
					action = 'setupInventory',
					data = { rightInventory = currentInventory }
				})
			end
		end
	end
end)

RegisterNetEvent('ox_inventory:removeDrop', function(dropId)
	if client.drops then
		local point = client.drops[dropId]

		if point then
			client.drops[dropId] = nil
			point:remove()

			if point.entity then
				Pickup.remove(point.entity)
				Utils.DeleteEntity(point.entity)
			end
		end
	end
end)

---@type function?
local function setStateBagHandler(stateId)
	AddStateBagChangeHandler('invOpen', stateId, function(_, _, value)
		invOpen = value
	end)

	AddStateBagChangeHandler('invBusy', stateId, function(_, _, value)
		invBusy = value
	end)

    AddStateBagChangeHandler('canUseWeapons', stateId, function(_, _, value)
        if not value and currentWeapon then
            currentWeapon = Weapon.Disarm(currentWeapon)
        end
    end)

	AddStateBagChangeHandler('instance', stateId, function(_, _, value)
		currentInstance = value

		if client.drops then
			-- Iterate over known drops and remove any points in a different instance (ignoring no instance)
			for dropId, point in pairs(client.drops) do
				if point.instance then
					if point.instance ~= value then
						if point.entity then
							Utils.DeleteEntity(point.entity)
							point.entity = nil
						end

						point:remove()
					else
						-- Recreate the drop using data from the old point
						createDrop(dropId, point)
					end
				end
			end
		end
	end)

	AddStateBagChangeHandler('dead', stateId, function(_, _, value)
		Utils.WeaponWheel()
		PlayerData.dead = value
	end)

	AddStateBagChangeHandler('invHotkeys', stateId, function(_, _, value)
		invHotkeys = value
	end)

	setStateBagHandler = nil
end

RegisterNetEvent('txcl:heal', function()
    if source == '' then return end

    PlayerData.dead = false
end)

lib.onCache('seat', function(seat)
	if seat then
		local hasWeapon = GetCurrentPedVehicleWeapon(cache.ped)

		if hasWeapon then
			return Utils.WeaponWheel(true)
		end
	end

	Utils.WeaponWheel(false)
end)

lib.onCache('vehicle', function()
	if invOpen and (not currentInventory.entity or currentInventory.entity == cache.vehicle) then
		return client.closeInventory()
	end
end)

RegisterNetEvent('ox_inventory:setPlayerInventory', function(currentDrops, inventory, weight, player)
	if source == '' then return end

    ---@class PlayerData
    ---@field inventory table<number, SlotWithItem?>
    ---@field weight number
    ---@field groups table<string, number>
	PlayerData = player
	PlayerData.id = cache.playerId
	PlayerData.source = cache.serverId
    PlayerData.maxWeight = shared.playerweight

	setmetatable(PlayerData, {
		__index = function(self, key)
			if key == 'ped' then
				return PlayerPedId()
			end
		end
	})

	if setStateBagHandler then setStateBagHandler(('player:%s'):format(cache.serverId)) end

	local ItemData = table.create(0, #Items)

	for _, v in pairs(Items --[[@as table<string, OxClientItem>]]) do
		local buttons = v.buttons and {} or nil

		if buttons then
			for i = 1, #v.buttons do
				buttons[i] = {label = v.buttons[i].label, group = v.buttons[i].group}
			end
		end

		ItemData[v.name] = {
			label = v.label,
			stack = v.stack,
			close = v.close,
			count = 0,
			description = v.description,
			buttons = buttons,
			ammoName = v.ammoname,
			image = v.client?.image,
			weapon = v.weapon and true or nil,
			component = v.client and v.client.component and true or nil,
			componentType = v.client and v.client.component and v.type or nil,
			category = client.itemcolours and Categories.of(v.name, v) or nil,
			rarity = client.rarity and Rarity.of(v.name, v) or nil
		}
	end

	for _, data in pairs(inventory) do
		local item = Items[data.name]

		if item then
			item.count += data.count
			ItemData[data.name].count += data.count
			local add = item.client?.add

			if add then
				add(item.count)
			end
		end
	end

	local phone = Items.phone

	if phone and phone.count < 1 then
		pcall(function()
			return exports.npwd:setPhoneDisabled(true)
		end)
	end

	client.setPlayerData('inventory', inventory)
	client.setPlayerData('weight', weight)
	currentWeapon = nil
	Weapon.ClearAll()

	local uiLocales = {}
	local locales = lib.getLocales()

	for k, v in pairs(locales) do
		if k:find('^ui_')then
			uiLocales[k] = v
		end
	end

	uiLocales['$'] = locales['$']
	uiLocales.ammo_type = locales.ammo_type

	client.drops = currentDrops

	for dropId, data in pairs(currentDrops) do
		createDrop(dropId, data)
	end

	local hasTextUi
	local uiOptions = { icon = 'fa-id-card' }

	---@param point CPoint
	local function nearbyLicense(point)
		---@diagnostic disable-next-line: param-type-mismatch
		DrawMarker(2, point.coords.x, point.coords.y, point.coords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 0.2, 0.15, 30, 150, 30, 222, false, false, 0, true, false, false, false)

		if point.isClosest and point.currentDistance < 1.2 then
			if not hasTextUi then
				hasTextUi = point
				lib.showTextUI(point.message, uiOptions)
			end

			if IsControlJustReleased(0, 38) then
				lib.callback('ox_inventory:buyLicense', 1000, function(success, message)
					if success ~= nil then
						lib.notify({
							id = message,
							type = success == false and 'error' or 'success',
							description = locale(message, locale('license', point.type:gsub("^%l", string.upper)))
						})
					end
				end, point.invId)
			end
		elseif hasTextUi == point then
			hasTextUi = false
			lib.hideTextUI()
		end
	end

	for id, data in pairs(lib.load('data.licenses') or {}) do
		lib.points.new({
			coords = data.coords,
			distance = 16,
			inv = 'license',
			type = data.name,
			price = data.price,
			invId = id,
			nearby = nearbyLicense,
			message = ('**%s**  \n%s'):format(locale('purchase_license', data.name), locale('interact_prompt', GetControlInstructionalButton(0, 38, true):sub(3)))
		})
	end

	while not client.uiLoaded do Wait(50) end

	SendNUIMessage({
		action = 'init',
		data = {
			locale = uiLocales,
			items = ItemData,
			leftInventory = {
				id = cache.playerId,
				slots = shared.playerslots + Equipment.count,
				items = PlayerData.inventory,
				maxWeight = shared.playerweight,
			},
			equipment = Equipment.payload(),
			config = {
				itemColours = client.itemcolours,
				categories = client.itemcolours and Categories.palette or {},
				rarities = client.rarity and Rarity.palette or {},
				rename = client.rename,
				throwing = client.throwing,
				status = client.statusboxes,
				weaponEditor = client.weaponeditor,
			},
			imagepath = client.imagepath
		}
	})

	PlayerData.loaded = true

	if not client.disablesetupnotification then
		lib.notify({ description = locale('inventory_setup') })
	end

	Shops.refreshShops()
	Inventory.Stashes()
	Inventory.Evidence()

	if registerCommands then registerCommands() end

	TriggerEvent('ox_inventory:updateInventory', PlayerData.inventory)

	client.interval = SetInterval(function()
        local canSteal = canOpenTarget(playerPed)

        if canSteal ~= client.player:get('canSteal') then
            client.player:setr('canSteal', canSteal)
        end

		if invOpen == false then
			playerCoords = GetEntityCoords(playerPed)

			if currentWeapon and IsPedUsingActionMode(playerPed) then
				SetPedUsingActionMode(playerPed, false, -1, 'DEFAULT_ACTION')
			end

		elseif invOpen == true then
			if not canOpenInventory() then
				client.closeInventory()
			else
				playerCoords = GetEntityCoords(playerPed)

				if not currentInventory.ignoreSecurityChecks then
                    local maxDistance = (currentInventory.distance or currentInventory.type == 'stash' and 4.8 or 1.8) + 0.2

					if currentInventory.type == 'otherplayer' then
						local id = GetPlayerFromServerId(currentInventory.id --[[@as number]])
						local ped = GetPlayerPed(id)
						local pedCoords = GetEntityCoords(ped)

						if not id or #(playerCoords - pedCoords) > maxDistance or (not client.hasGroup(shared.police) and not Player(currentInventory.id).state.canSteal) then
							client.closeInventory()
							lib.notify({ id = 'inventory_lost_access', type = 'error', description = locale('inventory_lost_access') })
						else
							TaskTurnPedToFaceCoord(playerPed, pedCoords.x, pedCoords.y, pedCoords.z, 50)
						end

					elseif currentInventory.coords and (#(playerCoords - currentInventory.coords) > maxDistance or canSteal) then
						client.closeInventory()
						lib.notify({ id = 'inventory_lost_access', type = 'error', description = locale('inventory_lost_access') })
					end
				end
			end
		end

		if client.parachute and GetPedParachuteState(playerPed) ~= -1 then
			Utils.DeleteEntity(client.parachute[1])
			client.parachute = false
		end

		if EnableWeaponWheel then return end

		local weaponHash = GetSelectedPedWeapon(playerPed)

		if currentWeapon then
			if weaponHash ~= currentWeapon.hash and currentWeapon.timer then
				local weaponCount = Items[currentWeapon.name]?.count

				if weaponCount > 0 then
					SetCurrentPedWeapon(playerPed, currentWeapon.hash, true)
					SetAmmoInClip(playerPed, currentWeapon.hash, currentWeapon.metadata.ammo)
					SetPedCurrentWeaponVisible(playerPed, true, false, false, false)

					weaponHash = GetSelectedPedWeapon(playerPed)
				end

				if weaponHash ~= currentWeapon.hash then
                    lib.print.info(('%s was forcibly unequipped (caused by game behaviour or another resource)'):format(currentWeapon.name))
					currentWeapon = Weapon.Disarm(currentWeapon, true)
				end
			end
		elseif client.weaponmismatch and not client.ignoreweapons[weaponHash] then
			local weaponType = GetWeapontypeGroup(weaponHash)

			if weaponType ~= 0 and weaponType ~= `GROUP_UNARMED` then
				Weapon.Disarm(currentWeapon, true)
			end
		end
	end, 200)

	local playerId = cache.playerId
	local EnableKeys = client.enablekeys
	local DisablePlayerVehicleRewards = DisablePlayerVehicleRewards
	local DisableAllControlActions = DisableAllControlActions
	local HideHudAndRadarThisFrame = HideHudAndRadarThisFrame
	local EnableControlAction = EnableControlAction
	local DisablePlayerFiring = DisablePlayerFiring
	local HudWeaponWheelIgnoreSelection = HudWeaponWheelIgnoreSelection
	local DisableControlAction = DisableControlAction
	local IsPedShooting = IsPedShooting
	local IsControlJustReleased = IsControlJustReleased

	client.tick = SetInterval(function()
		DisablePlayerVehicleRewards(playerId)

		if invOpen then
			DisableAllControlActions(0)
			HideHudAndRadarThisFrame()

			for i = 1, #EnableKeys do
				EnableControlAction(0, EnableKeys[i], true)
			end

			if currentInventory.type == 'drop' or currentInventory.type == 'newdrop' then
				EnableControlAction(0, 30, true)
				EnableControlAction(0, 31, true)
			end
		else
			if invBusy then
				DisableControlAction(0, 23, true)
				DisableControlAction(0, 36, true)
			end

			if usingItem or invOpen or IsPedCuffed(playerPed) then
				DisablePlayerFiring(playerId, true)
			end

			if not EnableWeaponWheel then
				HudWeaponWheelIgnoreSelection()
				DisableControlAction(0, 37, true)
			end

			if currentWeapon and currentWeapon.timer then
				DisableControlAction(0, 80, true)
				DisableControlAction(0, 140, true)

				if currentWeapon.metadata.durability <= 0 or not currentWeapon.timer then
					DisablePlayerFiring(playerId, true)
				elseif client.aimedfiring and not currentWeapon.melee and currentWeapon.group ~= `GROUP_PETROLCAN` and not IsPlayerFreeAiming(playerId) then
					DisablePlayerFiring(playerId, true)
				end

				local weaponAmmo = currentWeapon.metadata.ammo

				if not invBusy and currentWeapon.timer ~= 0 and currentWeapon.timer < GetGameTimer() then
					currentWeapon.timer = 0

					if weaponAmmo then
						TriggerServerEvent('ox_inventory:updateWeapon', 'ammo', weaponAmmo)

						if client.autoreload and currentWeapon.ammo and GetAmmoInPedWeapon(playerPed, currentWeapon.hash) == 0 then
							local slotId = Inventory.GetSlotIdWithItem(currentWeapon.ammo, { type = currentWeapon.metadata.specialAmmo }, false)

							if slotId then
								CreateThread(function() useSlot(slotId) end)
							end
						end

					elseif currentWeapon.metadata.durability then
						TriggerServerEvent('ox_inventory:updateWeapon', 'melee', currentWeapon.melee)
						currentWeapon.melee = 0
					end
				elseif weaponAmmo then
					if IsPedShooting(playerPed) then
						local currentAmmo
						local durabilityDrain = Items[currentWeapon.name].durability

						if currentWeapon.group == `GROUP_PETROLCAN` or currentWeapon.group == `GROUP_FIREEXTINGUISHER` then
							currentAmmo = weaponAmmo - durabilityDrain < 0 and 0 or weaponAmmo - durabilityDrain
							currentWeapon.metadata.durability = currentAmmo
							currentWeapon.metadata.ammo = (weaponAmmo < currentAmmo) and 0 or currentAmmo

							if currentAmmo <= 0 then
								SetPedInfiniteAmmo(playerPed, false, currentWeapon.hash)
							end
						else
							currentAmmo = GetAmmoInPedWeapon(playerPed, currentWeapon.hash)

							if currentAmmo < weaponAmmo then
								currentAmmo = (weaponAmmo < currentAmmo) and 0 or currentAmmo
								currentWeapon.metadata.ammo = currentAmmo
								currentWeapon.metadata.durability = currentWeapon.metadata.durability - (durabilityDrain * math.abs((weaponAmmo or 0.1) - currentAmmo))
							end
						end

						if currentAmmo <= 0 then
							if cache.vehicle then
								TaskSwapWeapon(playerPed, true)
							end

							currentWeapon.timer = GetGameTimer() + 200
						else currentWeapon.timer = GetGameTimer() + (GetWeaponTimeBetweenShots(currentWeapon.hash) * 1000) + 100 end
					end
				elseif currentWeapon.throwable then
					if not invBusy and IsControlPressed(0, 24) then
						invBusy = 1

						CreateThread(function()
							local weapon = currentWeapon

							while currentWeapon and (not IsPedWeaponReadyToShoot(cache.ped) or IsDisabledControlPressed(0, 24)) and GetSelectedPedWeapon(playerPed) == weapon.hash do
								Wait(0)
							end

							if GetSelectedPedWeapon(playerPed) == weapon.hash then Wait(700) end

							while IsPedPlantingBomb(playerPed) do Wait(0) end

							TriggerServerEvent('ox_inventory:updateWeapon', 'throw', nil, weapon.slot)
							client.player:setr('invBusy', false)

							currentWeapon = nil

							RemoveWeaponFromPed(playerPed, weapon.hash)
							TriggerEvent('ox_inventory:currentWeapon')
						end)
					end
				elseif currentWeapon.melee and IsControlJustReleased(0, 24) and IsPedPerformingMeleeAction(playerPed) then
					currentWeapon.melee += 1
					currentWeapon.timer = GetGameTimer() + 200
				end
			end
		end
	end)

	client.player:setr('invBusy', false)
	client.player:set('invOpen', false)
	client.player:set('invHotkeys', true)
	client.player:set('canUseWeapons', true)
	collectgarbage('collect')
end)

AddEventHandler('onResourceStop', function(resourceName)
	if shared.resource == resourceName then
		client.onLogout()
	end
end)

RegisterNetEvent('ox_inventory:viewInventory', function(left, right)
	if source == '' then return end

	client.player:set('invOpen', true)
	SetInterval(client.interval, 100)
	SetNuiFocus(true, true)
	SetNuiFocusKeepInput(true)
	closeTrunk()

	if client.screenblur then Utils.blurIn() end

	currentInventory = right or defaultInventory
	currentInventory.ignoreSecurityChecks = true
    currentInventory.type = 'inspect'
	left.items = PlayerData.inventory
	left.groups = PlayerData.groups

	SendNUIMessage({
		action = 'setupInventory',
		data = {
			leftInventory = left,
			rightInventory = currentInventory
		}
	})
end)

RegisterNUICallback('uiLoaded', function(_, cb)
	client.uiLoaded = true
	cb(1)
end)

RegisterNUICallback('getItemData', function(itemName, cb)
	cb(Items[itemName])
end)

RegisterNUICallback('removeComponent', function(data, cb)
	cb(1)

	if not currentWeapon then
		return TriggerServerEvent('ox_inventory:updateWeapon', 'component', data)
	end

	if data.slot ~= currentWeapon.slot then
		return lib.notify({ id = 'weapon_hand_wrong', type = 'error', description = locale('weapon_hand_wrong') })
	end

	local itemSlot = PlayerData.inventory[currentWeapon.slot]

    if not itemSlot then return end

	for _, component in pairs(Items[data.component].client.component) do
		if HasPedGotWeaponComponent(playerPed, currentWeapon.hash, component) then
			for k, v in pairs(itemSlot.metadata.components) do
				if v == data.component then
					local success = lib.callback.await('ox_inventory:updateWeapon', false, 'component', k)

					if success then
						RemoveWeaponComponentFromPed(playerPed, currentWeapon.hash, component)
						TriggerEvent('ox_inventory:updateWeaponComponent', 'removed', component, data.component)
					end

					break
				end
			end
		end
	end
end)

RegisterNUICallback('weaponEditor', function(slot, cb)
	if not client.weaponeditor or type(slot) ~= 'number' then return cb(false) end

	local item = PlayerData.inventory[slot]
	local data = item and Items[item.name]

	if not data or not data.weapon then return cb(false) end

	if currentWeapon?.slot ~= slot then
		local close = data.close
		data.close = false
		useSlot(slot, true)
		data.close = close

		if currentWeapon?.slot ~= slot then return cb(false) end
	end

	local components = {}

	for name, definition in pairs(Items) do
		local list = definition.client and definition.client.component

		if list then
			for i = 1, #list do
				if DoesWeaponTakeWeaponComponent(currentWeapon.hash, list[i]) then
					components[#components + 1] = { name = name, type = definition.type }
					break
				end
			end
		end
	end

	local attached = {}

	for _, name in ipairs((item.metadata or {}).components or {}) do
		local list = Items[name] and Items[name].client and Items[name].client.component

		for i = 1, #(list or {}) do
			attached[#attached + 1] = list[i]
		end
	end

	cb({ components = components, live = WeaponView.start(currentWeapon.hash, attached) })
end)

RegisterNUICallback('removeAmmo', function(slot, cb)
	cb(1)
	local slotData = PlayerData.inventory[slot]

	if usingItem or not slotData or not slotData.metadata.ammo or slotData.metadata.ammo == 0 then
		return
	end

	local success = lib.callback.await('ox_inventory:removeAmmoFromWeapon', false, slot)

	if success and slot == currentWeapon?.slot then
		SetPedAmmo(playerPed, currentWeapon.hash, 0)
	end
end)

RegisterNUICallback('useItem', function(slot, cb)
	local item = type(slot) == 'number' and PlayerData.inventory[slot]
	local data = item and Items[item.name]

	if data and data.component and WeaponView.isActive() then
		local close = data.close
		data.close = false
		useSlot(slot)
		data.close = close
	else
		useSlot(slot --[[@as number]])
	end

	cb(1)
end)

local function giveItemToTarget(serverId, slotId, count)
    if type(slotId) ~= 'number' then return TypeError('slotId', 'number', type(slotId)) end
    if count and type(count) ~= 'number' then return TypeError('count', 'number', type(count)) end

    if slotId == currentWeapon?.slot then
        currentWeapon = Weapon.Disarm(currentWeapon)
    end

    Utils.PlayAnim(0, 'mp_common', 'givetake1_a', 1.0, 1.0, 2000, 50, 0.0, 0, 0, 0)

    local notification = lib.callback.await('ox_inventory:giveItem', false, slotId, serverId, count or 0)

    if notification then
        lib.notify({ type = 'error', description = locale(table.unpack(notification)) })
    end
end

exports('giveItemToTarget', giveItemToTarget)

local function isGiveTargetValid(ped, coords)
    if cache.vehicle and GetVehiclePedIsIn(ped, false) == cache.vehicle then
        return true
    end

    local entity = Utils.Raycast(1|4|8|16, coords + vec3(0, 0, 0.5), 0.2)

    return entity == ped and IsEntityVisible(ped)
end

local givePanel

RegisterNUICallback('giveToPlayer', function(data, cb)
	cb(1)

	if not givePanel or not data or not givePanel.ids[data.id] or data.slot ~= givePanel.slot then return end

	local target = givePanel
	givePanel = nil

	if usingItem then return end

	local targetPlayer = GetPlayerFromServerId(data.id)
	if targetPlayer == -1 then return end

	local ped = GetPlayerPed(targetPlayer)
	local coords = cache.vehicle and GetWorldPositionOfEntityBone(playerPed, 0) or GetEntityCoords(playerPed)

	if not isGiveTargetValid(ped, GetEntityCoords(ped)) or #(coords - GetEntityCoords(ped)) > 3.5 then
		return lib.notify({ type = 'error', description = locale('cannot_give', target.count or 0, '') })
	end

	giveItemToTarget(data.id, target.slot, target.count)
end)

RegisterNUICallback('renameItem', function(data, cb)
	cb(1)

	if not client.rename or type(data) ~= 'table' then return end

	if not lib.callback.await('ox_inventory:renameItem', false, data.slot, data.label) then
		lib.notify({ type = 'error', description = locale('cannot_rename') })
	end
end)

local throwing = false

RegisterNUICallback('throwItem', function(data, cb)
	cb(1)

	if not client.throwing or throwing or type(data) ~= 'table' or not Throwing.ready() then return end

	local item = PlayerData.inventory[data.slot]
	if not item then return end

	if not canUseItem() or PlayerData.cuffed or IsPedCuffed(playerPed) or cache.vehicle or IsEntityInWater(playerPed) then
		return lib.notify({ type = 'error', description = locale('cannot_perform') })
	end

	local requested = math.floor(tonumber(data.count) or 0)
	local count = (requested < 1 or requested > item.count) and item.count or requested

	if currentWeapon and currentWeapon.slot == data.slot then
		currentWeapon = Weapon.Disarm(currentWeapon, true)
	end

	throwing = true
	Throwing.mark()

	local unit = (item.weight or 0) / math.max(item.count or 1, 1)
	local target = Throwing.target(playerPed, unit * count)

	local success, response, weaponSlot = lib.callback.await('ox_inventory:swapItems', false, {
		fromSlot = data.slot,
		fromType = 'player',
		toSlot = 1,
		toType = 'newdrop',
		count = count,
		coords = target,
		instance = currentInstance,
	})

	if success then
		if weaponSlot and currentWeapon then
			currentWeapon.slot = weaponSlot
		end

		if type(response) == 'table' then
			updateInventory(response.items, response.weight)
		end

		if Throwing.closes() then client.closeInventory() end

		Throwing.animate(playerPed)
	elseif type(response) == 'table' then
		SendNUIMessage({ action = 'refreshSlots', data = { items = response } })
	elseif response then
		lib.notify({ type = 'error', description = locale(response) })
	end

	throwing = false
end)

RegisterNUICallback('closeGiveList', function(_, cb)
	givePanel = nil
	cb(1)
end)

RegisterNUICallback('giveItem', function(data, cb)
	cb(1)

    if usingItem then return end

	if client.giveplayerlist then
		local coords = cache.vehicle and GetWorldPositionOfEntityBone(playerPed, 0) or GetEntityCoords(playerPed)

		local nearbyPlayers = lib.getNearbyPlayers(coords, 3.0)
        local nearbyCount = #nearbyPlayers

		if nearbyCount == 0 then return end

        if nearbyCount == 1 then
			local option = nearbyPlayers[1]

            if not isGiveTargetValid(option.ped, option.coords) then return end

            return giveItemToTarget(GetPlayerServerId(option.id), data.slot, data.count)
        end

        local giveList, n = {}, 0

		for i = 1, #nearbyPlayers do
			local option = nearbyPlayers[i]

            if isGiveTargetValid(option.ped, option.coords) then
				option.id = GetPlayerServerId(option.id)
				local playerName = Utils.getPlayerName(option.id)
                ---@diagnostic disable-next-line: inject-field
				option.label = playerName
				n += 1
				giveList[n] = option
			end
		end

        if n == 0 then return end

		if client.givepanel then
			local players = {}

			for i = 1, n do
				players[i] = { id = giveList[i].id, label = giveList[i].label, distance = #(coords - giveList[i].coords) }
			end

			givePanel = { slot = data.slot, count = data.count, ids = {} }
			for i = 1, n do givePanel.ids[giveList[i].id] = true end

			return SendNUIMessage({ action = 'openGiveList', data = { players = players, slot = data.slot, count = data.count } })
		end

		lib.registerMenu({
			id = 'ox_inventory:givePlayerList',
			title = 'Give item',
			options = giveList,
		}, function(selected)
            giveItemToTarget(giveList[selected].id, data.slot, data.count)
        end)

		return lib.showMenu('ox_inventory:givePlayerList')
	end

    if cache.vehicle then
		local seats = GetVehicleMaxNumberOfPassengers(cache.vehicle) - 1

		if seats >= 0 then
			local passenger = GetPedInVehicleSeat(cache.vehicle, cache.seat - 2 * (cache.seat % 2) + 1)

			if passenger ~= 0 and IsEntityVisible(passenger) then
                return giveItemToTarget(GetPlayerServerId(NetworkGetPlayerIndexFromPed(passenger)), data.slot, data.count)
			end
		end

        return
	end

    local entity = Utils.Raycast(1|2|4|8|16, GetOffsetFromEntityInWorldCoords(cache.ped, 0.0, 3.0, 0.5), 0.2)

    if entity and IsPedAPlayer(entity) and IsEntityVisible(entity) and #(GetEntityCoords(playerPed, true) - GetEntityCoords(entity, true)) < 3.0 then
        return giveItemToTarget(GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity)), data.slot, data.count)
    end
end)

RegisterNUICallback('useButton', function(data, cb)
	useButton(data.id, data.slot)
	cb(1)
end)

RegisterNUICallback('exit', function(_, cb)
	client.closeInventory()
	cb(1)
end)

lib.callback.register('ox_inventory:startCrafting', function(id, recipe)
	recipe = CraftingBenches[id].items[recipe]

	return lib.progressCircle({
		label = locale('crafting_item', recipe.metadata?.label or Items[recipe.name].label),
		duration = recipe.duration or 3000,
		canCancel = true,
		disable = {
			move = true,
			combat = true,
		},
		anim = {
			dict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
			clip = 'machinic_loop_mechandplayer',
		}
	})
end)

local swapActive = false

---Synchronise and validate all item movement between the NUI and server.
RegisterNUICallback('swapItems', function(data, cb)
    if swapActive or not invOpen or invBusy or usingItem then return cb(false) end

    swapActive = true

	if data.toType == 'newdrop' then
		if cache.vehicle or IsPedFalling(playerPed) then
			swapActive = false
			return cb(false)
		end

		local coords = GetEntityCoords(playerPed)

		if IsEntityInWater(playerPed) then
			local destination = vec3(coords.x, coords.y, -200)
			local handle = StartShapeTestLosProbe(coords.x, coords.y, coords.z, destination.x, destination.y, destination.z, 511, cache.ped, 4)

			while true do
				Wait(0)
				local retval, hit, endCoords = GetShapeTestResult(handle)

				if retval ~= 1 then
					if not hit then return end

					data.coords = vec3(endCoords.x, endCoords.y, endCoords.z + 1.0)

					break
				end
			end
		else
			data.coords = coords
		end
    end

	if currentInstance then
		data.instance = currentInstance
	end

	if currentWeapon and data.fromType ~= data.toType then
		if (data.fromType == 'player' and data.fromSlot == currentWeapon.slot) or (data.toType == 'player' and data.toSlot == currentWeapon.slot) then
			currentWeapon = Weapon.Disarm(currentWeapon, true)
		end
	end

	local success, response, weaponSlot = lib.callback.await('ox_inventory:swapItems', false, data)
    swapActive = false

	cb(success or false)

	if success then
        if weaponSlot and currentWeapon then
            currentWeapon.slot = weaponSlot
        end

		if response then
			updateInventory(response.items, response.weight)
		end
	elseif response then
		if type(response) == 'table' then
			SendNUIMessage({ action = 'refreshSlots', data = { items = response } })
		else
			lib.notify({ type = 'error', description = locale(response) })
		end
	end
end)

RegisterNUICallback('buyItem', function(data, cb)
	---@type boolean, false | { [1]: number, [2]: SlotWithItem, [3]: SlotWithItem | false, [4]: number}, NotifyProps
	local response, data, message = lib.callback.await('ox_inventory:buyItem', 100, data)

	if data then
		updateInventory({
			{
				item = data[2],
				inventory = cache.serverId
			}
		}, data[4])

		if data[3] then
			SendNUIMessage({
				action = 'refreshSlots',
				data = {
					items = {
						{
							item = data[3],
							inventory = 'shop'
						}
					}
				}
			})
		end
	end

	if message then
		lib.notify(message)
	end

	cb(response)
end)

RegisterNUICallback('craftItem', function(data, cb)
	cb(true)

	local id, index = currentInventory.id, currentInventory.index

	for i = 1, data.count do
		local success, response = lib.callback.await('ox_inventory:craftItem', 200, id, index, data.fromSlot, data.toSlot)

		if not success then
			if response then lib.notify({ type = 'error', description = locale(response or 'cannot_perform') }) end
			break
		end
	end

	if currentInventory.type ~= 'crafting' then
		client.openInventory('crafting', { id = id, index = index })
	end
end)

lib.callback.register('ox_inventory:getVehicleData', function(netid)
	local entity = NetworkGetEntityFromNetworkId(netid)

	if entity then
		return GetEntityModel(entity), GetVehicleClass(entity)
	end
end)
