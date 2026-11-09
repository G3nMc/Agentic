import 'package:agentic/data/repositories/agent_role_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the "Maximum Auto Round Actions" setting.
///
/// Only the pure clamp helper and the bound constants are exercised: the
/// accessors themselves need SQLite, while the value contract that matters
/// (what the Settings panel shows == what the orchestrator receives) is fully
/// covered by [AgentRoleSettingsRepository.clampMaxAutoRounds].
void main() {
  group('AgentRoleSettingsRepository.clampMaxAutoRounds', () {
    test('lifts values below the minimum', () {
      expect(AgentRoleSettingsRepository.clampMaxAutoRounds(0), 1);
      expect(AgentRoleSettingsRepository.clampMaxAutoRounds(-3), 1);
      expect(AgentRoleSettingsRepository.clampMaxAutoRounds(-1000), 1);
    });

    test('keeps in-range values untouched', () {
      expect(AgentRoleSettingsRepository.clampMaxAutoRounds(1), 1);
      expect(AgentRoleSettingsRepository.clampMaxAutoRounds(7), 7);
      expect(AgentRoleSettingsRepository.clampMaxAutoRounds(20), 20);
      expect(AgentRoleSettingsRepository.clampMaxAutoRounds(200), 200);
    });

    test('caps values above the maximum', () {
      expect(AgentRoleSettingsRepository.clampMaxAutoRounds(201), 200);
      expect(AgentRoleSettingsRepository.clampMaxAutoRounds(1000), 200);
      expect(AgentRoleSettingsRepository.clampMaxAutoRounds(99999), 200);
    });

    test('is idempotent', () {
      for (final value in <int>[-5, 0, 1, 20, 200, 500]) {
        final once = AgentRoleSettingsRepository.clampMaxAutoRounds(value);
        final twice = AgentRoleSettingsRepository.clampMaxAutoRounds(once);
        expect(twice, once, reason: 'clamp($value) must be stable');
      }
    });
  });

  group('bounds', () {
    test('are ordered min <= default <= max', () {
      expect(
        AgentRoleSettingsRepository.minMaxAutoRounds <=
            AgentRoleSettingsRepository.defaultMaxAutoRounds,
        isTrue,
      );
      expect(
        AgentRoleSettingsRepository.defaultMaxAutoRounds <=
            AgentRoleSettingsRepository.maxMaxAutoRounds,
        isTrue,
      );
    });

    test('the default is inside the range', () {
      expect(
        AgentRoleSettingsRepository.clampMaxAutoRounds(
          AgentRoleSettingsRepository.defaultMaxAutoRounds,
        ),
        AgentRoleSettingsRepository.defaultMaxAutoRounds,
      );
    });

    test('match the Python defaults (20 / 1 / 200)', () {
      // Must stay in lockstep with `bin/agent/loop/run_loop.py`
      // (_DEFAULT_MAX_AUTO_ROUNDS / _MIN_AUTO_ROUNDS / _MAX_AUTO_ROUNDS_CAP):
      // the UI rewrites the field to the clamped value, so a divergence would
      // make the number on screen disagree with the loop's actual bound.
      expect(AgentRoleSettingsRepository.defaultMaxAutoRounds, 20);
      expect(AgentRoleSettingsRepository.minMaxAutoRounds, 1);
      expect(AgentRoleSettingsRepository.maxMaxAutoRounds, 200);
    });
  });

  group('maxAutoRoundsNotifier', () {
    test('starts at the default value', () {
      expect(
        AgentRoleSettingsRepository.instance.maxAutoRoundsNotifier.value,
        AgentRoleSettingsRepository.defaultMaxAutoRounds,
      );
    });
  });
}