# Writing style for posted text

Applies to every draft that is posted under the user's name: Slack replies, PR reviews and
comments, ticket comments, standups, digests, doc reviews. Write the way the user would tell a
teammate: plain words, concrete facts, no AI tells. `scripts/draft-lint.sh` flags the mechanical
ones at the approval gate; the rest is judgment.

## Cut

- **Em dashes.** Use a period or a comma.
- **AI vocabulary.** delve, crucial, pivotal, tapestry, testament, underscore, showcase, foster,
  leverage, utilize, seamless, garner, intricate, vibrant. Use the plain word ("use", "shows",
  "important") or say the specific thing.
- **Chatbot phrases.** "Great question", "I hope this helps", "Let me know if...", "Happy to
  help", "You're absolutely right", "Certainly!". Answer directly.
- **Filler.** "in order to" → "to"; "due to the fact that" → "because"; "it is important to note
  that" → delete.
- **"Not just X, it's Y."** State the point.
- **Curly quotes.** Use straight quotes.
- **Inline-header lists** ("**Performance:** performance improved..."). Write the sentence.
- **Rule of three, synonym cycling, stacked hedges** ("could potentially possibly"). Use the
  natural count, one name per thing, one hedge at most.
- **Vague feeling words.** Not "this is concerning" but what breaks and when: "`retry()` loops
  forever when the token is expired".

## Keep

- Opinions with reasons. "I'd drop the cache here: it saves 2ms and adds an invalidation bug."
- Specifics: file:line, the command, the number.
- Short sentences, active voice, sentence-case headings.
