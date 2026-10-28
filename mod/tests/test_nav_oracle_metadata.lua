-- Real oracle module with deterministic fake native access; no game or native calls.
local here = assert(debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$"))
package.path = here .. "/../scripts/?.lua;" .. package.path
local json = require("dkjson")
local nav, ctx, anchor = {}, {}, {}
local U = {}
function U.try(f) local ok,v=pcall(f); if ok then return v end end
function U.try_err(f) local ok,v=pcall(f); if ok then return v end; return nil,v end
function U.valid(x) return x ~= nil end
function U.find_all(cls) if cls == 'GameStateBase' then return {ctx} end; return {} end
function U.loc(x) if x == anchor then return {X=0,Y=0,Z=0} end end
function U.event() end
function U.short() return 'fake' end
package.loaded['body.util'] = U
function StaticFindObject() return nav end
_G.DW_NAV_ANCHOR=anchor; _G.DW_NAV_ANCHOR_T=os.time()-10; _G.DW_NAV_LINKS_DONE=true
local mode, partial_mode = 'success', 'false'
function nav:K2_ProjectPointToNavigation(_, p, out, _, _, ext)
    if p.X == 0 then
        if mode == 'start_error' then error('start getter') end
        if mode == 'start_false' then return false end
        return true
    end
    if mode == 'error_then_false' and ext.Z == 150 then error('projection failure') end
    if mode == 'error_then_true' and ext.Z == 150 then error('projection failure') end
    if mode == 'wrongtype' and ext.Z == 150 then return 'bad' end
    if mode == 'both_false' or mode == 'error_then_false' or mode == 'wrongtype' then return false end
    return true
end
function nav:FindPathToLocationSynchronously()
    return { PathPoints = {ForEach=function(_, cb)
        cb(1,{get=function() return {X=0,Y=0,Z=0} end})
        if partial_mode=='badpoint' then cb(2,{get=function() return {X=0/0,Y=0,Z=0} end})
        elseif partial_mode=='iteration_error' then error('iteration failed')
        else cb(2,{get=function() return {X=100,Y=0,Z=0} end}) end
    end}, IsPartial=function()
        if partial_mode=='error' then error('getter') end
        if partial_mode=='wrongtype' then return 1 end
        return partial_mode=='true'
    end, GetPathLength=function() return 100 end }
end
local M = dofile(here .. '/../experiments/nav_oracle.lua')
local result={}
for _, pair in ipairs({{'success','false'}, {'both_false','true'}, {'error_then_false','error'},
                       {'error_then_true','wrongtype'}, {'wrongtype','false'},
                       {'success','badpoint'}, {'success','iteration_error'}, {'start_error','false'}, {'start_false','false'}}) do
    mode, partial_mode=pair[1],pair[2]
    result[#result+1]=M.run({}, {from={0,0,0},to={1,0,0}})
end
result[#result+1]=M.run({}, {from={1e308,0,0},to={1,0,0}})
print(assert(json.encode(result)))
