.pragma library
// Words for the EVOLVE panel: the glossary card / tooltips and the design preset's terms. The goal templates are block
// programs in EvolveBlocks.js.

// Plain-language explanations for the bundled design preset's terms (scripted autopilot, not a template).
const designTerms = { climb: "earns points for climbing (metres gained per second)",
                      efficiency: "height reached per kilogram of craft — lighter designs that climb score more",
                      crash: "−100 if it crashes" }

// Short glossary used by tooltips and the "What do these words mean?" card.
const glossary = [
    ["Fitness", "The score of one try. Higher is better; the goal decides how it is counted."],
    ["Candidate", "One variation being tested: a set of network weights and/or craft dimensions."],
    ["Population", "How many candidates are tried in each round."],
    ["Generation", "One round: every candidate flies, the best are kept and varied to make the next round."],
    ["Mutation", "Small random changes to a good candidate, so the next generation explores nearby ideas."],
    ["Genome / genes", "The list of numbers that evolves (network weights, wing span…)."],
    ["Episode", "One simulated flight of one candidate, from spawn until time runs out or it crashes."]
]
