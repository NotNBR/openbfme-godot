-- Income Banner (an OpenBFME SDK sample, docs/MODS.md): every 10 seconds of game time each player gets 250 resources.
-- A sim script: it changes the game, so every player runs it in lockstep and it is part of the mod's identity.
local PAYDAY_FRAMES = 50 -- the logic runs 5 frames a second (LOGICFRAMES_PER_SECOND)
local AMOUNT = 250

function onFrame(frame)
	if frame % PAYDAY_FRAMES == 0 then
		for i = 0, game.playerCount() - 1 do
			game.addMoney(i, AMOUNT)
		end
	end
end
