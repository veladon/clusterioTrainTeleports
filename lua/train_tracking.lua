local function unalert_all_players(entity)
    if entity.valid then
        for k, p in pairs(game.players) do
            p.remove_alert({entity=entity})
        end
    end
end

local function alert_all_players(entity, message)
    if entity.valid then
        for k, p in pairs(game.players) do
            p.add_custom_alert(entity, {type="item", name="train-stop"}, message, true)
        end
    end
end

local inventory_types = {}
do
    local map = {}
    for _, inventory_type in pairs(defines.inventory) do
        map[inventory_type] = true
    end
    for t in pairs(map) do
        inventory_types[#inventory_types + 1] = t
    end
    table.sort(inventory_types)
end

local function serialize_equipment_grid(grid)
    local names, xs, ys = {}, {}, {}

    local position = {0,0}
    local width, height = grid.width, grid.height
    local processed = {}
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local base = (y + 1) * width + x + 1
            if not processed[base] then
                position[1], position[2] = x, y
                local equipment = grid.get(position)
                if equipment ~= nil then
                    local shape = equipment.shape
                    for j = 0, shape.height - 1 do
                        for i = 0, shape.width - 1 do
                            processed[base + j * width + i] = true
                        end
                    end

                    local idx = #names + 1
                    names[idx] = equipment.name
                    xs[idx] = x
                    ys[idx] = y
                end
            end
        end
    end
    return {
        names = names,
        xs = xs,
        ys = ys,
    }
end

local function serialize_inventory(inventory)
    local filters

    local bar = nil
    if inventory.hasbar() then
        bar = inventory.getbar()
    end

    if inventory.supports_filters() then
        filters = {}
        for i = 1, #inventory do
            filters[i] = inventory.get_filter(i)
        end
    end
    local item_names, item_counts, item_durabilities,
    item_ammos, item_exports, item_labels, item_grids
    = {}, {}, {}, {}, {}, {}, {}

    for i = 1, #inventory do
        local slot = inventory[i]
        if slot.valid_for_read then
            if slot.is_item_with_inventory then
                print("sending items with inventory is not allowed")
            elseif slot.is_blueprint or slot.is_blueprint_book
                    or slot.is_deconstruction_item or slot.is_item_with_tags then
                local success, export = pcall(slot.export_stack)
                if not success then
                    print("failed to export item")
                else
                    item_exports[i] = export
                end
            else
                item_names[i] = slot.name
                item_counts[i] = slot.count
                local durability = slot.durability
                if durability ~= nil then
                    item_durabilities[i] = durability
                end
                if slot.type == "ammo" then
                    item_ammos[i] = slot.ammo
                end
                if slot.is_item_with_label then
                    item_labels[i] = {
                        label = slot.label,
                        label_color = slot.label_color,
                        allow_manual_label_change = slot.allow_manual_label_change,
                    }
                end

                local grid = slot.grid
                if grid then
                    item_grids[i] = serialize_equipment_grid(grid)
                end
            end
        end
    end

    return {
        bar = bar,
        filters = filters,
        item_names = item_names,
        item_counts = item_counts,
        item_durabilities = item_durabilities,
        item_ammos = item_ammos,
        item_exports = item_exports,
        item_labels = item_labels,
        item_grids = item_grids,
    }
end

local function serialize_train(train)
    local station = train.station
    if not station then
        -- don't error here. if you switch a train to manual_mode in the time it waits to be teleport erroring will crash the game
        log("train has no station")
        return nil
    end

    local data = {}
    for _, carriage in pairs(train.carriages) do
        local carriage_index = _

        --[[
        local distance = math.abs(carriage.position.x - station.position.x) + math.abs(carriage.position.y - station.position.y)
        local index = (distance + 2) / 7
        carriage_index = math.floor(index + 0.5)

        if carriage_index >= 1 and carriage_index <= 50 and math.abs(index - carriage_index) <= 0.01 then
        else
            return nil
        end
        ]]--

        local is_flipped = math.floor(carriage.orientation * 4 + 0.5)
        is_flipped = bit32.bxor(bit32.rshift(station.direction, 2), bit32.rshift(is_flipped, 1))

        local inventories = {}
        for _, inventory_type in pairs(inventory_types) do
            local inventory = carriage.get_inventory(inventory_type)
            if inventory then
                    inventories[inventory_type] = serialize_inventory(inventory)
            end
        end

        local fluids
        do
            local fluidbox = carriage.fluidbox
            if #fluidbox > 0 then
                fluids = {}
                for i = 1, #fluidbox do
                    fluids[i] = fluidbox[i]
                end
            end
        end

        data[carriage_index] = {
            name = carriage.name,
            color = carriage.color,
            health = carriage.health,
            is_flipped = is_flipped,
            inventories = inventories,
            fluids = fluids,
            energy = carriage.energy,
            currently_burning = carriage.burner and carriage.burner.currently_burning and carriage.burner.currently_burning.name,
            remaining_burning_fuel = carriage.burner and carriage.burner.remaining_burning_fuel
        }
    end

    return data
end

local function serialize_train_schedule(train)
    local schedule = train.schedule
    if schedule == nil then
        return
    end
    local myInstanceName = trainStopTrackingApi.lookupIdToServerName(0)
    for _, record in pairs(schedule.records) do
        -- add the @ instanceName to local stations
        if not record.station:match("@ (.*)$") then
            record.station = record.station .. " @ " .. myInstanceName
        end
    end
    return schedule
end


local function deserialize_grid(grid, data)
    grid.clear()
    local names, xs, ys = data.names, data.xs, data.ys
    for i = 1, #names do
        grid.put({
            name = names[i],
            position = {xs[i], ys[i]}
        })
    end
end

local function deserialize_inventory(inventory, data)
    local item_names, item_counts, item_durabilities,
    item_ammos, item_exports, item_labels, item_grids
    = data.item_names, data.item_counts, data.item_durabilities,
    data.item_ammos, data.item_exports, data.item_labels, data.item_grids

    if inventory.hasbar() then
        inventory.setbar(data.bar)
    end

    for idx, name in pairs(item_names) do
        local slot = inventory[idx]
        slot.set_stack({
            name = name,
            count = item_counts[idx]
        })
        if item_durabilities[idx] ~= nil then
            slot.durability = item_durabilities[idx]
        end
        if item_ammos[idx] ~= nil then
            slot.ammo = item_ammos[idx]
        end
        local label = item_labels[idx]
        if label then
            slot.label = label.label
            slot.label_color = label.label_color
            slot.allow_manual_label_change = label.allow_manual_label_change
        end

        local grid = item_grids[idx]
        if grid then
            deserialize_grid(slot.grid, grid)
        end
    end
    for idx, str in pairs(item_exports) do
        inventory[idx].import_stack(str)
    end
    if data.filters then
        for idx, filter in pairs(data.filters) do
            inventory.set_filter(idx, filter)
        end
    end
end

local function deserialize_train(station, data)
    local rotation
    if bit32.band(station.direction, 2) == 0 then
        rotation = { 1, 0, 0, 1 }
    else
        rotation = { 0, -1, 1, 0 }
    end
    if bit32.band(station.direction, 4) == 4 then
        for i = 1, 4 do rotation[i] = -rotation[i] end
    end

    local created_entities = {}
    xpcall(function ()
        local sp = station.position
        for idx, carriage in ipairs(data) do
            local ox, oy = -2, 7 * idx - 4
            ox, oy = rotation[1] * ox + rotation[2] * oy, rotation[3] * ox + rotation[4] * oy

            local entity = game.surfaces[1].create_entity({
                name = carriage.name,
                force = game.forces.player,
                position = {x=sp.x + ox, y=sp.y + oy},
                direction = (station.direction + carriage.is_flipped * 4) % 8
            })

            if entity and entity.valid then
                created_entities[#created_entities + 1] = entity
            else
                error("failed to create train carriage entity")
            end

            if carriage.color then
                entity.color = carriage.color
            end

            if carriage.health then
                entity.health = carriage.health
            end

            for inventory_id, inventory_data in pairs(carriage.inventories) do
                deserialize_inventory(entity.get_inventory(inventory_id), inventory_data)
            end

            if carriage.fluids then
                local fluidbox = entity.fluidbox
                for i = 1, #carriage.fluids do
                    fluidbox[i] = carriage.fluids[i]
                end
            end

            if carriage.energy > 0 then
                entity.energy = carriage.energy
                if entity.burner then
                    entity.burner.currently_burning = carriage.currently_burning
                    entity.burner.remaining_burning_fuel = carriage.remaining_burning_fuel
                end
            end



        end
    end, function (error_message)
        for _, entity in ipairs(created_entities) do
            entity.destroy()
        end
        created_entities = nil
    end)

    if created_entities ~= nil and created_entities[1] and created_entities[1].valid then
        return created_entities[1].train
    end
end

local function escape_pattern(text)
    return text:gsub("([^%w])", "%%%1")
end

local function deserialize_train_schedule(train, schedule)
    if schedule == nil then
        return
    end

    for _, record in ipairs(schedule.records) do
        local myInstanceName = trainStopTrackingApi.lookupIdToServerName(0)
        for _, record in ipairs(schedule.records) do
            -- remove the @ instanceName from local stations
            if record.station:match("@ " .. escape_pattern(myInstanceName)) then
                record.station = record.station:match("^(<CT?[0-9%+]*> .*) @")
            end
        end

    end

    schedule.current = schedule.current % #schedule.records + 1
    train.schedule = schedule
    train.manual_mode = false
end



script.on_event(defines.events.on_tick, function(event)

    if #global.trainsToDestroy > 0 then

        for k, v in pairs(global.trainsToDestroy) do
            if v.valid then
                unalert_all_players(v.carriages[1])
                for _, carriage in pairs(v.carriages) do
                    carriage.destroy()
                end

                global.trainsToDestroy[k] = nil
            end
        end

        script.raise_event(defines.events.script_raised_destroy, {})

    end
end)

script.on_nth_tick(TELEPORT_WORK_INTERVAL, function(event)
    -- do not start until we are up and running
    if tonumber(global.worldID) == 0 or global.lookUpTableIdToServer == nil or global.lookUpTableIdToServer[tonumber(global.worldID)] == nil then
        -- game.write_file(fileName, "init\n", true, 0)
        return
    end

    for k, v in pairs(global.trainsToSend) do
        if v.train.valid and not v.train.manual_mode and v.train.station ~= nil and v.train.station.valid then
            if global.trainLastSpawnTick[v.train.id] == nil or (event.tick - global.trainLastSpawnTick[v.train.id]) > TELEPORT_COOLDOWN_TICKS then
                local train = v.train
                local train_schedule = train.schedule
                local current_stop = train_schedule.current
                local number_of_stops = #train_schedule.records

                local next_stop = current_stop + 1
                if next_stop > number_of_stops then
                    next_stop = 1
                end

                if train_schedule.records[current_stop].station == train_schedule.records[next_stop].station then
                    alert_all_players(train.station, "Tried sending train to the same station it is now")
                    global.trainsToSend[k] = nil
                    break

                elseif not string.find(train_schedule.records[next_stop].station, '<CT',1, true) then
                    alert_all_players(train.station, "Tried sending train to a non-teleport station")
                    global.trainsToSend[k] = nil
                    break
                else
                    -- collect all restrictions of all zones this stop is in
                    local restrictions = {}
                    for _, zone in pairs(global.stopZones[train.station.unit_number]) do
                        if global.config.zones[zone].restrictions and #global.config.zones[zone].restrictions > 0 then
                            for _, restriction in pairs(global.config.zones[zone].restrictions) do
                                table.insert(restrictions, restriction)
                            end
                        end
                    end

                    if #restrictions > 0 then
                        -- check restrictions
                        -- find out the server and zone(s) the target stop is in, and then check if this stop is allowed to teleport there

                        local zoneMatch = false
                        local targetStopName, targetServerName = trainStopTrackingApi.resolveStop(train_schedule.records[next_stop].station)
                        local targetServerId = trainStopTrackingApi.lookupNameToId(targetServerName)
                        local targetServerZones = global.remoteStopZones[tostring(targetServerId)]
                        if targetServerZones ~= nil and table_size(targetServerZones) > 0 then
                            local targetZones = global.remoteStopZones[tostring(targetServerId)][targetStopName]

                            for _, restriction in pairs(restrictions) do
                                if restriction.server == targetServerName then
                                    for __, zoneName in pairs(targetZones) do
                                        if zoneName == restriction.zone then
                                            zoneMatch = true
                                            break
                                        end
                                    end
                                    if zoneMatch then
                                        break
                                    end
                                end
                            end
                        end

                        if not zoneMatch then
                            -- global.trainsToSend[k] = nil
                            alert_all_players(train.station,"Tried sending train to remote station "..targetStopName.." at "..targetServerName .." which it is not allowed to go to")
                            break
                        end
                    end
                end

                local targetStation = trainStopTrackingApi.find_station(train_schedule.records[next_stop].station, #train.carriages)

                -- local teleportation (the easy one)
                if targetStation.valid then
                    local trainData = serialize_train(train)
                    local scheduleData = serialize_train_schedule(train)

                    if global.stationQueue[targetStation.backer_name] == nil then
                        global.stationQueue[targetStation.backer_name] = 1
                    else
                        global.stationQueue[targetStation.backer_name] = global.stationQueue[targetStation.backer_name] + 1
                    end
                    table.insert(global.trainsToSpawn, {targetStation = targetStation, train = trainData, schedule = scheduleData })
                    table.insert(global.trainsToDestroy, train)
                    global.trainsToSend[k] = nil

                    -- teleportation to another instance (the hard one)
                elseif targetStation.remote then
                    if targetStation.instanceId then
                        -- game.print("Sending train to remote station "..targetStation.stationName.." at "..targetStation.instanceName .."("..targetStation.instanceId..")")
                        targetStation['train'] = train;
                        table.insert(global.trainsToSendRemote, targetStation)

                        global.trainsToSend[k] = nil
                    else
                        alert_all_players(train.station,"Tried sending train to remote station "..targetStation.stationName.." at "..targetStation.instanceName .." which seems to be down at the moment")
                    end
                else
                    -- local, but nothing free atm
                    alert_all_players(train.station, "Ran out of available stations with the name: "..train_schedule.records[next_stop].station..". Build more or suffer ... from limited throughput")
                end
            end
        else
            global.trainsToSend[k] = nil
        end
    end

    for k, v in pairs(global.trainsToSendRemote) do
        if v.train.valid and not v.train.manual_mode then
            local serializedTrain = serialize_train(v.train)
            local serializedTrainSchedule = serialize_train_schedule(v.train)

            if not serializedTrain then
                game.print("ERRRRRORRRRR")
                log(serpent.block(v.train))
                log(serpent.block(serializedTrain))
                break;
            end

            local package = {
                event = "teleportTrain",
                localTrainid = v.train.id,
                destinationInstanceId = v.instanceId,
                destinationStationName = v.stationName,
                train = serializedTrain,
                train_schedule = serializedTrainSchedule
            }

            game.write_file(fileName, json:encode(package) .. "\n", true, 0)

            global.trainsToSendRemote[k] = nil
            table.insert(global.trainsToDestroy, v.train)

            -- todo:
            -- maybe buffer train in serialized form until we get the safe arrival message back
            -- this way we are able to resend it, or even recall it
        end
    end

    for k, v in pairs(global.trainsToSpawn) do
        -- game.print("Trying to spawn train at: "..v.targetStation.backer_name)
        local targetState = trainStopTrackingApi.can_spawn_train(v.targetStation, #v.train)

        -- if there are no signals spawn anyway, maybe it is a lone track without need for signals
        if targetState == CAN_SPAWN_RESULT.ok or targetState == CAN_SPAWN_RESULT.no_signals then
            local created_train = deserialize_train(v.targetStation, v.train)
            if created_train then
                deserialize_train_schedule(created_train, v.schedule)
                global.trainsToSpawn[k] = nil
                global.stationQueue[v.targetStation.backer_name] = global.stationQueue[v.targetStation.backer_name] - 1
                if global.stationQueue[v.targetStation.unit_number] ~= nil then
                    global.stationQueue[v.targetStation.unit_number] = global.stationQueue[v.targetStation.unit_number] - 1
                    global.trainLastSpawnTick[created_train.id] = event.tick;
                end

                -- after spawning a train at the station unblock it again if it was blocked
                local fullName = v.targetStation.backer_name.." @ "..trainStopTrackingApi.lookupIdToServerName()
                if global.blockedStations[fullName] == true then
                    global.blockedStations[fullName] = nil
                    game.write_file(fileName, "event:trainstop_unblocked|name:"..fullName.."\n", true, 0)
                end
            else
                alert_all_players(v.targetStation,"Could not spawn train, player standing on the rails? Trying to redirect")
                local newStation = trainStopTrackingApi.find_station(v.targetStation.backer_name, #v.train)
                if newStation.valid then
                    global.stationQueue[v.targetStation.unit_number] = global.stationQueue[v.targetStation.unit_number] - 1
                    v.targetStation = newStation
                    global.trainsToSpawn[k] = v
                end
            end
        else
            if targetState == CAN_SPAWN_RESULT.blocked then
                alert_all_players(v.targetStation,"Station is blocked")
            elseif targetState == CAN_SPAWN_RESULT.no_adjacent_rail then
                alert_all_players(v.targetStation,"Station has no rails")
            elseif targetState == CAN_SPAWN_RESULT.not_enough_track then
                alert_all_players(v.targetStation,"Station has not enough room")
            -- elseif targetState == CAN_SPAWN_RESULT.no_signals then
            --    alert_all_players(v.targetStation,"Station needs signals")
            elseif targetState == CAN_SPAWN_RESULT.no_station then
                game.print("Station "..v.targetStation.backer_name.." got removed after being set as teleport spawn target, trying to redirect")
                local newStation = trainStopTrackingApi.find_station(v.targetStation.backer_name, #v.train)
                if newStation.valid then
                    v.targetStation = newStation
                    global.trainsToSpawn[k] = v
                else
                    game.print("No station with name "..v.targetStation.backer_name.." found, this train is lost forever.")
                    global.trainsToSpawn[k] = nil
                end
            end

        end
    end

end)

script.on_event(defines.events.on_train_changed_state, function (event)
	local entity = event.train
    if type(entity) ~= "table" or not entity.valid then return end
	local trainState = event.train.state
	local oldTrainState = event.old_state

    if entity.station == nil then

    elseif string.find(entity.station.backer_name, '<CT',1,true) == 1 then
        local schedule = entity.schedule
        local current_schedule = schedule.records[schedule.current]
        local wait_conditions = current_schedule.wait_conditions

        if wait_conditions and #wait_conditions>0 and trainState == defines.train_state.wait_station then
            if wait_conditions[1].type == "circuit"
                    and wait_conditions[1].condition
                    and wait_conditions[1].condition.first_signal and wait_conditions[1].condition.first_signal.name == "signal-T"
                    and wait_conditions[1].condition.second_signal and wait_conditions[1].condition.second_signal.name == "signal-T"
            then
                table.insert(global.trainsToSend, 1, {
                    train = entity,
                    station = entity.station
                })

            end
        elseif oldTrainState == defines.train_state.wait_station then
                for i,v in pairs(global.trainsToSend) do
                    if v and v.train == entity then
                        table.remove(global.trainsToSend, i)
                    end
                end
        end
	end
end)




local trainTrackingApi = setmetatable({
    -- nothing
},{
    __index = function(t, k)
        log({'trainTrackingApi.invalid-access', k}, nil, 3)
    end,
    __newindex = function(t, k, v)
        -- do nothing, read-only table
    end,
    -- Don't let mods muck around
    __metatable = false,
})


return trainTrackingApi