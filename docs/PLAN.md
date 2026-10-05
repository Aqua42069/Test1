# Where things stand (2026-10-05)

Work moved from the local Windows repo (`Aqua69420`, with the Roblox Studio MCP) to this repo.
Only the place file came across, so `place/scripts/` is exported from it; the Studio builder
tools (`tools/build_luxor_real.luau`, `osm_roads.luau`, `osm_areas.luau`, ...) and
`tools/osm/PLAN.md` are still only in the local repo - copy them in when you can.

This environment has no Studio: scripts can be edited, compiled (Lune) and written back into a
copy of the place, but nothing can be play-tested or screenshotted here.

## Done here (v295b)
- Craps bet boxes: labels on a Front-face plate so they read upright from the players' side.
- Phone bank app: amount parsing, real failure reasons, no-recipient / no-amount feedback.
- Night window lighting for the Luxor (RoomLightsClient + Lighting.CityDay).

## Queue (the user's order, from the earlier sessions)
1. REAL elevators: cars that ride the tower shafts (the builder left "ElevatorShaft" models with
   Bank / Shaft / Stops / FloorHeight / BaseY attributes, "ElevatorCar" models parked at floor 1,
   "LandingDoor" leaves with Level / Leaf, "CarDoor" / "CarPanel") + the pyramid's 39-degree
   inclinators in the four corners. Replaces the teleport menus (Workspace/Luxor/Elevators.Script,
   TowerElevatorClient). The private casino floor (West Tower 15) stays off the elevators.
2. NPC guests: walk the casino, gamble, go up to their rooms.
3. In-room TVs show the news: several channels when a court case AND a chase are live; otherwise
   weather, then re-runs about recent / upcoming stories.
4. Police breaching hotel room doors.
5. Then the landmarks at 1:1: Excalibur (re-aim the Luxor walkway's end at its door), MGM Grand,
   New York-New York, Mandalay Bay.

## Open question for the user
Guaranteed elite trial odds (90% / 75%) or folded into the trial engine (current).

## Notes
- Workspace.Luxor is ModelStreamingMode Default (~75k parts): it streams; client scripts must
  handle it arriving / leaving (RoomLightsClient does).
- Optional Workspace settings (Properties window only): StreamingMinRadius 192,
  StreamingTargetRadius 1400, StreamingIntegrityMode MinimumRadiusPause.
