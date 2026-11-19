# WoW Forever API rules (learned the hard way)

WoW Forever runs the **Midnight / 12.x Mainline API**. Addons can't cast automatically. Every rule below came from a real in-game bug.

## 1. Secret values: assume any unit value can be secret at any time
- Combat **and out of combat** (seen: `UnitInRange` was secret at `PLAYER_LOGIN`). Values can be secret from UnitHealth/Max, UnitPower,
  UnitInRange, UnitIsVisible, C_Spell.IsSpellInRange, UnitIsUnit, UnitIsDeadOrGhost, UnitIsConnected, UnitThreatSituation,
  UnitGroupRolesAssigned, UnitExists, aura tables/fields/auraInstanceID, names, GUIDs.
- **Forbidden on a secret:** `if x`, `not x`, `x and`, `x or`, `==`/`<`, arithmetic, `..`, `string.format`, `tostring`, `#t`, indexing a secret table.
- **Allowed:** `issecret(x)` (`ns.issecret`), and passing the value **straight into widget setters**: `StatusBar:SetValue`,
  `FontString:SetText`, `Texture:SetTexture`, `Region:SetAlphaFromBoolean(v, a1, a2)`, `GameTooltip:AddLine(name)`,
  `Cooldown:SetCooldownFromDurationObject(C_UnitAuras.GetAuraDuration(...))`, `C_UnitAuras.GetAuraApplicationDisplayCount`.
- The pattern: check `issecret(v)` first. If it's readable, branch normally. If it's secret, pass it through or keep the last known state. Treat "unknown" as the
  permissive answer (in range, exists).
- Wrap risky API calls in `pcall`. Render each aura icon in its own `pcall` so one bad aura can't blank the row, and keep the last-known icons if enumeration fails completely.

### 1b. Aura data is locked for addons in combat, so display auras with Blizzard's AuraContainer
- Real error (count 744): `GetAuraDuration(): Auras cannot be accessed when secret while tainted by 'HealerForever'`. In combat, addon code can't
  reliably enumerate or read party auras. Every enumeration method failed, and icons drawn by hand went stale (dispelled curses stayed on the bars).
- The fix pattern: `CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")` plus `SetUnit(unit)` and `AddAuraGroup(name, filter, opts)`
  with an `AuraButton` template (inherits `CustomAuraButtonTemplate`, inside `<ScopedModifier useForbiddenObjectTable="true">`). The GAME draws
  and updates the icons in combat.
- The installed HealKit addon uses this approach. Its license is "all rights reserved": read it to learn the APIs, never copy its code.
- Never call aura-reading APIs (GetAuraDuration, GetAuraDataBy*, GetUnitAuras) in combat for display. Buff-button logic runs out of combat only.

## 2. Taint and the "addon blocked / disable addon" popup
- Never call methods on, reparent, hook or write fields on Blizzard frames (PartyFrame, CompactPartyFrame, ColorPickerFrame fields,
  SettingsPanel). The "Hide Blizzard party frames" feature was **removed** for this reason. Users should use Blizzard's Edit Mode instead.
- No `UIDropDownMenu`, because it's a taint source. Use our own widgets or `Menu`/`MenuUtil`.
- `hooksecurefunc` is not used anywhere, and a test checks this.
- `ns.NewFrame` must **not** override SetScript/HookScript on secure or protected frames. If it does, it wraps Blizzard's restricted closures
  (SecureHandlerWrapScript) in xpcall, and the game raises "Cannot call restricted closure from insecure code".

## 3. Combat lockdown
- On secure frames (unit buttons, buff buttons) and their secure parents, `SetAttribute`, `SetPoint`, `SetSize`, `Show`/`Hide`, `RegisterUnitWatch`, `SetOverrideBinding*`,
  `EnableMouse` and `SetPropagate*` are all forbidden in combat. Go through `ns:AfterCombat`.
- Non-secure children (aura icons, badges, borders, glow, range overlays) can change in combat. Create them ahead of time (`Auras.Prepare`).
- Minimap pins: don't call EnableMouse every tick. Only call it when the value changes.
- **Mouse setters are blocked in combat**, also on the native aura buttons the game creates mid-fight (real error, count 80:
  `ADDON_ACTION_BLOCKED: Button:SetPropagateMouseMotion()`, from `initializeFrame`). Never call `SetPropagateMouseMotion`,
  `SetPropagateMouseClicks`, `EnableMouse`, `SetMouseClickEnabled` or `SetMouseMotionEnabled` while `InCombatLockdown()` on anything
  inside the unit buttons. Remember the wanted state and apply it on `PLAYER_REGEN_ENABLED` (`ns:AfterCombat`). Code that the game
  calls in combat (container `initializeFrame`, pool callbacks) must take the same route. Safe defaults go in the XML template
  (`enableMouseClicks="false"`), because XML attributes apply at creation without a protected call. A `pcall` doesn't help:
  the block is reported anyway.

- **Showing protected frames in combat:** only a secure state driver can (`RegisterStateDriver(frame, "visibility", "[group:raid] hide; show")`,
  registered out of combat). Our plain anchors work with it because `ns.NewFrame` only wraps SetScript/HookScript, never Show/Hide (a Lua
  override of Show would run addon code inside the secure driver). Unregister the driver before the addon itself shows/hides that frame again.
- **Game-managed aura regions:** never rely on SetAlpha/Hide on regions the game drives (Icon, DispelBorder, Cooldown, Count of an aura
  button, or a texture given to `AddDispelTypeTexture`): the game re-sets them. Put them under a plain frame of ours and show/alpha that.

## 4. Secure clicks and casting
- Unit buttons: `SecureUnitButtonTemplate`, `RegisterForClicks("AnyUp")` **only**. `SecureUnitButton_OnClick` has no down/up filter,
  so AnyDown+AnyUp casts twice. Secure *action* buttons (buff, smart and tank buttons) use AnyDown+AnyUp, because that template filters.
- **Never `type="spell"` with a unit.** When the unit is invalid, out of range or not visible, autoSelfCast redirects the cast to the player. Always use
  `type="macro"` with strict text: `/cast [@party2,help,nodead] Flash of Light`, or with res
  `/cast [@party2,dead] Redemption; [@party2,help,nodead] Flash of Light`. Never add a bare fallback clause, `@target` or `@mouseover`.
  `@player` is allowed only on the player's own frame. Macros must stay at 255 characters or fewer. A test parses every generated macro.
- Line of sight to friendly units isn't available to addons. Range (`UnitInRange`, `IsSpellInRange`) and visibility (`UnitIsVisible`) are.
- Attribute prefix order: `alt-ctrl-shift-` (from `SecureButton_GetModifierPrefix`). There's **no `meta-` prefix**.

## 5. Cmd (meta) on macOS
- Working solution, confirmed in game: a secure state driver `[mod:meta] meta; none` (`hfmeta`) on each unit button. While Cmd is held,
  its restricted snippet copies the Cmd bindings into the matching non-Cmd attribute slots and restores them on release.
- Override bindings (`META-BUTTONn`, chord order `ALT-CTRL-SHIFT-META-`) remain as a second route, but alone they didn't fire for mouse buttons 1–3.
  If users see "spell not ready" after a Cmd cast, remove that route.
- On Mac, Cmd+Left may act as a right click. The bindings editor shows a note about this.

## 6. SavedVariables timing
WoW writes saved settings only on `/reload`, logout or a clean quit. A crash loses that session's changes.
