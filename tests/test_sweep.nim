## The gossip baseline's weights, swept — the measurement behind the two
## constants, kept in CI so the choice is recorded and drift is visible.
##
## `ClueLogOdds` and `ClaimLogOdds` (`sim.nim`) are derived analytically:
## ln(0.6/0.4) for a seat's own 60 %-reliable clue, ln(0.56/0.44) for one
## neighbour's first claim once about a quarter of the neighbourhood is
## paid to lie. A derivation is not a measurement, so this harness replays
## the same seeds through the same rules with the claim weight moved across
## a grid, prints the whole table, and asserts the shipped pair sits on the
## grid's plateau and beats the ignore-the-network cell.
##
## Only the RATIO of the two weights can change a decision — the claim is
## the sign of a weighted sum, which is scale-free — so the grid varies the
## claim weight against the shipped clue weight and covers the ratio line
## from 0 (never listen) to 4x (follow whatever you heard first).

import std/[math, unittest]
import rumor/[llm, sim]

const
  SweepSeeds = 300
  ClaimWeightMultiples = [0.0, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 4.0]
  ## The shipped pair is this entry of the grid.
  ShippedCell = 4

proc fixture(seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = 5
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc weightedClaim(sim: Sim, seat: int, clueWeight, claimWeight: float):
    string =
  ## The gossip baseline's rule with both weights as parameters. The
  ## saboteur branch (mirror your own clue and never drift) does not depend
  ## on them, so it is reproduced as-is.
  if sim.roleOf[seat] == 1:
    return (if sim.clue[seat] == "A": "B" else: "A")
  var odds = (if sim.clue[seat] == "A": clueWeight else: -clueWeight)
  for entry in sim.firstClaims(seat):
    odds += (if entry.claim == "A": claimWeight else: -claimWeight)
  if odds > 0.0: "A"
  elif odds < 0.0: "B"
  else: sim.clue[seat]

proc playWeighted(config: GameConfig, clueWeight, claimWeight: float): float =
  ## One whole episode of the parameterised baseline through the real
  ## rules; the result is the honest cogs' accuracy.
  var sim = initSim(config)
  while not sim.done:
    let ballot = sim.phase == phBallot
    for seat in sim.pendingSeats():
      let claim = sim.weightedClaim(seat, clueWeight, claimWeight)
      if ballot:
        sim.applyVote(seat, claim, 50, "", "", true)
      else:
        sim.applyMessage(seat, claim, 60, 60, "swept", "", true)
  sim.accuracy

proc playShipped(config: GameConfig): float =
  ## The same episode played by the SHIPPED baseline, unparameterised.
  var sim = initSim(config)
  while not sim.done:
    let ballot = sim.phase == phBallot
    for seat in sim.pendingSeats():
      let decision = scriptedAction(sim, seat, skGossip)
      if ballot:
        sim.applyVote(seat, decision.vote, decision.belief, decision.reason,
          decision.notes, true)
      else:
        sim.applyMessage(seat, decision.claim, decision.confidence,
          decision.belief, decision.message, decision.notes, true)
  sim.accuracy

suite "baseline weight sweep":
  test "the shipped weights are the derivation they claim to be":
    check abs(ClueLogOdds - ln(0.6 / 0.4)) < 1e-12
    check abs(ClaimLogOdds - ln(0.56 / 0.44)) < 1e-12

  test "the parameterised baseline reproduces the shipped one exactly":
    ## Without this the grid would be measuring a lookalike. At the shipped
    ## weights the harness must land on the shipped baseline's own numbers,
    ## episode for episode.
    for seed in 0 ..< 40:
      let config = fixture(seed)
      check playWeighted(config, ClueLogOdds, ClaimLogOdds) ==
        playShipped(config)

  test "the shipped claim weight is the grid's plateau":
    var rates: array[ClaimWeightMultiples.len, float]
    for cell, multiple in ClaimWeightMultiples:
      var total = 0.0
      for seed in 0 ..< SweepSeeds:
        total += playWeighted(fixture(seed), ClueLogOdds,
          multiple * ClaimLogOdds)
      rates[cell] = total / SweepSeeds.float
      echo "sweep: claim weight ", multiple, "x ClaimLogOdds (",
        multiple * ClaimLogOdds, ") -> honest accuracy ", rates[cell],
        " over ", SweepSeeds, " seeds"
    var best = 0
    for cell in 0 ..< rates.len:
      check rates[cell] > 0.5
      check rates[cell] < 0.9
      if rates[cell] > rates[best]:
        best = cell
    echo "sweep: best cell ", ClaimWeightMultiples[best], "x at ",
      rates[best], "; shipped ", ClaimWeightMultiples[ShippedCell], "x at ",
      rates[ShippedCell]
    ## The shipped weight is on the plateau: no cell of the grid beats it
    ## by more than a point on the same seeds.
    check rates[best] - rates[ShippedCell] <= 0.03
    ## And aggregation is worth doing at all: the shipped weight beats the
    ## cell that ignores the network and votes its own clue.
    check rates[ShippedCell] > rates[0]
