#!/usr/bin/env python3
"""Keep platform, candidate engine, product UI and exact-target claims separate."""
ENGINE_CHECKS = frozenset(("launchCanary", "foreignRoundTrip", "sameAppIndependent", "crossAppGroup",
                           "repeatedSwitch", "yellowButton", "focusRestore", "cleanup"))


def evaluate(engine, product=None):
    checks = engine.get("checks", {})
    foreign_pass = (engine.get("status") == "FOREIGN_ENGINE_PASS" and engine.get("cleanup") is True
                    and engine.get("foreignProcesses") is True and engine.get("windowWrites", 0) > 0
                    and all(checks.get(name, {}).get("status") == "PASS" for name in ENGINE_CHECKS))
    target = engine.get("targetEnvironment", {})
    exact = target.get("kernelBuild") == "26A428" and target.get("sipEnabled") is True and target.get("exactTarget") is True
    product = product or {}
    product_pass = (product.get("status") == "PRODUCT_R4_PASS" and product.get("cleanup") is True
                    and product.get("actualR4Inputs", 0) > 0 and product.get("foreignWindowReadback") is True)
    return {
        "schema": 1,
        "engine": "PASS" if foreign_pass else ("UNKNOWN" if engine.get("status") == "FOREIGN_ENGINE_PASS" else engine.get("status", "NOT_RUN")),
        "exactTargetEngine": "PASS" if foreign_pass and exact else "NOT_PROVEN",
        "R4ProductPath": "PASS" if product_pass else ("UNKNOWN" if product.get("status") == "PRODUCT_R4_PASS" else product.get("status", "NOT_RUN")),
        "yellowButtonRouting": product.get("yellowButtonRouting", "NOT_RUN"),
        "missionControl": product.get("missionControl", "NOT_RUN"),
        "desktopGestures": product.get("desktopGestures", "NOT_RUN"),
        "fullScreenSplitView": product.get("fullScreenSplitView", "NOT_RUN"),
        "overall": "PASS" if foreign_pass and exact and product_pass and all(
            product.get(k) == "PASS" for k in ("missionControl", "desktopGestures", "fullScreenSplitView")) else "INCOMPLETE",
        "qualificationGranted": False,
    }
