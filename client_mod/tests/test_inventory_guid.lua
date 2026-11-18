-- inventory.describe_item carries the item instance (UItem.Guid as hex) so the job grader can tell a piece made in a
-- run from one carried in (tools/job_run.py made_here, job L1). Actual inventory module with fake UE bindings.
local here=debug.getinfo(1,'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
local old=loadfile
local U={}
U.try=function(f,...) local ok,v=pcall(f,...);if ok then return v end end
U.valid=function(o) return o~=nil end
U.alive=U.valid
U.str=function(v) return v~=nil and tostring(v) or nil end
U.class_word=function() return 'WearableEquipment' end
U.path_of=function(o) return o.path end
U.find_object=function() return nil end
U.find_all=function() return {} end
U.guid_hex=function(g)
 if type(g)~='table' and type(g)~='userdata' then return nil end
 local ok,s=pcall(function() return string.format('%08X%08X%08X%08X',g.A%0x100000000,g.B%0x100000000,g.C%0x100000000,g.D%0x100000000) end)
 return ok and s or nil
end
loadfile=function(path,...) if path:find('/mod/body/util.lua',1,true) then return function() return U end end return old(path,...) end
local M=assert(old(here..'/../scripts/inventory.lua'))();loadfile=old
local data={path='/Game/Gameplay/Character/Player/Equipment/Head/ITEM_Armour_T2_Head_Leather.ITEM_Armour_T2_Head_Leather',Name='Leather Cowl'}
local function item(guid) return {ItemData=data,Count=1,Durability=636,GetMaxDurability=function() return 1000 end,
 IsBroken=function() return false end,IsEnchanted=function() return false end,NumMasterworkUpgradesApplied=0,Guid=guid} end
local n=0;local function check(x,msg) if not x then print('FAIL '..msg) os.exit(1) end n=n+1 end
local d=M.describe_item(item({A=0x0A0A0A0A,B=0x0B0B0B0B,C=0x0C0C0C0C,D=0x0D0D0D0D}))
check(d and d.item=='ITEM_Armour_T2_Head_Leather' and d.durability==636,'the item is described')
check(d.guid=='0A0A0A0A0B0B0B0B0C0C0C0C0D0D0D0D','the instance guid is carried as hex')
d=M.describe_item(item({A=-1,B=0,C=0,D=1}))
check(d.guid=='FFFFFFFF000000000000000000000001','a negative int32 word reads as its unsigned hex')
d=M.describe_item(item({A=0,B=0,C=0,D=0}))
check(d.guid==nil,'an empty guid is no instance id')
d=M.describe_item(item(nil))
check(d.guid==nil and d.item=='ITEM_Armour_T2_Head_Leather','an unread guid leaves the rest of the description')
print('inventory guid fake: '..n..' passed')
