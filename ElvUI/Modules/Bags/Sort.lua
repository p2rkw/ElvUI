local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local B = E:GetModule("Bags");
local Search = LibStub("LibItemSearch-1.2");

--Cache global variables
--Lua functions
local ipairs, pairs, pcall, tonumber, select, unpack = ipairs, pairs, pcall, tonumber, select, unpack
local tinsert, tremove, tsort, twipe = table.insert, table.remove, table.sort, table.wipe
local floor, mod = math.floor, math.mod
local band = bit.band
local match, gmatch, find = string.match, string.gmatch, string.find
--WoW API / Variables
local GetTime = GetTime
local GetItemInfo = GetItemInfo
local GetAuctionItemClasses = GetAuctionItemClasses
local GetAuctionItemSubClasses = GetAuctionItemSubClasses
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerItemLink = GetContainerItemLink
local PickupContainerItem = PickupContainerItem
local SplitContainerItem = SplitContainerItem
local GetContainerNumSlots = GetContainerNumSlots
local GetContainerNumFreeSlots = GetContainerNumFreeSlots
local ContainerIDToInventoryID = ContainerIDToInventoryID
local GetInventoryItemLink = GetInventoryItemLink
local CursorHasItem = CursorHasItem
local ARMOR = ARMOR

local bankBags = {BANK_CONTAINER}
local MAX_MOVE_TIME = 1.25

for i = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do
	tinsert(bankBags, i)
end

local playerBags = {}
for i = 0, NUM_BAG_SLOTS do
	tinsert(playerBags, i)
end

local allBags = {}
for _, i in ipairs(playerBags) do
	tinsert(allBags, i)
end
for _, i in ipairs(bankBags) do
	tinsert(allBags, i)
end

local coreGroups = {
	bank = bankBags,
	bags = playerBags,
	all = allBags,
}

local bagCache = {}
local bagIDs = {}
local bagQualities = {}
local bagStacks = {}
local bagMaxStacks = {}
local bagGroups = {}
local initialOrder = {}
local itemTypes, itemSubTypes
local bagSorted, bagLocked = {}, {}
local bagRole
local moves = {}
local targetItems = {}
local sourceUsed = {}
local targetSlots = {}
local specialtyBags = {}
local emptySlots = {}

local moveRetries = 0
local lastItemID, currentItemID, lockStop, lastDestination, lastMove
local moveTracker = {}

local inventorySlots = {
	INVTYPE_AMMO = 0,
	INVTYPE_HEAD = 1,
	INVTYPE_NECK = 2,
	INVTYPE_SHOULDER = 3,
	INVTYPE_BODY = 4,
	INVTYPE_CHEST = 5,
	INVTYPE_ROBE = 5,
	INVTYPE_WAIST = 6,
	INVTYPE_LEGS = 7,
	INVTYPE_FEET = 8,
	INVTYPE_WRIST = 9,
	INVTYPE_HAND = 10,
	INVTYPE_FINGER = 11,
	INVTYPE_TRINKET = 12,
	INVTYPE_CLOAK = 13,
	INVTYPE_WEAPON = 14,
	INVTYPE_SHIELD = 15,
	INVTYPE_2HWEAPON = 16,
	INVTYPE_WEAPONMAINHAND = 18,
	INVTYPE_WEAPONOFFHAND = 19,
	INVTYPE_HOLDABLE = 20,
	INVTYPE_RANGED = 21,
	INVTYPE_THROWN = 22,
	INVTYPE_RANGEDRIGHT = 23,
	INVTYPE_RELIC = 24,
	INVTYPE_TABARD = 25,
}

local safe = {
	[BANK_CONTAINER] = true,
	[0] = true
}

local frame = CreateFrame("Frame")
local t, WAIT_TIME = 0, 0.05
frame:SetScript("OnUpdate", function(_, elapsed)
	t = t + (elapsed or 0.01)
	if t > WAIT_TIME then
		t = 0
		B:DoMoves()
	end
end)
frame:Hide()
B.SortUpdateTimer = frame

local function BuildSortOrder()
	itemTypes = {}
	itemSubTypes = {}
	for i, iType in ipairs({GetAuctionItemClasses()}) do
		itemTypes[iType] = i
		itemSubTypes[iType] = {}
		for ii, isType in ipairs({GetAuctionItemSubClasses(i)}) do
			itemSubTypes[iType][isType] = ii
		end
	end
end

local function UpdateLocation(from, to)
	if (bagIDs[from] == bagIDs[to]) and (bagStacks[to] < bagMaxStacks[to]) then
		local stackSize = bagMaxStacks[to]
		if (bagStacks[to] + bagStacks[from]) > stackSize then
			bagStacks[from] = bagStacks[from] - (stackSize - bagStacks[to])
			bagStacks[to] = stackSize
		else
			bagStacks[to] = bagStacks[to] + bagStacks[from]
			bagStacks[from] = nil
			bagIDs[from] = nil
			bagQualities[from] = nil
			bagMaxStacks[from] = nil
		end
	else
		bagIDs[from], bagIDs[to] = bagIDs[to], bagIDs[from]
		bagQualities[from], bagQualities[to] = bagQualities[to], bagQualities[from]
		bagStacks[from], bagStacks[to] = bagStacks[to], bagStacks[from]
		bagMaxStacks[from], bagMaxStacks[to] = bagMaxStacks[to], bagMaxStacks[from]
	end
end

local function PrimarySort(a, b)
	local aName = GetItemInfo(bagIDs[a])
	local bName = GetItemInfo(bagIDs[b])

	if aName and bName then
		return aName < bName
	end
end

local function DefaultSort(a, b)
	local aID = bagIDs[a]
	local bID = bagIDs[b]

	if (not aID) or (not bID) then return aID end

	local aOrder, bOrder = initialOrder[a], initialOrder[b]

	if aID == bID then
		local aCount = bagStacks[a]
		local bCount = bagStacks[b]
		if aCount and bCount and aCount == bCount then
			return aOrder < bOrder
		elseif aCount and bCount then
			return aCount < bCount
		end
	end

	local _, _, aRarity, _, aType, aSubType, _, aEquipLoc = GetItemInfo(aID)
	local _, _, bRarity, _, bType, bSubType, _, bEquipLoc = GetItemInfo(bID)

	aRarity = bagQualities[a]
	bRarity = bagQualities[b]

	if aRarity ~= bRarity and aRarity and bRarity then
		return aRarity > bRarity
	end

	if itemTypes[aType] ~= itemTypes[bType] then
		return (itemTypes[aType] or 99) < (itemTypes[bType] or 99)
	end

	if aType == ARMOR then
		local aEquipLoc = inventorySlots[aEquipLoc] or -1
		local bEquipLoc = inventorySlots[bEquipLoc] or -1
		if aEquipLoc == bEquipLoc then
			return PrimarySort(a, b)
		end

		if aEquipLoc and bEquipLoc then
			return aEquipLoc < bEquipLoc
		end
	end

	if aSubType == bSubType then
		return PrimarySort(a, b)
	end

	return ((itemSubTypes[aType] or {})[aSubType] or 99) < ((itemSubTypes[bType] or {})[bSubType] or 99)
end

local function ReverseSort(a, b)
	return DefaultSort(b, a)
end

local function UpdateSorted(source, destination)
	for i, bs in pairs(bagSorted) do
		if bs == source then
			bagSorted[i] = destination
		elseif bs == destination then
			bagSorted[i] = source
		end
	end
end

local function ShouldMove(source, destination)
	if destination == source then return end

	if not bagIDs[source] then return end
	if bagIDs[source] == bagIDs[destination] and bagStacks[source] == bagStacks[destination] then return end

	return true
end

local function IterateForwards(bagList, i)
	i = i + 1
	local step = 1
	for _, bag in ipairs(bagList) do
		local slots = B:GetNumSlots(bag)
		if i > slots + step then
			step = step + slots
		else
			for slot = 1, slots do
				if step == i then
					return i, bag, slot
				end
				step = step + 1
			end
		end
	end
	bagRole = nil
end

local function IterateBackwards(bagList, i)
	i = i + 1
	local step = 1
	for ii = getn(bagList), 1, -1 do
		local bag = bagList[ii]
		local slots = B:GetNumSlots(bag)
		if i > slots + step then
			step = step + slots
		else
			for slot = slots, 1, -1 do
				if step == i then
					return i, bag, slot
				end
				step = step + 1
			end
		end
	end
	bagRole = nil
end

function B.IterateBags(bagList, reverse, role)
	bagRole = role
	return (reverse and IterateBackwards or IterateForwards), bagList, 0
end

function B:GetItemID(bag, slot)
	local link = self:GetItemLink(bag, slot)
	return link and tonumber(match(link, "item:(%d+)"))
end

function B:GetItemInfo(bag, slot)
	return GetContainerItemInfo(bag, slot)
end

function B:GetItemLink(bag, slot)
	return GetContainerItemLink(bag, slot)
end

function B:PickupItem(bag, slot)
	return PickupContainerItem(bag, slot)
end

function B:SplitItem(bag, slot, amount)
	return SplitContainerItem(bag, slot, amount)
end

function B:GetNumSlots(bag)
	if bag then
		return GetContainerNumSlots(bag)
	end

	return 0
end

local function ConvertLinkToID(link)
	if not link then return end

	if tonumber(match(link, "item:(%d+)")) then
		return tonumber(match(link, "item:(%d+)"))
	end
end

local function DefaultCanMove()
	return true
end

function B:Encode_BagSlot(bag, slot)
	return (bag * 100) + slot
end

function B:Decode_BagSlot(int)
	return floor(int / 100), mod(int, 100)
end

function B:IsPartial(bag, slot)
	local bagSlot = B:Encode_BagSlot(bag, slot)
	return ((bagMaxStacks[bagSlot] or 0) - (bagStacks[bagSlot] or 0)) > 0
end

function B:EncodeMove(source, target)
	return (source * 10000) + target
end

function B:DecodeMove(move)
	local s = floor(move / 10000)
	local t = mod(move, 10000)
	s = (t > 9000) and (s + 1) or s
	t = (t > 9000) and (t - 10000) or t
	return s, t
end

function B:AddMove(source, destination)
	UpdateLocation(source, destination)
	tinsert(moves, 1, B:EncodeMove(source, destination))
end

function B:ScanBags()
	for _, bag, slot in B.IterateBags(allBags) do
		local bagSlot = B:Encode_BagSlot(bag, slot)
		local itemID = ConvertLinkToID(B:GetItemLink(bag, slot))
		if itemID then
			bagMaxStacks[bagSlot] = select(7, GetItemInfo(itemID))
			bagIDs[bagSlot] = itemID
			bagQualities[bagSlot] = select(3, GetItemInfo(itemID))
			bagStacks[bagSlot] = select(2, B:GetItemInfo(bag, slot))
		end
	end
end

local bagTypes = {
	["Bag"] = 0,
	["Quiver"] = 1,
	["Ammo Pouch"] = 2,
	["Soul Bag"] = 4,
	["Leatherworking Bag"] = 8,
	["Herb Bag"] = 16,
	["Enchanting Bag"] = 32,
	["Engineering Bag"] = 64,
	["Mining Bag"] = 128
}

local function GetItemFamily(bag)
	local bagID = match(bag, "item:(%d+)")
	local itemType
	if bagID then
		itemType = select(6, GetItemInfo(bagID))
		if itemType then
			return tonumber(bagTypes[itemType])
		end
	end

	return nil
end

function B:IsSpecialtyBag(bagID)
	if safe[bagID] then return false end

	local inventorySlot = ContainerIDToInventoryID(bagID)
	if not inventorySlot then return false end

	local bag = GetInventoryItemLink("player", inventorySlot)
	if not bag then return false end

	local family = GetItemFamily(bag)
	if family == 0 or family == nil then return false end

	return family
end

function B:CanItemGoInBag(bag, slot, targetBag)
	local item = bagIDs[B:Encode_BagSlot(bag, slot)]
	local itemFamily = GetItemFamily(item)
	if itemFamily then
		local equipSlot = select(8, GetItemInfo(item))
		if equipSlot == "INVTYPE_BAG" then
			itemFamily = 1
		end
	end
	local bagFamily = GetItemFamily(targetBag)
	if itemFamily then
		return (bagFamily == 0) or band(itemFamily, bagFamily) > 0
	else
		return false
	end
end

function B.Compress(...)
	for i = 1, arg.n do
		local bags = arg[i]
		B.Stack(bags, bags, B.IsPartial)
	end
end

function B.Stack(sourceBags, targetBags, canMove)
	if not canMove then canMove = DefaultCanMove end

	for _, bag, slot in B.IterateBags(targetBags, nil, "deposit") do
		local bagSlot = B:Encode_BagSlot(bag, slot)
		local itemID = bagIDs[bagSlot]

		if itemID and (bagStacks[bagSlot] ~= bagMaxStacks[bagSlot]) then
			targetItems[itemID] = (targetItems[itemID] or 0) + 1
			tinsert(targetSlots, bagSlot)
		end
	end

	for _, bag, slot in B.IterateBags(sourceBags, true, "withdraw") do
		local sourceSlot = B:Encode_BagSlot(bag, slot)
		local itemID = bagIDs[sourceSlot]

		if itemID and targetItems[itemID] and canMove(itemID, bag, slot) then
			for i = getn(targetSlots), 1, -1 do
				local targetedSlot = targetSlots[i]
				if bagIDs[sourceSlot] and bagIDs[targetedSlot] == itemID and targetedSlot ~= sourceSlot and not (bagStacks[targetedSlot] == bagMaxStacks[targetedSlot]) and not sourceUsed[targetedSlot] then
					B:AddMove(sourceSlot, targetedSlot)
					sourceUsed[sourceSlot] = true

					if bagStacks[targetedSlot] == bagMaxStacks[targetedSlot] then
						targetItems[itemID] = (targetItems[itemID] > 1) and (targetItems[itemID] - 1) or nil
					end
					if bagStacks[sourceSlot] == 0 then
						targetItems[itemID] = (targetItems[itemID] > 1) and (targetItems[itemID] - 1) or nil
						break
					end
					if not targetItems[itemID] then break end
				end
			end
		end
	end

	twipe(targetItems)
	twipe(targetSlots)
	twipe(sourceUsed)
end

local blackListedSlots = {}
local blackList = {}
local blackListQueries = {}

local function buildBlacklist(arg)
	for entry in pairs(arg) do
		local itemName = GetItemInfo(entry)
		if itemName then
			blackList[itemName] = true
		elseif entry ~= "" then
			if find(entry, "%[") and find(entry, "%]") then
				entry = match(entry, "%[(.*)%]")
			end
			blackListQueries[getn(blackListQueries) + 1] = entry
		end
	end
end

function B.Sort(bags, sorter, invertDirection)
	if not sorter then sorter = invertDirection and ReverseSort or DefaultSort end
	if not itemTypes then BuildSortOrder() end

	twipe(blackList)
	twipe(blackListQueries)
	twipe(blackListedSlots)

	buildBlacklist(B.db.ignoredItems)
	buildBlacklist(E.global.bags.ignoredItems)

	for i, bag, slot in B.IterateBags(bags, nil, "both") do
		local bagSlot = B:Encode_BagSlot(bag, slot)
		local link = B:GetItemLink(bag, slot)

		if link then
			if blackList[GetItemInfo(link)] then
				blackListedSlots[bagSlot] = true
			end

			if not blackListedSlots[bagSlot] then
				for _, itemsearchquery in pairs(blackListQueries) do
					local success, result = pcall(Search.Matches, Search, link, itemsearchquery)
					if success and result then
						blackListedSlots[bagSlot] = blackListedSlots[bagSlot] or result
						break
					end
				end
			end
		end

		if not blackListedSlots[bagSlot] then
			initialOrder[bagSlot] = i
			tinsert(bagSorted, bagSlot)
		end
	end

	tsort(bagSorted, sorter)

	local passNeeded = true
	while passNeeded do
		passNeeded = false
		local i = 1
		for _, bag, slot in B.IterateBags(bags, nil, "both") do
			local destination = B:Encode_BagSlot(bag, slot)
			local source = bagSorted[i]

			if not blackListedSlots[destination] then
				if ShouldMove(source, destination) then
					if not (bagLocked[source] or bagLocked[destination]) then
						B:AddMove(source, destination)
						UpdateSorted(source, destination)
						bagLocked[source] = true
						bagLocked[destination] = true
					else
						passNeeded = true
					end
				end
				i = i + 1
			end
		end
		twipe(bagLocked)
	end

	twipe(bagSorted)
	twipe(initialOrder)
end

function B.FillBags(from, to)
	B.Stack(from, to)
	for _, bag in ipairs(to) do
		if B:IsSpecialtyBag(bag) then
			tinsert(specialtyBags, bag)
		end
	end

	if getn(specialtyBags) > 0 then
		B:Fill(from, specialtyBags)
	end

	B.Fill(from, to)
	twipe(specialtyBags)
end

function B.Fill(sourceBags, targetBags, reverse, canMove)
	if not canMove then canMove = DefaultCanMove end

	twipe(blackList)
	twipe(blackListedSlots)

	buildBlacklist(B.db.ignoredItems)
	buildBlacklist(E.global.bags.ignoredItems)

	for _, bag, slot in B.IterateBags(targetBags, reverse, "deposit") do
		local bagSlot = B:Encode_BagSlot(bag, slot)
		if not bagIDs[bagSlot] then
			tinsert(emptySlots, bagSlot)
		end
	end

	for _, bag, slot in B.IterateBags(sourceBags, not reverse, "withdraw") do
		if getn(emptySlots) == 0 then break end
		local bagSlot = B:Encode_BagSlot(bag, slot)
		local targetBag = B:Decode_BagSlot(emptySlots[1])
		local link = B:GetItemLink(bag, slot)

		if link and blackList[GetItemInfo(link)] then
			blackListedSlots[bagSlot] = true
		end

		if bagIDs[bagSlot] and B:CanItemGoInBag(bag, slot, targetBag) and canMove(bagIDs[bagSlot], bag, slot) and not blackListedSlots[bagSlot] then
			B:AddMove(bagSlot, tremove(emptySlots, 1))
		end
	end
	twipe(emptySlots)
end

function B.SortBags(...)
	for i = 1, arg.n do
		local bags = arg[i]
		for i, slotNum in ipairs(bags) do
			local bagType = B:IsSpecialtyBag(slotNum)
			if bagType == false then bagType = "Normal" end
			if not bagCache[bagType] then bagCache[bagType] = {} end
			bagCache[bagType][i] = slotNum
		end
		for bagType, sortedBags in pairs(bagCache) do
			if bagType ~= "Normal" then
				B.Stack(sortedBags, sortedBags, B.IsPartial)
				B.Stack(bagCache["Normal"], sortedBags)
				B.Fill(bagCache["Normal"], sortedBags, B.db.sortInverted)
				B.Sort(sortedBags, nil, B.db.sortInverted)
				twipe(sortedBags)
			end
		end

		if bagCache["Normal"] then
			B.Stack(bagCache["Normal"], bagCache["Normal"], B.IsPartial)
			B.Sort(bagCache["Normal"], nil, B.db.sortInverted)
			twipe(bagCache["Normal"])
		end
		twipe(bagCache)
		twipe(bagGroups)
	end
end

function B:StartStacking()
	twipe(bagMaxStacks)
	twipe(bagStacks)
	twipe(bagIDs)
	twipe(bagQualities)
	twipe(moveTracker)

	if getn(moves) > 0 then
		self.SortUpdateTimer:Show()
	else
		B:StopStacking()
	end
end

function B:StopStacking(message)
	twipe(moves)
	twipe(moveTracker)
	moveRetries, lastItemID, currentItemID, lockStop, lastDestination, lastMove = 0, nil, nil, nil, nil, nil

	self.SortUpdateTimer:Hide()
	if message then
		E:Print(message)
	end
end

function B:DoMove(move)
	if CursorHasItem() then
		return false, "cursorhasitem"
	end

	local source, target = B:DecodeMove(move)
	local sourceBag, sourceSlot = B:Decode_BagSlot(source)
	local targetBag, targetSlot = B:Decode_BagSlot(target)

	local _, sourceCount, sourceLocked = B:GetItemInfo(sourceBag, sourceSlot)
	local _, targetCount, targetLocked = B:GetItemInfo(targetBag, targetSlot)

	if sourceLocked or targetLocked then
		return false, "source/target_locked"
	end

	local sourceItemID = self:GetItemID(sourceBag, sourceSlot)
	local targetItemID = self:GetItemID(targetBag, targetSlot)

	if not sourceItemID then
		if moveTracker[source] then
			return false, "move incomplete"
		else
			return B:StopStacking(L["Confused.. Try Again!"])
		end
	end

	local stackSize = select(7, GetItemInfo(sourceItemID))
	if (sourceItemID == targetItemID) and (targetCount ~= stackSize) and ((targetCount + sourceCount) > stackSize) then
		B:SplitItem(sourceBag, sourceSlot, stackSize - targetCount)
	else
		B:PickupItem(sourceBag, sourceSlot)
	end

	if CursorHasItem() then
		B:PickupItem(targetBag, targetSlot)
	end

	return true, sourceItemID, source, targetItemID, target
end

function B:DoMoves()
	if CursorHasItem() and currentItemID then
		if lastItemID ~= currentItemID then
			return B:StopStacking(L["Confused.. Try Again!"])
		end

		if moveRetries < 100 then
			local targetBag, targetSlot = self:Decode_BagSlot(lastDestination)
			local _, _, targetLocked = self:GetItemInfo(targetBag, targetSlot)
			if not targetLocked then
				self:PickupItem(targetBag, targetSlot)
				WAIT_TIME = 0.1
				lockStop = GetTime()
				moveRetries = moveRetries + 1
				return
			end
		end
	end

	if lockStop then
		for slot, itemID in pairs(moveTracker) do
			local actualItemID = self:GetItemID(self:Decode_BagSlot(slot))
			if actualItemID ~= itemID then
				WAIT_TIME = 0.1
				if (GetTime() - lockStop) > MAX_MOVE_TIME then
					if lastMove and moveRetries < 100 then
						local success, moveID, moveSource, targetID, moveTarget = self:DoMove(lastMove)
						WAIT_TIME = 0.1

						if not success then
							lockStop = GetTime()
							moveRetries = moveRetries + 1
							return
						end

						moveTracker[moveSource] = targetID
						moveTracker[moveTarget] = moveID
						lastDestination = moveTarget
						lastMove = moves[i]
						lastItemID = moveID
						tremove(moves, i)
						return
					end

					B:StopStacking()
					return
				end
				return --give processing time to happen
			end
			moveTracker[slot] = nil
		end
	end

	lastItemID, lockStop, lastDestination, lastMove = nil, nil, nil, nil
	twipe(moveTracker)

	local success, moveID, targetID, moveSource, moveTarget
	if getn(moves) > 0 then
		for i = getn(moves), 1, -1 do
			success, moveID, moveSource, targetID, moveTarget = B:DoMove(moves[i])
			if not success then
				WAIT_TIME = 0.1
				lockStop = GetTime()
				return
			end
			moveTracker[moveSource] = targetID
			moveTracker[moveTarget] = moveID
			lastDestination = moveTarget
			lastMove = moves[i]
			lastItemID = moveID
			tremove(moves, i)

			if moves[i-1] then
				WAIT_TIME = 0
				return
			end
		end
	end
	B:StopStacking()
end

function B:GetGroup(id)
	if match(id, "^[-%d,]+$") then
		local bags = {}
		for b in gmatch(id, "-?%d+") do
			tinsert(bags, tonumber(b))
		end
		return bags
	end
	return coreGroups[id]
end

function B:CommandDecorator(func, groupsDefaults)
	return function(groups)
		if self.SortUpdateTimer:IsShown() then
			E:Print(L["Already Running.. Bailing Out!"])
			B:StopStacking()
			return
		end

		twipe(bagGroups)
		if not groups or getn(groups) == 0 then
			groups = groupsDefaults
		end
		for bags in gmatch(groups or "", "[^%s]+") do
			bags = B:GetGroup(bags)
			if bags then
				tinsert(bagGroups, bags)
			end
		end

		B:ScanBags()
		if func(unpack(bagGroups)) == false then
			return
		end
		twipe(bagGroups)
		B:StartStacking()
	end
end