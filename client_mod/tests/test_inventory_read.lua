-- Actual client inventory module with fake UE object/array reads; no game calls.
local here=debug.getinfo(1,"S").source:match("^@(.*)[/\\][^/\\]*$") or "."
local original_loadfile=loadfile
local pc,pawn,inv,eq,loadout,personal,items,pages,bar,pressed
local calls=0
local function obj(id,t)
    t=t or {}; t.IsValid=function() return true end; t.GetAddress=function() return id end
    return t
end
local U={}
function U.try(f,...) local ok,v=pcall(f,...); if ok then return v end end
function U.valid(o) return o~=nil and U.try(function() return o:IsValid() end)==true end
U.alive=U.valid
function U.find_all(name) calls=calls+1; if name=="BP_PlayerController_C" then return {pc} elseif name=="QuickAccessBarBase" then return {bar} end return {} end
function FindAllOf(name) return U.find_all(name) end
function U.find_object() return nil end
function U.path_of(o) return U.valid(o) and o.path or nil end
function U.fullname(o) return U.try(function() return o:GetFullName() end) end
function U.class_word() return "Item" end
function U.short() return nil end
function U.str(v) if type(v)=="string" then return v end end
loadfile=function(path,...)
    if path:find("mod/body/util.lua",1,true) then return function() return U end end
    return original_loadfile(path,...)
end
local M=assert(original_loadfile(here.."/../scripts/inventory.lua"))()
loadfile=original_loadfile
local function data(id,name) return obj(id,{path="/Game/"..name.."."..name,Name=name,GetFullName=function() return "ItemData /Game/"..name.."."..name end}) end
local function item(id,name,count) return obj(id,{ItemData=data(id+100,name),Count=count}) end
local function array(rows)
    return setmetatable({GetArrayNum=function() return #rows end},{__index=function(_,i) if type(i)=="number" then return rows[i] end end})
end
local function reset()
    _G.DW_PAUSE=nil; calls=0
    items={item(10,"ITEM_Alpha",2),item(11,"ITEM_Beta",3)}
    pages={GetArrayNum=function() return 1 end,ForEach=function(_,fn) fn(1,{get=function() return {SlotType=1,NumSlots=1} end}) end}
    inv=obj(2,{NumberOfQuickActionSlots=1,InventoryPages=pages,ItemSlots=array(items)})
    loadout=obj(3,{ItemSlots=array({})}); personal=obj(4,{ItemSlots=array({})})
    eq=obj(5,{GetHeldEquipmentDataRight=function() return data(30,"ITEM_Alpha") end,
              GetHeldEquipmentDataLeft=function() return nil end})
    pawn=obj(6,{PlayerEquipmentComponent=eq})
    pressed=0; bar=obj(7,{GetFullName=function() return "Widget /Engine/Transient.Bar" end,UseItemInSlot=function(_,slot) if slot==0 then pressed=pressed+1 end end})
    pc=obj(1,{Pawn=pawn,InventoryComponent=inv,LoadoutComponent=loadout,PersonalInventoryComponent=personal,
              IsLocalController=function() return true end})
end
local n=0
local function check(cond,msg) assert(cond,msg); n=n+1 end
reset(); local r=M.list()
check(r.ok and r.read_status.carried.status=="complete" and r.read_status.carried.count_semantics=="exact" and r.read_status.pages.status=="complete","complete occupied array")
check(#r.hotbar==1 and #r.bag==1 and #r.unmapped==0 and r.hotbar[1].item=="ITEM_Alpha","page mapping")
check(r.read_status.held.right.status=="complete" and r.read_status.held.left.status=="unknown","hands independent")
check(r.read_status.loadout.status=="unknown" and r.read_status.personal.status=="unknown","zero length not known empty")
reset(); inv.ItemSlots=setmetatable({GetArrayNum=function() return 2 end},{__index=function(_,i) if i==1 then return items[1] end; error("second read") end})
r=M.list(); check(r.read_status.carried.status=="partial" and r.read_status.carried.count_semantics=="lower_bound" and #r.hotbar==1 and r.read_status.carried.gaps[1].reason=="slot_read_failed","partial row retained")
reset(); inv.ItemSlots=array({items[1],false})
r=M.list(); check(r.read_status.carried.status=="partial" and #r.hotbar==1 and r.read_status.carried.gaps[1].reason=="slot_invalid_or_empty_unverified","invalid/empty unknown")
reset(); inv.ItemSlots=array({false})
r=M.list(); check(r.read_status.carried.status=="unknown" and #r.hotbar==0,"all invalid not known empty")
reset(); pages.ForEach=function() error("missing pages") end
r=M.list(); check(r.read_status.pages.status=="partial" and r.read_status.carried.status=="complete" and #r.unmapped==1 and #r.bag==0 and #r.hotbar==1,"verified hotbar and unmapped rows retained")
local found,where=M.find(r,"ITEM_Beta")
check(found and found.item=="ITEM_Beta" and where=="unmapped","unmapped item visible to finder")
local used=M.use(nil,"ITEM_Beta")
check(not used.ok and used.reason=="verification_failed" and used.item.item=="ITEM_Beta","unmapped observed use is not falsely absent")
local equipped=M.equip(nil,"ITEM_Alpha")
check(equipped.ok and pressed==1,"verified hotbar item remains actionable after page failure")
local missing_slot=M.equip(nil,"ITEM_Beta")
check(not missing_slot.ok and missing_slot.reason=="verification_failed" and pressed==1,"unmapped equip does not invent a slot")
local dropped=M.drop(nil,"ITEM_Beta",1)
check(not dropped.ok and dropped.reason=="verification_failed","unmapped drop does not falsely claim absent")
reset(); items[2].Count=nil
r=M.list(); check(r.read_status.carried.status=="partial" and #r.bag==1 and r.bag[1].count==nil and r.read_status.carried.gaps[1].reason=="item_identity_or_quantity_unknown","quantity gap")
reset(); local reads=0; inv.ItemSlots=setmetatable({GetArrayNum=function() reads=reads+1; return reads==1 and 2 or 3 end},{__index=function(_,i) return items[i] end})
r=M.list(); check(r.read_status.carried.status=="partial" and #r.hotbar==1 and #r.bag==1 and r.read_status.carried.reason=="slot_count_changed_or_unknown","count changed")
reset(); local ids=0; inv.GetAddress=function() ids=ids+1; return ids<=2 and 2 or 9 end
r=M.list(); check(r.read_status.carried.status~="complete" and #r.hotbar+#r.bag+#r.unmapped==2,"component changed")
reset(); eq.GetHeldEquipmentDataRight=function() error("getter") end
r=M.list(); check(r.read_status.held.right.reason=="hand_getter_failed" and r.read_status.held.left.status=="unknown","getter failure")
reset(); eq.GetHeldEquipmentDataLeft=function() pawn.PlayerEquipmentComponent=obj(99,{}); return nil end
r=M.list(); check(r.held.right_item=="ITEM_Alpha" and r.read_status.held.right.status=="partial" and r.read_status.held.right.reason=="hand_identity_changed_or_unknown","equipment changed after first hand")
reset(); local pid_reads=0; pc.GetAddress=function() pid_reads=pid_reads+1; return pid_reads==1 and 1 or 88 end
r=M.list(); check(r.read_status.carried.status=="partial" and r.read_status.carried.reason=="controller_identity_changed_or_unknown" and #r.unmapped==2 and #r.hotbar==0 and #r.bag==0,"controller changed")
reset(); pc.InventoryComponent=nil
r=M.list(); check(r.read_status.carried.status=="unknown" and r.read_status.carried.reason=="component_unavailable","invalid component")
reset(); local unsafe=0
pages.GetArrayNum=function() _G.DW_PAUSE=true; return 1 end
pages.ForEach=function() unsafe=unsafe+1 end
r=M.list(); check(unsafe==0 and r.read_status.pages.status~="complete","pause during page count prevents later page reads")
reset(); unsafe=0
local first=items[1]; local firstdata=first.ItemData; first.ItemData=nil
setmetatable(first,{__index=function(_,key)
    if key=="ItemData" then _G.DW_PAUSE=true; return firstdata end
    if _G.DW_PAUSE then unsafe=unsafe+1 end
end})
r=M.list(); check(unsafe==0 and r.read_status.carried.status~="complete","pause during item data prevents subsequent field reads")
reset(); unsafe=0
eq.GetHeldEquipmentDataRight=function() _G.DW_PAUSE=true; return data(30,"ITEM_Alpha") end
eq.GetHeldEquipmentDataLeft=function() unsafe=unsafe+1 end
setmetatable(eq,{__index=function() if _G.DW_PAUSE then unsafe=unsafe+1 end end})
local h=M.held(pawn); check(unsafe==0 and h.read_status.right.status~="complete" and h.read_status.left.status=="unknown","pause in hand getter prevents other hands/worn/actors")
reset(); unsafe=0
setmetatable(eq,{__index=function(_,key)
    if key=="CurrentHeadWearable" then _G.DW_PAUSE=true; return nil end
    if _G.DW_PAUSE then unsafe=unsafe+1 end
end})
h=M.held(pawn); check(unsafe==0,"pause in worn getter prevents later worn and actor reads")
reset(); _G.DW_PAUSE=true; r=M.list()
check(not r.ok and r.reason=="paused" and calls==0,"pause makes no engine reads")
print("inventory completeness actual-module: "..n.." passed")
