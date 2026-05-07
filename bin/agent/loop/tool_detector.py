import re
from typing import Tuple, Pattern


class ToolIntentDetector:
    """Heuristic that decides whether a user message needs the tool loop.

    Two-tier negatives:
      * HARD negatives — meta/explanatory phrasing always means chat
        ("how does X work", "explain", "tell me about", ...).
      * TOOL-TALK negatives — phrasing that discusses tools/functions as
        a *concept* ("make a custom tool", "design a new hook") is chat
        UNLESS a concrete file path/extension is also present, in which
        case the user is asking us to write that thing in a real file.

    Two-tier positives:
      * High-confidence patterns — "git commit", "run the tests",
        "read the file at ..." — always tools.
      * Problem reports — "X doesn't work", "is broken", combined with a
        UI/feature word ("chat view", "app crashed"). These are tools
        even when no path/extension is mentioned.

    Fallback: an action verb plus a file/code marker, both checked with
    word boundaries so "thread" no longer matches "read", "research"
    no longer matches "search", and "profile" no longer matches "file".
    """

    # ------------------------------------------------------------------
    # HARD negatives — always chat regardless of other signals
    # ------------------------------------------------------------------
    _HARD_NEGATIVE_PATTERNS: Tuple[Pattern, ...] = (
        re.compile(r"\bhow\s+(to|do|does|did|can|could|should|would)\b"),
        re.compile(r"\bwhat\s+(is|are|was|were|does|do|did|would|should|if)\b"),
        re.compile(r"\bwhy\s+(is|are|was|were|does|do|did|would|should)\b"),
        re.compile(r"\bwhen\s+(to|should|would|do|does)\s+\w+"),
        re.compile(r"\bwhich\s+(is|are|one|of)\b"),
        re.compile(r"\bexplain\b"),
        re.compile(r"\btheor(y|ies|etical)\b"),
        re.compile(r"\bconcept(s|ual(ly)?)?\b"),
        re.compile(r"\bbest\s+practice"),
        re.compile(r"\bexamples?\b"),
        re.compile(r"\btutorials?\b"),
        re.compile(r"\bdiscuss(ion|ing)?\b"),
        re.compile(r"\btell\s+me\s+about\b"),
        re.compile(r"\bdescribe\b"),
        re.compile(r"\boverview\b"),
        re.compile(r"\bintroduction\s+to\b"),
        re.compile(r"\bdifference\s+between\b"),
        re.compile(r"\bpros\s+and\s+cons\b"),
        re.compile(r"\bvs\.?\b"),
        re.compile(r"\bcomparison\b"),
        re.compile(r"\bwhat\s+do\s+you\s+think\b"),
        re.compile(r"\b(your|any)\s+opinion\b"),
        re.compile(r"\brecommend(ation)?\b"),
    )

    # ------------------------------------------------------------------
    # TOOL-TALK negatives — chat unless a file marker is also present
    # ------------------------------------------------------------------
    # The "thing" group lists abstractions the user might propose to
    # build/design rather than concrete code in a real file.
    _TOOL_TALK_PATTERNS: Tuple[Pattern, ...] = (
        re.compile(
            r"\b(make|create|add|build|design|implement|need|want|write|"
            r"propose|suggest|sketch|plan|outline)\b"
            r"[^.\n]{0,40}?"
            r"\b(tool|function|action|capability|skill|agent|"
            r"detector|parser|hook|plugin|prompt|heuristic|rule|policy|"
            r"system|module|component|feature)s?\b"
        ),
        re.compile(
            r"\b(another|new|custom|extra|additional)\s+"
            r"(tool|function|action|capability|skill|agent|"
            r"detector|parser|hook|plugin|module|component|feature)s?\b"
        ),
        re.compile(
            r"\b(tool|hook|parser|detector|prompt|policy)s?\s+"
            r"(definition|schema|format|spec(ification)?|registry|"
            r"interface|contract|design)\b"
        ),
        # Explicit tool-discussion patterns — talking ABOUT tools, not using them
        re.compile(r"\b(tool|function)s?\s+(usage|use|calling|invocation|execution)\b"),
        re.compile(r"\bhow\s+tools?\s+work\b"),
        re.compile(r"\bunderstand\s+tools?\b"),
        re.compile(r"\btool\s+(system|architecture|design|flow|pipeline|loop)\b"),
        re.compile(r"\btool\s+(detection|detector|dispatch|dispatching)\b"),
        re.compile(r"\b(tool|function)\s+call(ing)?\b"),
        re.compile(r"\bidea\s+(for|about)\b"),
        re.compile(r"\bthoughts?\s+on\b"),
        re.compile(r"\bbrainstorm\b"),
    )

    # ------------------------------------------------------------------
    # File / code markers (word-boundary)
    #
    # STRONG markers are concrete pointers — extensions, repo-relative
    # paths, the literal word "codebase". A strong marker overrides
    # tool-talk negatives because the user is naming a real artifact.
    #
    # WEAK markers are generic nouns ("file", "folder", "path") that
    # often appear in conceptual discussion. They contribute to the
    # action+marker fallback but don't override tool-talk.
    # ------------------------------------------------------------------
    _STRONG_FILE_MARKER_PATTERNS: Tuple[Pattern, ...] = tuple(
        re.compile(p) for p in (
            r"\.(?:dart|py|js|ts|tsx|jsx|json|yaml|yml|md|txt|csv|xml|"
            r"toml|ini|cfg|sh|ps1|sql|html|css|scss|rs|go|java|kt|swift)\b",
            r"\b(?:lib|src|bin|test|tests|assets|config|scripts|app|"
            r"public|build|dist|node_modules|vendor)/",
            r"\bcodebase\b",
        )
    )

    _WEAK_FILE_MARKER_PATTERNS: Tuple[Pattern, ...] = tuple(
        re.compile(p) for p in (
            r"\bfiles?\b",
            r"\bfolders?\b",
            r"\bdirector(y|ies)\b",
            r"\bpaths?\b",
            r"\brepo(sitor(y|ies))?\b",
            r"\bproject\s+(file|folder|director|root)",
        )
    )

    # ------------------------------------------------------------------
    # Action verbs (word-boundary, with common conjugations)
    # ------------------------------------------------------------------
    _ACTION_VERB_PATTERNS: Tuple[Pattern, ...] = tuple(
        re.compile(rf"\b{v}\b") for v in (
            "fix", "fixes", "fixed",
            "edit", "edits", "edited",
            "modify", "modifies", "modified",
            "change", "changes", "changed",
            "update", "updates", "updated",
            "refactor", "refactors", "refactored",
            "rename", "renames", "renamed",
            "create", "creates", "created",
            "delete", "deletes", "deleted",
            "remove", "removes", "removed",
            "add", "adds", "added",
            "implement", "implements", "implemented",
            "write", "writes", "wrote", "written",
            "run", "runs", "ran",
            "build", "builds", "built",
            "compile", "compiles", "compiled",
            "test", "tests", "tested",
            "install", "installs", "installed",
            "deploy", "deploys", "deployed",
            "execute", "executes", "executed",
            "read", "reads",
            "open", "opens", "opened",
            "show", "shows", "showed",
            "list", "lists", "listed",
            "find", "finds", "found",
            "search", "searches", "searched",
            "save", "saves", "saved",
            "download", "downloads", "downloaded",
            "upload", "uploads", "uploaded",
            "export", "exports", "exported",
            "import", "imports", "imported",
            "copy", "copies", "copied",
            "move", "moves", "moved",
            "clone", "clones", "cloned",
        )
    )

    # ------------------------------------------------------------------
    # Git markers (word-boundary)
    # ------------------------------------------------------------------
    _GIT_MARKER_PATTERNS: Tuple[Pattern, ...] = tuple(
        re.compile(rf"\b{g}\b") for g in (
            "git", "commit", "commits", "branch", "branches",
            "merge", "merges", "merged",
            "push", "pushes", "pushed",
            "pull", "pulls", "pulled",
            "diff", "diffs",
            "rebase", "stash", "checkout", "checkouts",
            "fetch", "fetches", "fetched",
            "reset", "blame",
        )
    )

    # ------------------------------------------------------------------
    # High-confidence positive patterns
    # ------------------------------------------------------------------
    _TOOL_INTENT_PATTERNS: Tuple[Pattern, ...] = (
        re.compile(r"\bflutter\s+analy[sz]e\b"),
        re.compile(r"\bflutter\s+(test|run|build|pub|clean)\b"),
        re.compile(r"\b(get-content|select-string|findstr|grep|cat|less|head|tail)\b"),
        re.compile(
            r"\b(export|download|save)\b[^.\n]*"
            r"\b(chat|conversation|history|log)\b[^.\n]*\bjson\b"
        ),
        re.compile(
            r"\b(read|open|search|find|list)\s+"
            r"(the\s+|a\s+|all\s+|every\s+|this\s+)?"
            r"(file|folder|directory|repo|project|module|codebase)\b"
        ),
        re.compile(
            r"\b(show|list|display)\s+(the\s+|a\s+)?"
            r"(code|content|contents|source|tree|structure)\b"
        ),
        re.compile(
            r"\b(edit|modify|change|update|patch)\s+"
            r"(the\s+|a\s+|this\s+|that\s+)?"
            r"(file|code|function|class|method|line|import|config)\b"
        ),
        re.compile(
            r"\b(create|delete|remove|add)\s+"
            r"(a\s+|the\s+|new\s+|another\s+)?"
            r"(file|folder|directory|repo|branch|test|module|class|"
            r"variable|import|line)\b"
        ),
        re.compile(
            r"\b(run|build|compile|test|deploy)\s+"
            r"(the\s+|this\s+|a\s+)?"
            r"(project|app|code|program|test|suite|module|script|server)\b"
        ),
        re.compile(r"\b(git\s+)?(commit|push|pull|merge|rebase|checkout)\b"),
    )

    # ------------------------------------------------------------------
    # Problem-report patterns — work + UI feature → tool mode
    # ------------------------------------------------------------------
    _PROBLEM_REPORT_PATTERNS: Tuple[Pattern, ...] = (
        re.compile(r"\b(doesn'?t|does\s+not|isn'?t|is\s+not|won'?t|will\s+not|can'?t|cannot)\s+work"),
        re.compile(r"\bnot\s+work(ing)?\b"),
        re.compile(r"\b(is|are|seems?|looks?|gets?)\s+broken\b"),
        re.compile(r"\bbroken\b"),
        re.compile(r"\b(there'?s|there\s+is|there\s+are)\s+(a\s+|an\s+|some\s+)?(bug|issue|problem|error|glitch)s?\b"),
        re.compile(r"\b(fix|debug|investigate|diagnose)\s+(the|this|a|an)?\s*(bug|issue|problem|error|crash|glitch)\b"),
        re.compile(r"\bcrash(es|ing|ed)?\b"),
        re.compile(r"\bfails?\s+(to|with|when)\b"),
        re.compile(r"\bfailing\b"),
        re.compile(r"\bnot\s+(display(ing|ed)?|show(ing|n)?|render(ing|ed)?|load(ing|ed)?|appear(ing|ed)?|respond(ing|ed)?)\b"),
        re.compile(r"\bsomething\s+(is\s+|seems\s+|looks\s+)?wrong\b"),
        re.compile(r"\b(wrong|unexpected|incorrect)\s+(behavior|behaviour|output|result|value|state)\b"),
        re.compile(r"\bdoesn'?t\s+(work|render|load|show|display|respond|behave)\s+(as|like)"),
        re.compile(r"\b(throws?|throwing|raises?|raising)\s+(an?\s+)?(error|exception)\b"),
        re.compile(r"\bstuck\b"),
        re.compile(r"\bhang(s|ing|ed)?\b"),
        re.compile(r"\bfreezes?\b"),
    )

    # ------------------------------------------------------------------
    # UI / feature words — combined with a problem report → tool mode
    # ------------------------------------------------------------------
    _UI_FEATURE_PATTERNS: Tuple[Pattern, ...] = (
        re.compile(
            r"\b(view|page|screen|widget|panel|tab|button|dialog|menu|"
            r"sidebar|window|component|form|input|field|list|card|toolbar|"
            r"modal|drawer|navbar|header|footer|tooltip|popup)s?\b"
        ),
        re.compile(r"\bchat\b"),
        re.compile(r"\bui\b"),
        re.compile(r"\bapp\b"),
        re.compile(r"\b(frontend|front-end|backend|back-end)\b"),
        re.compile(r"\bserver\b"),
        re.compile(r"\bdaemon\b"),
        re.compile(r"\borchestrator\b"),
        re.compile(r"\bworker\b"),
        re.compile(r"\bagent\b"),
    )

    # ------------------------------------------------------------------
    @classmethod
    def needs_tools(cls, text: str) -> bool:
        """Return True only if the message likely requires a tool call."""
        if not text:
            return False
        t = text.lower()

        # 1. Hard negatives — always chat.
        if any(p.search(t) for p in cls._HARD_NEGATIVE_PATTERNS):
            return False

        # Compute markers up front; tool-talk and the fallback both
        # depend on them. Tool-talk is overridden only by STRONG markers
        # (concrete paths/extensions); WEAK markers ("files", "folder")
        # can still appear in conceptual discussion.
        strong_markers_present = any(
            p.search(t) for p in cls._STRONG_FILE_MARKER_PATTERNS
        )
        weak_markers_present = any(
            p.search(t) for p in cls._WEAK_FILE_MARKER_PATTERNS
        )
        file_markers_present = strong_markers_present or weak_markers_present

        # 2. Tool-talk negatives — chat *unless* a strong file marker
        #    is also present (in which case the user really wants the
        #    code written in that file).
        if not strong_markers_present and any(
            p.search(t) for p in cls._TOOL_TALK_PATTERNS
        ):
            return False

        # 3. High-confidence positives.
        if any(p.search(t) for p in cls._TOOL_INTENT_PATTERNS):
            return True

        # 4. Problem reports + UI/feature word → tools.
        problem_present = any(
            p.search(t) for p in cls._PROBLEM_REPORT_PATTERNS
        )
        if problem_present:
            ui_present = any(
                p.search(t) for p in cls._UI_FEATURE_PATTERNS
            )
            if ui_present or file_markers_present:
                return True

        # 5. Fallback: action verb + file marker, or git term + either.
        action_verbs_present = any(
            p.search(t) for p in cls._ACTION_VERB_PATTERNS
        )
        git_markers_present = any(
            p.search(t) for p in cls._GIT_MARKER_PATTERNS
        )

        if git_markers_present and (action_verbs_present or file_markers_present):
            return True

        if file_markers_present and action_verbs_present:
            return True

        return False
