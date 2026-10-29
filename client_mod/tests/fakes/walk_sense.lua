-- Explicit fake native sensor for mover integration tests. The real adapter has
-- its own native-wrapper/ownership suite; this fixture reads independent world
-- callbacks installed by test_move.lua and never loads the actual engine.
local M={}
function M.acquire(o)
 local env=assert(rawget(_G,'TEST_WALK_NATIVE'),'missing fake walking world')
 local closed=false
 local function valid() return not closed and o.live()==true and env.valid~=false end
 local function call(kind,a,b)
  env.calls=env.calls or {};env.calls[#env.calls+1]={kind=kind,a=a,b=b}
  if not valid() then return {status='unknown',known=false,consumed=1} end
  if kind=='floor' then return env.floor(a) end
  return {known=true,blocking=env.sweep(a,b),consumed=1}
 end
 return {shape={radius_cm=34,half_height_cm=90,step_cm=45,clearance_cm=0,clearance_line_trace=false,profile='Player'},
  valid=valid,floor=function(a) return call('floor',a) end,
  sweep=function(a,b) return call('sweep',a,b) end,
  initial=function(a) return call('initial',a,{X=a.X,Y=a.Y,Z=a.Z+10}) end,
  close=function() if env.close_blocked then return false end;closed=true;return true end}
end
return M
