"""Classic circuit-breaker for wrapping unreliable operations."""
from __future__ import annotations

import enum
import sys
import time
from typing import Optional


class CircuitState(enum.Enum):
    """States for the circuit-breaker pattern."""
    CLOSED    = "closed"     # Normal: requests go through.
    OPEN      = "open"       # Failing: requests are rejected immediately.
    HALF_OPEN = "half_open"  # Recovery probe: one request allowed through.


class CircuitBreaker:
    """
    Classic circuit-breaker for wrapping unreliable operations.

    Transitions:
      CLOSED  -> OPEN      when consecutive failures reach failure_threshold
      OPEN    -> HALF_OPEN after recovery_timeout seconds
      HALF_OPEN -> CLOSED  on success; back to OPEN on failure
    """

    def __init__(self, name: str = "unnamed", failure_threshold: int = 5,
                 recovery_timeout: float = 60.0):
        self.name = name
        self.failure_threshold = failure_threshold
        self.recovery_timeout = recovery_timeout
        self.state = CircuitState.CLOSED
        self.failure_count = 0
        self.last_failure_time: Optional[float] = None

    def allow_request(self) -> bool:
        """Return True when the caller should proceed with the operation."""
        if self.state == CircuitState.CLOSED:
            return True
        if self.state == CircuitState.OPEN:
            if (self.last_failure_time is not None
                    and time.time() - self.last_failure_time > self.recovery_timeout):
                self.state = CircuitState.HALF_OPEN
                print(f"[circuit-breaker:{self.name}] HALF-OPEN: testing recovery.",
                      file=sys.stderr, flush=True)
                return True
            return False
        # HALF_OPEN: let one probe through
        return True

    def record_success(self):
        """Call after a successful operation."""
        if self.state != CircuitState.CLOSED:
            print(f"[circuit-breaker:{self.name}] CLOSED (recovered).",
                  file=sys.stderr, flush=True)
        self.failure_count = 0
        self.state = CircuitState.CLOSED

    def record_failure(self):
        """Call after a failed operation."""
        self.failure_count += 1
        self.last_failure_time = time.time()
        if self.failure_count >= self.failure_threshold:
            if self.state != CircuitState.OPEN:
                print(
                    f"[circuit-breaker:{self.name}] OPEN after "
                    f"{self.failure_count} consecutive failures.",
                    file=sys.stderr, flush=True,
                )
            self.state = CircuitState.OPEN
