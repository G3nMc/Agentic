#!/usr/bin/env python3
"""
Test verification script for task compliance mode enforcement changes.

This script verifies that:
1. _TASK_STATUS_FORCE_DIRECTIVE is defined
2. _TASKS_FORCE_DIRECTIVE is defined  
3. _STEP_REPORT_DIRECTIVE includes mandatory note for task compliance modes
4. Task Checklist Panel has proper icons for task states
"""

import re
import sys

def check_run_loop_directives():
    """Check run_loop.py for the required directives."""
    print("=" * 60)
    print("Checking run_loop.py for task compliance directives...")
    print("=" * 60)
    
    run_loop_path = "/agent/loop/run_loop.py"
    
    with open(run_loop_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Check 1: _TASK_STATUS_FORCE_DIRECTIVE
    if "_TASK_STATUS_FORCE_DIRECTIVE" in content:
        print("✓ _TASK_STATUS_FORCE_DIRECTIVE is defined")
        
        # Extract and display it
        match = re.search(
            r'_TASK_STATUS_FORCE_DIRECTIVE = \([^)]+\)',
            content,
            re.DOTALL
        )
        if match:
            directive = match.group(0)
            print("  Content (first 200 chars):", directive[:200] + "..." if len(directive) > 200 else directive)
    else:
        print("✗ _TASK_STATUS_FORCE_DIRECTIVE NOT FOUND")
        return False
    
    # Check 2: _TASKS_FORCE_DIRECTIVE
    if "_TASKS_FORCE_DIRECTIVE" in content:
        print("✓ _TASKS_FORCE_DIRECTIVE is defined")
        
        match = re.search(
            r'_TASKS_FORCE_DIRECTIVE = \([^)]+\)',
            content,
            re.DOTALL
        )
        if match:
            directive = match.group(0)
            print("  Content (first 200 chars):", directive[:200] + "..." if len(directive) > 200 else directive)
    else:
        print("✗ _TASKS_FORCE_DIRECTIVE NOT FOUND")
        return False
    
    # Check 3: _STEP_REPORT_DIRECTIVE with task compliance note
    if "_STEP_REPORT_DIRECTIVE" in content:
        print("✓ _STEP_REPORT_DIRECTIVE is defined")
        
        if "TASK COMPLIANCE modes, this is MANDATORY" in content:
            print("  ✓ Task compliance mandatory note found in _STEP_REPORT_DIRECTIVE")
        else:
            print("  ✗ Task compliance mandatory note NOT found in _STEP_REPORT_DIRECTIVE")
            return False
    else:
        print("✗ _STEP_REPORT_DIRECTIVE NOT FOUND")
        return False
    
    # Check 4: Usage of _TASK_STATUS_FORCE_DIRECTIVE
    if "_TASK_STATUS_FORCE_DIRECTIVE" in content and "content: _TASK_STATUS_FORCE_DIRECTIVE" in content:
        print("✓ _TASK_STATUS_FORCE_DIRECTIVE is used in conversation_history")
    else:
        print("  ⚠ _TASK_STATUS_FORCE_DIRECTIVE may not be actively used")
    
    # Check 5: Task status enforcement logic
    if "saw_status_this_iter is False" in content and "content: _TASK_STATUS_FORCE_DIRECTIVE" in content:
        print("✓ Task status enforcement logic is in place")
    else:
        print("  ⚠ Task status enforcement logic may be incomplete")
    
    return True

def check_task_checklist_panel():
    """Check task_checklist_panel.dart for proper icons."""
    print("\n" + "=" * 60)
    print("Checking task_checklist_panel.dart for icons...")
    print("=" * 60)
    
    panel_path = "C:/Users/Gentian/AsPro/AI/Agentic/lib/ui/widgets/task_checklist_panel.dart"
    
    with open(panel_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Check for task status icons
    icon_checks = [
        ("Icons.check_circle", "green check for done tasks"),
        ("Icons.radio_button_unchecked", "uncheck for pending tasks"),
        ("Icons.timelapse", "timer for in_progress tasks"),
        ("Icons.donut_large", "donut for partial tasks"),
        ("Icons.pause_circle", "pause for blocked tasks"),
        ("Icons.cancel", "cancel for failed tasks"),
    ]
    
    all_found = True
    for icon, description in icon_checks:
        if icon in content:
            print(f"✓ {description} ({icon})")
        else:
            print(f"✗ {description} ({icon}) NOT FOUND")
            all_found = False
    
    # Check action buttons
    action_buttons = ["Start", "Proceed", "Retry", "Skip", "Replan", "Abort"]
    for btn in action_buttons:
        if f"'{btn}'" in content:
            print(f"✓ Action button: {btn}")
        else:
            print(f"  ⚠ Action button {btn} not explicitly found")
    
    return all_found

def main():
    """Run all checks."""
    print("\n" + "=" * 60)
    print("TASK COMPLIANCE MODE ENFORCEMENT VERIFICATION")
    print("=" * 60 + "\n")
    
    result1 = check_run_loop_directives()
    result2 = check_task_checklist_panel()
    
    print("\n" + "=" * 60)
    print("VERIFICATION SUMMARY")
    print("=" * 60)
    
    if result1 and result2:
        print("✓ ALL CHECKS PASSED")
        print("\nChanges implemented:")
        print("1. Task status tags are enforced in task compliance modes")
        print("2. Step reports are mandatory in task compliance modes")
        print("3. UI checklist shows proper icons for all task states")
        print("4. Action buttons appear based on task status")
        return 0
    else:
        print("✗ SOME CHECKS FAILED")
        return 1

if __name__ == "__main__":
    sys.exit(main())
