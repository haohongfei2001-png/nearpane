#!/usr/bin/env python3
"""Keep platform, candidate engine, product UI and exact-target claims separate."""
ENGINE_CHECKS = frozenset(("launchCanary", "foreignRoundTrip", "sameAppIndependent", "crossAppGroup",
                           "repeatedSwitch", "yellowButton", "focusRestore", "cleanup"))
SYSTEM_CHECKS = ("yellowButtonRouting", "missionControl", "appExpose", "nativeFullScreen",
                 "nativeDesktopSwitch", "nativeDesktopReveal", "desktopGestures", "fullScreenSplitView",
                 "groupMergeSplit", "hostCrashRecovery")


def evaluate(engine, product=None, platform_diagnostic=None):
    checks = engine.get("checks", {})
    foreign_pass = (engine.get("status") == "FOREIGN_ENGINE_PASS" and engine.get("cleanup") is True
                    and engine.get("foreignProcesses") is True and engine.get("windowWrites", 0) > 0
                    and all(checks.get(name, {}).get("status") == "PASS" for name in ENGINE_CHECKS))
    target = engine.get("targetEnvironment", {})
    exact = target.get("kernelBuild") == "26A428" and target.get("sipEnabled") is True and target.get("exactTarget") is True
    product = product or {}
    product_pass = (product.get("status") == "PRODUCT_R4_PASS" and product.get("cleanup") is True
                    and product.get("actualR4Inputs", 0) > 0 and product.get("foreignWindowReadback") is True)
    platform_diagnostic = platform_diagnostic or {}
    platform_pass = (platform_diagnostic.get("status") == "PLATFORM_FOREIGN_PASS"
                     and platform_diagnostic.get("scope") == "platform-only-mechanism"
                     and platform_diagnostic.get("cleanup") is True
                     and platform_diagnostic.get("foreignProcesses") is True
                     and platform_diagnostic.get("completedForeignCycles") == 2
                     and platform_diagnostic.get("windowWrites", 0) >= 4
                     and platform_diagnostic.get("createdSpace", 0) > 0
                     and platform_diagnostic.get("numericHome", 0) > 0
                     and platform_diagnostic.get("qualificationGranted") is False
                     and platform_diagnostic.get("engineStateMachine") == "NOT_RUN"
                     and platform_diagnostic.get("R4ProductPath") == "NOT_RUN")
    return {
        "schema": 1,
        "platformForeignMechanism": "PASS" if platform_pass else (
            "UNKNOWN" if platform_diagnostic.get("status") == "PLATFORM_FOREIGN_PASS"
            else platform_diagnostic.get("status", "NOT_RUN")),
        "engine": "PASS" if foreign_pass else ("UNKNOWN" if engine.get("status") == "FOREIGN_ENGINE_PASS" else engine.get("status", "NOT_RUN")),
        "exactTargetEngine": "PASS" if foreign_pass and exact else "NOT_PROVEN",
        "R4ProductPath": "PASS" if product_pass else ("UNKNOWN" if product.get("status") == "PRODUCT_R4_PASS" else product.get("status", "NOT_RUN")),
        **{key: product.get(key, "NOT_RUN") for key in SYSTEM_CHECKS},
        "overall": "PASS" if foreign_pass and exact and product_pass and all(
            product.get(k) == "PASS" for k in SYSTEM_CHECKS) else "INCOMPLETE",
        "qualificationGranted": False,
    }
