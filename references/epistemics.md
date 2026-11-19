# Epistemics: calibrated claims

Shared spec for skills that answer questions from evidence (`answer-slack`, `investigate-ticket`).
Code shows what it does, not why it exists. The why lives in commits, PRs, tickets, docs and chat,
all incomplete. A confident guess posted under the user's name is worse than "we don't know".

## Confidence tiers

Every substantive claim sits in exactly one tier. The tier decides the wording.

| Tier | Meaning | Wording |
|---|---|---|
| **Direct** | A source an author *wrote* states it: PR body, ticket, code comment, doc, chat message. | "X because Y" + citation. |
| **Supported** | No single source says it, but 2+ independent sources converge. | "The evidence points to X: {sources}." |
| **Inferred** | Your reading of context; nothing states it. | "Likely", "appears", "is consistent with". Show the chain: "Given A and B, C." |
| **Speculative** | Plausible, but other explanations fit as well. | "One possibility is X; no direct evidence." |
| **Unknown** | You looked and could not find out. A valid result. | "Searched {where} for {what}; found nothing." |

## Rules

- **Causal words need a citation next to them.** "because", "the reason is", "was designed to",
  "fixes", "the team decided" are Direct/Supported only.
- **Code is not evidence of its own intent.** "The code clamps to 100, so they wanted 100" is
  Inferred at best.
- **Absence of evidence is not evidence of absence.** "Nobody mentioned security" does not mean it
  was not a concern.
- **Don't retrofit a tidy rationale.** Consistent patterns may be copy-paste; old code may encode
  reasons that no longer apply or were wrong.
- **The asker's hypothesis is a candidate, not a conclusion.** "I assume it's for performance?"
  gets checked independently. Confirm only with evidence; otherwise say what the evidence supports.
- **Contradicting sources are both reported**, each with its citation. Don't pick the tidier one.
- **Name gaps concretely**: the question, the sources searched, the search terms, what came back.
  "We couldn't find out" alone is not acceptable.
- **Avoid** "obviously", "clearly", "of course", dismissive "just".

## Calibration check before finishing

1. Every Direct/Supported claim has an adjacent citation; otherwise downgrade it.
2. Wording matches tier (no "because" on an Inferred claim).
3. No claim uses the code as evidence for its own intent.
4. There is an explicit unknowns/gaps entry. If there are none, re-check: complete evidence is
   rare.
