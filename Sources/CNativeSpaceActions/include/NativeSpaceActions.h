#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

typedef enum {
    NPDockUnsupported = 0, NPDockLowTravel26 = 26, NPDockSerialized27 = 27
} NPDockProtocol;

// Protocol selection and event construction have no side effects.
NPDockProtocol NPDockProtocolForVersion(int major, int minor);
NPDockProtocol NPDockInstalledProtocol(void);
CGEventRef NPDockCopySwipeEvent(NPDockProtocol protocol, bool right, bool natural,
                                int phase, CGPoint point, uint64_t timestamp) CF_RETURNS_RETAINED;
CGEventRef NPDockCopyCompanion(NPDockProtocol protocol, CGPoint point, uint64_t timestamp) CF_RETURNS_RETAINED;
typedef struct {
    uint64_t phaseTimes[3];
    int protocolVersion;
    bool natural;
    double signedProgress;
    double endVelocity;
} NPDockDispatch;
bool NPSendAdjacentSwipe(bool right, CGDirectDisplayID intendedDisplay, NPDockDispatch *receipt);
bool NPMoveAvailable(void);
// Returns NULL when gated. The caller owns a prepared context through terminal readback.
CFTypeRef NPCreateWindowMove(uint32_t window, uint64_t space) CF_RETURNS_RETAINED;
typedef enum { NPMoveNotIssued, NPMoveSubmitted, NPMoveSubmissionUncertain } NPWindowMoveSubmission;
NPWindowMoveSubmission NPSubmitWindowMove(CFTypeRef context);
