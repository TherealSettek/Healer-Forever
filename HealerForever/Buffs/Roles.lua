local ADDON_NAME, ns = ...

-- Role detection: manual override (ns.db.roleOverrides[name-realm]) first, then the group role
-- assigned by the game, and for the player the spec role when such an API exists.
local Roles = {}
ns.Roles = Roles

local issecret = ns.issecret

local VALID = { TANK = true, HEALER = true, DAMAGER = true }

function Roles.Key(unit)
    if not (UnitExists and ns.Exists(unit)) then return nil end
    local name, realm
    if UnitFullName then
        name, realm = UnitFullName(unit)
    else
        name = UnitName(unit)
    end
    if issecret(name) or not name then return nil end
    if issecret(realm) or not realm or realm == "" then
        realm = GetNormalizedRealmName and GetNormalizedRealmName() or ""
        if issecret(realm) then realm = "" end
    end
    return name .. "-" .. realm
end

function Roles.GetDetected(unit)
    local role
    if UnitGroupRolesAssigned then
        role = UnitGroupRolesAssigned(unit)
        if issecret(role) or not VALID[role] then role = nil end
    end
    if not role and unit == "player" and GetSpecialization and GetSpecializationRole then
        local spec = GetSpecialization()
        if spec and not issecret(spec) then
            local specRole = GetSpecializationRole(spec)
            if not issecret(specRole) and VALID[specRole] then role = specRole end
        end
    end
    return role
end

function Roles.GetOverride(unit)
    local key = Roles.Key(unit)
    local role = key and ns.db and ns.db.roleOverrides[key]
    if VALID[role] then return role end
    return nil
end

function Roles.Get(unit)
    return Roles.GetOverride(unit) or Roles.GetDetected(unit)
end

-- role nil / "AUTO" clears the override
function Roles.SetOverride(unit, role)
    local key = Roles.Key(unit)
    if not key then return false end
    ns:AfterCombat("role-" .. key, function()
        if VALID[role] then ns.db.roleOverrides[key] = role else ns.db.roleOverrides[key] = nil end
        ns:Changed("roles")
    end)
    return true
end

ns:RegisterEvent("PLAYER_ROLES_ASSIGNED", function() ns:Changed("roles") end)
