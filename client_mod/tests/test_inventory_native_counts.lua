-- Native item count (GetNumItemsByData), actual inventory module with fake UE bindings.
local here=debug.getinfo(1,'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
local old=loadfile
local function obj(id,name)
 return {IsValid=function() return true end,GetAddress=function() return id end,GetFullName=function() return name end}
end
local pc
local U={}
U.try=function(f,...) local ok,v=pcall(f,...);if ok then return v end end
U.valid=function(o) return o~=nil end
U.alive=U.valid
U.find_all=function() return {pc} end
U.find_object=function(p) return StaticFindObject(p) end
loadfile=function(path,...) if path:find('/mod/body/util.lua',1,true) then return function() return U end end return old(path,...) end
local M=assert(old(here..'/../scripts/inventory.lua'))();loadfile=old
local itempath='/Game/Example.ITEM_Example'
local asset=obj(3,'ItemData '..itempath)
StaticFindObject=function(p) if p==itempath then return asset end end
local get=0;local value=0
local inventory=obj(5,'Inventory /Main');inventory.GetNumItemsByData=function(_,x) assert(x==asset);get=get+1;return value end
pc=obj(7,'PC /Dev');pc.InventoryComponent=inventory
pc.IsLocalController=function() return true end
local n=0;local function check(x,msg) assert(x,msg);n=n+1 end
local r,why=M.count_item(itempath);check(r==0 and get==1,'zero is a count')
value=231;r=M.count_item(itempath);check(r==231,'positive item')
get=0;r,why=M.count_item('/Game/NotLoaded.NotLoaded');check(r==nil and why=='inventory_or_item_unavailable' and get==0,'unloaded item is unknown')
value=-1;r,why=M.count_item(itempath);check(r==nil and why=='count_unavailable','invalid result is unknown');value=0
inventory.GetNumItemsByData=function() error('native failure') end
r,why=M.count_item(itempath);check(r==nil and why=='count_unavailable','failed call is unknown')
_G.DW_PAUSE=true;r,why=M.count_item(itempath);check(r==nil and why=='paused','pause skips the native call');_G.DW_PAUSE=nil
print('inventory native count fake: '..n..' passed')
