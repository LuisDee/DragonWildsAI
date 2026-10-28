-- Native item count contract, actual inventory module with fake UE bindings.
local here=debug.getinfo(1,'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
local old=loadfile
local function obj(id,name)
 return {IsValid=function() return true end,GetAddress=function() return id end,GetFullName=function() return name end,IsA=function() return true end}
end
local world='dev';local U={GARBAGE_OR_UNREACHABLE=1,world_id=function() return world end}
local pc,pawn,inventory
U.find_all=function() return {pc} end
function FindAllOf() return {pc} end
loadfile=function(path,...) if path:find('/mod/body/util.lua',1,true) then return function() return U end end return old(path,...) end
local M=assert(old(here..'/../scripts/inventory.lua'))();loadfile=old
local ic=obj(1,'Class /Script/Dominion.InventoryComponent')
local itemclass=obj(2,'Class /Script/Dominion.ItemData')
local itempath='/Game/Example.ITEM_Example'
local asset=obj(3,'ItemData '..itempath)
PropertyTypes={ObjectProperty='obj',IntProperty='int'}
local function prop(name,kind)
 return {GetFName=function() return {ToString=function() return name end} end,IsA=function(_,v) return v==kind end,GetPropertyClass=function() return itemclass end}
end
local fn=obj(4,'Function /GetNumItemsByData');local extra=false;local flags=0x54020401
fn.GetFunctionFlags=function() return flags end
fn.ForEachProperty=function(_,cb) cb(prop('ItemData','obj'));cb(prop('ReturnValue','int'));if extra then cb(prop('Extra','int')) end end
StaticFindObject=function(p) if p=='/Script/Dominion.InventoryComponent' then return ic elseif p=='/Script/Dominion.ItemData' then return itemclass elseif p=='/Script/Dominion.InventoryComponent:GetNumItemsByData' then return fn elseif p==itempath then return asset end end
local get=0;local value=0
inventory=obj(5,'Inventory /Main');inventory.GetNumItemsByData=function(_,x) assert(x==asset);get=get+1;return value end
pawn=obj(6,'Pawn /Dev');pc=obj(7,'PC /Dev');pc.Pawn=pawn;pc.InventoryComponent=inventory
pc.IsLocalController=function() return true end;pc.HasAnyInternalFlags=function() return false end
pawn.HasAnyInternalFlags=function() return false end
local n=0;local function check(x,msg) assert(x,msg);n=n+1 end
local r=M.count_item(itempath);check(r.status=='observed' and r.count==0 and get==1,'zero is observed')
value=231;r=M.count_item(itempath);check(r.status=='observed' and r.count==231,'positive item')
get=0;r=M.count_item('/Game/NotLoaded.NotLoaded');check(r.status=='unknown' and get==0,'unloaded unknown')
extra=true;get=0;r=M.count_item(itempath);check(r.status=='unknown' and get==0,'extra parameter refused');extra=false
flags=0x40;r=M.count_item(itempath);check(r.status=='unknown','flags refused');flags=0x54020401
value=-1;r=M.count_item(itempath);check(r.status=='unknown','invalid result unknown');value=0
get=0;inventory.GetNumItemsByData=function() get=get+1;pc.InventoryComponent=obj(99,'changed');return 0 end
r=M.count_item(itempath);check(r.status=='unknown' and get==1,'reentry refuses result');pc.InventoryComponent=inventory
_G.DW_PAUSE=true;get=0;r=M.count_item(itempath);check(r.status=='unknown' and get==0,'pause skips native');_G.DW_PAUSE=nil
world='unknown';get=0;r=M.count_item(itempath);check(r.status=='unknown' and get==0,'unknown world denied');world='dev'
local first=pc;inventory.GetNumItemsByData=function() get=get+1;pc=obj(88,'other');return 0 end;get=0
r=M.count_item(itempath);check(r.status=='unknown' and get==1,'local controller replacement denied');pc=first
inventory.GetNumItemsByData=function() get=get+1;world="other";return 0 end;get=0
r=M.count_item(itempath);check(r.status=="unknown" and get==1,"world change denies result");world="dev"
local oldstatic=StaticFindObject;local visits=0
StaticFindObject=function(p) if p==itempath then visits=visits+1;if visits==2 then pc.InventoryComponent=obj(90,"replaced") end end;return oldstatic(p) end
get=0;r=M.count_item(itempath);check(r.status=="unknown" and get==0,"binding mutation before getter denied")
StaticFindObject=oldstatic;pc.InventoryComponent=inventory
print('inventory native count fake: '..n..' passed')
