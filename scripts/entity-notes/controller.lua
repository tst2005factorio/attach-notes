local this = {}
local util = scripts.util
local components = scripts.components
local gui = scripts["gui-tools"]
local mod_gui = require("mod-gui")
local config = require("config")
local templates = scripts["entity-notes.gui-templates"].templates

local rebuildGuiOnSetting = {
	["default-font"] = true,
	["default-text-color2"] = true,
	["default-title-color2"] = true
}

function this.on_gui_opened(event)
	local index = event.player_index
	local player = game.players[index]
	local cache = global.cache[index]

	-- clear blueprint cache if player stops editing blueprint
	if event.gui_type ~= defines.gui_type.item then
		cache.blueprint = nil
	end
	
	if event.gui_type == defines.gui_type.entity and util.isValid(event.entity) then
		if cache.openedEntityGui ~= event.entity then
			cache.noteIsHidden = player.mod_settings["hide-note-by-default"].value -- read hidden by default setting
		
			this.buildGUI(player, cache) -- create edit window
		end
		
	elseif cache.openedEntityGui then
		this.destroyGUI(player, cache)
	end
end

function this.on_gui_closed(event)
	local index = event.player_index
	local player = game.players[index]
	local cache = global.cache[index]

	this.destroyGUI(player, cache)
	
	local stack = event.item
	if util.isValidStack(stack) then this.filterStorages(stack) end
end

function this.on_selected_entity_changed(event) 
	local index = event.player_index
	local player = game.players[index]
	local cache = global.cache[index]
	
	this.buildPreviewGUI(player, cache)
end

function this.buildPreviewGUI(player, cache)
	this.destroyPreviewGUI(player)
	if not player.mod_settings["show-note-on-hover"].value then return end
	
	local selected = player.selected
	
	if util.isValid(selected) and (cache.openedEntityGui ~= selected or cache.noteIsHidden) then
		local note = global.notes[selected]
		if note then
			gui.create(player, templates.notePreview, { note = note, settings = player.mod_settings, selected = selected })
		end
	end
end

function this.destroyPreviewGUI(player)
	gui.destroy(player, templates.notePreview)
end

function this.buildGUI(player, cache)
	this.destroyGUI(player, cache)
	local opened = player.opened
	
	if util.isValid(opened) then
		local note = global.notes[opened]
		
		if config.offerAttachNote[opened.type] and not config.alwaysAttachNote[opened.name] then -- create attach/delete note button if needed
			gui.create(player, templates.attachNoteButton, { attached = (note ~= nil), settings = player.mod_settings, opened = opened, cache = cache })
		end
		
		if config.alwaysAttachNote[opened.type] or config.alwaysAttachNote[opened.name] or (note and not cache.noteIsHidden) then
			gui.create(player, templates.noteWindow, { note = note, settings = player.mod_settings, opened = opened })
		end
		
		cache.openedEntityGui = opened
		this.buildPreviewGUI(player, cache)
	end
end

function this.destroyGUI(player, cache)
	gui.destroy(player, templates.attachNoteButton)
	gui.destroy(player, templates.noteWindow)
	cache.openedEntityGui = nil
	this.buildPreviewGUI(player, cache) -- show note preview if entity is still selected
end

function this.on_runtime_mod_setting_changed(event)
	if rebuildGuiOnSetting[event.setting] then
		local index = event.player_index
		local player = game.players[index]
		local cache = global.cache[index]
		
		if cache.openedEntityGui then
			this.buildGUI(player, cache)
		end
	end
end

function this.on_pre_player_mined_item(event) -- close gui and delete data when entity is destroyed
	local entity = event.entity
	local notes = global.notes
	
	if notes[entity] then
		for name in pairs(components) do util.destroyIfValid(notes[entity][name]) end
		notes[entity] = nil
	end
	
	for index,cache in pairs(global.cache) do
		if cache.openedEntityGui == entity then
			this.destroyGUI(game.players[index], cache)
		end
	end
end

this.on_robot_pre_mined = this.on_pre_player_mined_item

function this.on_entity_died(event)
	local entity = event.entity
	local notes = global.notes
	
	if notes[entity] then
		for name in pairs(components) do
			if name ~= "bpInterface" then 
				util.destroyIfValid(notes[entity][name])
			end
		end
	end
	
	for index,cache in pairs(global.cache) do
		if cache.openedEntityGui == entity then
			this.destroyGUI(game.players[index], cache)
		end
	end
end

function this.on_player_deconstructed_area(event)
	local player = game.players[event.player_index]
	local notes = global.notes
	
	if not event.alt then
		local key, area = util.fixArea(event.area)
		
		for _,interface in pairs(player.surface.find_entities_filtered{ [key] = area, force = player.force, name = "blueprint-note-interface" }) do
			local unitNumber = components.bpInterface.getUnitNumber(interface)
			local interfaceIsInvalid = true
			
			-- remove note when the ghost entity has been deconstructed (= no other valid entity at the interfaces position exists)
			for _,entity in pairs(interface.surface.find_entities_filtered{ force = interface.force, area = util.getSurroundingArea(interface.position, 0.01) }) do
				if util.isValid(entity) and entity.name ~= "blueprint-note-interface" then
					interfaceIsInvalid = false
					break
				end
			end
			
			if interfaceIsInvalid then 
				for name in pairs(components) do util.destroyIfValid(notes[unitNumber][name]) end
				notes[unitNumber] = nil
			end
		end
	end
end

function this.on_entity_settings_pasted(event)
	local player = game.players[event.player_index]
	local source, destination = event.source, event.destination
	
	if  util.isValidPlayer(player) and util.isValid(source) and util.isValid(destination) then
		if destination.name == "signpost" then
			this.copyAttachedNote(player, source, destination, true)
		elseif player.mod_settings["copy-paste-attached-notes"].value then
			if util.supportsNotes(destination) then
				this.copyAttachedNote(player, source, destination, false)
			end
		end
	end
end

function this.copyAttachedNote(player, source, destination, isSignpost)
	local notes = global.notes
	local sourceNote = notes[source]
	
	if sourceNote then
		notes[destination] = notes[destination] or {}
		local destNote = notes[destination]
		
		destination.last_user = player -- copy common values
		destNote.text = sourceNote.text
		destNote.font = sourceNote.font
		destNote.textColor = sourceNote.textColor
		
		if isSignpost then destNote.icon = sourceNote.icon and util.shallowCopy(sourceNote.icon) end
		if not components.flyingText.isDisabledForEntity(destination) then
			destNote.title = sourceNote.title
			destNote.titleColor = sourceNote.titleColor
		end
		
		for name,component in pairs(components) do
			if not component.isDisabledForEntity(destination) then
				if component.showByDefault == true then
					component.update(destination, destNote)
				else
					util.destroyIfValid(destNote[name])
					if util.isValid(sourceNote[name]) or (component.isDisabledForEntity(source) and
														  player.mod_settings["show-"..name.."-by-default"].value) then
						destNote[name] = component.create(destination, destNote, player)
					end
				end
			end
		end
		
		-- TODO: update gui
	elseif notes[destination] and util.supportsNotes(destination) then
		for name in pairs(components) do util.destroyIfValid(notes[destination][name]) end
		notes[destination] = nil
	end
end

function this.on_player_setup_blueprint(event)
	local player = game.players[event.player_index]
	local cache = global.cache[event.player_index]
	local cursorStack = player.cursor_stack
	local bpToSetup = player.blueprint_to_setup
	local notes = global.notes
	
	cache.blueprint = {} -- save attached notes to players cache
	local key, area = util.fixArea(event.area)
	
	for _,interface in pairs(player.surface.find_entities_filtered{ name = "blueprint-note-interface", [key] = area, force = player.force }) do
		local unitNumber = components.bpInterface.getUnitNumber(interface)
		cache.blueprint[unitNumber] = notes[unitNumber]
	end
	
	if bpToSetup.valid_for_read then
		this.convertBlueprint(player, cache, bpToSetup)
	elseif event.alt and cursorStack.valid_for_read then
		this.convertBlueprint(player, cache, cursorStack)
	end
end

function this.on_player_configured_blueprint(event)
	local player = game.players[event.player_index]
	local cache = global.cache[event.player_index]
	local cursorStack = player.cursor_stack
	
	if cursorStack.valid_for_read and cache.blueprint then
		this.convertBlueprint(player, cache, cursorStack)
	else
		cache.blueprint = nil
	end
	
	this.filterStorages(cursorStack)
end

function this.filterStorages(stack) -- filter out note storages if their entity got removed
	if not stack.is_blueprint or not stack.is_blueprint_setup() then return end
	
	local entities = stack.get_blueprint_entities()
	local result = {}
	
	if entities then
		local notePairs = {}
		for _,entity in pairs(entities) do
			local pos = entity.position
			local key = pos.x..";"..pos.y
			notePairs[key] = notePairs[key] or {}
			local ref = notePairs[key]
			
			if entity.name == "blueprint-note-storage" or 
			   entity.name == "blueprint-note-interface" then
				ref.storage = entity
			else
				ref.other = ref.other or {}
				ref.other[#ref.other + 1] = entity
			end
		end
		
		
		for _,pair in pairs(notePairs) do
		
			if pair.other then 
				for _,other in ipairs(pair.other) do
					result[#result + 1] = other
				end
				
				local storage = pair.storage
				if storage then 
					result[#result + 1] = storage
				end
			end
		end
	end
	
	stack.set_blueprint_entities(result)
end

function this.convertBlueprint(player, cache, stack) -- replace note interfaces of a blueprint with actual note storages
	local entities = stack.get_blueprint_entities() or {}
	local newEntities = {}
	
	for i,entity in pairs(entities) do
		if entity.name ~= "blueprint-note-interface" then
			newEntities[i] = entity
		end

		-- if entity.name == "blueprint-note-interface" then
		-- 	local note = cache.blueprint[entity.control_behavior.filters[1].count] -- get cached note using the saved unit number from interface
		-- 	if note then
		-- 		entity.name = "blueprint-note-storage" -- convert interface to storage
		-- 		entity.control_behavior = nil
		-- 		entity.alert_parameters = this.encodeNote(note) -- save encoded note
		-- 	end
		-- end
	end
	
	-- dlog("BEFORE:",entities)
	-- stack.set_blueprint_entities(entities)
	stack.set_blueprint_entities(newEntities)
	-- dlog("AFTER:",stack.get_blueprint_entities())

	cache.blueprint = nil
end

function this.encodeNote(note)
	local encodedNote = {
		text = note.text,
		title = note.title,
		textColor = note.textColor,
		titleColor = note.titleColor,
		font = note.font,
		icon = note.icon
	}
	
	for name,component in pairs(components) do
		if component.showByDefault ~= true then
			encodedNote[name] = util.isValid(note[name])
		end
	end

	return {
		show_alert = false,
		show_on_map = false,
		alert_message = serpent.dump(encodedNote)
	}
end

function this.decodeNote(storage) -- reads storage contents and destroys storage
	storage.teleport{1000000, 1000000} -- teleport storage to avoid the deletion of other ghosts during the following revival
	local _, revived = storage.revive()
	if revived then
		local params = revived.alert_parameters
		revived.destroy()
		
		return loadstring(params.alert_message)()
	end
end

function this.on_built_entity(event)
	local entity = event.created_entity
	local notes = global.notes
	
	if entity.name == "entity-ghost" or entity.name == "tile-ghost" then -- handle blueprint placement
		if entity.ghost_name == "blueprint-note-storage" then
			--dlog("built ghost storage at "..serpent.line(entity.position)..", un: "..entity.unit_number)
			local ghosts = entity.surface.find_entities_filtered{
				name = "entity-ghost", 
				force = entity.force,
				area = util.getSurroundingArea(entity.position, 0.01) 
			}
			
			for _,ghost in ipairs(ghosts) do
				--if not util.isValid(entity) then break end
			
				if util.isValid(ghost) and util.supportsNotes(ghost) then
					if notes[ghost] then
						entity.destroy()
						--dlog("removed storage because note already present")
					else
						local note = this.decodeNote(entity)
						--dlog("decoded note: "..serpent.line(note))
						-- create blueprint interface which contains the ghosts unit number
						note.bpInterface = components.bpInterface.create(ghost)
						notes[ghost] = note
						--dlog("ghost "..ghost.ghost_name.." at "..serpent.line(ghost.position).." had the saved note "..serpent.line(note))
					end
					return
				end
			end
			
			entity.destroy()
			--dlog("WARNING: could not restore note, no actual ghost entity found")
		--else
			--dlog("built non storage ghost "..entity.ghost_name.." at "..serpent.line(entity.position)..", un: "..entity.unit_number)
		end
	else
		this.restoreGhostNote(entity)
	end
end

function this.on_robot_built_entity(event)
	this.restoreGhostNote(event.created_entity)
end

function this.restoreGhostNote(entity) -- restore an entity note when it got revived from a ghost
	--dlog("built normal entity "..entity.name.." at "..serpent.line(entity.position))
	local interface = entity.surface.find_entity("blueprint-note-interface", entity.position)
	local notes = global.notes
	
	if util.isValid(interface) then
		local unitNumber = components.bpInterface.getUnitNumber(interface)
		
		if notes[entity] ~= notes[unitNumber] then -- restore note if needed
			notes[entity] = notes[unitNumber] 
			notes[unitNumber] = nil
		end
		
		local note = notes[entity] -- revive components
		if not note then return end
		
		util.destroyIfValid(note.bpInterface)
		for name,component in pairs(components) do
			if not component.isDisabledForEntity(entity) then
				if component.showByDefault == true then
					component.update(entity, note)
				elseif note[name] then
					note[name] = component.create(entity, note)
				end
			end
		end
	--else
		--dlog("no valid interface found, found: "..serpent.line(interface))
	end
end

return this