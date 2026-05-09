import re

# Pure affirmations that should trigger immediate final response without
# further processing. These are distinct from mixed messages that combine
# praise with additional instructions.
_AFFIRMATION_RE = re.compile(
    r"^\s*(?:"
    r"great\s+work"
    r"|well\s+done"
    r"|perfect"
    r"|excellent"
    r"|awesome"
    r"|fantastic"
    r"|amazing"
    r"|outstanding"
    r"|brilliant"
    r"|superb"
    r"|incredible"
    r"|wonderful"
    r"|terrific"
    r"|fabulous"
    r"|marvelous"
    r"|impressive"
    r"|remarkable"
    r"|extraordinary"
    r"|phenomenal"
    r"|exceptional"
    r")[\s!.?]*$",
    re.IGNORECASE,
)

def _is_short_followup(text: str) -> bool:
    if not text:
        return False
    # Check for pure affirmations first - these should always trigger final response
    # Pure affirmations are those that don't contain action words
    if _AFFIRMATION_RE.match(text):
        # Make sure it's not a mixed message with action words
        lower_text = text.lower()
        action_words = ("proceed", "continue", "go", "do it", "next", "step", "follow", "execute", "run", "implement")
        if not any(word in lower_text for word in action_words):
            return True
    # Followup patterns that mean "execute the prior plan"
    _FOLLOWUP_RE = re.compile(
        r"^\s*(?:"
        r"ok(?:ay)?(?:\s+(?:proceed|go|do\s+it|continue|good))?"
        r"|yes(?:\s+(?:proceed|go|do\s+it|continue|please))?"
        r"|sure(?:\s+(?:do\s+it|go|proceed))?"
        r"|proceed|continue|go\s+ahead|do\s+it|fix\s+it|please\s+continue"
        r")[\s!.?]*$",
        re.IGNORECASE,
    )
    if _FOLLOWUP_RE.match(text):
        return True
    stripped = text.strip()
    return len(stripped) <= 25 and not any(
        m in stripped.lower() for m in (".dart", ".py", "lib/", "bin/", "git ")
    )

# Test cases
print("Testing pure affirmations:")
print(_is_short_followup("Great work"))  # Should be True
print(_is_short_followup("Well done"))   # Should be True
print(_is_short_followup("Perfect"))     # Should be True

print("\nTesting mixed messages:")
print(_is_short_followup("Great work, proceed with the next step"))  # Should be False
print(_is_short_followup("Well done, please continue"))             # Should be False
print(_is_short_followup("Perfect, go ahead"))                      # Should be False

print("\nTesting standard followups:")
print(_is_short_followup("OK"))          # Should be True
print(_is_short_followup("Yes, proceed")) # Should be True
print(_is_short_followup("Sure, go ahead")) # Should be True