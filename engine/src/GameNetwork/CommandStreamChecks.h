// OpenBFME. GPL-3.0.
//
// CommandStreamChecks (lane ANTICHEAT-1, owner 2026-10-21): two after-the-fact checks over a re-simulated game's command stream, beside OrdersIntoFog
// (D1) in FogCheckDriver. OpenBFME's own code: retail has no such check. Not simulation code: they read the messages and the logic, never change either.
//
// D5 InputRateCheck ("macro detector"): the commands each human player issued, counted over every window of 5 seconds of game time (25 logic frames,
// the frames the commands ran on: deterministic, no wall clock). A window with more than `threshold` commands (default 100) is an input-rate episode;
// overlapping windows are one episode (its peak, the frame of the peak, the most frequent command type in the peak window). Macros and hotkeys are
// allowed: the result is informational (band "review" at most), the owner wants to know who plays at that rate. MSG_LOGIC_CRC (the client's own
// checksum, not the player's input) is not counted. Note: a click usually sends two messages (the selection, then the order).
//
// D6 CommandIntegrityCheck ("modified client"): commands an unmodified OpenBFME client never sends:
//   * unknown_type: a message type outside RotWK's 1001 .. 1147 numbering (GameMessageTypeName has no name for it);
//   * malformed: an argument of the wrong type where the command's own handler requires a type (the object of an object-targeted order, a selection's
//     flag and object ids, the issuer object of a rally point / auto ability / formation / enter command);
//   * foreign_object: a command naming another player's object as the ISSUER (a rally point, an auto ability, a formation, the object that enters): the
//     client only names objects of the issuing player's own group (GameLogicDispatch::issuerObject drops these; the check reports them).
// Results are review-level until real games show the clean-client rate is zero.

#pragma once

#include "GameLogic/GameMessage.h"
#include "GameLogic/ObjectTypes.h"

#include <cstdint>
#include <deque>
#include <map>
#include <string>
#include <vector>

class GameLogic;

// the report players' common fields (the D1 report's shape: tools/integrity/README.md)
struct StreamCheckPlayer
{
	int player = -1;
	int slot = -1;
	std::string name;
};

class InputRateCheck
{
public:
	struct Settings
	{
		unsigned windowFrames = 25; ///< 5 seconds of game time
		unsigned threshold = 100;   ///< more than this many commands in one window is an episode
	};
	struct Episode
	{
		UnsignedInt startFrame = 0, endFrame = 0; ///< the first and last window end frames over the threshold
		UnsignedInt peakFrame = 0;                ///< the end frame of the busiest window
		unsigned peak = 0;                        ///< commands in that window
		int topCommand = 0;                       ///< the most frequent message type in that window (the lowest type on a tie)
	};
	struct PlayerResult : StreamCheckPlayer
	{
		unsigned long long commands = 0; ///< every counted command of the game
		unsigned peak = 0;               ///< the busiest window of the game
		UnsignedInt peakFrame = 0;
		std::vector<Episode> episodes;
	};

	InputRateCheck(GameLogic &logic, std::vector<int> players, Settings settings);
	InputRateCheck(GameLogic &logic, std::vector<int> players);
	void setSlot(int player, int slot);
	// every batch in frame order (also the empty ones)
	void beforeFrame(UnsignedInt frame, const std::vector<GameMessage> &commands);
	void abstain(const std::string &reason);
	const std::string &abstainReason() const { return m_abstain; }
	std::vector<PlayerResult> results() const { return m_results; }
	std::string json(const std::string &gameId, const std::string &crcParity, UnsignedInt frames) const;
	static bool counted(int messageType) { return messageType != MSG_LOGIC_CRC; }

private:
	struct Window
	{
		std::deque<std::pair<UnsignedInt, std::vector<int>>> frames; ///< the last windowFrames batches' counted types
		unsigned count = 0;
		bool inEpisode = false;
	};
	PlayerResult *resultFor(int player, size_t *index);
	Settings m_settings;
	std::vector<PlayerResult> m_results;
	std::vector<Window> m_windows;
	std::string m_abstain;
	UnsignedInt m_lastFrame = 0;
	bool m_any = false;
};

class CommandIntegrityCheck
{
public:
	struct Event
	{
		UnsignedInt frame = 0;
		int messageType = 0;
		std::string reason; ///< unknown_type | malformed | foreign_object
		ObjectID object = 0; ///< the object named (foreign_object), 0 otherwise
		int argument = -1;   ///< the argument index found wrong (malformed / foreign_object)
		int encounter = 0;
	};
	struct PlayerResult : StreamCheckPlayer
	{
		unsigned long long commands = 0;
		std::vector<Event> events;
		int encounters = 0;
	};
	CommandIntegrityCheck(GameLogic &logic, std::vector<int> players, unsigned encounterFrames = 150);
	void setSlot(int player, int slot);
	// before batch `frame` runs (the objects named are looked up in the state the commands run on)
	void beforeFrame(UnsignedInt frame, const std::vector<GameMessage> &commands);
	void abstain(const std::string &reason);
	const std::string &abstainReason() const { return m_abstain; }
	std::vector<PlayerResult> results() const;
	std::string json(const std::string &gameId, const std::string &crcParity, UnsignedInt frames) const;
	// the argument index of the ISSUER object a command names (rally point, auto ability, formation, enter), -1 for none
	static int issuerArgument(int messageType);

private:
	void check(UnsignedInt frame, const GameMessage &m, PlayerResult &r);
	GameLogic &m_logic;
	unsigned m_encounterFrames;
	std::vector<PlayerResult> m_results;
	std::string m_abstain;
};
