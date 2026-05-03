# Task Decomposition Plan

## Initial Assessment
- **Finding**: No prior plan exists in the project.
- **Scope**: Strictly limited to the `task_decomposition` group within `bin/agent/team/`.
- **Constraint**: Each subtask ≤ 600 tokens.

---

## Step 1 — Analyze the Original Request

The original request is to implement a **task decomposition system** that breaks a high-level user goal into logical, manageable subtasks. The system must:

1. Accept a structured goal/constraints/success-criteria input.
2. Decompose the goal into ordered subtasks.
3. Enforce a per-subtask token budget (~600 tokens).
4. Track dependencies between subtasks.
5. Validate that all success criteria are covered by the resulting subtasks.

The target home is `bin/agent/team/task_decomposition/`, integrating with the existing team orchestration layer.

---

## Step 2 — Break Into Subtasks

### Subtask 1: Define Data Models
- **Description**: Create Pydantic/dataclass models for `Subtask`, `DecompositionPlan`, `Dependency`, and `SuccessCriterion`. These models represent the core data structures the rest of the system operates on.
- **Files**: `bin/agent/team/task_decomposition/models.py`

### Subtask 2: Implement Decomposition Engine
- **Description**: Build the core `TaskDecomposer` class that takes a goal, constraints, and success criteria, then produces a `DecompositionPlan` containing ordered `Subtask` objects. The engine applies heuristics (sequential splitting, dependency inference, token-budget enforcement).
- **Files**: `bin/agent/team/task_decomposition/engine.py`

### Subtask 3: Implement Dependency Resolver
- **Description**: Create a `DependencyResolver` that accepts a list of subtasks, infers or validates dependency edges between them, performs topological sort, and detects cycles. Outputs an ordered execution schedule.
- **Files**: `bin/agent/team/task_decomposition/dependency_resolver.py`

### Subtask 4: Implement Token Budget Validator
- **Description**: Build a `TokenBudgetValidator` that checks each subtask's estimated token count against the 600-token limit. If a subtask exceeds the limit, it flags it for further splitting. Returns a validation report.
- **Files**: `bin/agent/team/task_decomposition/token_validator.py`

### Subtask 5: Implement Success Criteria Mapper
- **Description**: Create a `CriteriaMapper` that maps each success criterion from the original request to one or more subtasks that satisfy it. Identifies any uncovered criteria and reports gaps.
- **Files**: `bin/agent/team/task_decomposition/criteria_mapper.py`

### Subtask 6: Create Public API / Facade
- **Description**: Build a `TaskDecompositionFacade` that orchestrates the engine, dependency resolver, token validator, and criteria mapper in a single call. This is the entry point the rest of the agent system uses.
- **Files**: `bin/agent/team/task_decomposition/api.py`

### Subtask 7: Write Unit Tests
- **Description**: Write pytest test suites for each module (models, engine, dependency resolver, token validator, criteria mapper, API). Tests cover happy paths, edge cases (cycles, oversized subtasks, uncovered criteria), and integration.
- **Files**: `bin/agent/team/task_decomposition/tests/`

### Subtask 8: Package and Register
- **Description**: Add `__init__.py` exports, update the team module's registration so the task_decomposition group is importable, and add a brief usage example in the module docstring.
- **Files**: `bin/agent/team/task_decomposition/__init__.py`, `bin/agent/team/__init__.py`

---

## Step 3 — Token Limit Check

| Subtask | Est. Tokens | Within 600? |
|---------|------------|-------------|
| 1. Data Models | ~400 | ✅ |
| 2. Decomposition Engine | ~550 | ✅ |
| 3. Dependency Resolver | ~500 | ✅ |
| 4. Token Budget Validator | ~350 | ✅ |
| 5. Success Criteria Mapper | ~400 | ✅ |
| 6. Public API / Facade | ~450 | ✅ |
| 7. Unit Tests | ~580 | ✅ |
| 8. Package and Register | ~250 | ✅ |

All subtasks are within the 600-token budget. No further splitting required.

---

## Step 4 — Assign Dependencies

```
Subtask 1 (Models)
  └── No dependencies (foundation)

Subtask 2 (Engine)        → depends on Subtask 1
Subtask 3 (Dep Resolver)  → depends on Subtask 1
Subtask 4 (Token Validator)→ depends on Subtask 1
Subtask 5 (Criteria Mapper)→ depends on Subtask 1

Subtask 6 (API / Facade)  → depends on Subtasks 2, 3, 4, 5

Subtask 7 (Tests)         → depends on Subtask 6

Subtask 8 (Package/Reg)    → depends on Subtask 7
```

Execution order: 1 → {2,3,4,5} (parallel) → 6 → 7 → 8

---

## Step 5 — Define Success Criteria

1. **Models exist** — `Subtask`, `DecompositionPlan`, `Dependency`, `SuccessCriterion` are defined and instantiable.
2. **Engine produces plans** — Given a goal + constraints + criteria, `TaskDecomposer.decompose()` returns a valid `DecompositionPlan`.
3. **Dependencies resolved** — `DependencyResolver.resolve()` returns a topologically-ordered list with no cycles.
4. **Token budget enforced** — `TokenBudgetValidator.validate()` flags any subtask exceeding 600 tokens.
5. **Criteria coverage** — `CriteriaMapper.map()` reports 100% coverage or lists gaps.
6. **Facade works end-to-end** — `TaskDecompositionFacade.run()` returns a complete, validated plan in one call.
7. **Tests pass** — All pytest cases pass with ≥ 90% line coverage.
8. **Module importable** — `from bin.agent.team.task_decomposition import TaskDecompositionFacade` succeeds.

---

## Final Summary

### Actions Taken
- Explored project structure (`bin/agent/`, `lib/`) to locate existing code and confirm no prior plan.
- Searched for `task_decomposition` references — none found.
- Confirmed no `.py` files exist yet in `bin/agent/` (only `__pycache__` directories remain).
- Created this plan document at `bin/agent/team/task_decomposition.md`.

### Files Modified
| File | Action |
|------|--------|
| `bin/agent/team/task_decomposition.md` | **Created** — this plan document |

### Warnings
- **No source files exist yet.** The `bin/agent/` directory tree has structure but zero `.py` files. The `__pycache__` directories suggest files were previously present and may have been removed. Before implementing, confirm whether the Python source was intentionally deleted or is missing due to a filter/environment issue.
- **No existing team integration.** Since `bin/agent/team/` has no Python files, the "Package and Register" subtask (8) will need to create the team module from scratch.
- **Token estimates are approximate.** Actual token counts should be validated during implementation using a tokenizer matching the target LLM.